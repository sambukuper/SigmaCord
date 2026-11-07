//! Vídeos tocando dentro do app (anexos e embeds), com o FFmpeg do sistema
//! (platform/ffmpeg.zig, carregado só no primeiro play). Sem FFmpeg, o play
//! abre o vídeo no navegador como antes.
//!
//! Uma thread baixa (pelo mesmo `fetch` das imagens: só domínios
//! permitidos, redirecionamentos conferidos, proxy) e outra decodifica para
//! um anel de 3 quadros RGBA enquanto o download anda; a interface só sobe
//! o quadro da vez para uma textura. Limites: 854×480, ~30 qps e 64 MB
//! baixados (fica tudo na memória para poder voltar). Som pelo SDL (f32).
//! Um vídeo de cada vez; fora da tela pausa e, 30 s depois, solta tudo.
const std = @import("std");
const c = @import("c");
const d = @import("draw.zig");
const anim = @import("anim.zig");
const qa = @import("qa.zig");
const i18n = @import("i18n.zig");
const ffmpeg = @import("../platform/ffmpeg.zig");
const images = @import("images.zig");
const platform = @import("../platform/window.zig");
const media_url = @import("../net/media_url.zig");
const S = @import("settings_state.zig");

const alloc = std.heap.c_allocator;

/// Teto do vídeo baixado (o Discord sem Nitro aceita até 10 MB).
pub const max_bytes: usize = 64 * 1024 * 1024;
const max_w: u32 = 854;
const max_h: u32 = 480;
/// ~30 quadros por segundo no máximo (os outros nem são convertidos).
const min_frame_ms: i64 = 33;
const ring_n = 3;
/// Pacotes de vídeo guardados enquanto o áudio precisa andar na frente.
const max_packets = 600;
const audio_ahead_ms: f64 = 1000;

/// Vídeo da demonstração (3 s, 426×240, 60 qps com som: testa o limite de
/// 30 qps e o áudio). Também vira o "GIF em MP4" da demonstração.
pub const demo_mp4 = @embedFile("demo_video.mp4");
pub const demo_link = "demo:video";

const Status = enum(u8) { opening, ready, failed };
const Fail = enum(u8) { none, download, too_big, format };

const Slot = struct { px: []u8 = &.{}, pts_ms: i64 = 0 };

/// Estado dividido entre a interface e as duas threads (o que não diz
/// "só a thread X" fica sob o mutex). Quem soltar a última referência libera.
const Shared = struct {
    refs: std.atomic.Value(u32),
    stop: std.atomic.Value(bool) = .init(false),
    mutex: *c.SDL_Mutex,
    cond: *c.SDL_Condition,
    url: []u8,
    wake_type: u32,
    want_w: u32,
    want_h: u32,
    audio_on: bool,

    data: std.ArrayList(u8) = .empty,
    dl_done: bool = false,
    dl_failed: bool = false,
    too_big: bool = false,
    total: i64 = -1,
    /// Posição de leitura do FFmpeg (só a thread de decodificação).
    io_pos: usize = 0,

    status: Status = .opening,
    fail: Fail = .none,
    w: u32 = 0,
    h: u32 = 0,
    duration_ms: i64 = 0,
    ring: [ring_n]Slot = @splat(.{}),
    head: usize = 0,
    len: usize = 0,
    /// O decodificador entregou o último quadro.
    eof: bool = false,
    seek_ms: i64 = -1,
    gen: u32 = 0,
    decoded: u32 = 0,

    audio: ?*c.SDL_AudioStream = null,
    audio_base_ms: i64 = 0,
    audio_pushed: u64 = 0,
    audio_bpms: f64 = 0,

    fn lock(sh: *Shared) void {
        c.SDL_LockMutex(sh.mutex);
    }
    fn unlock(sh: *Shared) void {
        c.SDL_UnlockMutex(sh.mutex);
    }
};

fn release(sh: *Shared) void {
    if (sh.refs.fetchSub(1, .acq_rel) != 1) return;
    if (sh.audio) |s| c.SDL_DestroyAudioStream(s);
    for (sh.ring) |s| if (s.px.len > 0) alloc.free(s.px);
    sh.data.deinit(alloc);
    alloc.free(sh.url);
    c.SDL_DestroyCondition(sh.cond);
    c.SDL_DestroyMutex(sh.mutex);
    alloc.destroy(sh);
}

/// Threads ainda rodando (o encerramento do app espera por elas).
var live: std.atomic.Value(u32) = .init(0);

// --- Interface -----------------------------------------------------------------

const Player = struct {
    sh: *Shared,
    key: u64,
    link: [1024]u8 = undefined,
    link_len: usize = 0,
    tex: ?*c.SDL_Texture = null,
    have_frame: bool = false,
    pos_ms: f64 = 0,
    playing: bool = true,
    ended: bool = false,
    /// O ganho já passado para o som (-1: ainda nenhum).
    gain: f32 = -1,
    clock_ms: i64 = 0,
    drawn: bool = false,
    last_drawn_ms: i64 = 0,
    /// Quadros mostrados (o QA confere).
    shown: u32 = 0,
    audio_running: bool = false,
    status: Status = .opening,
    fail: Fail = .none,
    w: u32 = 0,
    h: u32 = 0,
    duration_ms: i64 = 0,
    has_audio: bool = false,
    next_due_ms: ?f64 = null,

    fn linkSlice(p: *const Player) []const u8 {
        return p.link[0..p.link_len];
    }
};

var cur: ?Player = null;
/// O volume antes de silenciar pelo botão.
var unmute_to: u8 = 0;
var vol_dragging = false;
var audio_tried = false;
var audio_ok = false;

/// O vídeo `key` está tocando (ou aberto) no lugar da prévia.
pub fn isActive(key: u64) bool {
    return if (cur) |p| p.key == key else false;
}

/// Dá para tocar aqui dentro? (Para a dica: antes do primeiro play não se
/// sabe se tem FFmpeg; aí a dica promete tocar e o play cai no navegador.)
pub fn canPlay(link: []const u8, size: u64) bool {
    return playable(link) and size <= max_bytes and ffmpeg.known() != false;
}

