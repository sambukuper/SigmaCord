//! Voz de verdade: gateway de voz (v8), UDP, Opus, DAVE (E2EE) e SDL3.
//!
//! Tudo roda numa thread própria, criada só quando alguém entra numa call.
//! Fora de uma call este módulo não consome CPU: o app nem inicializa o áudio.
//!
//! O protocolo segue a documentação do Discord e do DAVE (https://daveprotocol.com):
//!   - WebSocket v8 com heartbeat (seq_ack) e RESUME quando a conexão cai;
//!   - IP discovery (pacote de 74 bytes) e Select Protocol;
//!   - RTP com aead_xchacha20_poly1305_rtpsize;
//!   - Opus 48 kHz estéreo, 20 ms por pacote, só enquanto alguém fala;
//!   - DAVE/MLS via libdave para as chamadas de hoje em dia.
//!
//! Áudio: o SDL3 mistura. Cada pessoa da call tem um SDL_AudioStream ligado
//! ao mesmo dispositivo de saída (o volume dela é o ganho do stream) e o
//! microfone é um stream lido a cada 20 ms. Nada de callback de áudio nem
//! buffer dividido entre threads. O que abrir e como (dispositivo pelo nome,
//! volumes, limiar, aperte para falar, filtros) vem de net/voz_audio.zig e de
//! core/voz.zig; o medidor e o teste de microfone das Configurações usam o
//! mesmo código numa thread à parte.
//!
//! `local` (a demonstração): só a metade do áudio, sem rede. O microfone, a
//! detecção de voz e o aviso de falha valem de verdade; nada sai do computador.
//!
//! SIGMACORD_VOICE_DEBUG=1 mostra no terminal o que acontece na call (opcodes,
//! códigos de fechamento, DAVE). Nunca imprime token nem chaves.
const std = @import("std");
const sys = @import("../platform/sys.zig");
const c = @import("c");
const types = @import("../core/types.zig");
const ev = @import("../core/event.zig");
const Sink = @import("fake_gateway.zig").Sink;
const i18n = @import("../ui/i18n.zig");
const j = @import("jsonx.zig");
const voz = @import("../core/voz.zig");
const voz_audio = @import("voz_audio.zig");

const Id = types.Id;
const alloc = std.heap.c_allocator;
const nowMs = @import("fake_gateway.zig").nowMs;

const opus_rate = 48000;
const frame_ms = 20;
const frame_samples = opus_rate * frame_ms / 1000; // 960
const channels = 2;
const frame_bytes = frame_samples * channels * @sizeOf(i16); // 3840
const bytes_per_ms = opus_rate * channels * @sizeOf(i16) / 1000; // 192
const silence = [_]u8{ 0xF8, 0xFF, 0xFE };

fn queuedMs(st: *c.SDL_AudioStream) u32 {
    return @intCast(@divTrunc(@max(c.SDL_GetAudioStreamQueued(st), 0), bytes_per_ms));
}

var debug_on = false;

fn debugOn() bool {
    return debug_on or @import("../platform/debug_log.zig").isOn();
}

fn dbg(comptime fmt: []const u8, args: anytype) void {
    if (debugOn()) std.log.info("voz: " ++ fmt, args);
}

/// Como a thread terminou (o gateway principal decide o que fazer).
pub const Ended = enum(u8) {
    running,
    /// Pedido nosso (saiu da call, trocou de canal).
    stopped,
    /// O Discord encerrou de vez (sessão inválida, recusou…): já avisou o app.
    fatal,
    /// 4014: o servidor de voz mudou ou alguém nos moveu. Espera um
    /// VOICE_SERVER_UPDATE novo para recomeçar.
    moved,
};

pub const Voice = struct {
    sink: Sink,
    guild: Id = 0,
    /// Muda quando alguém nos move de canal (o grupo do DAVE é o canal).
    channel: std.atomic.Value(Id) = .init(0),
    user: Id = 0,
    endpoint: [256]u8 = @splat(0),
    endpoint_len: usize = 0,
    token: [256]u8 = @splat(0),
    token_len: usize = 0,
    session: [128]u8 = @splat(0),
    session_len: usize = 0,
    muted: std.atomic.Value(bool) = .init(false),
    deafened: std.atomic.Value(bool) = .init(false),
    stopping: std.atomic.Value(bool) = .init(false),
    ended: std.atomic.Value(Ended) = .init(.running),
    thread: ?*c.SDL_Thread = null,
    volume_mutex: ?*c.SDL_Mutex = null,
    volumes: std.AutoHashMapUnmanaged(Id, f32) = .empty,
    /// Sobe a cada mudança de volume (a thread de voz reaplica os ganhos).
    volumes_gen: std.atomic.Value(u32) = .init(0),
    /// Sem rede: só o microfone e a detecção de voz (a demonstração).
    local: bool = false,

    pub fn init(sink: Sink, guild: Id, channel: Id, user: Id, endpoint: []const u8, token: []const u8, session: []const u8, mute: bool, deaf: bool) Voice {
        var v: Voice = .{ .sink = sink, .guild = guild, .user = user };
        v.channel = .init(channel);
        v.endpoint_len = @min(endpoint.len, v.endpoint.len - 1);
        @memcpy(v.endpoint[0..v.endpoint_len], endpoint[0..v.endpoint_len]);
        v.token_len = @min(token.len, v.token.len - 1);
        @memcpy(v.token[0..v.token_len], token[0..v.token_len]);
        v.session_len = @min(session.len, v.session.len - 1);
        @memcpy(v.session[0..v.session_len], session[0..v.session_len]);
        v.muted = .init(mute);
        v.deafened = .init(deaf);
        v.volume_mutex = c.SDL_CreateMutex();
        return v;
    }

    pub fn start(v: *Voice) !void {
        debug_on = c.SDL_getenv("SIGMACORD_VOICE_DEBUG") != null;
        v.thread = c.SDL_CreateThread(threadMain, "voice", v) orelse return error.SdlThread;
    }

    pub fn stop(v: *Voice) void {
        v.stopping.store(true, .release);
        if (v.thread) |t| {
            c.SDL_WaitThread(t, null);
            v.thread = null;
        }
    }

    pub fn deinit(v: *Voice) void {
        std.crypto.secureZero(u8, &v.token);
        std.crypto.secureZero(u8, &v.session);
        v.volumes.deinit(alloc);
        if (v.volume_mutex) |m| c.SDL_DestroyMutex(m);
    }

    pub fn setFlags(v: *Voice, mute: bool, deaf: bool) void {
        v.muted.store(mute, .release);
        v.deafened.store(deaf, .release);
    }

    pub fn setVolume(v: *Voice, user: Id, gain: f32) void {
        c.SDL_LockMutex(v.volume_mutex);
        defer c.SDL_UnlockMutex(v.volume_mutex);
        v.volumes.put(alloc, user, std.math.clamp(gain, 0, 2)) catch {};
        _ = v.volumes_gen.fetchAdd(1, .release);
    }

    /// Mudo por nós ou pelo servidor: nada de transmitir (nem abrir o microfone).
    fn micBlocked(v: *Voice) bool {
        return v.muted.load(.acquire) or v.deafened.load(.acquire) or
            voz_audio.sh.server_mute.load(.acquire) or voz_audio.sh.server_deaf.load(.acquire);
    }

    fn outBlocked(v: *Voice) bool {
        return v.deafened.load(.acquire) or voz_audio.sh.server_deaf.load(.acquire);
    }

    fn volumeOf(v: *Voice, user: Id) f32 {
        c.SDL_LockMutex(v.volume_mutex);
        defer c.SDL_UnlockMutex(v.volume_mutex);
        return v.volumes.get(user) orelse 1;
    }

    fn emit(v: *Voice, e: ev.Event) void {
        v.sink.push(v.sink.ctx, e);
    }

    fn status(v: *Voice, st: ev.VoiceStatus) void {
        v.emit(.{ .voice_status = .{ .status = st, .channel = v.channel.load(.acquire) } });
    }

    fn notice(v: *Voice, comptime pt: []const u8, comptime en: []const u8, args: anytype) void {
        const s = i18n.allocPrint(alloc, pt, en, args) catch return;
        v.emit(.{ .notice = s });
    }

    fn threadMain(data: ?*anyopaque) callconv(.c) c_int {
        const v: *Voice = @ptrCast(@alignCast(data.?));
        // Compilar ou abrir imagens em paralelo não pode picotar a call.
        _ = c.SDL_SetCurrentThreadPriority(c.SDL_THREAD_PRIORITY_HIGH);
        voz_audio.in_call.store(true, .release);
        defer voz_audio.in_call.store(false, .release);
        if (!v.local) v.status(.connecting);
        // O Worker tem buffers grandes: no heap, não na pilha da thread.
        const worker = alloc.create(Worker) catch {
            v.ended.store(.fatal, .release);
            v.status(.disconnected);
            return 0;
        };
        defer alloc.destroy(worker);
        worker.* = .{ .v = v };
        const how = if (v.local) worker.runLocal() else worker.run();
        v.ended.store(how, .release);
        if (how == .fatal) v.status(.disconnected);
        return 0;
    }
};

// ---------------------------------------------------------------------------
// Estado da conexão (só existe na thread de voz)
// ---------------------------------------------------------------------------

/// Por que o laço da conexão parou.
const End = enum { stop, fatal, moved, resume_ws };

