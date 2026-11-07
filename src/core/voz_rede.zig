//! Simula a rede ruim para a recepção de voz: `zig build voz-rede` (sempre em
//! ReleaseFast). Opus de verdade, 60 s de fala por cenário, um dispositivo que
//! puxa áudio em ritmo fixo. Compara o jeito antigo de tocar com `voz.Jitter` e
//! conta buracos e estalos. `SIGMACORD_VOZ_FALA=arquivo.wav` (48 kHz, 16 bits, mono)
//! usa a fala dele, e `SIGMACORD_VOZ_WAV=pasta` grava o que saiu para ouvir.
//! Só para quem desenvolve; não entra no app.
const std = @import("std");
const voz = @import("voz.zig");

extern fn opus_encoder_create(fs: i32, channels: c_int, application: c_int, err: *c_int) ?*anyopaque;
extern fn opus_encoder_ctl(st: *anyopaque, request: c_int, ...) c_int;
extern fn opus_encode(st: *anyopaque, pcm: [*]const i16, frame_size: c_int, data: [*]u8, max: i32) i32;
extern fn opus_decoder_create(fs: i32, channels: c_int, err: *c_int) ?*anyopaque;
extern fn opus_decoder_destroy(st: *anyopaque) void;
extern fn opus_decode(st: *anyopaque, data: ?[*]const u8, len: i32, pcm: [*]i16, frame_size: c_int, fec: c_int) c_int;
extern fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern fn fread(p: [*]u8, size: usize, n: usize, f: *anyopaque) usize;
extern fn fwrite(p: [*]const u8, size: usize, n: usize, f: *anyopaque) usize;
extern fn fclose(f: *anyopaque) c_int;
extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern fn printf(fmt: [*:0]const u8, ...) c_int;

const gpa = std.heap.c_allocator;
const seconds = 60;
const n_packets = seconds * 1000 / voz.frame_ms;
/// Um "quantum" típico do PipeWire: o dispositivo puxa 21 ms de cada vez.
const pull_frames = 1024;

const Scenario = struct {
    name: [*:0]const u8,
    file: [:0]const u8,
    loss_pct: f32 = 0,
    /// Chance de um buraco de 3 pacotes seguidos.
    burst_pct: f32 = 0,
    jitter_ms: f32 = 0,
    reorder_pct: f32 = 0,
    /// A cada tanto, nada chega por um tempo e depois vem tudo de uma vez.
    stall_every_ms: i64 = 0,
    stall_ms: i64 = 0,
    /// A porta de ruído de quem fala: rajadas curtas, com o relógio RTP andando.
    gate: bool = false,
    /// Dispositivo que puxa mais áudio de cada vez.
    pull: u32 = pull_frames,
};

const scenarios = [_]Scenario{
    .{ .name = "rede limpa", .file = "limpa" },
    .{ .name = "perde 2%", .file = "perde2", .loss_pct = 2 },
    .{ .name = "perde 5% + rajadas", .file = "perde5", .loss_pct = 5, .burst_pct = 0.5 },
    .{ .name = "atraso de ate 30 ms", .file = "atraso30", .jitter_ms = 30 },
    .{ .name = "atraso de ate 80 ms", .file = "atraso80", .jitter_ms = 80 },
    .{ .name = "fora de ordem 3%", .file = "ordem", .jitter_ms = 5, .reorder_pct = 3 },
    .{ .name = "para 300 ms a cada 7 s", .file = "para300", .stall_every_ms = 7000, .stall_ms = 300 },
    .{ .name = "fala com pausas, para 200 ms", .file = "para200", .gate = true, .jitter_ms = 5, .stall_every_ms = 12_000, .stall_ms = 200 },
    .{ .name = "wi-fi ruim (tudo junto)", .file = "wifi", .loss_pct = 3, .burst_pct = 0.3, .jitter_ms = 40, .reorder_pct = 1, .stall_every_ms = 11000, .stall_ms = 200 },
    .{ .name = "porta de ruido de quem fala", .file = "porta", .gate = true, .jitter_ms = 5 },
    .{ .name = "dispositivo de 85 ms", .file = "disp85", .jitter_ms = 10, .pull = 4096 },
};