fn playable(link: []const u8) bool {
    if (std.mem.eql(u8, link, demo_link)) return true;
    if (std.mem.startsWith(u8, link, "file://")) return true;
    return media_url.allowedHost(link);
}

/// Chave de um anexo/embed (mensagem + posição).
pub fn keyOf(msg_id: u64, index: usize) u64 {
    return std.hash.Wyhash.hash(index, std.mem.asBytes(&msg_id));
}

/// O play de uma prévia: toca `link` aqui ou, sem FFmpeg (ou grande
/// demais), abre `page` no navegador.
pub fn click(ctx: *d.Ctx, key: u64, link: []const u8, page: []const u8, r: d.Rect, size: u64) void {
    if (isActive(key)) return;
    const ok = playable(link) and size <= max_bytes and ffmpeg.get() != null and start(ctx, key, link, page, r);
    if (ok) return;
    if (std.mem.startsWith(u8, page, "https://")) {
        @import("attachments.zig").openUrl(page);
        if (ffmpeg.known() == false) ctx.st.showToast(ctx.now_ms, false, "sem FFmpeg, abriu no navegador. Para tocar aqui: Configurações → Chat → Vídeos", "no FFmpeg, opened in the browser. To play here: Settings → Chat → Videos", .{});
    } else ctx.st.showToast(ctx.now_ms, false, "vídeo de demonstração (sem FFmpeg)", "demo video (no FFmpeg)", .{});
}

/// O som do SDL abriu (no QA, o driver mudo).
pub fn audioAvailable() bool {
    return audio_ok;
}

fn ensureAudio() bool {
    if (audio_tried) return audio_ok;
    audio_tried = true;
    // No QA o som vai para o driver mudo (testa o caminho sem fazer barulho).
    if (qa.on()) @import("../net/voz_audio.zig").force_dummy = true;
    // Pelo mesmo caminho da voz: duas threads não podem iniciar o áudio juntas.
    audio_ok = @import("../net/voz_audio.zig").acquire();
    return audio_ok;
}

fn start(ctx: *d.Ctx, key: u64, link: []const u8, page: []const u8, r: d.Rect) bool {
    stop();
    const scale = ctx.io.*.DisplayFramebufferScale.x;
    const mutex = c.SDL_CreateMutex() orelse return false;
    const cond = c.SDL_CreateCondition() orelse {
        c.SDL_DestroyMutex(mutex);
        return false;
    };
    const sh = alloc.create(Shared) catch {
        c.SDL_DestroyCondition(cond);
        c.SDL_DestroyMutex(mutex);
        return false;
    };
    sh.* = .{
        .refs = .init(1),
        .mutex = mutex,
        .cond = cond,
        .url = alloc.dupe(u8, link) catch "",
        .wake_type = ctx.images.wake_type,
        .want_w = @intFromFloat(@max(64, r.w * scale)),
        .want_h = @intFromFloat(@max(64, r.h * scale)),
        .audio_on = ensureAudio(),
    };
    if (sh.url.len == 0) {
        alloc.destroy(sh);
        c.SDL_DestroyCondition(cond);
        c.SDL_DestroyMutex(mutex);
        return false;
    }
    var source = link;
    // SIGMACORD_DEMO_VIDEO=/caminho.mp4 troca o vídeo da demonstração (testes).
    if (std.mem.eql(u8, link, demo_link)) if (c.SDL_getenv("SIGMACORD_DEMO_VIDEO")) |p| {
        var fb: [1024]u8 = undefined;
        if (std.fmt.bufPrint(&fb, "file://{s}", .{std.mem.span(p)})) |f| {
            if (alloc.dupe(u8, f)) |owned| {
                alloc.free(sh.url);
                sh.url = owned;
                source = owned;
            } else |_| {}
        } else |_| {}
    };
    if (std.mem.eql(u8, source, demo_link)) {
        sh.data.appendSlice(alloc, demo_mp4) catch {};
        sh.dl_done = true;
    } else if (!spawn(sh, downloadMain, "video-dl")) {
        release(sh);
        return false;
    }
    if (!spawn(sh, decodeMain, "video")) {
        sh.stop.store(true, .release);
        c.SDL_BroadcastCondition(sh.cond);
        release(sh);
        return false;
    }
    // `drawn`: o clique vem no meio do desenho; não pausa no fim deste quadro.
    var p: Player = .{ .sh = sh, .key = key, .clock_ms = ctx.now_ms, .last_drawn_ms = ctx.now_ms, .drawn = true };
    // O que o "Abrir no navegador" abre se não der para tocar.
    p.link_len = @min(page.len, p.link.len);
    @memcpy(p.link[0..p.link_len], page[0..p.link_len]);
    cur = p;
    return true;
}

fn spawn(sh: *Shared, f: c.SDL_ThreadFunction, name: [*:0]const u8) bool {
    _ = sh.refs.fetchAdd(1, .acq_rel);
    _ = live.fetchAdd(1, .acq_rel);
    const t = c.SDL_CreateThread(f, name, sh) orelse {
        _ = sh.refs.fetchSub(1, .acq_rel);
        _ = live.fetchSub(1, .acq_rel);
        return false;
    };
    c.SDL_DetachThread(t);
    return true;
}

/// Para e solta o vídeo atual (as threads terminam sozinhas).
pub fn stop() void {
    var p = cur orelse return;
    cur = null;
    if (p.tex) |t| c.SDL_DestroyTexture(t);
    const sh = p.sh;
    sh.lock();
    if (sh.audio) |s| _ = c.SDL_PauseAudioStreamDevice(s);
    sh.unlock();
    sh.stop.store(true, .release);
    c.SDL_BroadcastCondition(sh.cond);
    release(sh);
    p.tex = null;
}