const Worker = struct {
    v: *Voice,
    ws: ?*c.CURL = null,
    ws_sock: sys.Socket = sys.no_socket,
    udp: sys.Socket = sys.no_socket,
    server: sys.SockAddrIn = undefined,
    ssrc: u32 = 0,
    secret: [32]u8 = @splat(0),
    have_secret: bool = false,
    rtp_seq: u16 = 0,
    rtp_ts: u32 = 0,
    nonce: u32 = 0,
    hb_interval: i64 = 13750,
    next_hb: i64 = std.math.maxInt(i64),
    hb_acked: bool = true,
    hb_sent_ms: i64 = 0,
    next_frame: i64 = 0,
    next_keepalive: i64 = 0,
    pull_ms: u32 = 22,
    last_seq: i64 = -1,
    connected: bool = false,
    resuming: bool = false,
    end: ?End = null,
    dave: ?Dave = null,
    /// Quem está na call e de quem é cada SSRC. Chegam (op 11, 5, 18, 20)
    /// antes da descrição da sessão, quando o DAVE ainda nem existe: ficam
    /// aqui e entram no DAVE quando ele nasce.
    call_users: std.AutoHashMapUnmanaged(Id, void) = .empty,
    call_ssrcs: std.AutoHashMapUnmanaged(u32, Id) = .empty,
    encoder: ?*c.OpusEncoder = null,
    // Áudio.
    audio_on: bool = false,
    out: voz_audio.Output = .{},
    mic: voz_audio.Mic = .{},
    /// O que já avisamos à interface sobre o microfone e a saída.
    mic_ok_sent: bool = true,
    out_ok_sent: bool = true,
    deaf_applied: bool = false,
    volumes_gen: u32 = 0,
    sources: [32]Source = undefined,
    n_sources: usize = 0,
    // Detecção de fala (nossa).
    cap: voz.Capture = .{},
    talk: voz.Talk = .{},
    speaking_now: bool = false,
    speaking_emit_ms: i64 = 0,
    trailing_silence: u8 = 0,
    /// O próximo pacote é o primeiro de uma fala (bit de marcação do RTP).
    spurt_start: bool = true,
    // Diagnóstico (SIGMACORD_VOICE_DEBUG).
    mic_peak_rms: f64 = 0,
    stats: Stats = .{},
    sent_frames: u64 = 0,
    stats_ms: i64 = 0,
    ws_in: std.ArrayList(u8) = .empty,
    in_buf: [65536]u8 = undefined,
    url_buf: [320]u8 = undefined,

    fn run(w: *Worker) Ended {
        defer w.cleanup();
        const url = w.buildUrl() orelse {
            w.v.notice("endereço de voz inválido", "invalid voice endpoint", .{});
            return .fatal;
        };
        if (!w.initAudio()) {
            // Sem placa/microfone ainda dá para ficar na call (o Discord
            // derruba quem não responde, não quem não fala).
            std.log.warn("voz: sem dispositivo de áudio", .{});
        }
        var tries: u8 = 0;
        while (!w.v.stopping.load(.acquire)) {
            if (!w.connectWs(url)) {
                tries += 1;
                if (tries > 3) {
                    w.v.notice("não consegui abrir a conexão de voz", "couldn't open the voice connection", .{});
                    return .fatal;
                }
                w.pause(@as(i64, tries) * 1000);
                continue;
            }
            w.end = null;
            w.next_hb = std.math.maxInt(i64);
            w.hb_acked = true;
            const opened_ms = nowMs();
            const how = w.loop();
            w.closeWs();
            // Ficou de pé um bom tempo: esta queda não é a mesma de antes.
            if (nowMs() - opened_ms >= 30_000) tries = 0;
            switch (how) {
                .stop => return .stopped,
                .fatal => return .fatal,
                .moved => return .moved,
                .resume_ws => {
                    tries += 1;
                    if (tries > 3) {
                        w.v.notice("a call caiu e não voltou", "the call dropped and didn't come back", .{});
                        return .fatal;
                    }
                    // Sem sessão completa ainda (sem chave): começa do zero.
                    w.resuming = w.have_secret;
                    dbg("reconectando (tentativa {d}, resume={})", .{ tries, w.resuming });
                    w.v.status(.connecting);
                    w.pause(@as(i64, tries) * 500);
                },
            }
        }
        return .stopped;
    }

    /// A demonstração: o áudio da call sem a call. Mesmo caminho até a hora de
    /// mandar o pacote (`sendRtp` não faz nada sem a chave).
    fn runLocal(w: *Worker) Ended {
        defer w.cleanup();
        _ = w.initAudio();
        w.next_frame = nowMs();
        while (!w.v.stopping.load(.acquire)) {
            const now = nowMs();
            w.applyAudioFlags();
            w.audioPoll(now);
            if (now >= w.next_frame) {
                w.sendFrame(now);
                w.next_frame += frame_ms;
                if (w.next_frame < now - 100) w.next_frame = now + frame_ms;
            }
            c.SDL_Delay(@intCast(std.math.clamp(w.next_frame - nowMs(), 1, frame_ms)));
        }
        return .stopped;
    }

    /// Espera sem travar o pedido de parar.
    fn pause(w: *Worker, ms: i64) void {
        const until = nowMs() + ms;
        while (nowMs() < until and !w.v.stopping.load(.acquire)) c.SDL_Delay(50);
    }

    fn buildUrl(w: *Worker) ?[:0]u8 {
        var ep: []const u8 = w.v.endpoint[0..w.v.endpoint_len];
        if (std.mem.startsWith(u8, ep, "wss://")) ep = ep[6..];
        if (std.mem.startsWith(u8, ep, "https://")) ep = ep[8..];
        if (ep.len == 0) return null;
        return std.fmt.bufPrintSentinel(&w.url_buf, "wss://{s}/?v=8", .{ep}, 0) catch null;
    }

    fn connectWs(w: *Worker, url: [:0]const u8) bool {
        const h = c.curl_easy_init() orelse return false;
        sys.curlTls(h);
        w.ws = h;
        _ = c.curl_easy_setopt(h, c.CURLOPT_URL, url.ptr);
        _ = c.curl_easy_setopt(h, c.CURLOPT_NOSIGNAL, @as(c_long, 1));
        _ = c.curl_easy_setopt(h, c.CURLOPT_CONNECT_ONLY, @as(c_long, 2));
        _ = c.curl_easy_setopt(h, c.CURLOPT_CONNECTTIMEOUT_MS, @as(c_long, 4000));
        _ = c.curl_easy_setopt(h, c.CURLOPT_HTTP_VERSION, @as(c_long, c.CURL_HTTP_VERSION_1_1));
        _ = c.curl_easy_setopt(h, c.CURLOPT_USERAGENT, @as([*c]const u8, @ptrCast("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36")));
        const rc = c.curl_easy_perform(h);
        if (rc != c.CURLE_OK) {
            std.log.warn("voz: curl {d}: {s}", .{ rc, c.curl_easy_strerror(rc) });
            w.closeWs();
            return false;
        }
        var sock: sys.Socket = sys.no_socket;
        _ = c.curl_easy_getinfo(h, c.CURLINFO_ACTIVESOCKET, &sock);
        if (!sys.valid(sock)) {
            w.closeWs();
            return false;
        }
        w.ws_sock = sock;
        dbg("websocket aberto", .{});
        return true;
    }

    fn closeWs(w: *Worker) void {
        if (w.ws) |h| c.curl_easy_cleanup(h);
        w.ws = null;
        w.ws_sock = sys.no_socket;
        w.ws_in.clearRetainingCapacity();
    }

    fn cleanup(w: *Worker) void {
        for (w.sources[0..w.n_sources]) |*s| s.deinit();
        w.n_sources = 0;
        w.cap.release();
        w.mic.close();
        w.out.close();
        if (w.audio_on) voz_audio.release();
        if (w.encoder) |e| c.opus_encoder_destroy(e);
        if (w.dave) |*d| d.deinit();
        if (sys.valid(w.udp)) sys.closeSocket(w.udp);
        w.closeWs();
        std.crypto.secureZero(u8, &w.secret);
        w.ws_in.deinit(alloc);
        w.call_users.deinit(alloc);
        w.call_ssrcs.deinit(alloc);
    }

    fn addCallUser(w: *Worker, uid: Id) void {
        w.call_users.put(alloc, uid, {}) catch {};
        if (w.dave) |*dave| dave.addUser(uid);
    }

    fn loop(w: *Worker) End {
        while (w.end == null) {
            if (w.v.stopping.load(.acquire)) return .stop;
            const now = nowMs();
            const next = if (w.connected) @min(w.next_hb, w.next_frame) else w.next_hb;
            const wait: c_int = @intCast(std.math.clamp(next - now, 0, 50));
            w.waitSockets(wait);
            const woke = nowMs();
            w.stats.wake_late_ms = @max(w.stats.wake_late_ms, woke - now - wait);
            w.readWs();
            w.readUdp();
            w.tick(nowMs());
            w.stats.busy_ms = @max(w.stats.busy_ms, nowMs() - woke);
        }
        return w.end.?;
    }

    fn waitSockets(w: *Worker, timeout_ms: c_int) void {
        var fds: [2]sys.PollFd = undefined;
        var n: usize = 0;
        if (sys.valid(w.ws_sock)) {
            fds[n] = .{ .fd = w.ws_sock, .events = c.POLLIN, .revents = 0 };
            n += 1;
        }
        if (sys.valid(w.udp)) {
            fds[n] = .{ .fd = w.udp, .events = c.POLLIN, .revents = 0 };
            n += 1;
        }
        if (n == 0) {
            c.SDL_Delay(@intCast(timeout_ms));
            return;
        }
        sys.poll(&fds, n, timeout_ms);
    }

    fn tick(w: *Worker, now: i64) void {
        if (now >= w.next_hb) {
            // Dois heartbeats sem resposta: a conexão morreu sem avisar.
            if (!w.hb_acked) {
                dbg("heartbeat sem resposta", .{});
                w.end = .resume_ws;
                return;
            }
            w.heartbeat();
            w.next_hb = now + w.hb_interval;
        }
        w.applyAudioFlags();
        w.audioPoll(now);
        if (!w.connected) return;
        if (now >= w.next_keepalive) {
            const keep = [_]u8{ 0x13, 0x37 };
            _ = sys.sendTo(w.udp, &keep, &w.server);
            w.next_keepalive = now + 5000;
        }
        if (now >= w.next_frame) {
            w.sendFrame(now);
            w.next_frame += frame_ms;
            // O relógio do RTP anda com o tempo, falando ou não: quem recebe
            // usa ele para saber quanto tempo passou entre duas falas.
            w.rtp_ts +%= frame_samples;
            if (w.next_frame < now - 100) w.next_frame = now + frame_ms; // não acumula atraso
        }
        w.conceal();
        w.expireSpeakers(now);
    }

    // --- WebSocket ---------------------------------------------------------

    fn sendFrame_(w: *Worker, flags0: c_uint, data: []const u8) bool {
        const h = w.ws orelse return false;
        var off: usize = 0;
        var first = true;
        var waited: u8 = 0;
        while (off < data.len) {
            var sent: usize = 0;
            const flags: c_uint = if (first) flags0 else c.CURLWS_CONT;
            const rc = c.curl_ws_send(h, data.ptr + off, data.len - off, &sent, 0, flags);
            if (rc == c.CURLE_AGAIN) {
                waited += 1;
                if (waited > 50) return false;
                w.waitSockets(20);
                continue;
            }
            if (rc != c.CURLE_OK) {
                dbg("ws send rc={d}", .{rc});
                // Socket morto: o laço reconecta em vez de insistir.
                if (w.end == null) w.end = .resume_ws;
                return false;
            }
            if (sent == 0) return false;
            off += sent;
            first = false;
        }
        return true;
    }

    fn sendText(w: *Worker, text: []const u8) bool {
        return w.sendFrame_(c.CURLWS_TEXT, text);
    }

    fn sendBinary(w: *Worker, opcode: u8, payload: []const u8) bool {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(alloc);
        buf.ensureTotalCapacity(alloc, payload.len + 1) catch return false;
        buf.appendAssumeCapacity(opcode);
        buf.appendSliceAssumeCapacity(payload);
        dbg("enviou binário op {d} ({d} bytes)", .{ opcode, payload.len });
        return w.sendFrame_(c.CURLWS_BINARY, buf.items);
    }

    fn heartbeat(w: *Worker) void {
        var b: [96]u8 = undefined;
        const p = std.fmt.bufPrint(&b, "{{\"op\":3,\"d\":{{\"t\":{d},\"seq_ack\":{d}}}}}", .{ nowMs(), w.last_seq }) catch return;
        w.hb_acked = false;
        w.hb_sent_ms = nowMs();
        _ = w.sendText(p);
    }

    fn identify(w: *Worker) void {
        var out: std.ArrayList(u8) = .empty;
        defer {
            std.crypto.secureZero(u8, out.items);
            out.deinit(alloc);
        }
        out.print(alloc, "{{\"op\":0,\"d\":{{\"server_id\":\"{d}\",\"user_id\":\"{d}\",\"session_id\":", .{ w.v.guild, w.v.user }) catch return;
        j.writeString(&out, alloc, w.v.session[0..w.v.session_len]) catch return;
        out.appendSlice(alloc, ",\"token\":") catch return;
        j.writeString(&out, alloc, w.v.token[0..w.v.token_len]) catch return;
        out.print(alloc, ",\"video\":false,\"max_dave_protocol_version\":{d}}}}}", .{c.daveMaxSupportedProtocolVersion()}) catch return;
        dbg("identify (DAVE até v{d})", .{c.daveMaxSupportedProtocolVersion()});
        _ = w.sendText(out.items);
    }

    /// Op 7: retoma a mesma sessão depois de uma queda (o UDP continua).
    fn sendResume(w: *Worker) void {
        var out: std.ArrayList(u8) = .empty;
        defer {
            std.crypto.secureZero(u8, out.items);
            out.deinit(alloc);
        }
        out.print(alloc, "{{\"op\":7,\"d\":{{\"server_id\":\"{d}\",\"session_id\":", .{w.v.guild}) catch return;
        j.writeString(&out, alloc, w.v.session[0..w.v.session_len]) catch return;
        out.appendSlice(alloc, ",\"token\":") catch return;
        j.writeString(&out, alloc, w.v.token[0..w.v.token_len]) catch return;
        out.print(alloc, ",\"seq_ack\":{d}}}}}", .{w.last_seq}) catch return;
        dbg("resume", .{});
        _ = w.sendText(out.items);
    }

    fn readWs(w: *Worker) void {
        const h = w.ws orelse return;
        while (w.end == null) {
            var got: usize = 0;
            var meta: [*c]const c.struct_curl_ws_frame = null;
            const rc = c.curl_ws_recv(h, &w.in_buf, w.in_buf.len, &got, &meta);
            if (rc == c.CURLE_AGAIN) return;
            if (rc != c.CURLE_OK or meta == null) {
                // Conexão caiu sem o Discord fechar (rede, NAT, suspensão).
                dbg("ws recv rc={d}", .{rc});
                w.end = .resume_ws;
                return;
            }
            const flags = meta.*.flags;
            if (flags & c.CURLWS_CLOSE != 0) {
                const code: u16 = if (got >= 2) (@as(u16, w.in_buf[0]) << 8) | w.in_buf[1] else 0;
                const reason = if (got > 2) w.in_buf[2..got] else "";
                std.log.warn("voz: fechou {d}: {s}", .{ code, reason });
                w.end = w.onClose(code);
                return;
            }
            if (flags & (c.CURLWS_PING | c.CURLWS_PONG) != 0) continue;
            if (got > 0) w.ws_in.appendSlice(alloc, w.in_buf[0..got]) catch return;
            // Mensagem em vários pedaços: junta até o último.
            if (meta.*.bytesleft != 0 or flags & c.CURLWS_CONT != 0) continue;
            const bytes = w.ws_in.items;
            if (bytes.len > 0) {
                if (flags & c.CURLWS_TEXT != 0) {
                    w.onText(bytes);
                } else if (flags & c.CURLWS_BINARY != 0) {
                    w.onBinary(bytes);
                }
            }
            w.ws_in.clearRetainingCapacity();
        }
    }

    /// O que fazer com cada código de fechamento do gateway de voz.
    fn onClose(w: *Worker, code: u16) End {
        w.connected = false;
        if (w.v.stopping.load(.acquire)) return .stop;
        return switch (code) {
            // Queda de rede / servidor reiniciou: retoma a mesma sessão.
            0, 1000, 1001, 1006, 4015 => .resume_ws,
            // Movido de canal, servidor de voz trocado ou desconectado por
            // alguém: o gateway principal manda (ou não) o servidor novo.
            4014 => .moved,
            4004 => blk: {
                w.v.notice("o Discord recusou a sessão de voz (4004).", "Discord refused the voice session (4004).", .{});
                break :blk .fatal;
            },
            4006, 4009 => blk: {
                w.v.notice("a sessão de voz não vale mais; entre na call de novo.", "the voice session is no longer valid; join the call again.", .{});
                break :blk .fatal;
            },
            4016, 4017 => blk: {
                w.v.notice("o Discord exigiu E2EE (DAVE) e a negociação falhou ({d}).", "Discord requires E2EE (DAVE) and negotiation failed ({d}).", .{code});
                break :blk .fatal;
            },
            else => blk: {
                w.v.notice("a call caiu (código {d}).", "the call dropped (code {d}).", .{code});
                break :blk .fatal;
            },
        };
    }

    fn onText(w: *Worker, text: []const u8) void {
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const root = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), text, .{}) catch return;
        if (j.int(j.get(root, "seq"))) |s| w.last_seq = s;
        const op = j.int(j.get(root, "op")) orelse return;
        const d = j.get(root, "d") orelse std.json.Value{ .null = {} };
        if (op != 6) dbg("op {d}", .{op});
        switch (op) {
            8 => {
                w.hb_interval = @max(j.int(j.get(d, "heartbeat_interval")) orelse 13750, 1000);
                // O primeiro heartbeat vai logo (com jitter), como o cliente oficial.
                w.next_hb = nowMs() + @divTrunc(w.hb_interval, 4);
                if (w.resuming) w.sendResume() else w.identify();
            },
            6 => {
                w.hb_acked = true;
                if (w.hb_sent_ms != 0) w.v.emit(.{ .voice_ping = @intCast(std.math.clamp(nowMs() - w.hb_sent_ms, 1, 60_000)) });
            },
            2 => w.onReady(d),
            4 => w.onSession(d),
            9 => {
                // Resumed: o UDP e a chave continuam valendo.
                w.resuming = false;
                w.connected = w.have_secret;
                w.next_frame = nowMs();
                if (w.connected) {
                    w.announceSpeaking();
                    w.v.status(.connected);
                }
            },
            5 => w.onSpeaking(d),
            11 => for (j.array(j.get(d, "user_ids"))) |u| {
                if (j.id(u)) |uid| w.addCallUser(uid);
            },
            // Flags e plataforma de quem está na call: também diz que ele está aqui.
            18, 20 => if (j.id(j.get(d, "user_id"))) |uid| w.addCallUser(uid),
            13 => if (j.id(j.get(d, "user_id"))) |uid| {
                _ = w.call_users.remove(uid);
                w.removeSource(uid);
                if (w.dave) |*dave| dave.removeUser(uid);
                w.v.emit(.{ .voice_speaking = .{ .user = uid, .speaking = false } });
            },
            21 => {
                const ver: u16 = @intCast(std.math.clamp(j.int(j.get(d, "protocol_version")) orelse 1, 0, 1));
                const tid = j.int(j.get(d, "transition_id")) orelse 0;
                if (w.dave) |*dave| {
                    dave.prepareTransition(ver);
                    // 0 = (re)início: executa já, sem esperar o servidor.
                    if (tid == 0) dave.executeTransition() else w.sendReady(tid);
                } else if (tid != 0) w.sendReady(tid);
            },
            22 => if (w.dave) |*dave| dave.executeTransition(),
            24 => {
                const epoch = j.int(j.get(d, "epoch")) orelse 0;
                const ver: u16 = @intCast(std.math.clamp(j.int(j.get(d, "protocol_version")) orelse 1, 0, 1));
                if (epoch == 1 and ver > 0) {
                    // Grupo novo: esquece o estado local e manda outro key package.
                    if (w.dave == null) w.initDave(ver);
                    if (w.dave) |*dave| {
                        dave.reinit(ver, w.v.channel.load(.acquire));
                        w.sendKeyPackage();
                    }
                }
            },
            else => {},
        }
    }

    fn sendReady(w: *Worker, tid: i64) void {
        var b: [80]u8 = undefined;
        const p = std.fmt.bufPrint(&b, "{{\"op\":23,\"d\":{{\"transition_id\":{d}}}}}", .{tid}) catch return;
        _ = w.sendText(p);
    }

    fn onBinary(w: *Worker, data: []const u8) void {
        // Do servidor: seq (u16, big endian) + opcode + dados.
        if (data.len < 3) return;
        w.last_seq = std.mem.readInt(u16, data[0..2], .big);
        const opcode = data[2];
        const payload = data[3..];
        dbg("binário op {d} ({d} bytes)", .{ opcode, payload.len });
        const dave = if (w.dave) |*d| d else return;
        switch (opcode) {
            25 => dave.setExternalSender(payload),
            27 => {
                var out: std.ArrayList(u8) = .empty;
                defer out.deinit(alloc);
                dave.proposals(payload, &out);
                if (out.items.len > 0) _ = w.sendBinary(28, out.items);
            },
            29, 30 => {
                if (payload.len < 2) return;
                const tid = std.mem.readInt(u16, payload[0..2], .big);
                const ok = if (opcode == 29) dave.commit(tid, payload[2..]) else dave.welcome(tid, payload[2..]);
                const res = ok orelse return; // commit ignorado (nosso mesmo)
                if (res) {
                    if (tid != 0) w.sendReady(tid);
                    dave.setLocalSsrc(w.ssrc);
                } else {
                    // Commit/welcome inválido: avisa (op 31), recomeça o MLS
                    // e manda um key package novo.
                    dbg("commit/welcome inválido (transição {d})", .{tid});
                    w.sendInvalid(tid);
                    dave.reinit(dave.version, w.v.channel.load(.acquire));
                    w.sendKeyPackage();
                }
            },
            else => {},
        }
    }

    fn sendInvalid(w: *Worker, tid: i64) void {
        var b: [80]u8 = undefined;
        const p = std.fmt.bufPrint(&b, "{{\"op\":31,\"d\":{{\"transition_id\":{d}}}}}", .{tid}) catch return;
        _ = w.sendText(p);
    }

    fn parseIp4(ip: []const u8, port: u16) !sys.SockAddrIn {
        var z: [64]u8 = @splat(0);
        if (ip.len == 0 or ip.len >= z.len) return error.InvalidAddress;
        @memcpy(z[0..ip.len], ip);
        return sys.ipv4(@ptrCast(&z), port) orelse error.InvalidAddress;
    }

    fn onReady(w: *Worker, d: std.json.Value) void {
        const ip = j.str(j.get(d, "ip")) orelse return;
        const port: u16 = @intCast(std.math.clamp(j.int(j.get(d, "port")) orelse 0, 0, 65535));
        w.ssrc = @intCast(std.math.clamp(j.int(j.get(d, "ssrc")) orelse 0, 0, std.math.maxInt(u32)));
        if (port == 0) return;
        w.server = parseIp4(ip, port) catch {
            w.v.notice("endereço UDP de voz inválido", "invalid voice UDP address", .{});
            w.end = .fatal;
            return;
        };
        if (sys.valid(w.udp)) sys.closeSocket(w.udp);
        const fd = sys.udpSocket() orelse {
            w.v.notice("não consegui abrir o UDP da call", "couldn't open the call UDP", .{});
            w.end = .fatal;
            return;
        };
        w.udp = fd;
        if (!sys.bindAny(w.udp)) {
            w.v.notice("não consegui abrir o UDP da call", "couldn't open the call UDP", .{});
            w.end = .fatal;
            return;
        }
        // IP discovery: o pedido tem 74 bytes (cabeçalho de 4 + ssrc + 66).
        var pkt: [74]u8 = @splat(0);
        std.mem.writeInt(u16, pkt[0..2], 1, .big);
        std.mem.writeInt(u16, pkt[2..4], 70, .big);
        std.mem.writeInt(u32, pkt[4..8], w.ssrc, .big);
        for (0..5) |_| {
            _ = sys.sendTo(w.udp, &pkt, &w.server);
            const deadline = nowMs() + 1000;
            while (nowMs() < deadline and !w.v.stopping.load(.acquire)) {
                w.waitSockets(100);
                var resp: [256]u8 = undefined;
                const nr = sys.recvNow(w.udp, &resp);
                if (nr < 74) continue;
                if (std.mem.readInt(u16, resp[0..2], .big) != 2) continue;
                const iplen = std.mem.indexOfScalar(u8, resp[8..72], 0) orelse 64;
                const ext_port = std.mem.readInt(u16, resp[72..74], .big);
                dbg("discovery ok (porta {d})", .{ext_port});
                w.selectProtocol(resp[8..][0..iplen], ext_port);
                return;
            }
        }
        w.v.notice("a call não respondeu ao UDP (firewall/NAT?)", "the call didn't answer on UDP (firewall/NAT?)", .{});
        w.end = .fatal;
    }

    fn selectProtocol(w: *Worker, ip: []const u8, port: u16) void {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(alloc);
        out.appendSlice(alloc, "{\"op\":1,\"d\":{\"protocol\":\"udp\",\"data\":{\"address\":") catch return;
        j.writeString(&out, alloc, ip) catch return;
        out.print(alloc, ",\"port\":{d},\"mode\":\"aead_xchacha20_poly1305_rtpsize\"}}}}}}", .{port}) catch return;
        _ = w.sendText(out.items);
    }

    fn onSession(w: *Worker, d: std.json.Value) void {
        const mode = j.str(j.get(d, "mode")) orelse "";
        if (!std.mem.eql(u8, mode, "aead_xchacha20_poly1305_rtpsize")) {
            w.v.notice("modo de criptografia de voz não suportado ({s})", "unsupported voice encryption mode ({s})", .{mode});
            w.end = .fatal;
            return;
        }
        const keys = j.array(j.get(d, "secret_key"));
        if (keys.len != 32) return;
        for (keys, 0..) |kv, i| w.secret[i] = @intCast(std.math.clamp(j.int(kv) orelse 0, 0, 255));
        w.have_secret = true;
        const dave_ver: u16 = @intCast(std.math.clamp(j.int(j.get(d, "dave_protocol_version")) orelse 0, 0, 1));
        dbg("sessão pronta (DAVE v{d})", .{dave_ver});
        if (dave_ver > 0 and w.dave == null) {
            w.initDave(dave_ver);
            w.sendKeyPackage();
        }
        w.announceSpeaking();
        w.connected = true;
        w.next_frame = nowMs();
        w.next_keepalive = nowMs();
        w.v.status(.connected);
    }

    fn onSpeaking(w: *Worker, d: std.json.Value) void {
        const uid = j.id(j.get(d, "user_id")) orelse return;
        const ssrc: u32 = @intCast(std.math.clamp(j.int(j.get(d, "ssrc")) orelse 0, 0, std.math.maxInt(u32)));
        if (ssrc == 0) return;
        _ = w.sourceFor(ssrc, uid);
        w.addCallUser(uid);
        w.call_ssrcs.put(alloc, ssrc, uid) catch {};
        if (w.dave) |*dave| dave.setSsrcUser(ssrc, uid);
    }

    // --- DAVE --------------------------------------------------------------

    fn initDave(w: *Worker, version: u16) void {
        var d = Dave.init(w.v.channel.load(.acquire), w.v.user, version) orelse {
            std.log.warn("voz: DAVE indisponível", .{});
            return;
        };
        d.setLocalSsrc(w.ssrc);
        var ui = w.call_users.keyIterator();
        while (ui.next()) |u| d.addUser(u.*);
        var si = w.call_ssrcs.iterator();
        while (si.next()) |kv| d.setSsrcUser(kv.key_ptr.*, kv.value_ptr.*);
        w.dave = d;
    }

    fn sendKeyPackage(w: *Worker) void {
        const dave = if (w.dave) |*d| d else return;
        var kp: [4096]u8 = undefined;
        const n = dave.keyPackage(&kp);
        if (n > 0) _ = w.sendBinary(26, kp[0..n]);
    }

    // --- UDP / mídia -------------------------------------------------------

    fn readUdp(w: *Worker) void {
        if (!sys.valid(w.udp)) return;
        // No máximo 64 pacotes por volta: o resto fica para a próxima.
        for (0..64) |_| {
            var buf: [2048]u8 = undefined;
            const nr = sys.recvNow(w.udp, &buf);
            if (nr <= 0) return;
            w.onRtp(buf[0..@intCast(nr)]);
        }
    }

    /// Lê 20 ms do microfone; manda só enquanto há voz (ou a tecla do aperte
    /// para falar), mais 5 quadros de silêncio no fim, como o cliente oficial,
    /// e nada quando mudo, por nós ou pelo servidor.
    fn sendFrame(w: *Worker, now: i64) void {
        const sh = &voz_audio.sh;
        const blocked = w.v.micBlocked();
        var pcm: [frame_samples * channels]i16 = undefined;
        const have = !blocked and w.mic.read(&pcm);
        const ptt = sh.ptt.load(.monotonic);
        const key = sh.ptt_down.load(.monotonic);
        // Aperte para falar com a tecla solta: o microfone segue sendo lido (o
        // som velho não pode sair quando a tecla descer), mas nada é tratado.
        const idle = w.talk.pttIdle(now, ptt, key);
        // Mudo não gasta nada com o supressor: nem o estado fica.
        if (blocked or w.mic.stream == null or idle) w.cap.release();
        var voice = false;
        if (have and !idle) {
            const res = w.cap.process(&pcm, sh.captureCfg());
            voice = res.voice;
            w.mic_peak_rms = @max(w.mic_peak_rms, res.rms);
        }
        const talking = w.talk.update(now, .{
            .voice = voice,
            .ptt = ptt,
            .key = key,
            .blocked = blocked or w.mic.stream == null,
        });
        if (debugOn() and now - w.stats_ms >= 3000) {
            dbg("recebido: {d} pacotes de {d} pessoas, fora de ordem {d}, perdidos refeitos {d}, inventados {d}, fila vazia {d}, pausas de quem fala {d}, maior vão {d} ms, descartados {d}, recomeços {d}, sem decifrar {d}; thread: acordou atrasada até {d} ms, ocupada até {d} ms", .{ w.stats.packets, w.n_sources, w.stats.late, w.stats.rebuilt, w.stats.concealed, w.stats.starved, w.stats.paused, w.stats.gap_max_ms, w.stats.skipped, w.stats.cleared, w.stats.undecrypted, w.stats.wake_late_ms, w.stats.busy_ms });
            dbg("extra: com padding {d}, silêncios decodificados {d}, quadros quase no limite {d}, mistura estourou {d} amostras", .{ w.stats.padded, w.stats.silence_frames, w.stats.near_full, mix_over.swap(0, .monotonic) });
            w.stats = .{};
            dbg("mic: {s}, rms máx {d:.0}, {d} quadros enviados, DAVE {s}", .{ if (w.mic.stream == null) "sem microfone" else if (blocked) "mudo" else "ligado", w.mic_peak_rms, w.sent_frames, if (w.dave) |dv| (if (dv.enabled) "cifrando" else "esperando") else "não" });
            w.stats_ms = now;
            w.mic_peak_rms = 0;
        }
        if (talking != w.speaking_now) {
            dbg("falando: {}", .{talking});
            w.speaking_now = talking;
            if (talking) w.spurt_start = true;
            w.setSpeaking(talking);
            w.speaking_emit_ms = now;
            if (!talking) w.trailing_silence = 5;
        } else if (talking and now - w.speaking_emit_ms >= 1000) {
            // O anel apaga sozinho depois de 4 s sem notícia (Store.isSpeaking).
            w.setSpeaking(true);
            w.speaking_emit_ms = now;
        }
        if (!talking) {
            if (w.trailing_silence > 0) {
                w.trailing_silence -= 1;
                w.sendOpus(&silence);
            }
            return;
        }
        // Falando, mas o microfone ainda não entregou este quadro: não é pausa
        // na fala; vem no próximo tique.
        if (!have) return;
        const enc = w.encoder orelse return;
        var packet: [1500]u8 = undefined;
        const len = c.opus_encode(enc, &pcm, frame_samples, &packet, packet.len);
        if (len <= 0) return;
        w.sendOpus(packet[0..@intCast(len)]);
    }

    fn sendOpus(w: *Worker, frame: []const u8) void {
        var payload = frame;
        var dave_buf: [2048]u8 = undefined;
        if (w.dave) |*dave| if (dave.enabled and !std.mem.eql(u8, frame, &silence)) {
            const n = dave.encrypt(w.ssrc, frame, &dave_buf);
            if (n == 0) return;
            payload = dave_buf[0..n];
        };
        w.sendRtp(payload);
    }

    /// O anel verde em volta da gente. O Discord não precisa saber de cada
    /// fala: o op 5 vai uma vez só, quando a sessão abre (como o cliente
    /// oficial); mandar "parei" fazia o servidor descartar o começo
    /// da próxima fala, que chega pelo UDP antes do "voltei" pelo WebSocket.
    fn setSpeaking(w: *Worker, on: bool) void {
        w.v.emit(.{ .voice_speaking = .{ .user = w.v.user, .speaking = on } });
    }

    /// Op 5: "este SSRC manda áudio de microfone".
    fn announceSpeaking(w: *Worker) void {
        var b: [96]u8 = undefined;
        const p = std.fmt.bufPrint(&b, "{{\"op\":5,\"d\":{{\"speaking\":1,\"delay\":0,\"ssrc\":{d}}}}}", .{w.ssrc}) catch return;
        _ = w.sendText(p);
    }

    fn sendRtp(w: *Worker, payload: []const u8) void {
        if (!sys.valid(w.udp) or payload.len == 0 or !w.have_secret) return;
        var buf: [12 + 2048 + 16 + 4]u8 = undefined;
        const off = 12;
        if (payload.len + off + 16 + 4 > buf.len) return;
        buf[0] = 0x80;
        // Payload 120 (Opus); o bit de marcação abre cada fala.
        buf[1] = if (w.spurt_start) 0xF8 else 0x78;
        w.spurt_start = false;
        std.mem.writeInt(u16, buf[2..4], w.rtp_seq, .big);
        std.mem.writeInt(u32, buf[4..8], w.rtp_ts, .big);
        std.mem.writeInt(u32, buf[8..12], w.ssrc, .big);
        var nonce: [24]u8 = @splat(0);
        w.nonce +%= 1;
        std.mem.writeInt(u32, nonce[0..4], w.nonce, .big);
        var tag: [16]u8 = undefined;
        const aead = std.crypto.aead.chacha_poly.XChaCha20Poly1305;
        aead.encrypt(buf[off..][0..payload.len], &tag, payload, buf[0..off], nonce, w.secret);
        @memcpy(buf[off + payload.len ..][0..16], &tag);
        @memcpy(buf[off + payload.len + 16 ..][0..4], nonce[0..4]);
        const total = off + payload.len + 16 + 4;
        const rc = sys.sendTo(w.udp, buf[0..total], &w.server);
        if (rc < 0) dbg("sendto falhou", .{}) else w.sent_frames += 1;
        w.rtp_seq +%= 1;
    }

    fn onRtp(w: *Worker, buf: []const u8) void {
        if (buf.len < 12 + 16 + 4 or !w.have_secret) return;
        if ((buf[0] >> 6) != 2) return;
        if ((buf[1] & 0x7f) != 120) return; // só Opus (RTCP e o resto ficam de fora)
        const ssrc = std.mem.readInt(u32, buf[8..12], .big);
        if (ssrc == w.ssrc) return;
        // Nos modos "rtpsize" só o cabeçalho fixo, os CSRC e os 4 bytes do
        // cabeçalho da extensão vão em claro; o corpo da extensão vai
        // cifrado junto com o áudio e sai depois de decifrar.
        var aad_len: usize = 12 + @as(usize, buf[0] & 0x0f) * 4;
        var ext_words: usize = 0;
        if (buf[0] & 0x10 != 0) {
            if (aad_len + 4 > buf.len) return;
            ext_words = std.mem.readInt(u16, buf[aad_len + 2 ..][0..2], .big);
            aad_len += 4;
        }
        if (buf.len < aad_len + 16 + 4) return;
        const cipher = buf[aad_len .. buf.len - 20];
        var tag: [16]u8 = undefined;
        @memcpy(&tag, buf[buf.len - 20 ..][0..16]);
        var nonce: [24]u8 = @splat(0);
        @memcpy(nonce[0..4], buf[buf.len - 4 ..]);
        var plain: [2048]u8 = undefined;
        if (cipher.len > plain.len) return;
        const aead = std.crypto.aead.chacha_poly.XChaCha20Poly1305;
        aead.decrypt(plain[0..cipher.len], cipher, tag, buf[0..aad_len], nonce, w.secret) catch return;
        // With the padding bit set, the last byte counts the padding bytes that
        // end the (encrypted) payload. Left on, they hide the DAVE 0xFAFA
        // marker and the ciphertext goes to the Opus decoder.
        var end = cipher.len;
        if (buf[0] & 0x20 != 0) {
            w.stats.padded += 1;
            if (end == 0 or plain[end - 1] == 0 or plain[end - 1] > end) return;
            end -= plain[end - 1];
        }
        if (ext_words * 4 > end) return;
        var frame: []const u8 = plain[ext_words * 4 .. end];
        if (frame.len == 0) return;
        const src = w.sourceFor(ssrc, 0) orelse return;
        const seq = std.mem.readInt(u16, buf[2..4], .big);
        const ts = std.mem.readInt(u32, buf[4..8], .big);
        if (std.mem.eql(u8, frame, &silence)) {
            // Passa pelo decodificador: ele prevê o volume de cada quadro a partir do anterior.
            // Sem isto, a próxima fala pode sair muitas vezes mais alta por uns 100 ms.
            var quiet: [5760 * channels]i16 = undefined;
            _ = c.opus_decode(src.dec, frame.ptr, @intCast(frame.len), &quiet, 5760, 0);
            w.stats.silence_frames += 1;
            src.jitter.silenceFrame(seq, ts);
            return;
        }
        // Quadro do DAVE (termina com o marcador 0xFAFA): decifra. Sem o
        // marcador é Opus puro (call sem E2EE ou no meio de uma transição).
        var dave_out: [2048]u8 = undefined;
        if (frame.len >= 2 and frame[frame.len - 1] == 0xFA and frame[frame.len - 2] == 0xFA) {
            const dave = if (w.dave) |*d| d else return;
            const n = dave.decrypt(ssrc, src.user, frame, &dave_out) orelse {
                w.stats.undecrypted += 1;
                return;
            };
            frame = dave_out[0..n];
        }
        w.play(src, frame, seq, ts);
    }

    // --- Áudio ------------------------------------------------------------

    const spec: c.SDL_AudioSpec = voz_audio.spec;

    fn initAudio(w: *Worker) bool {
        var err: c_int = 0;
        w.encoder = c.opus_encoder_create(opus_rate, channels, c.OPUS_APPLICATION_VOIP, &err);
        if (err == c.OPUS_OK) {
            _ = c.opus_encoder_ctl(w.encoder, c.OPUS_SET_BITRATE_REQUEST, @as(c_int, 64000));
            _ = c.opus_encoder_ctl(w.encoder, c.OPUS_SET_COMPLEXITY_REQUEST, @as(c_int, 5));
            _ = c.opus_encoder_ctl(w.encoder, c.OPUS_SET_INBAND_FEC_REQUEST, @as(c_int, 1));
            _ = c.opus_encoder_ctl(w.encoder, c.OPUS_SET_PACKET_LOSS_PERC_REQUEST, @as(c_int, 10));
        } else w.encoder = null;
        if (voz_audio.acquire()) {
            w.audio_on = true;
            const now = nowMs();
            w.out.open(now);
            w.updatePull();
            w.mic.paused = w.v.micBlocked();
            w.mic.open(now);
        }
        w.applyAudioFlags();
        w.reportAudio();
        return w.out.dev != 0 or w.mic.stream != null;
    }

    /// Mudo desliga o microfone de verdade; ensurdecer pausa a saída.
    fn applyAudioFlags(w: *Worker) void {
        w.mic.setPaused(w.v.micBlocked());
        const deaf = w.v.outBlocked();
        if (w.out.dev != 0 and deaf != w.deaf_applied) {
            if (deaf) _ = c.SDL_PauseAudioDevice(w.out.dev) else _ = c.SDL_ResumeAudioDevice(w.out.dev);
            for (w.sources[0..w.n_sources]) |*s| if (s.stream) |st| {
                _ = c.SDL_ClearAudioStream(st);
            };
            w.deaf_applied = deaf;
        }
        const gen = w.v.volumes_gen.load(.acquire);
        if (gen != w.volumes_gen) {
            w.volumes_gen = gen;
            for (w.sources[0..w.n_sources]) |*s| s.applyGain(w.v);
        }
    }

    /// Dispositivo escolhido mudou, sumiu ou voltou, em plena call: reabre o
    /// microfone e passa cada pessoa para a saída nova. A conexão nem percebe.
    fn audioPoll(w: *Worker, now: i64) void {
        if (!w.audio_on) return;
        w.mic.check(now);
        w.out.applyGain();
        if (w.out.check(now)) |dev| {
            for (w.sources[0..w.n_sources]) |*s| {
                if (s.stream == null) s.stream = c.SDL_CreateAudioStream(&spec, &spec);
                if (s.stream) |st| voz_audio.Output.rebind(dev, st);
            }
            w.out.adopt(dev);
            w.updatePull();
            // Era um dispositivo novo, ainda sem a pausa do ensurdecer.
            if (w.deaf_applied) _ = c.SDL_PauseAudioDevice(dev);
        }
        w.reportAudio();
    }

    /// Avisa a interface quando o microfone ou a saída mudam de situação: ela
    /// mostra na barra de voz, em vez de ficar calada sem explicação.
    fn reportAudio(w: *Worker) void {
        const mic_ok = !w.mic.failed();
        const out_ok = w.out.dev != 0;
        if (mic_ok == w.mic_ok_sent and out_ok == w.out_ok_sent) return;
        w.mic_ok_sent = mic_ok;
        w.out_ok_sent = out_ok;
        w.v.emit(.{ .voice_audio = .{ .mic_ok = mic_ok, .out_ok = out_ok } });
    }

    fn sourceFor(w: *Worker, ssrc: u32, user: Id) ?*Source {
        for (w.sources[0..w.n_sources]) |*s| if (s.ssrc == ssrc) {
            if (user != 0 and s.user != user) {
                s.user = user;
                s.applyGain(w.v);
            }
            return s;
        };
        if (w.n_sources == w.sources.len) return null;
        var err: c_int = 0;
        const dec = c.opus_decoder_create(opus_rate, channels, &err) orelse return null;
        if (err != c.OPUS_OK) {
            c.opus_decoder_destroy(dec);
            return null;
        }
        var src: Source = .{ .ssrc = ssrc, .user = user, .dec = dec };
        src.jitter.pull_ms = w.pull_ms;
        if (w.out.dev != 0) {
            src.stream = c.SDL_CreateAudioStream(&spec, &spec);
            if (src.stream) |st| _ = c.SDL_BindAudioStream(w.out.dev, st);
        }
        w.sources[w.n_sources] = src;
        w.n_sources += 1;
        const s = &w.sources[w.n_sources - 1];
        s.applyGain(w.v);
        return s;
    }

    fn removeSource(w: *Worker, user: Id) void {
        var i: usize = 0;
        while (i < w.n_sources) {
            if (w.sources[i].user == user) {
                w.sources[i].deinit();
                w.sources[i] = w.sources[w.n_sources - 1];
                w.n_sources -= 1;
            } else i += 1;
        }
    }

    /// Opus -> PCM -> o stream da pessoa (o SDL mistura e toca).
    fn play(w: *Worker, src: *Source, frame: []const u8, seq: u16, ts: u32) void {
        const now = nowMs();
        // Começo de uma fala (silêncio antes): a fila do SDL recomeça com
        // uma folga contra o jitter. No meio da fala nunca entra silêncio.
        const since = now - src.last_ms;
        const spurt = since > 250;
        if (!spurt) w.stats.gap_max_ms = @max(w.stats.gap_max_ms, since);
        if (!src.speaking or now - src.last_emit_ms > 1000) {
            src.speaking = true;
            src.last_emit_ms = now;
            if (src.user != 0) w.v.emit(.{ .voice_speaking = .{ .user = src.user, .speaking = true } });
        }
        src.last_ms = now;
        w.stats.packets += 1;
        if (w.deaf_applied) {
            src.jitter.last_seq = seq;
            src.jitter.last_ts = ts;
            return;
        }
        const st = src.stream orelse return;
        const queued_ms = queuedMs(st);
        const plan = src.jitter.plan(seq, ts, spurt, queued_ms);
        if (plan.late) {
            w.stats.late += 1;
            return;
        }
        if (plan.clear) {
            w.stats.cleared += 1;
            _ = c.SDL_ClearAudioStream(st);
            src.seam.dropped();
        }
        if (plan.gap) src.seam.dropped();
        if (plan.paused) w.stats.paused += 1;
        // Depois de uma pausa ou de um buraco grande, o estado dele é de outra hora.
        if (spurt or plan.fresh) _ = c.opus_decoder_ctl(src.dec, c.OPUS_RESET_STATE);
        if (!spurt and !plan.clear and !plan.paused and queued_ms == 0) w.stats.starved += 1;
        if (plan.pad_ms > 0) {
            const silence_buf: [voz.Jitter.cushion_max * bytes_per_ms]u8 = @splat(0);
            var left: usize = plan.pad_ms * bytes_per_ms;
            while (left > 0) {
                const n = @min(left, silence_buf.len);
                _ = c.SDL_PutAudioStreamData(st, &silence_buf, @intCast(n));
                left -= n;
            }
            src.seam.silence();
        }
        // O que se perdeu vem antes deste pacote, para o ouvido e para o Opus: o
        // decodificador continua de onde parou, e fora de ordem a emenda estala.
        if (plan.lost > 0) {
            w.stats.rebuilt += plan.lost;
            var fill: [frame_samples * channels]i16 = undefined;
            for (0..plan.lost) |i| {
                // O último dá para recuperar do próprio pacote (FEC do Opus);
                // sem esses dados, ele faz o mesmo que os outros: inventa.
                const fec = i + 1 == plan.lost;
                const m = c.opus_decode(src.dec, if (fec) frame.ptr else null, if (fec) @intCast(frame.len) else 0, &fill, frame_samples, @intFromBool(fec));
                if (m > 0) src.put(st, fill[0..@as(usize, @intCast(m)) * channels]);
            }
        }
        var pcm: [5760 * channels]i16 = undefined;
        const n = c.opus_decode(src.dec, frame.ptr, @intCast(frame.len), &pcm, 5760, 0);
        if (n <= 0) return;
        if (debugOn()) w.noteLevel(src, pcm[0..@as(usize, @intCast(n)) * channels], since, spurt, plan, frame);
        if (plan.skip) {
            w.stats.skipped += 1;
            src.seam.dropped();
            return;
        }
        src.put(st, pcm[0..@as(usize, @intCast(n)) * channels]);
    }

    /// Com a depuração ligada: o estalo some na média de 3 s, então o salto vai para o registro
    /// na hora, com o que pode explicar ele.
    fn noteLevel(w: *Worker, src: *Source, pcm: []const i16, since: i64, spurt: bool, plan: voz.Jitter.Plan, frame: []const u8) void {
        var peak: i32 = 0;
        for (pcm) |v| peak = @max(peak, @as(i32, @intCast(@abs(@as(i32, v)))));
        if (peak >= 32000) w.stats.near_full += 1;
        const now = nowMs();
        // Sílaba forte depois de uma fraca é normal: só o que passa bem disso.
        if (peak >= 16000 and peak > src.peak_prev * 4 and now - src.jump_ms >= 200) {
            src.jump_ms = now;
            dbg("salto de volume: ssrc {d}, pessoa {d}: pico {d} -> {d}, {d} bytes, TOC {x:0>2}, {d} ms sem pacote, perdidos {d}, começo de fala {}, pausa {}", .{ src.ssrc, src.user, src.peak_prev, peak, frame.len, frame[0], since, plan.lost, spurt, plan.paused });
        }
        src.peak_prev = peak;
    }

    /// A fila de alguém seca antes da próxima volta: em vez de um corte seco no
    /// meio da onda, o Opus inventa e vai se apagando.
    fn conceal(w: *Worker) void {
        if (w.deaf_applied) return;
        for (w.sources[0..w.n_sources]) |*s| {
            if (s.jitter.ended) continue;
            const st = s.stream orelse continue;
            const what = s.jitter.conceal(queuedMs(st));
            if (what == .none) continue;
            var fill: [frame_samples * channels]i16 = undefined;
            const m = c.opus_decode(s.dec, null, 0, &fill, frame_samples, 0);
            if (m <= 0) continue;
            w.stats.concealed += 1;
            const pcm = fill[0..@as(usize, @intCast(m)) * channels];
            if (what == .last) {
                s.seam.fadeOut(pcm);
                _ = c.SDL_PutAudioStreamData(st, pcm.ptr, @intCast(pcm.len * @sizeOf(i16)));
            } else s.put(st, pcm);
        }
    }

    /// De quanto em quanto o dispositivo puxa áudio de cada stream.
    fn updatePull(w: *Worker) void {
        var fmt: c.SDL_AudioSpec = undefined;
        var frames: c_int = 0;
        if (w.out.dev == 0 or !c.SDL_GetAudioDeviceFormat(w.out.dev, &fmt, &frames) or frames <= 0 or fmt.freq <= 0) return;
        w.pull_ms = @intCast(@divTrunc(frames * 1000, fmt.freq) + 1);
        dbg("saída: {d} Hz, {d} quadros de cada vez ({d} ms)", .{ fmt.freq, frames, w.pull_ms });
        if (debugOn()) _ = c.SDL_SetAudioPostmixCallback(w.out.dev, mixCheck, null);
        for (w.sources[0..w.n_sources]) |*s| s.jitter.pull_ms = w.pull_ms;
    }

    /// Quem parou de mandar áudio há 300 ms parou de falar (o anel apaga).
    fn expireSpeakers(w: *Worker, now: i64) void {
        for (w.sources[0..w.n_sources]) |*s| if (s.speaking and now - s.last_ms > 400) {
            s.speaking = false;
            if (s.user != 0) w.v.emit(.{ .voice_speaking = .{ .user = s.user, .speaking = false } });
        };
    }
};