const Packet = struct { seq: u16, ts: u32, arrive_ms: i64, data: []const u8 };

fn lessArrive(_: void, a: Packet, b: Packet) bool {
    return a.arrive_ms < b.arrive_ms;
}

/// Fala de mentira: harmônicas com entonação e sílabas.
fn synth(out: []i16) void {
    var phase: f32 = 0;
    for (out, 0..) |*s, i| {
        const t = @as(f32, @floatFromInt(i)) / voz.rate;
        const f0 = 140 + 30 * @sin(t * 2.1) + 12 * @sin(t * 7.3);
        phase = @mod(phase + 2 * std.math.pi * f0 / voz.rate, 2 * std.math.pi);
        const syl = @max(0, @sin(t * 2 * std.math.pi * 3.7) + 0.4);
        var v: f32 = 0;
        for ([_]f32{ 1, 0.7, 0.45, 0.3, 0.2, 0.12 }, 1..) |a, h| v += a * @sin(phase * @as(f32, @floatFromInt(h)));
        s.* = @intFromFloat(std.math.clamp(v * syl * 6000, -30000, 30000));
    }
}

fn loadWav(path: [*:0]const u8, out: []i16) bool {
    const f = fopen(path, "rb") orelse return false;
    defer _ = fclose(f);
    const data = gpa.alloc(u8, 32 * 1024 * 1024) catch return false;
    defer gpa.free(data);
    const n = fread(data.ptr, 1, data.len, f);
    const at = std.mem.indexOf(u8, data[0..n], "data") orelse return false;
    const body = data[at + 8 .. n];
    const samples = body.len / 2;
    if (samples == 0) return false;
    for (out, 0..) |*s, i| {
        const k = (i % samples) * 2;
        s.* = std.mem.readInt(i16, body[k..][0..2], .little);
    }
    return true;
}

fn writeWav(dir: [*:0]const u8, name: []const u8, which: []const u8, mono: []const i16) void {
    var pb: [512]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&pb, "{s}/{s}-{s}.wav", .{ std.mem.span(dir), name, which }, 0) catch return;
    const f = fopen(path.ptr, "wb") orelse return;
    defer _ = fclose(f);
    var h: [44]u8 = undefined;
    const bytes: u32 = @intCast(mono.len * 2);
    @memcpy(h[0..4], "RIFF");
    std.mem.writeInt(u32, h[4..8], 36 + bytes, .little);
    @memcpy(h[8..16], "WAVEfmt ");
    std.mem.writeInt(u32, h[16..20], 16, .little);
    std.mem.writeInt(u16, h[20..22], 1, .little);
    std.mem.writeInt(u16, h[22..24], 1, .little);
    std.mem.writeInt(u32, h[24..28], voz.rate, .little);
    std.mem.writeInt(u32, h[28..32], voz.rate * 2, .little);
    std.mem.writeInt(u16, h[32..34], 2, .little);
    std.mem.writeInt(u16, h[34..36], 16, .little);
    @memcpy(h[36..40], "data");
    std.mem.writeInt(u32, h[40..44], bytes, .little);
    _ = fwrite(&h, 1, h.len, f);
    _ = fwrite(@ptrCast(mono.ptr), 2, mono.len, f);
}

/// A fila do dispositivo (como o SDL_AudioStream): amostras intercaladas.
const Queue = struct {
    buf: std.ArrayList(i16) = .empty,
    head: usize = 0,

    fn ms(q: *const Queue) u32 {
        return @intCast((q.buf.items.len - q.head) / (voz.channels * voz.rate / 1000));
    }
    fn put(q: *Queue, pcm: []const i16) void {
        q.buf.appendSlice(gpa, pcm) catch unreachable;
    }
    fn silence(q: *Queue, ms_n: u32) void {
        q.buf.appendNTimes(gpa, 0, ms_n * voz.channels * voz.rate / 1000) catch unreachable;
    }
    fn clear(q: *Queue) void {
        q.buf.clearRetainingCapacity();
        q.head = 0;
    }
};