/// Fim do app: para e espera as threads (no máximo 3 s).
pub fn shutdown() void {
    stop();
    var waited: u32 = 0;
    while (live.load(.acquire) > 0 and waited < 3000) : (waited += 5) c.SDL_Delay(5);
}

/// A textura recebeu um quadro de vídeo: o desenho é o mesmo, mas a imagem mudou.
var texture_changed = false;

pub fn takeChanged() bool {
    defer texture_changed = false;
    return texture_changed;
}

/// Uma vez por quadro, depois de desenhar: o vídeo que não apareceu neste
/// quadro (rolou para fora, trocou de canal) pausa; 30 s fora, é solto
/// (download, quadros e textura). O app pode estar dormindo: pede um quadro
/// para essa hora, senão a memória só voltaria no próximo evento.
pub fn endFrame(now_ms: i64) void {
    const p = if (cur) |*pp| pp else return;
    if (!p.drawn) {
        if (p.playing) setPlaying(p, false);
        if (now_ms - p.last_drawn_ms > 30_000) stop() else anim.at(p.last_drawn_ms + 30_001);
        return;
    }
    p.drawn = false;
}

/// Para o QA: o que mudou no player (entra na impressão digital da varredura).
pub fn qaState() u64 {
    const p = cur orelse return 0;
    return p.key ^ (@as(u64, @intFromBool(p.playing)) << 1) ^ (@as(u64, @intFromBool(p.gain == 0)) << 2);
}

pub const Info = struct { active: bool = false, playing: bool = false, ended: bool = false, failed: bool = false, ready: bool = false, w: u32 = 0, h: u32 = 0, pos_ms: f64 = 0, duration_ms: i64 = 0, shown: u32 = 0, decoded: u32 = 0, has_audio: bool = false, muted: bool = false, gain: f32 = -1, audio_queued: i32 = 0, drawn_ms: i64 = 0 };

pub fn info() Info {
    const p = cur orelse return .{};
    const sh = p.sh;
    sh.lock();
    defer sh.unlock();
    return .{
        .active = true,
        .playing = p.playing,
        .ended = p.ended,
        .failed = p.status == .failed,
        .ready = p.status == .ready,
        .w = sh.w,
        .h = sh.h,
        .pos_ms = p.pos_ms,
        .duration_ms = p.duration_ms,
        .shown = p.shown,
        .decoded = sh.decoded,
        .has_audio = sh.audio != null,
        .muted = p.gain == 0,
        // O que o SDL está aplicando de fato, não o que pedimos.
        .gain = if (sh.audio) |s| c.SDL_GetAudioStreamGain(s) else -1,
        .audio_queued = if (sh.audio) |s| c.SDL_GetAudioStreamQueued(s) else 0,
        .drawn_ms = p.last_drawn_ms,
    };
}

fn setPlaying(p: *Player, on: bool) void {
    if (on and p.ended) {
        seek(p, 0);
        p.ended = false;
    }
    p.playing = on;
    syncAudio(p);
}

/// A janela foi para a bandeja: pausa, sem fechar o vídeo.
pub fn pause() void {
    const p = if (cur) |*pp| pp else return;
    if (p.playing) setPlaying(p, false);
}

fn seek(p: *Player, ms: i64) void {
    const sh = p.sh;
    sh.lock();
    sh.seek_ms = @max(0, ms);
    sh.gen +%= 1;
    sh.len = 0;
    sh.eof = false;
    sh.unlock();
    c.SDL_BroadcastCondition(sh.cond);
    p.pos_ms = @floatFromInt(@max(0, ms));
    p.have_frame = false;
    p.ended = false;
    syncAudio(p);
}

/// Som andando só quando a imagem anda.
fn syncAudio(p: *Player) void {
    const s = p.sh.audio orelse return;
    const want = p.playing and p.have_frame and !p.ended;
    if (want == p.audio_running) return;
    p.audio_running = want;
    _ = if (want) c.SDL_ResumeAudioStreamDevice(s) else c.SDL_PauseAudioStreamDevice(s);
}

/// O slider vale na hora, mesmo no meio do que já está na fila do som.
fn applyVolume(p: *Player, volume: u8) void {
    const s = p.sh.audio orelse return;
    const gain = S.videoGain(volume);
    if (gain != p.gain and c.SDL_SetAudioStreamGain(s, gain)) p.gain = gain;
}

fn saveVolume(ctx: *d.Ctx) void {
    ctx.act(.{ .set_setting = .{ .index = S.fieldIndex("video_volume"), .value = ctx.st.settings.video_volume } });
}