/// Amostras da mistura final fora de -1..1 (o SDL corta seco): a soma das vozes estourou.
var mix_over: std.atomic.Value(u32) = .init(0);

fn mixCheck(_: ?*anyopaque, _: [*c]const c.SDL_AudioSpec, buffer: [*c]f32, buflen: c_int) callconv(.c) void {
    const n: usize = @intCast(@divTrunc(buflen, @sizeOf(f32)));
    var over: u32 = 0;
    for (buffer[0..n]) |v| {
        if (@abs(v) > 1) over += 1;
    }
    if (over > 0) _ = mix_over.fetchAdd(over, .monotonic);
}

/// O que aconteceu com o áudio desde o último relatório (SIGMACORD_VOICE_DEBUG=1).
const Stats = struct {
    packets: u32 = 0,
    late: u32 = 0,
    rebuilt: u32 = 0,
    starved: u32 = 0,
    /// Quem fala parou de mandar um pouco: não é culpa da rede.
    paused: u32 = 0,
    /// Quadros inventados porque a fila ia secar.
    concealed: u32 = 0,
    /// O maior tempo entre dois pacotes da mesma pessoa, dentro de uma fala.
    gap_max_ms: i64 = 0,
    skipped: u32 = 0,
    cleared: u32 = 0,
    undecrypted: u32 = 0,
    /// Pacotes com padding no RTP, quadros de silêncio e quadros quase no limite de 16 bits.
    padded: u32 = 0,
    silence_frames: u32 = 0,
    near_full: u32 = 0,
    wake_late_ms: i64 = 0,
    busy_ms: i64 = 0,
};