const Result = struct {
    gaps: u32 = 0,
    gap_ms: f32 = 0,
    clicks: u32 = 0,
    max_jump: i32 = 0,
    latency_sum: u64 = 0,
    latency_max: u32 = 0,
    pulls: u64 = 0,
    late: u32 = 0,
    skipped: u32 = 0,
    cleared: u32 = 0,
    concealed: u32 = 0,
};

/// `.antes`: decodifica este e só então inventa os perdidos, toca o que chega fora
/// de ordem e não repõe a folga. `.folga`: em ordem e com folga, mas chama pausa
/// de quem fala de rede ruim, enche de silêncio e não suaviza nada. `.agora`: voz.Jitter.
const Mode = enum { antes, folga, agora };

/// A lógica de `.folga`, só para comparar.
const OldJitter = struct {
    last_seq: u16 = 0,
    cushion_ms: u32 = 60,
    starved: bool = false,

    fn plan(j: *OldJitter, seq: u16, new_spurt: bool, queued_ms: u32) voz.Jitter.Plan {
        if (new_spurt) {
            if (!j.starved) j.cushion_ms = @max(60, j.cushion_ms -| 20);
            j.starved = false;
            j.last_seq = seq;
            return .{ .pad_ms = j.cushion_ms -| queued_ms };
        }
        const diff: i16 = @bitCast(seq -% j.last_seq);
        if (diff <= 0 and diff >= -64) return .{ .late = true };
        const lost: u16 = if (diff > 0) @intCast(diff - 1) else 0;
        j.last_seq = seq;
        if (queued_ms > j.cushion_ms + 500) return .{ .clear = true, .pad_ms = j.cushion_ms };
        if (queued_ms > j.cushion_ms + 120) return .{ .skip = true };
        var out: voz.Jitter.Plan = .{ .lost = if (lost <= 3) lost else 0 };
        if (queued_ms == 0) {
            j.starved = true;
            j.cushion_ms = @min(140, j.cushion_ms + 20);
            out.pad_ms = j.cushion_ms -| @as(u32, out.lost) * voz.frame_ms;
        }
        return out;
    }
};