/// Avança o relógio e sobe o quadro da vez.
fn update(p: *Player, renderer: *c.SDL_Renderer, now_ms: i64) void {
    const sh = p.sh;
    const dt: f64 = @floatFromInt(std.math.clamp(now_ms - p.clock_ms, 0, 250));
    p.clock_ms = now_ms;
    sh.lock();
    defer sh.unlock();
    p.status = sh.status;
    p.fail = sh.fail;
    p.w = sh.w;
    p.h = sh.h;
    if (sh.duration_ms > 0) p.duration_ms = sh.duration_ms;
    p.has_audio = sh.audio != null;
    if (p.tex == null and sh.w > 0 and sh.h > 0) {
        p.tex = c.SDL_CreateTexture(renderer, c.SDL_PIXELFORMAT_RGBA32, c.SDL_TEXTUREACCESS_STREAMING, @intCast(sh.w), @intCast(sh.h));
        if (p.tex) |t| _ = c.SDL_SetTextureScaleMode(t, c.SDL_SCALEMODE_LINEAR);
    }
    const stalled = sh.len == 0 and !sh.eof;
    if (p.playing and p.have_frame and !stalled and !p.ended) {
        p.pos_ms += dt;
        // O som manda no relógio (o dispositivo de áudio não anda exatamente
        // no ritmo do relógio do sistema).
        if (sh.audio) |s| if (sh.audio_bpms > 0) {
            const queued = c.SDL_GetAudioStreamQueued(s);
            if (queued > 0) {
                const played: f64 = @as(f64, @floatFromInt(sh.audio_pushed)) - @as(f64, @floatFromInt(queued));
                const apos = @as(f64, @floatFromInt(sh.audio_base_ms)) + played / sh.audio_bpms;
                if (@abs(apos - p.pos_ms) > 80) p.pos_ms = apos;
            }
        };
    }
    // Quadros vencidos: só o último sobe para a textura.
    var due: usize = 0;
    while (due < sh.len) : (due += 1) {
        const s = &sh.ring[(sh.head + due) % ring_n];
        if (!p.have_frame and due == 0) {
            p.pos_ms = @floatFromInt(s.pts_ms);
            p.have_frame = true;
            continue;
        }
        if (@as(f64, @floatFromInt(s.pts_ms)) > p.pos_ms + 2) break;
    }
    if (due > 0) {
        const s = &sh.ring[(sh.head + due - 1) % ring_n];
        if (p.tex) |t| _ = c.SDL_UpdateTexture(t, null, s.px.ptr, @intCast(sh.w * 4));
        texture_changed = true;
        sh.head = (sh.head + due) % ring_n;
        sh.len -= due;
        p.shown += 1;
        c.SDL_BroadcastCondition(sh.cond);
    }
    p.next_due_ms = if (sh.len > 0) @as(f64, @floatFromInt(sh.ring[sh.head].pts_ms)) - p.pos_ms else null;
    if (sh.eof and sh.len == 0 and p.have_frame and !p.ended) {
        // Acabou: fica no último quadro, com o play para recomeçar.
        if (p.duration_ms <= 0) p.duration_ms = @intFromFloat(p.pos_ms);
        p.pos_ms = @floatFromInt(p.duration_ms);
        p.ended = true;
        p.playing = false;
    }
    if (p.duration_ms > 0) p.pos_ms = @min(p.pos_ms, @as(f64, @floatFromInt(p.duration_ms)));
}

fn fmtTime(buf: []u8, ms: f64) []const u8 {
    const s: u64 = @intFromFloat(@max(0, ms) / 1000);
    return std.fmt.bufPrint(buf, "{d}:{d:0>2}", .{ s / 60, s % 60 }) catch "";
}