/// Uma pessoa da call: o decodificador Opus e o stream de áudio dela.
const Source = struct {
    ssrc: u32,
    user: Id = 0,
    dec: *c.OpusDecoder,
    stream: ?*c.SDL_AudioStream = null,
    speaking: bool = false,
    last_ms: i64 = 0,
    last_emit_ms: i64 = 0,
    jitter: voz.Jitter = .{},
    seam: voz.Seam = .{},
    /// Só para o registro de depuração: o pico do último quadro e do último salto avisado.
    peak_prev: i32 = 0,
    jump_ms: i64 = 0,

    /// Entrega áudio ao stream, sem degrau onde ele não continua de onde parou.
    fn put(s: *Source, st: *c.SDL_AudioStream, pcm: []i16) void {
        s.seam.apply(pcm);
        _ = c.SDL_PutAudioStreamData(st, pcm.ptr, @intCast(pcm.len * @sizeOf(i16)));
    }

    fn deinit(s: *Source) void {
        c.opus_decoder_destroy(s.dec);
        if (s.stream) |st| c.SDL_DestroyAudioStream(st);
        s.stream = null;
    }

    fn applyGain(s: *Source, v: *Voice) void {
        const st = s.stream orelse return;
        _ = c.SDL_SetAudioStreamGain(st, if (s.user != 0) v.volumeOf(s.user) else 1);
    }
};