const Player = struct {
    dec: *anyopaque,
    q: Queue = .{},
    mode: Mode,
    last_ms: i64 = -10000,
    last_seq: u16 = 0,
    old: OldJitter = .{},
    jitter: voz.Jitter = .{},
    seam: voz.Seam = .{},
    res: *Result,

    /// A volta da thread de voz, a cada 20 ms.
    fn tick(p: *Player) void {
        if (p.mode != .agora) return;
        const what = p.jitter.conceal(p.q.ms());
        if (what == .none) return;
        var fill: [voz.frame_len]i16 = undefined;
        const m = opus_decode(p.dec, null, 0, &fill, voz.frame_samples, 0);
        if (m <= 0) return;
        const pcm = fill[0..@as(usize, @intCast(m)) * voz.channels];
        if (what == .last) p.seam.fadeOut(pcm) else p.seam.apply(pcm);
        p.q.put(pcm);
        p.res.concealed += 1;
    }

    fn receive(p: *Player, pkt: Packet, now: i64) void {
        const spurt = now - p.last_ms > 250;
        p.last_ms = now;
        var pcm: [5760 * voz.channels]i16 = undefined;
        var fill: [voz.frame_len]i16 = undefined;
        const frame = pkt.data;
        const len: i32 = @intCast(frame.len);
        switch (p.mode) {
            .antes => {
                const n = opus_decode(p.dec, frame.ptr, len, &pcm, 5760, 0);
                if (n <= 0) return;
                if (spurt or p.q.ms() > 250) {
                    if (p.q.ms() > 250) {
                        p.q.clear();
                        p.res.cleared += 1;
                    }
                    p.q.silence(60);
                } else {
                    const lost = pkt.seq -% p.last_seq -% 1;
                    if (lost > 0 and lost <= 3) for (0..lost) |_| {
                        const m = opus_decode(p.dec, null, 0, &fill, voz.frame_samples, 0);
                        if (m > 0) p.q.put(fill[0..@as(usize, @intCast(m)) * voz.channels]);
                    };
                }
                p.last_seq = pkt.seq;
                p.q.put(pcm[0..@as(usize, @intCast(n)) * voz.channels]);
            },
            .folga => {
                const plan = p.old.plan(pkt.seq, spurt, p.q.ms());
                if (plan.late) {
                    p.res.late += 1;
                    return;
                }
                if (plan.clear) {
                    p.q.clear();
                    p.res.cleared += 1;
                }
                if (plan.pad_ms > 0) p.q.silence(plan.pad_ms);
                if (plan.lost > 0) for (0..plan.lost) |i| {
                    const fec = i + 1 == plan.lost;
                    const m = opus_decode(p.dec, if (fec) frame.ptr else null, if (fec) len else 0, &fill, voz.frame_samples, @intFromBool(fec));
                    if (m > 0) p.q.put(fill[0..@as(usize, @intCast(m)) * voz.channels]);
                };
                const n = opus_decode(p.dec, frame.ptr, len, &pcm, 5760, 0);
                if (n <= 0) return;
                if (plan.skip) {
                    p.res.skipped += 1;
                    return;
                }
                p.q.put(pcm[0..@as(usize, @intCast(n)) * voz.channels]);
            },
            .agora => {
                const plan = p.jitter.plan(pkt.seq, pkt.ts, spurt, p.q.ms());
                if (plan.late) {
                    p.res.late += 1;
                    return;
                }
                if (plan.clear) {
                    p.q.clear();
                    p.res.cleared += 1;
                    p.seam.dropped();
                }
                if (plan.gap) p.seam.dropped();
                if (plan.pad_ms > 0) {
                    p.q.silence(plan.pad_ms);
                    p.seam.silence();
                }
                if (plan.lost > 0) for (0..plan.lost) |i| {
                    const fec = i + 1 == plan.lost;
                    const m = opus_decode(p.dec, if (fec) frame.ptr else null, if (fec) len else 0, &fill, voz.frame_samples, @intFromBool(fec));
                    if (m > 0) {
                        const part = fill[0..@as(usize, @intCast(m)) * voz.channels];
                        p.seam.apply(part);
                        p.q.put(part);
                    }
                };
                const n = opus_decode(p.dec, frame.ptr, len, &pcm, 5760, 0);
                if (n <= 0) return;
                if (plan.skip) {
                    p.res.skipped += 1;
                    p.seam.dropped();
                    return;
                }
                const part = pcm[0..@as(usize, @intCast(n)) * voz.channels];
                p.seam.apply(part);
                p.q.put(part);
            },
        }
    }
};

/// Salto entre amostras acima do que a fala limpa tem: é estalo.
fn analyze(mono: []const i16, limit: i32, res: *Result) void {
    var last_click: usize = 0;
    var i: usize = 1;
    while (i < mono.len) : (i += 1) {
        const jump = @as(i32, mono[i]) - mono[i - 1];
        const a: i32 = if (jump < 0) -jump else jump;
        if (a > res.max_jump) res.max_jump = a;
        if (a > limit and i - last_click > voz.rate / 50) {
            res.clicks += 1;
            last_click = i;
        }
    }
}