/// Desenha o vídeo `key` (ativo) em `r`. `preview` é a prévia parada,
/// mostrada até chegar o primeiro quadro.
pub fn draw(ctx: *d.Ctx, dl: *c.ImDrawList, r: d.Rect, alpha: f32, msg_id: u64, preview: ?images.Tex) void {
    const p = if (cur) |*pp| pp else return;
    p.drawn = true;
    p.last_drawn_ms = ctx.now_ms;
    update(p, ctx.images.renderer, ctx.now_ms);
    // Antes de soltar o som: o primeiro instante já sai no volume certo.
    applyVolume(p, ctx.st.settings.video_volume);
    syncAudio(p);
    const radius: f32 = 8;
    const ids: usize = @truncate(p.key);
    const hovered = ctx.hovering(r);

    d.rect(dl, r, d.Rgba.black.alpha(alpha), radius);
    if (p.have_frame and p.tex != null and p.w > 0) {
        // Cabe no retângulo sem distorcer (faixas pretas se precisar).
        const vw: f32 = @floatFromInt(p.w);
        const vh: f32 = @floatFromInt(p.h);
        const k = @min(r.w / vw, r.h / vh);
        const iw = vw * k;
        const ih = vh * k;
        const ix = r.x + (r.w - iw) / 2;
        const iy = r.y + (r.h - ih) / 2;
        const ref: c.ImTextureRef = .{ ._TexData = null, ._TexID = @intFromPtr(p.tex.?) };
        c.ImDrawList_AddImageRounded(dl, ref, d.v(ix, iy), d.v(ix + iw, iy + ih), d.v(0, 0), d.v(1, 1), d.Rgba.white.col(alpha), radius, 0);
    } else if (preview) |t| {
        c.ImDrawList_AddImageRounded(dl, t.ref, d.v(r.x, r.y), d.v(r.right(), r.bottom()), d.v(0, 0), d.v(1, 1), d.Rgba.white.col(0.5 * alpha), radius, 0);
    }
    const failed = p.status == .failed;
    const waiting = !failed and (!p.have_frame or (p.playing and p.next_due_ms == null and !p.ended));
    if (waiting and !p.have_frame) {
        const t = @as(f32, @floatFromInt(@mod(ctx.now_ms, 100_000))) / 1000.0;
        c.ImDrawList_PathArcTo(dl, d.v(r.x + r.w / 2, r.y + r.h / 2), 18, t * 5, t * 5 + 4.2, 32);
        c.ImDrawList_PathStroke(dl, d.Rgba.white.col(0.8 * alpha), 2.5, 0);
        anim.every(50);
    }
    if (failed) {
        const f = ctx.ui.get(.medium);
        const msg = switch (p.fail) {
            .too_big => i18n.tr("vídeo grande demais para tocar aqui", "video too large to play here"),
            .download => i18n.tr("não deu para baixar o vídeo", "couldn't download the video"),
            else => i18n.tr("não deu para tocar este vídeo", "couldn't play this video"),
        };
        d.text(dl, f, 13, r.x + (r.w - d.width(f, 13, msg)) / 2, r.y + r.h / 2 - 26, d.Rgba.white.alpha(0.85 * alpha), msg);
        const link = p.linkSlice();
        if (std.mem.startsWith(u8, link, "https://")) {
            const label = i18n.tr("Abrir no navegador", "Open in Browser");
            const bw = d.width(f, 13, label) + 24;
            const br: d.Rect = .{ .x = r.x + (r.w - bw) / 2, .y = r.y + r.h / 2, .w = bw, .h = 30 };
            const hb = d.hit(ctx, ids +% 7, br);
            qa.mark(br, "video-browser", .{});
            d.rect(dl, br, d.Rgba.white.alpha((if (hb.hovered) @as(f32, 0.22) else 0.12) * alpha), 6);
            d.text(dl, f, 13, br.x + 12, d.centerY(br, 13), d.Rgba.white.alpha(alpha), label);
            if (hb.clicked) {
                @import("attachments.zig").openUrl(link);
                stop();
                return;
            }
        }
    }

    // Fechar (volta à prévia).
    const xr: d.Rect = .{ .x = r.right() - 32, .y = r.y + 6, .w = 26, .h = 26 };
    const xh = d.hit(ctx, ids +% 1, xr);
    qa.mark(xr, "video-close", .{});
    if (hovered or failed or !p.playing) {
        d.circle(dl, xr.x + 13, xr.y + 13, 12, d.Rgba.black.alpha((if (xh.hovered) @as(f32, 0.8) else 0.55) * alpha));
        d.line(dl, xr.x + 8.5, xr.y + 8.5, xr.x + 17.5, xr.y + 17.5, d.Rgba.white.alpha(alpha), 1.6);
        d.line(dl, xr.x + 17.5, xr.y + 8.5, xr.x + 8.5, xr.y + 17.5, d.Rgba.white.alpha(alpha), 1.6);
    }
    if (xh.clicked) {
        stop();
        return;
    }

    // Barra de controles: com o mouse em cima, pausado ou no fim.
    const show_bar = !failed and (hovered or !p.playing or p.ended or vol_dragging);
    const bar: d.Rect = .{ .x = r.x, .y = r.bottom() - 36, .w = r.w, .h = 36 };
    if (show_bar) {
        const top = d.Rgba.black.col(0);
        const bot = d.Rgba.black.col(0.7 * alpha);
        c.ImDrawList_AddRectFilledMultiColor(dl, d.v(bar.x, bar.y - 14), d.v(bar.right(), bar.y), top, top, d.Rgba.black.col(0.35 * alpha), d.Rgba.black.col(0.35 * alpha));
        d.rectFlags(dl, bar, d.Rgba.black.alpha(0.35 * alpha), radius, c.ImDrawFlags_RoundCornersBottom);
        _ = bot;
    }
    const pr: d.Rect = .{ .x = bar.x + 6, .y = bar.y + 4, .w = 28, .h = 28 };
    const ph = d.hit(ctx, ids +% 2, pr);
    qa.mark(pr, "video-play", .{});
    if (show_bar) {
        const ccx = pr.x + 14;
        const ccy = pr.y + 14;
        const col = d.Rgba.white.alpha((if (ph.hovered) @as(f32, 1) else 0.88) * alpha);
        if (p.playing) {
            d.rect(dl, .{ .x = ccx - 6, .y = ccy - 7, .w = 4, .h = 14 }, col, 1);
            d.rect(dl, .{ .x = ccx + 2, .y = ccy - 7, .w = 4, .h = 14 }, col, 1);
        } else c.ImDrawList_AddTriangleFilled(dl, d.v(ccx - 5, ccy - 8), d.v(ccx - 5, ccy + 8), d.v(ccx + 8, ccy), col.u());
    }
    if (ph.clicked and !failed) setPlaying(p, !p.playing);

    // Tempo.
    const f = ctx.ui.get(.medium);
    var tb1: [16]u8 = undefined;
    var tb2: [16]u8 = undefined;
    var tbuf: [40]u8 = undefined;
    const ttxt = if (p.duration_ms > 0)
        std.fmt.bufPrint(&tbuf, "{s} / {s}", .{ fmtTime(&tb1, p.pos_ms), fmtTime(&tb2, @floatFromInt(p.duration_ms)) }) catch ""
    else
        fmtTime(&tb1, p.pos_ms);
    // Num vídeo estreito, o espaço do tempo fica para as barras.
    const show_time = r.w >= 260;
    const tw = if (show_time) d.width(f, 12, ttxt) else 0;
    if (show_bar and show_time) d.text(dl, f, 12, pr.right() + 6, d.centerY(bar, 12), d.Rgba.white.alpha(0.9 * alpha), ttxt);

    // Som (só se o vídeo tem).
    var right = bar.right() - 8;
    if (p.has_audio) {
        const mr: d.Rect = .{ .x = right - 26, .y = bar.y + 5, .w = 26, .h = 26 };
        right = mr.x - 6;
        const mh = d.hit(ctx, ids +% 3, mr);
        qa.mark(mr, "video-mute", .{});
        const volume = &ctx.st.settings.video_volume;
        if (show_bar) speakerIcon(dl, mr.x + 13, mr.y + 13, d.Rgba.white.alpha((if (mh.hovered) @as(f32, 1) else 0.85) * alpha), volume.*);
        if (mh.clicked) {
            if (volume.* > 0) {
                unmute_to = volume.*;
                volume.* = 0;
            } else volume.* = if (unmute_to > 0) unmute_to else 100;
            applyVolume(p, volume.*);
            saveVolume(ctx);
        }

        // Volume: à esquerda do alto-falante, no mesmo desenho da barra de progresso.
        const vw: f32 = if (r.w >= 320) 72 else 44;
        const vt: d.Rect = .{ .x = right - vw, .y = bar.y + 16, .w = vw, .h = 4 };
        right = vt.x - 10;
        const vr: d.Rect = .{ .x = vt.x - 6, .y = bar.y + 6, .w = vw + 12, .h = 24 };
        const vh = d.hit(ctx, ids +% 6, vr);
        qa.mark(vr, "video-vol", .{});
        if (vh.held) {
            volume.* = @intFromFloat(std.math.round(std.math.clamp((ctx.mouse.x - vt.x) / vt.w, 0, 1) * 100));
            applyVolume(p, volume.*);
            vol_dragging = true;
        } else if (vol_dragging) {
            // Grava ao soltar, mesmo fora da barra (não a cada pixel do arrasto).
            vol_dragging = false;
            saveVolume(ctx);
        }
        if (show_bar) {
            const k = @as(f32, @floatFromInt(@min(volume.*, 100))) / 100;
            d.rect(dl, vt, d.Rgba.white.alpha(0.25 * alpha), 2);
            d.rect(dl, .{ .x = vt.x, .y = vt.y, .w = vt.w * k, .h = vt.h }, d.Rgba.white.alpha(0.9 * alpha), 2);
            if (vh.hovered or vh.held) d.circle(dl, vt.x + vt.w * k, vt.y + 2, 6, d.Rgba.white.alpha(alpha));
        }
    }

    // Barra de progresso (clicar pula para o ponto).
    const tx0 = if (show_time) pr.right() + 6 + tw + 12 else pr.right() + 8;
    const track: d.Rect = .{ .x = tx0, .y = bar.y + 16, .w = @max(10, right - tx0 - 4), .h = 4 };
    const hr: d.Rect = .{ .x = track.x - 4, .y = bar.y + 6, .w = track.w + 8, .h = 24 };
    const th = d.hit(ctx, ids +% 4, hr);
    qa.mark(hr, "video-bar", .{});
    const dur: f64 = @floatFromInt(p.duration_ms);
    if (show_bar and track.w > 20) {
        const k: f32 = if (dur > 0) @floatCast(std.math.clamp(p.pos_ms / dur, 0, 1)) else 0;
        d.rect(dl, track, d.Rgba.white.alpha(0.25 * alpha), 2);
        d.rect(dl, .{ .x = track.x, .y = track.y, .w = track.w * k, .h = track.h }, ctx.col(.accent).alpha(alpha), 2);
        if (th.hovered or th.held) d.circle(dl, track.x + track.w * k, track.y + 2, 6, d.Rgba.white.alpha(alpha));
        // Arrastando: mostra onde vai soltar.
        if (th.held and dur > 0) {
            const hk = std.math.clamp((ctx.mouse.x - track.x) / track.w, 0, 1);
            d.circle(dl, track.x + track.w * hk, track.y + 2, 4, ctx.col(.accent).alpha(alpha));
        }
    }
    if (th.clicked and dur > 0 and !failed) {
        const hk: f64 = std.math.clamp((ctx.mouse.x - track.x) / track.w, 0, 1);
        seek(p, @intFromFloat(hk * dur));
        if (p.ended) p.ended = false;
    }

    // O resto do vídeo: clique pausa/continua; botão direito, o menu.
    const area = d.hit(ctx, ids +% 5, r);
    qa.mark(r, "video", .{});
    if (area.clicked and !failed) setPlaying(p, !p.playing);
    if (area.right and msg_id != 0) ctx.popup(.{ .menu = .{ .kind = .message, .id = msg_id, .x = ctx.mouse.x, .y = ctx.mouse.y } });

    // Próximo redesenho: o próximo quadro (o decodificador acorda o app
    // quando o anel estava vazio).
    if (p.playing and !p.ended) {
        if (p.next_due_ms) |due| anim.at(ctx.now_ms + @as(i64, @intFromFloat(@max(1, @ceil(due))))) else anim.every(100);
    }
}