// ---------------------------------------------------------------------------
// DAVE (libdave, C API)
// ---------------------------------------------------------------------------

const Dave = struct {
    session: c.DAVESessionHandle = null,
    encryptor: c.DAVEEncryptorHandle = null,
    version: u16 = 0,
    group: Id,
    me: Id,
    /// Nossa mídia sai cifrada (a chave do grupo atual já está valendo).
    enabled: bool = false,
    pending_version: u16 = 0,
    /// Commit/welcome processado, esperando o "execute" do servidor.
    ready: bool = false,
    users: std.AutoHashMapUnmanaged(Id, void) = .empty,
    ssrc_users: std.AutoHashMapUnmanaged(u32, Id) = .empty,
    decryptors: std.AutoHashMapUnmanaged(u32, c.DAVEDecryptorHandle) = .empty,
    local_ssrc: u32 = 0,

    fn init(group: Id, me: Id, version: u16) ?Dave {
        var d: Dave = .{ .group = group, .me = me, .version = version, .pending_version = version };
        c.daveSetLogSinkCallback(logSink);
        d.session = c.daveSessionCreate(null, "", mlsFailure, null);
        if (d.session == null) return null;
        var idbuf: [24]u8 = undefined;
        const self = std.fmt.bufPrintSentinel(&idbuf, "{d}", .{me}, 0) catch return null;
        c.daveSessionInit(d.session, version, group, self.ptr);
        d.encryptor = c.daveEncryptorCreate();
        if (d.encryptor == null) {
            c.daveSessionDestroy(d.session);
            return null;
        }
        d.users.put(alloc, me, {}) catch {};
        return d;
    }

    fn deinit(d: *Dave) void {
        var it = d.decryptors.valueIterator();
        while (it.next()) |h| if (h.* != null) c.daveDecryptorDestroy(h.*);
        d.decryptors.deinit(alloc);
        if (d.encryptor != null) c.daveEncryptorDestroy(d.encryptor);
        if (d.session != null) c.daveSessionDestroy(d.session);
        d.users.deinit(alloc);
        d.ssrc_users.deinit(alloc);
    }

    /// O libdave escreve cada falha e os pacotes do MLS no stderr, e essa escrita
    /// para a thread de voz se o terminal estiver lento.
    fn logSink(_: c.DAVELoggingSeverity, file: [*c]const u8, line: c_int, message: [*c]const u8) callconv(.c) void {
        // Sem as chaves públicas e os "welcome" inteiros, que só encheriam um arquivo feito para ser compartilhado.
        if (debugOn()) {
            const text = std.mem.span(message);
            std.log.info("[dave] {s}:{d} {s}", .{ std.mem.span(file), line, text[0..@min(text.len, 80)] });
        }
    }

    fn mlsFailure(source: [*c]const u8, reason: [*c]const u8, _: ?*anyopaque) callconv(.c) void {
        std.log.warn("DAVE: {s} {s}", .{ std.mem.span(source), std.mem.span(reason) });
    }

    fn addUser(d: *Dave, user: Id) void {
        d.users.put(alloc, user, {}) catch {};
    }

    fn removeUser(d: *Dave, user: Id) void {
        _ = d.users.remove(user);
        var ssrcs: [64]u32 = undefined;
        var n: usize = 0;
        var it = d.ssrc_users.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.* == user and n < ssrcs.len) {
                ssrcs[n] = kv.key_ptr.*;
                n += 1;
            }
        }
        for (ssrcs[0..n]) |ssrc| {
            _ = d.ssrc_users.remove(ssrc);
            if (d.decryptors.fetchRemove(ssrc)) |x| if (x.value != null) c.daveDecryptorDestroy(x.value);
        }
    }

    fn setSsrcUser(d: *Dave, ssrc: u32, user: Id) void {
        d.ssrc_users.put(alloc, ssrc, user) catch {};
        d.ensureDecryptor(ssrc, user);
    }

    fn keyPackage(d: *Dave, out: []u8) usize {
        var p: [*c]u8 = null;
        var n: usize = 0;
        c.daveSessionGetMarshalledKeyPackage(d.session, &p, &n);
        if (p == null or n == 0) return 0;
        defer c.daveFree(p);
        if (n > out.len) return 0;
        @memcpy(out[0..n], p[0..n]);
        return n;
    }

    /// Recomeça o MLS do zero (grupo novo, commit inválido, fomos movidos).
    fn reinit(d: *Dave, version: u16, group: Id) void {
        d.version = version;
        d.pending_version = version;
        d.group = group;
        d.ready = false;
        var idbuf: [24]u8 = undefined;
        const self = std.fmt.bufPrintSentinel(&idbuf, "{d}", .{d.me}, 0) catch return;
        c.daveSessionReset(d.session);
        c.daveSessionInit(d.session, version, group, self.ptr);
        d.users.put(alloc, d.me, {}) catch {};
    }

    fn setExternalSender(d: *Dave, data: []const u8) void {
        c.daveSessionSetExternalSender(d.session, data.ptr, data.len);
    }

    /// IDs de quem o gateway disse que está na call (o MLS recusa os outros).
    fn recognized(d: *Dave, ids: *[64][24]u8, ptrs: *[64][*c]const u8) usize {
        var n: usize = 0;
        var it = d.users.keyIterator();
        while (it.next()) |u| {
            if (n == ids.len) break;
            const s = std.fmt.bufPrintSentinel(&ids[n], "{d}", .{u.*}, 0) catch continue;
            ptrs[n] = s.ptr;
            n += 1;
        }
        return n;
    }

    fn proposals(d: *Dave, data: []const u8, out: *std.ArrayList(u8)) void {
        var ids: [64][24]u8 = undefined;
        var ptrs: [64][*c]const u8 = undefined;
        const n = d.recognized(&ids, &ptrs);
        var p: [*c]u8 = null;
        var len: usize = 0;
        c.daveSessionProcessProposals(d.session, data.ptr, data.len, &ptrs, n, &p, &len);
        if (p != null) {
            defer c.daveFree(p);
            if (len > 0) out.appendSlice(alloc, p[0..len]) catch {};
        }
    }

    /// null = o servidor reenviou o nosso próprio commit (ignorado).
    fn commit(d: *Dave, tid: u16, data: []const u8) ?bool {
        const res = c.daveSessionProcessCommit(d.session, data.ptr, data.len);
        if (res == null) return false;
        defer c.daveCommitResultDestroy(res);
        if (c.daveCommitResultIsIgnored(res)) return null;
        if (c.daveCommitResultIsFailed(res)) return false;
        d.ready = true;
        d.applyReceiveKeys();
        if (tid == 0) d.executeTransition();
        return true;
    }

    fn welcome(d: *Dave, tid: u16, data: []const u8) ?bool {
        var ids: [64][24]u8 = undefined;
        var ptrs: [64][*c]const u8 = undefined;
        const n = d.recognized(&ids, &ptrs);
        const res = c.daveSessionProcessWelcome(d.session, data.ptr, data.len, &ptrs, n);
        if (res == null) return false;
        c.daveWelcomeResultDestroy(res);
        d.ready = true;
        d.applyReceiveKeys();
        if (tid == 0) d.executeTransition();
        return true;
    }

    fn prepareTransition(d: *Dave, version: u16) void {
        d.pending_version = version;
        // Indo para sem E2EE: já aceita mídia em claro de quem mudou antes.
        if (version == 0) {
            var it = d.decryptors.valueIterator();
            while (it.next()) |h| if (h.* != null) c.daveDecryptorTransitionToPassthroughMode(h.*, true);
        }
    }

    /// As chaves novas valem para ouvir assim que o grupo muda: quem recebe o
    /// "execute" antes de nós já está cifrando com elas. As velhas continuam
    /// aceitas por 10 s, para quem ainda não mudou.
    fn applyReceiveKeys(d: *Dave) void {
        var it = d.ssrc_users.iterator();
        while (it.next()) |kv| d.setRatchet(kv.key_ptr.*, kv.value_ptr.*);
    }

    /// O servidor mandou executar (op 22) ou a transição era a 0: só o que
    /// mandamos muda de chave aqui.
    fn executeTransition(d: *Dave) void {
        d.version = d.pending_version;
        if (d.version == 0) {
            d.enabled = false;
            d.ready = false;
            return;
        }
        if (!d.ready) return;
        d.ready = false;
        var idbuf: [24]u8 = undefined;
        const self = std.fmt.bufPrintSentinel(&idbuf, "{d}", .{d.me}, 0) catch return;
        const self_ratchet = c.daveSessionGetKeyRatchet(d.session, self.ptr);
        if (self_ratchet != null) {
            c.daveEncryptorSetKeyRatchet(d.encryptor, self_ratchet);
            c.daveEncryptorAssignSsrcToCodec(d.encryptor, d.local_ssrc, c.DAVE_CODEC_OPUS);
            c.daveKeyRatchetDestroy(self_ratchet);
        }
        d.enabled = c.daveEncryptorHasKeyRatchet(d.encryptor);
    }

    fn ensureDecryptor(d: *Dave, ssrc: u32, user: Id) void {
        if (d.decryptors.get(ssrc) == null) {
            const dec = c.daveDecryptorCreate();
            if (dec == null) return;
            d.decryptors.put(alloc, ssrc, dec) catch {
                c.daveDecryptorDestroy(dec);
                return;
            };
        }
        d.setRatchet(ssrc, user);
    }

    fn setRatchet(d: *Dave, ssrc: u32, user: Id) void {
        const dec = d.decryptors.get(ssrc) orelse return;
        var idbuf: [24]u8 = undefined;
        const s = std.fmt.bufPrintSentinel(&idbuf, "{d}", .{user}, 0) catch return;
        const r = c.daveSessionGetKeyRatchet(d.session, s.ptr);
        if (r == null) return;
        c.daveDecryptorTransitionToKeyRatchet(dec, r);
        c.daveKeyRatchetDestroy(r);
    }

    fn encrypt(d: *Dave, ssrc: u32, frame: []const u8, out: []u8) usize {
        const cap = c.daveEncryptorGetMaxCiphertextByteSize(d.encryptor, c.DAVE_MEDIA_TYPE_AUDIO, frame.len);
        if (cap > out.len) return 0;
        var written: usize = 0;
        const rc = c.daveEncryptorEncrypt(d.encryptor, c.DAVE_MEDIA_TYPE_AUDIO, ssrc, frame.ptr, frame.len, out.ptr, out.len, &written);
        if (rc != c.DAVE_ENCRYPTOR_RESULT_CODE_SUCCESS) return 0;
        return written;
    }

    fn decrypt(d: *Dave, ssrc: u32, user: Id, frame: []const u8, out: []u8) ?usize {
        // O decryptor aparece quando o SSRC é anunciado (op 5); se o áudio
        // chegou antes e já sabemos de quem é, cria agora.
        if (d.decryptors.get(ssrc) == null) {
            const owner = d.ssrc_users.get(ssrc) orelse user;
            if (owner == 0) return null;
            d.setSsrcUser(ssrc, owner);
        }
        const dec = d.decryptors.get(ssrc) orelse return null;
        const cap = c.daveDecryptorGetMaxPlaintextByteSize(dec, c.DAVE_MEDIA_TYPE_AUDIO, frame.len);
        if (cap > out.len) return null;
        var written: usize = 0;
        const rc = c.daveDecryptorDecrypt(dec, c.DAVE_MEDIA_TYPE_AUDIO, frame.ptr, frame.len, out.ptr, out.len, &written);
        if (rc != c.DAVE_DECRYPTOR_RESULT_CODE_SUCCESS) return null;
        return written;
    }

    fn setLocalSsrc(d: *Dave, ssrc: u32) void {
        d.local_ssrc = ssrc;
        if (d.encryptor != null) c.daveEncryptorAssignSsrcToCodec(d.encryptor, ssrc, c.DAVE_CODEC_OPUS);
    }
};