fn run(s: Scenario, mode: Mode, packets: []const Packet, limit: i32, wav: ?[*:0]const u8) !Result {
    var res: Result = .{};
    var err: c_int = 0;
    const dec = opus_decoder_create(voz.rate, voz.channels, &err) orelse return error.Opus;
    defer opus_decoder_destroy(dec);
    var p: Player = .{ .dec = dec, .mode = mode, .res = &res };
    p.jitter.pull_ms = s.pull * 1000 / voz.rate + 1;
    defer p.q.buf.deinit(gpa);
    const out = try gpa.alloc(i16, (seconds + 5) * voz.rate);
    defer gpa.free(out);
    var written: usize = 0;
    var next: usize = 0;
    var pull_at: f64 = 0;
    const end_ms: i64 = (seconds + 2) * 1000;
    var started = false;
    var gap_open = false;
    var t: i64 = 0;
    while (t < end_ms) : (t += 1) {
        while (next < packets.len and packets[next].arrive_ms <= t) : (next += 1) p.receive(packets[next], t);
        if (@mod(t, voz.frame_ms) == 7) p.tick();
        const now_f: f64 = @floatFromInt(t);
        while (pull_at <= now_f) : (pull_at += @as(f64, @floatFromInt(s.pull)) * 1000.0 / voz.rate) {
            const q = &p.q;
            const have = (q.buf.items.len - q.head) / voz.channels;
            if (have > 0) started = true;
            if (!started) continue;
            res.latency_sum += q.ms();
            res.latency_max = @max(res.latency_max, q.ms());
            res.pulls += 1;
            const take: usize = @min(have, s.pull);
            for (0..take) |k| {
                if (written < out.len) {
                    out[written] = q.buf.items[q.head + k * voz.channels];
                    written += 1;
                }
            }
            q.head += take * voz.channels;
            if (take < s.pull and next < packets.len) {
                // Faltou áudio: o dispositivo toca silêncio.
                if (!gap_open) res.gaps += 1;
                gap_open = true;
                res.gap_ms += @as(f32, @floatFromInt(s.pull - take)) * 1000.0 / voz.rate;
                for (0..s.pull - take) |_| if (written < out.len) {
                    out[written] = 0;
                    written += 1;
                };
            } else gap_open = false;
            if (q.head > 1 << 20) {
                q.buf.replaceRange(gpa, 0, q.head, &.{}) catch unreachable;
                q.head = 0;
            }
        }
    }
    analyze(out[0..written], limit, &res);
    if (wav) |dir| writeWav(dir, s.file, @tagName(mode), out[0..written]);
    return res;
}