fn speakerIcon(dl: *c.ImDrawList, cx: f32, cy: f32, col: d.Rgba, volume: u8) void {
    d.rect(dl, .{ .x = cx - 8, .y = cy - 3, .w = 4, .h = 6 }, col, 0);
    c.ImDrawList_AddTriangleFilled(dl, d.v(cx - 5, cy - 3), d.v(cx + 1, cy - 8), d.v(cx + 1, cy + 8), col.u());
    c.ImDrawList_AddTriangleFilled(dl, d.v(cx - 5, cy - 3), d.v(cx + 1, cy + 8), d.v(cx - 5, cy + 3), col.u());
    if (volume == 0) {
        d.line(dl, cx + 4, cy - 4, cx + 10, cy + 4, col, 1.6);
        d.line(dl, cx + 10, cy - 4, cx + 4, cy + 4, col, 1.6);
    } else {
        c.ImDrawList_PathArcTo(dl, d.v(cx + 1, cy), 5, -0.9, 0.9, 10);
        c.ImDrawList_PathStroke(dl, col.u(), 1.5, 0);
        if (volume >= 50) {
            c.ImDrawList_PathArcTo(dl, d.v(cx + 1, cy), 9, -0.9, 0.9, 12);
            c.ImDrawList_PathStroke(dl, col.u(), 1.5, 0);
        }
    }
}

// --- Thread de download ----------------------------------------------------------

fn downloadMain(ud: ?*anyopaque) callconv(.c) c_int {
    const sh: *Shared = @ptrCast(@alignCast(ud.?));
    defer {
        platform.Window.wake(sh.wake_type, .media);
        release(sh);
        _ = live.fetchSub(1, .acq_rel);
    }
    _ = c.SDL_SetCurrentThreadPriority(c.SDL_THREAD_PRIORITY_LOW);
    var ok = false;
    if (std.mem.startsWith(u8, sh.url, "file://")) {
        ok = loadFile(sh);
    } else {
        var curl: ?*c.CURL = null;
        defer if (curl) |h| c.curl_easy_cleanup(h);
        var zb: [2048]u8 = undefined;
        if (std.fmt.bufPrintSentinel(&zb, "{s}", .{sh.url}, 0)) |z| {
            ok = images.fetch(&curl, z, .{ .ctx = sh, .write = dlWrite }, &sh.stop, 0);
        } else |_| {}
    }
    sh.lock();
    if (ok) sh.dl_done = true else sh.dl_failed = true;
    sh.unlock();
    c.SDL_BroadcastCondition(sh.cond);
    return 0;
}

fn loadFile(sh: *Shared) bool {
    var pbuf: [1024]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&pbuf, "{s}", .{sh.url[7..]}, 0) catch return false;
    var size: usize = 0;
    const data = c.SDL_LoadFile(path.ptr, &size) orelse return false;
    defer c.SDL_free(data);
    sh.lock();
    defer sh.unlock();
    if (size > max_bytes) {
        sh.too_big = true;
        return false;
    }
    sh.data.appendSlice(alloc, @as([*]const u8, @ptrCast(data))[0..size]) catch return false;
    sh.total = @intCast(size);
    return true;
}

fn dlWrite(ud: *anyopaque, chunk: []const u8, total: i64) bool {
    const sh: *Shared = @ptrCast(@alignCast(ud));
    sh.lock();
    defer sh.unlock();
    if (sh.data.items.len + chunk.len > max_bytes or total > @as(i64, max_bytes)) {
        sh.too_big = true;
        return false;
    }
    // Tamanho conhecido: reserva tudo de uma vez (sem realocar e copiar o
    // que já veio a cada pedaço, com o decodificador esperando o mutex).
    if (total > 0 and sh.data.capacity < @as(usize, @intCast(total)))
        sh.data.ensureTotalCapacityPrecise(alloc, @intCast(total)) catch {};
    sh.data.appendSlice(alloc, chunk) catch return false;
    sh.total = total;
    c.SDL_BroadcastCondition(sh.cond);
    return true;
}

// O FFmpeg lê do que já chegou e espera o resto.
fn ioRead(ud: ?*anyopaque, buf: [*]u8, size: c_int) callconv(.c) c_int {
    const sh: *Shared = @ptrCast(@alignCast(ud.?));
    sh.lock();
    defer sh.unlock();
    while (true) {
        if (sh.stop.load(.acquire)) return ffmpeg.err_exit;
        if (sh.io_pos < sh.data.items.len) {
            const n = @min(@as(usize, @intCast(@max(size, 0))), sh.data.items.len - sh.io_pos);
            @memcpy(buf[0..n], sh.data.items[sh.io_pos..][0..n]);
            sh.io_pos += n;
            return @intCast(n);
        }
        if (sh.dl_done) return ffmpeg.err_eof;
        if (sh.dl_failed) return ffmpeg.err_io;
        _ = c.SDL_WaitConditionTimeout(sh.cond, sh.mutex, 100);
    }
}

fn ioSeek(ud: ?*anyopaque, off: i64, whence: c_int) callconv(.c) i64 {
    const sh: *Shared = @ptrCast(@alignCast(ud.?));
    sh.lock();
    defer sh.unlock();
    const len: i64 = if (sh.dl_done) @intCast(sh.data.items.len) else sh.total;
    return ffmpeg.seekTo(&sh.io_pos, len, off, whence);
}

// --- Thread de decodificação -------------------------------------------------------

fn decodeMain(ud: ?*anyopaque) callconv(.c) c_int {
    const sh: *Shared = @ptrCast(@alignCast(ud.?));
    defer {
        platform.Window.wake(sh.wake_type, .media);
        release(sh);
        _ = live.fetchSub(1, .acq_rel);
    }
    const a = ffmpeg.get() orelse return failWith(sh, .format);
    var m = ffmpeg.Media.open(a, .{ .ctx = sh, .read = ioRead, .seek = ioSeek }, sh.audio_on, 2) catch return failWith(sh, .format);
    defer m.close();
    var dec: Decoder = .{ .sh = sh, .m = &m };
    defer dec.deinit();
    sh.lock();
    sh.duration_ms = m.duration_ms;
    sh.unlock();
    if (m.hasAudio()) dec.openAudio();
    dec.run();
    return 0;
}

/// Falhou antes do primeiro quadro: diz por quê (o download manda).
fn failWith(sh: *Shared, why: Fail) c_int {
    sh.lock();
    defer sh.unlock();
    if (sh.status == .ready) return 0;
    sh.status = .failed;
    sh.fail = if (sh.too_big) .too_big else if (sh.dl_failed) .download else why;
    return 0;
}