pub fn main() !void {
    const voice_mono = try gpa.alloc(i16, (seconds + 1) * voz.rate);
    defer gpa.free(voice_mono);
    var source: [*:0]const u8 = "fala sintetica";
    if (getenv("SIGMACORD_VOZ_FALA")) |path| {
        if (!loadWav(path, voice_mono)) return error.WavInvalido;
        source = path;
    } else synth(voice_mono);
    const wav = getenv("SIGMACORD_VOZ_WAV");

    // Codifica uma vez, como o cliente do Discord (64 kbit/s, com FEC).
    var err: c_int = 0;
    const enc = opus_encoder_create(voz.rate, voz.channels, 2048, &err) orelse return error.Opus;
    _ = opus_encoder_ctl(enc, 4002, @as(c_int, 64000));
    _ = opus_encoder_ctl(enc, 4012, @as(c_int, 1));
    _ = opus_encoder_ctl(enc, 4014, @as(c_int, 10));
    const packets = try gpa.alloc([]u8, n_packets);
    var stereo: [voz.frame_len]i16 = undefined;
    var buf: [1500]u8 = undefined;
    for (packets, 0..) |*pk, i| {
        for (0..voz.frame_samples) |k| {
            const v = voice_mono[i * voz.frame_samples + k];
            stereo[k * 2] = v;
            stereo[k * 2 + 1] = v;
        }
        const n = opus_encode(enc, &stereo, voz.frame_samples, &buf, buf.len);
        if (n <= 0) return error.Opus;
        pk.* = try gpa.dupe(u8, buf[0..@intCast(n)]);
    }

    // O limite de estalo vem da própria fala, decodificada sem perda nenhuma.
    var limit: i32 = 0;
    {
        const dec = opus_decoder_create(voz.rate, voz.channels, &err) orelse return error.Opus;
        defer opus_decoder_destroy(dec);
        var pcm: [5760 * voz.channels]i16 = undefined;
        for (packets) |pk| {
            const n = opus_decode(dec, pk.ptr, @intCast(pk.len), &pcm, 5760, 0);
            var i: usize = 2;
            while (i < @as(usize, @intCast(n)) * 2) : (i += 2) {
                const j = @as(i32, pcm[i]) - pcm[i - 2];
                limit = @max(limit, if (j < 0) -j else j);
            }
        }
    }
    limit = @divTrunc(limit * 3, 2);

    _ = printf("fonte: %s; 60 s por cenario; salto acima de %d conta como estalo\n\n", source, limit);
    _ = printf("%-27s %-6s %8s %9s %8s %7s %10s %9s %7s %6s\n", "cenario", "versao", "buracos", "silencio", "estalos", "salto", "atraso med", "atraso max", "descart", "invent");
    for (scenarios) |s| {
        var prng = std.Random.DefaultPrng.init(0x1a2b3c);
        const r = prng.random();
        var list: std.ArrayList(Packet) = .empty;
        defer list.deinit(gpa);
        var burst: u32 = 0;
        var seq: u16 = 1000;
        var open_left: u32 = 5;
        var shut_left: u32 = 0;
        // Quem fala só codifica o que manda: o decodificador não vê buraco nenhum.
        const gate_enc = if (s.gate) opus_encoder_create(voz.rate, voz.channels, 2048, &err) orelse return error.Opus else null;
        if (gate_enc) |g| {
            _ = opus_encoder_ctl(g, 4002, @as(c_int, 64000));
            _ = opus_encoder_ctl(g, 4012, @as(c_int, 1));
            _ = opus_encoder_ctl(g, 4014, @as(c_int, 10));
        }
        for (packets, 0..) |pk_all, i| {
            var pk = pk_all;
            const send: i64 = @intCast(i * voz.frame_ms);
            if (s.gate) {
                if (shut_left > 0) {
                    shut_left -= 1;
                    if (shut_left == 0) open_left = r.intRangeAtMost(u32, 3, 12);
                    continue;
                }
                open_left -= 1;
                if (open_left == 0) shut_left = r.intRangeAtMost(u32, 3, 10);
                for (0..voz.frame_samples) |k| {
                    const v = voice_mono[i * voz.frame_samples + k];
                    stereo[k * 2] = v;
                    stereo[k * 2 + 1] = v;
                }
                const n = opus_encode(gate_enc.?, &stereo, voz.frame_samples, &buf, buf.len);
                if (n <= 0) return error.Opus;
                pk = try gpa.dupe(u8, buf[0..@intCast(n)]);
            }
            seq +%= 1;
            if (burst > 0) {
                burst -= 1;
                continue;
            }
            if (r.float(f32) * 100 < s.burst_pct) {
                burst = 2;
                continue;
            }
            if (r.float(f32) * 100 < s.loss_pct) continue;
            var arrive = send + 30 + @as(i64, @intFromFloat(r.float(f32) * s.jitter_ms));
            if (r.float(f32) * 100 < s.reorder_pct) arrive += 25;
            if (s.stall_every_ms > 0) {
                const pos = @mod(arrive, s.stall_every_ms);
                if (arrive > s.stall_every_ms and pos < s.stall_ms) arrive += s.stall_ms - pos;
            }
            try list.append(gpa, .{ .seq = seq, .ts = @truncate(i * voz.frame_samples), .arrive_ms = arrive, .data = pk });
        }
        std.mem.sort(Packet, list.items, {}, lessArrive);
        if (s.gate) {
            // O que já vem da fonte, tocado sem fila nenhuma: isso não é defeito de quem toca.
            var base: Result = .{};
            const dec = opus_decoder_create(voz.rate, voz.channels, &err) orelse return error.Opus;
            defer opus_decoder_destroy(dec);
            const mono = try gpa.alloc(i16, (seconds + 5) * voz.rate);
            defer gpa.free(mono);
            var at: usize = 0;
            var pcm: [5760 * voz.channels]i16 = undefined;
            for (list.items) |pk| {
                const n: usize = @intCast(@max(opus_decode(dec, pk.data.ptr, @intCast(pk.data.len), &pcm, 5760, 0), 0));
                for (0..n) |k| {
                    mono[at] = pcm[k * 2];
                    at += 1;
                }
            }
            analyze(mono[0..at], limit, &base);
            _ = printf("%-27s %-6s %8s %9s %8u %7d\n", s.name, "fonte", "-", "-", base.clicks, base.max_jump);
        }
        for ([_]Mode{ .antes, .folga, .agora }) |mode| {
            const res = try run(s, mode, list.items, limit, wav);
            const avg: u64 = if (res.pulls > 0) res.latency_sum / res.pulls else 0;
            _ = printf("%-27s %-6s %8u %7.0fms %8u %7d %8llums %7ums %7u %6u\n", s.name, @tagName(mode).ptr, res.gaps, @as(f64, res.gap_ms), res.clicks, res.max_jump, avg, res.latency_max, res.skipped + res.cleared, res.concealed);
        }
    }
    if (wav) |dir| _ = printf("\narquivos para ouvir em %s\n", dir);
}