const Decoder = struct {
    sh: *Shared,
    m: *ffmpeg.Media,
    pktq: std.ArrayList(*ffmpeg.Packet) = .empty,
    pool: std.ArrayList(*ffmpeg.Packet) = .empty,
    demux_eof: bool = false,
    video_eof: bool = false,
    flushed: bool = false,
    skip_until: i64 = 0,
    last_out: i64 = std.math.minInt(i64) / 2,
    gen: u32 = 0,
    audio_fresh: bool = true,

    fn deinit(dec: *Decoder) void {
        const a = dec.m.api;
        for (dec.pktq.items) |p| {
            var pp: ?*ffmpeg.Packet = p;
            a.av_packet_free(&pp);
        }
        for (dec.pool.items) |p| {
            var pp: ?*ffmpeg.Packet = p;
            a.av_packet_free(&pp);
        }
        dec.pktq.deinit(alloc);
        dec.pool.deinit(alloc);
    }

    fn openAudio(dec: *Decoder) void {
        const m = dec.m;
        const spec: c.SDL_AudioSpec = .{ .format = c.SDL_AUDIO_F32, .channels = @intCast(m.channels), .freq = @intCast(m.rate) };
        const s = c.SDL_OpenAudioDeviceStream(c.SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, &spec, null, null) orelse return;
        dec.sh.lock();
        dec.sh.audio = s;
        dec.sh.audio_bpms = @as(f64, @floatFromInt(m.rate * m.channels * 4)) / 1000.0;
        dec.sh.unlock();
    }

    fn audioQueuedMs(dec: *Decoder) f64 {
        const s = dec.sh.audio orelse return std.math.inf(f64);
        if (dec.sh.audio_bpms <= 0) return std.math.inf(f64);
        return @as(f64, @floatFromInt(c.SDL_GetAudioStreamQueued(s))) / dec.sh.audio_bpms;
    }

    /// Quadro de áudio decodificado (chamado pelo Media.decodeAudio).
    pub fn audio(dec: *Decoder, samples: []const f32, pts: ?i64) void {
        const sh = dec.sh;
        const s = sh.audio orelse return;
        if (pts) |t| if (t < dec.skip_until) return;
        const bytes = samples.len * 4;
        sh.lock();
        defer sh.unlock();
        if (dec.gen != sh.gen) return;
        if (dec.audio_fresh) {
            dec.audio_fresh = false;
            sh.audio_base_ms = pts orelse dec.skip_until;
            sh.audio_pushed = 0;
        }
        if (c.SDL_PutAudioStreamData(s, samples.ptr, @intCast(bytes))) sh.audio_pushed += bytes;
    }

    fn ringRoom(dec: *Decoder) bool {
        dec.sh.lock();
        defer dec.sh.unlock();
        return dec.sh.len < ring_n;
    }

    fn run(dec: *Decoder) void {
        const sh = dec.sh;
        const m = dec.m;
        while (!sh.stop.load(.acquire)) {
            // Pulo pedido pela interface.
            sh.lock();
            const want = sh.seek_ms;
            if (want >= 0) {
                sh.seek_ms = -1;
                dec.gen = sh.gen;
            }
            sh.unlock();
            if (want >= 0) {
                m.seek(want);
                for (dec.pktq.items) |p| {
                    m.unref(p);
                    dec.pool.append(alloc, p) catch {};
                }
                dec.pktq.clearRetainingCapacity();
                dec.demux_eof = false;
                dec.video_eof = false;
                dec.flushed = false;
                dec.skip_until = want;
                dec.last_out = std.math.minInt(i64) / 2;
                dec.audio_fresh = true;
                if (sh.audio) |s| _ = c.SDL_ClearAudioStream(s);
                continue;
            }
            var did = false;
            if (!dec.video_eof and dec.ringRoom()) {
                const r = m.receiveVideo();
                if (r == 0) {
                    dec.onFrame();
                    did = true;
                } else if (r == ffmpeg.err_again) {
                    if (dec.pktq.items.len > 0) {
                        const p = dec.pktq.orderedRemove(0);
                        _ = m.sendVideo(p);
                        m.unref(p);
                        dec.pool.append(alloc, p) catch {
                            var pp: ?*ffmpeg.Packet = p;
                            m.api.av_packet_free(&pp);
                        };
                        did = true;
                    } else if (dec.demux_eof and !dec.flushed) {
                        _ = m.sendVideo(null);
                        dec.flushed = true;
                        did = true;
                    }
                } else {
                    dec.video_eof = true;
                    sh.lock();
                    sh.eof = true;
                    const none = sh.decoded == 0 and sh.status == .opening;
                    sh.unlock();
                    if (none) _ = failWith(sh, .format);
                    platform.Window.wake(sh.wake_type, .media);
                    did = true;
                }
            }
            // Mais pacotes: poucos de vídeo na fila, ou o som ficando curto.
            const audio_low = sh.audio != null and dec.audioQueuedMs() < audio_ahead_ms;
            if (!dec.demux_eof and (dec.pktq.items.len < 8 or (audio_low and dec.pktq.items.len < max_packets))) {
                switch (m.read()) {
                    .video => dec.queue(),
                    .audio => {
                        m.decodeAudio(m.pkt.?, dec);
                        m.unref(m.pkt.?);
                    },
                    .skip => {},
                    .eof => dec.demux_eof = true,
                }
                did = true;
            }
            if (!did) {
                sh.lock();
                if (sh.seek_ms < 0 and !sh.stop.load(.acquire)) _ = c.SDL_WaitConditionTimeout(sh.cond, sh.mutex, 20);
                sh.unlock();
            }
        }
    }

    fn queue(dec: *Decoder) void {
        const m = dec.m;
        const p = dec.pool.pop() orelse m.api.av_packet_alloc() orelse {
            m.unref(m.pkt.?);
            return;
        };
        m.api.av_packet_move_ref(p, m.pkt.?);
        dec.pktq.append(alloc, p) catch {
            m.unref(p);
            var pp: ?*ffmpeg.Packet = p;
            m.api.av_packet_free(&pp);
        };
    }

    fn onFrame(dec: *Decoder) void {
        const sh = dec.sh;
        const m = dec.m;
        const t = m.framePtsMs(m.vtb) orelse dec.last_out + min_frame_ms;
        // Antes do ponto pedido, ou cedo demais para 30 qps: nem converte.
        if (t < dec.skip_until - 2) return;
        if (t < dec.last_out + min_frame_ms - 3) return;
        const src = m.frameSize();
        if (src[0] == 0 or src[1] == 0) return;
        sh.lock();
        if (sh.w == 0) {
            // Tamanho de saída: cabe no retângulo da tela e em 854×480.
            const bw = @min(sh.want_w, max_w);
            const bh = @min(sh.want_h, max_h);
            const k = @min(1.0, @min(@as(f64, @floatFromInt(bw)) / @as(f64, @floatFromInt(src[0])), @as(f64, @floatFromInt(bh)) / @as(f64, @floatFromInt(src[1]))));
            const ow: u32 = @max(2, @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(src[0])) * k))));
            const oh: u32 = @max(2, @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(src[1])) * k))));
            var ok = true;
            for (&sh.ring) |*s| {
                s.px = alloc.alloc(u8, ffmpeg.rgbaSize(ow, oh)) catch {
                    ok = false;
                    break;
                };
            }
            if (!ok) {
                sh.unlock();
                _ = failWith(sh, .format);
                sh.stop.store(true, .release);
                return;
            }
            sh.w = ow;
            sh.h = oh;
        }
        const idx = (sh.head + sh.len) % ring_n;
        const gen = sh.gen;
        const room = sh.len < ring_n;
        const slot = sh.ring[idx];
        sh.unlock();
        if (!room or gen != dec.gen) return;
        if (!m.toRgba(slot.px, sh.w, sh.h)) return;
        sh.lock();
        // A interface pode ter pulado (seek) enquanto convertia: descarta.
        if (gen == sh.gen and sh.len < ring_n and (sh.head + sh.len) % ring_n == idx) {
            sh.ring[idx].pts_ms = t;
            const was_empty = sh.len == 0;
            sh.len += 1;
            sh.decoded += 1;
            sh.status = .ready;
            dec.last_out = t;
            sh.unlock();
            if (was_empty) platform.Window.wake(sh.wake_type, .media);
            return;
        }
        sh.unlock();
    }
};
