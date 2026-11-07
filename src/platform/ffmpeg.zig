//! FFmpeg do sistema, carregado só quando algo precisa dele (um vídeo vai
//! tocar, um GIF do Tenor só existe em MP4): SDL_LoadObject, sem dependência
//! de build nem de execução. Sem FFmpeg instalado, vídeo abre no navegador.
//!
//! Os protótipos estão declarados aqui à mão. As structs do FFmpeg são
//! opacas para nós; os poucos campos que lemos (o começo de AVFrame,
//! AVPacket, AVStream, AVFormatContext e AVIOContext) estão nos deslocamentos
//! das versões conhecidas abaixo, conferidas com avformat_version() e cia.
//! Versão desconhecida = recusa (melhor abrir no navegador do que ler lixo).
//! O resto vem de funções e de AVOptions ("ar", "ch_layout"), que não
//! dependem do layout.
const std = @import("std");
const c = @import("c");

pub const Frame = opaque {};
pub const Packet = opaque {};
pub const FormatCtx = opaque {};
pub const CodecCtx = opaque {};
pub const Codec = opaque {};
pub const Stream = opaque {};
pub const IoCtx = opaque {};
pub const Sws = opaque {};
pub const Rational = extern struct { num: c_int, den: c_int };
/// AVChannelLayout (igual desde a libavutil 57).
pub const ChLayout = extern struct { order: c_int = 0, nb_channels: c_int = 0, u: u64 = 0, opaque_: ?*anyopaque = null };

pub const err_again: c_int = -11; // AVERROR(EAGAIN)
pub const err_eof: c_int = -@as(c_int, 'E' | @as(c_int, 'O') << 8 | @as(c_int, 'F') << 16 | @as(c_int, ' ') << 24);
pub const err_exit: c_int = -@as(c_int, 'E' | @as(c_int, 'X') << 8 | @as(c_int, 'I') << 16 | @as(c_int, 'T') << 24);
pub const err_io: c_int = -5; // AVERROR(EIO)
pub const nopts: i64 = std.math.minInt(i64);
pub const seek_size: c_int = 0x10000;
const seek_force: c_int = 0x20000;
const media_video: c_int = 0;
const media_audio: c_int = 1;
const sws_bilinear: c_int = 2;
const log_quiet: c_int = -8;
/// AVSampleFormat (valores fixos desde sempre).
const SampleFmt = enum(c_int) { s16 = 1, s32 = 2, flt = 3, s16p = 6, s32p = 7, fltp = 8, _ };

pub const ReadFn = *const fn (?*anyopaque, [*]u8, c_int) callconv(.c) c_int;
pub const SeekFn = *const fn (?*anyopaque, i64, c_int) callconv(.c) i64;

/// Funções que usamos (o nome do campo é o símbolo).
pub const Api = struct {
    avutil_version: *const fn () callconv(.c) c_uint,
    av_frame_alloc: *const fn () callconv(.c) ?*Frame,
    av_frame_free: *const fn (*?*Frame) callconv(.c) void,
    av_malloc: *const fn (usize) callconv(.c) ?*anyopaque,
    av_free: *const fn (?*anyopaque) callconv(.c) void,
    av_log_set_level: *const fn (c_int) callconv(.c) void,
    av_opt_set: *const fn (*anyopaque, [*:0]const u8, [*:0]const u8, c_int) callconv(.c) c_int,
    av_opt_set_int: *const fn (*anyopaque, [*:0]const u8, i64, c_int) callconv(.c) c_int,
    av_opt_get_int: *const fn (*anyopaque, [*:0]const u8, c_int, *i64) callconv(.c) c_int,
    av_opt_get_chlayout: *const fn (*anyopaque, [*:0]const u8, c_int, *ChLayout) callconv(.c) c_int,
    av_channel_layout_uninit: *const fn (*ChLayout) callconv(.c) void,
    av_get_pix_fmt: *const fn ([*:0]const u8) callconv(.c) c_int,

    avcodec_version: *const fn () callconv(.c) c_uint,
    avcodec_alloc_context3: *const fn (?*const Codec) callconv(.c) ?*CodecCtx,
    avcodec_free_context: *const fn (*?*CodecCtx) callconv(.c) void,
    avcodec_parameters_to_context: *const fn (*CodecCtx, *const anyopaque) callconv(.c) c_int,
    avcodec_open2: *const fn (*CodecCtx, ?*const Codec, ?*anyopaque) callconv(.c) c_int,
    avcodec_send_packet: *const fn (*CodecCtx, ?*const Packet) callconv(.c) c_int,
    avcodec_receive_frame: *const fn (*CodecCtx, *Frame) callconv(.c) c_int,
    avcodec_flush_buffers: *const fn (*CodecCtx) callconv(.c) void,
    av_packet_alloc: *const fn () callconv(.c) ?*Packet,
    av_packet_free: *const fn (*?*Packet) callconv(.c) void,
    av_packet_unref: *const fn (*Packet) callconv(.c) void,
    av_packet_move_ref: *const fn (*Packet, *Packet) callconv(.c) void,

    avformat_version: *const fn () callconv(.c) c_uint,
    avformat_alloc_context: *const fn () callconv(.c) ?*FormatCtx,
    avformat_open_input: *const fn (*?*FormatCtx, ?[*:0]const u8, ?*const anyopaque, ?*anyopaque) callconv(.c) c_int,
    avformat_find_stream_info: *const fn (*FormatCtx, ?*anyopaque) callconv(.c) c_int,
    avformat_close_input: *const fn (*?*FormatCtx) callconv(.c) void,
    avformat_free_context: *const fn (?*FormatCtx) callconv(.c) void,
    av_find_best_stream: *const fn (*FormatCtx, c_int, c_int, c_int, ?*?*const Codec, c_int) callconv(.c) c_int,
    av_read_frame: *const fn (*FormatCtx, *Packet) callconv(.c) c_int,
    av_seek_frame: *const fn (*FormatCtx, c_int, i64, c_int) callconv(.c) c_int,
    avio_alloc_context: *const fn ([*]u8, c_int, c_int, ?*anyopaque, ?ReadFn, ?*const anyopaque, ?SeekFn) callconv(.c) ?*IoCtx,
    avio_context_free: *const fn (*?*IoCtx) callconv(.c) void,

    swscale_version: *const fn () callconv(.c) c_uint,
    sws_getContext: *const fn (c_int, c_int, c_int, c_int, c_int, c_int, c_int, ?*anyopaque, ?*anyopaque, ?*const f64) callconv(.c) ?*Sws,
    sws_scale: *const fn (*Sws, [*]const ?[*]const u8, [*]const c_int, c_int, c_int, [*]const ?[*]u8, [*]const c_int) callconv(.c) c_int,
    sws_freeContext: *const fn (?*Sws) callconv(.c) void,
};

/// Versões com o layout conferido (FFmpeg 9, 8 e 7). Os campos que lemos
/// estão no mesmo lugar nas três (o `duration` do AVFormatContext só foi
/// conferido na 63; nas outras não é lido).
const Set = struct { lavf: u32, lavc: u32, lavu: u32, sws: u32 };
const sets = [_]Set{
    .{ .lavf = 63, .lavc = 63, .lavu = 61, .sws = 10 },
    .{ .lavf = 62, .lavc = 62, .lavu = 60, .sws = 9 },
    .{ .lavf = 61, .lavc = 61, .lavu = 59, .sws = 8 },
};

var api: Api = undefined;
var loaded: Set = undefined;
var rgba_fmt: c_int = -1;
/// 0 = não tentou, 1 = carregando, 2 = pronto, 3 = não tem.
var state: std.atomic.Value(u8) = .init(0);

/// O FFmpeg, carregando na primeira vez (de qualquer thread). null = não tem
/// (ou é de uma versão que não conhecemos).
pub fn get() ?*const Api {
    switch (state.load(.acquire)) {
        2 => return &api,
        3 => return null,
        else => {},
    }
    if (state.cmpxchgStrong(0, 1, .acq_rel, .acquire) == null) {
        const ok = loadAll();
        state.store(if (ok) 2 else 3, .release);
        return if (ok) &api else null;
    }
    while (state.load(.acquire) == 1) c.SDL_Delay(1);
    return if (state.load(.acquire) == 2) &api else null;
}

/// Onde o botão "Baixar FFmpeg" do Windows deixa as bibliotecas.
pub fn localDir(buf: []u8) ?[]const u8 {
    var hb: [400]u8 = undefined;
    const base = @import("sys.zig").cacheHome(&hb) orelse return null;
    return std.fmt.bufPrint(buf, "{s}/sigmacord/ffmpeg", .{base}) catch null;
}

/// O Windows também procura as bibliotecas (e as que elas pedem) nesta pasta.
fn useLocalDir() void {
    if (@import("builtin").os.tag != .windows) return;
    const SetDllDirectoryW = @extern(*const fn ([*:0]const u16) callconv(.winapi) c_int, .{ .name = "SetDllDirectoryW", .library_name = "kernel32" });
    var ub: [512]u8 = undefined;
    const dir = localDir(&ub) orelse return;
    var wb: [512:0]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(&wb, dir) catch return;
    for (wb[0..n]) |*ch| {
        if (ch.* == '/') ch.* = '\\';
    }
    wb[n] = 0;
    _ = SetDllDirectoryW(&wb);
}

/// Depois de instalar: se não tinha achado, procura de novo no próximo uso.
pub fn forget() void {
    _ = state.cmpxchgStrong(3, 0, .acq_rel, .acquire);
}

/// Já se sabe se tem FFmpeg? (null = ainda não tentou carregar).
pub fn known() ?bool {
    return switch (state.load(.acquire)) {
        2 => true,
        3 => false,
        else => null,
    };
}

fn loadAll() bool {
    // SIGMACORD_NO_FFMPEG=1 finge que não tem (para testar o caminho do navegador).
    if (c.SDL_getenv("SIGMACORD_NO_FFMPEG") != null) return false;
    useLocalDir();
    for (sets) |s| if (loadSet(s)) {
        loaded = s;
        rgba_fmt = api.av_get_pix_fmt("rgba");
        if (rgba_fmt < 0) return false;
        if (c.SDL_getenv("SIGMACORD_DEBUG_MEDIA") == null and !@import("debug_log.zig").isOn()) {
            api.av_log_set_level(log_quiet);
        } else std.log.info("ffmpeg: libavformat {d}", .{s.lavf});
        return true;
    };
    return false;
}

/// Prefixos de cada biblioteca e o fim do nome do arquivo em cada sistema.
const lib_name = if (@import("builtin").os.tag == .windows)
    [_][]const u8{ "avutil-", ".dll", "swscale-", "avcodec-", "avformat-" }
else
    [_][]const u8{ "libavutil.so.", "", "libswscale.so.", "libavcodec.so.", "libavformat.so." };

fn loadSet(s: Set) bool {
    var names: [4][40]u8 = undefined;
    const files = [_][]const u8{
        std.fmt.bufPrint(&names[0], lib_name[0] ++ "{d}" ++ lib_name[1] ++ "\x00", .{s.lavu}) catch return false,
        std.fmt.bufPrint(&names[1], lib_name[2] ++ "{d}" ++ lib_name[1] ++ "\x00", .{s.sws}) catch return false,
        std.fmt.bufPrint(&names[2], lib_name[3] ++ "{d}" ++ lib_name[1] ++ "\x00", .{s.lavc}) catch return false,
        std.fmt.bufPrint(&names[3], lib_name[4] ++ "{d}" ++ lib_name[1] ++ "\x00", .{s.lavf}) catch return false,
    };
    var libs: [4]*c.SDL_SharedObject = undefined;
    var n: usize = 0;
    // (Carregado fica até o fim: o app usa de novo e o custo é só o mapeamento.)
    for (files) |f| {
        libs[n] = c.SDL_LoadObject(f.ptr) orelse {
            for (libs[0..n]) |l| c.SDL_UnloadObject(l);
            return false;
        };
        n += 1;
    }
    var tmp: Api = undefined;
    const info = @typeInfo(Api).@"struct";
    inline for (info.field_names, info.field_types) |fname, ftype| {
        const sym: [*:0]const u8 = fname ++ "";
        const p = for (libs) |l| {
            if (c.SDL_LoadFunction(l, sym)) |f| break f;
        } else null;
        @field(tmp, fname) = @as(ftype, @ptrCast(p orelse {
            for (libs) |l| c.SDL_UnloadObject(l);
            return false;
        }));
    }
    // O soname bate, mas confere a versão de verdade.
    const ok = tmp.avformat_version() >> 16 == s.lavf and tmp.avcodec_version() >> 16 == s.lavc and
        tmp.avutil_version() >> 16 == s.lavu and tmp.swscale_version() >> 16 == s.sws;
    if (!ok) {
        for (libs) |l| c.SDL_UnloadObject(l);
        return false;
    }
    api = tmp;
    return true;
}

// --- Campos lidos direto (deslocamentos das versões acima, 64 bits) ----------

fn field(comptime T: type, p: anytype, off: usize) *T {
    return @ptrFromInt(@intFromPtr(p) + off);
}

pub fn frameData(f: *Frame) *[8]?[*]u8 {
    return field([8]?[*]u8, f, 0);
}
pub fn frameLinesize(f: *Frame) *[8]c_int {
    return field([8]c_int, f, 64);
}
fn frameExtended(f: *Frame) [*]?[*]u8 {
    return field([*]?[*]u8, f, 96).*;
}
pub fn frameWidth(f: *Frame) c_int {
    return field(c_int, f, 104).*;
}
pub fn frameHeight(f: *Frame) c_int {
    return field(c_int, f, 108).*;
}
fn frameSamples(f: *Frame) c_int {
    return field(c_int, f, 112).*;
}
fn frameFormat(f: *Frame) c_int {
    return field(c_int, f, 116).*;
}
fn framePts(f: *Frame) i64 {
    return field(i64, f, 136).*;
}
fn packetStream(p: *Packet) c_int {
    return field(c_int, p, 36).*;
}
fn streamAt(fmt: *FormatCtx, i: c_int) ?*Stream {
    const n = field(c_uint, fmt, 44).*;
    if (i < 0 or @as(c_uint, @intCast(i)) >= n) return null;
    return field([*]*Stream, fmt, 48).*[@intCast(i)];
}
fn streamCodecpar(s: *Stream) *const anyopaque {
    return field(*const anyopaque, s, 16).*;
}
fn streamTimeBase(s: *Stream) Rational {
    return field(Rational, s, 32).*;
}
fn streamStart(s: *Stream) i64 {
    return field(i64, s, 40).*;
}
fn streamDuration(s: *Stream) i64 {
    return field(i64, s, 48).*;
}

// --- Uma mídia aberta ----------------------------------------------------------

/// De onde vêm os bytes (memória ou um download em andamento).
pub const Io = struct { ctx: *anyopaque, read: ReadFn, seek: SeekFn };

/// Só os formatos e codecs que aparecem no Discord: nada de HLS/concat (que
/// abririam outras URLs por conta própria, sem passar pelo allowedHost) nem
/// decodificadores exóticos.
const formats = "mov,mp4,m4a,3gp,3g2,mj2,matroska,webm";
const codecs = "h264,hevc,vp8,vp9,av1,mpeg4,aac,mp3,opus,vorbis,flac,pcm_s16le";

pub const Kind = enum { video, audio, skip, eof };

pub const Media = struct {
    api: *const Api,
    fmt: ?*FormatCtx = null,
    io: ?*IoCtx = null,
    vctx: ?*CodecCtx = null,
    actx: ?*CodecCtx = null,
    vi: c_int = -1,
    ai: c_int = -1,
    vtb: Rational = .{ .num = 1, .den = 1000 },
    atb: Rational = .{ .num = 1, .den = 1000 },
    /// Começo do vídeo (ms): vira o zero de tudo.
    start_ms: i64 = 0,
    duration_ms: i64 = 0,
    frame: ?*Frame = null,
    pkt: ?*Packet = null,
    sws: ?*Sws = null,
    sws_key: [5]c_int = @splat(0),
    rate: u32 = 0,
    channels: u32 = 0,
    /// Áudio convertido para f32 intercalado (reaproveitado).
    abuf: std.ArrayList(f32) = .empty,

    pub fn open(a: *const Api, io: Io, want_audio: bool, threads: i64) !Media {
        var m: Media = .{ .api = a };
        errdefer m.close();
        m.frame = a.av_frame_alloc() orelse return error.NoMem;
        m.pkt = a.av_packet_alloc() orelse return error.NoMem;
        const buf: [*]u8 = @ptrCast(a.av_malloc(64 * 1024) orelse return error.NoMem);
        m.io = a.avio_alloc_context(buf, 64 * 1024, 0, io.ctx, io.read, null, io.seek) orelse {
            a.av_free(buf);
            return error.NoMem;
        };
        var fmt: ?*FormatCtx = a.avformat_alloc_context() orelse return error.NoMem;
        field(?*IoCtx, fmt.?, 32).* = m.io; // AVFormatContext.pb
        _ = a.av_opt_set(fmt.?, "format_whitelist", formats, 0);
        _ = a.av_opt_set(fmt.?, "codec_whitelist", codecs, 0);
        // Em caso de erro o avformat_open_input já solta o contexto.
        if (a.avformat_open_input(&fmt, null, null, null) < 0) return error.Format;
        m.fmt = fmt;
        if (a.avformat_find_stream_info(fmt.?, null) < 0) return error.Format;
        var vcodec: ?*const Codec = null;
        m.vi = a.av_find_best_stream(fmt.?, media_video, -1, -1, &vcodec, 0);
        if (m.vi < 0 or vcodec == null) return error.NoVideo;
        const vs = streamAt(fmt.?, m.vi) orelse return error.NoVideo;
        m.vctx = try openCodec(a, vcodec.?, vs, threads);
        m.vtb = streamTimeBase(vs);
        if (m.vtb.num <= 0 or m.vtb.den <= 0) return error.Format;
        const st = streamStart(vs);
        m.start_ms = if (st == nopts) 0 else toMs(st, m.vtb);
        const dur = streamDuration(vs);
        if (dur != nopts and dur > 0) {
            m.duration_ms = toMs(dur, m.vtb);
        } else if (loaded.lavf == 63) {
            // WebM: a duração só vem no contêiner (AVFormatContext.duration, µs).
            const fd = field(i64, fmt.?, 104).*;
            if (fd > 0 and fd < 24 * 3600 * 1_000_000) m.duration_ms = @divTrunc(fd, 1000);
        }
        if (want_audio) m.openAudio();
        return m;
    }

    fn openAudio(m: *Media) void {
        const a = m.api;
        var acodec: ?*const Codec = null;
        const ai = a.av_find_best_stream(m.fmt.?, media_audio, -1, m.vi, &acodec, 0);
        if (ai < 0 or acodec == null) return;
        const as = streamAt(m.fmt.?, ai) orelse return;
        const ctx = openCodec(a, acodec.?, as, 1) catch return;
        var rate: i64 = 0;
        var layout: ChLayout = .{};
        const ok = a.av_opt_get_int(ctx, "ar", 0, &rate) >= 0 and a.av_opt_get_chlayout(ctx, "ch_layout", 0, &layout) >= 0;
        const ch = layout.nb_channels;
        a.av_channel_layout_uninit(&layout);
        if (!ok or rate < 8000 or rate > 192_000 or ch < 1 or ch > 8) {
            var tmp: ?*CodecCtx = ctx;
            a.avcodec_free_context(&tmp);
            return;
        }
        const tb = streamTimeBase(as);
        if (tb.num <= 0 or tb.den <= 0) {
            var tmp: ?*CodecCtx = ctx;
            a.avcodec_free_context(&tmp);
            return;
        }
        m.actx = ctx;
        m.ai = ai;
        m.atb = tb;
        m.rate = @intCast(rate);
        m.channels = @intCast(ch);
    }

    pub fn close(m: *Media) void {
        const a = m.api;
        if (m.vctx != null) a.avcodec_free_context(&m.vctx);
        if (m.actx != null) a.avcodec_free_context(&m.actx);
        if (m.fmt != null) a.avformat_close_input(&m.fmt);
        if (m.io) |io| {
            // O buffer pode ter sido trocado pelo FFmpeg: solta o atual.
            a.av_free(field(?*anyopaque, io, 8).*);
            a.avio_context_free(&m.io);
        }
        if (m.sws) |s| a.sws_freeContext(s);
        m.sws = null;
        if (m.frame != null) a.av_frame_free(&m.frame);
        if (m.pkt != null) a.av_packet_free(&m.pkt);
        m.abuf.deinit(std.heap.c_allocator);
    }

    pub fn hasAudio(m: *const Media) bool {
        return m.actx != null;
    }

    /// Lê o próximo pacote para `m.pkt` (o chamador solta com unref).
    pub fn read(m: *Media) Kind {
        const p = m.pkt.?;
        if (m.api.av_read_frame(m.fmt.?, p) < 0) return .eof;
        const si = packetStream(p);
        if (si == m.vi) return .video;
        if (si == m.ai and m.actx != null) return .audio;
        m.api.av_packet_unref(p);
        return .skip;
    }

    pub fn unref(m: *Media, p: *Packet) void {
        m.api.av_packet_unref(p);
    }

    /// Volta (ou avança) para perto de `ms`: o quadro-chave antes dele.
    pub fn seek(m: *Media, ms: i64) void {
        const a = m.api;
        // A base de tempo vem do arquivo: pode ser 0 ou absurda.
        if (m.vtb.num <= 0) return;
        const ts: i64 = @intCast(std.math.clamp(@divTrunc(@as(i128, ms + m.start_ms) * m.vtb.den, 1000 * @as(i128, m.vtb.num)), std.math.minInt(i64), std.math.maxInt(i64)));
        _ = a.av_seek_frame(m.fmt.?, m.vi, ts, 1); // AVSEEK_FLAG_BACKWARD
        if (m.vctx) |v| a.avcodec_flush_buffers(v);
        if (m.actx) |v| a.avcodec_flush_buffers(v);
    }

    /// Manda um pacote de vídeo (null = fim, solta os quadros guardados).
    pub fn sendVideo(m: *Media, p: ?*Packet) c_int {
        return m.api.avcodec_send_packet(m.vctx.?, p);
    }

    /// Próximo quadro de vídeo em `m.frame`: 0, err_again ou err_eof.
    pub fn receiveVideo(m: *Media) c_int {
        return m.api.avcodec_receive_frame(m.vctx.?, m.frame.?);
    }

    pub fn frameSize(m: *const Media) [2]u32 {
        const f = m.frame.?;
        return .{ @intCast(@max(0, frameWidth(f))), @intCast(@max(0, frameHeight(f))) };
    }

    /// Tempo do quadro em ms desde o começo (null = sem tempo).
    pub fn framePtsMs(m: *const Media, tb: Rational) ?i64 {
        const pts = framePts(m.frame.?);
        if (pts == nopts) return null;
        return toMs(pts, tb) - m.start_ms;
    }

    /// O quadro atual reduzido para dw×dh em RGBA. `dst` precisa de
    /// `rgbaSize(dw, dh)` bytes: as conversões em SIMD do swscale escrevem
    /// alguns pixels além do fim da linha quando a largura não é múltipla de 8.
    pub fn toRgba(m: *Media, dst: []u8, dw: u32, dh: u32) bool {
        const a = m.api;
        const f = m.frame.?;
        if (dst.len < rgbaSize(dw, dh)) return false;
        const key = [5]c_int{ frameWidth(f), frameHeight(f), frameFormat(f), @intCast(dw), @intCast(dh) };
        if (key[0] <= 0 or key[1] <= 0 or key[0] > 8192 or key[1] > 8192) return false;
        if (m.sws == null or !std.mem.eql(c_int, &key, &m.sws_key)) {
            if (m.sws) |s| a.sws_freeContext(s);
            m.sws = a.sws_getContext(key[0], key[1], key[2], key[3], key[4], rgba_fmt, sws_bilinear, null, null, null);
            m.sws_key = key;
        }
        const s = m.sws orelse return false;
        const planes: [4]?[*]u8 = .{ dst.ptr, null, null, null };
        const strides: [4]c_int = .{ @intCast(dw * 4), 0, 0, 0 };
        const src: *const [8]?[*]const u8 = @ptrCast(frameData(f));
        return a.sws_scale(s, src, frameLinesize(f), 0, key[1], &planes, &strides) > 0;
    }

    /// Decodifica um pacote de áudio e entrega cada quadro como f32
    /// intercalado: `sink.audio(samples, pts_ms)`.
    pub fn decodeAudio(m: *Media, p: *Packet, sink: anytype) void {
        const a = m.api;
        const ctx = m.actx orelse return;
        if (a.avcodec_send_packet(ctx, p) < 0) return;
        const f = m.frame.?;
        while (a.avcodec_receive_frame(ctx, f) == 0) {
            const n: usize = @intCast(@max(0, frameSamples(f)));
            const ch: usize = m.channels;
            if (n == 0 or n > 1 << 20) continue;
            m.abuf.resize(std.heap.c_allocator, n * ch) catch return;
            if (!convertAudio(f, m.abuf.items, n, ch)) continue;
            const pts = framePts(f);
            sink.audio(m.abuf.items, if (pts == nopts) null else toMs(pts, m.atb) - m.start_ms);
        }
    }
};

/// Bytes de um quadro RGBA dw×dh com a folga que o swscale pede.
pub fn rgbaSize(dw: u32, dh: u32) usize {
    return @as(usize, dw) * dh * 4 + 256;
}

fn openCodec(a: *const Api, codec: *const Codec, s: *Stream, threads: i64) !*CodecCtx {
    var ctx: ?*CodecCtx = a.avcodec_alloc_context3(codec) orelse return error.NoMem;
    errdefer a.avcodec_free_context(&ctx);
    if (a.avcodec_parameters_to_context(ctx.?, streamCodecpar(s)) < 0) return error.Codec;
    _ = a.av_opt_set(ctx.?, "codec_whitelist", codecs, 0);
    _ = a.av_opt_set_int(ctx.?, "threads", threads, 0);
    if (a.avcodec_open2(ctx.?, codec, null) < 0) return error.Codec;
    return ctx.?;
}

fn toMs(v: i64, tb: Rational) i64 {
    const num: i128 = tb.num;
    const den: i128 = tb.den;
    return @intCast(std.math.clamp(@divTrunc(@as(i128, v) * num * 1000, den), -(1 << 50), 1 << 50));
}

/// Qualquer formato de amostra comum para f32 intercalado.
fn convertAudio(f: *Frame, out: []f32, n: usize, ch: usize) bool {
    const fmt: SampleFmt = @fromBackingInt(@intCast(frameFormat(f)));
    const ext = frameExtended(f);
    switch (fmt) {
        .flt, .s16, .s32 => {
            const p = ext[0] orelse return false;
            for (0..n * ch) |i| out[i] = sample(fmt, p, i);
        },
        .fltp, .s16p, .s32p => {
            for (0..ch) |k| {
                const p = ext[k] orelse return false;
                for (0..n) |i| out[i * ch + k] = sample(fmt, p, i);
            }
        },
        else => return false,
    }
    return true;
}

fn sample(fmt: SampleFmt, p: [*]u8, i: usize) f32 {
    return switch (fmt) {
        .flt, .fltp => @as([*]const f32, @ptrCast(@alignCast(p)))[i],
        .s16, .s16p => @as(f32, @floatFromInt(@as([*]const i16, @ptrCast(@alignCast(p)))[i])) / 32768.0,
        .s32, .s32p => @as(f32, @floatFromInt(@as([*]const i32, @ptrCast(@alignCast(p)))[i])) / 2147483648.0,
        else => 0,
    };
}

// --- Bytes na memória (GIF em MP4) ---------------------------------------------

/// Leitor sobre um buffer já inteiro na memória.
pub const MemReader = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn io(r: *MemReader) Io {
        return .{ .ctx = r, .read = readCb, .seek = seekCb };
    }

    fn readCb(ud: ?*anyopaque, buf: [*]u8, size: c_int) callconv(.c) c_int {
        const r: *MemReader = @ptrCast(@alignCast(ud.?));
        if (r.pos >= r.data.len) return err_eof;
        const n = @min(@as(usize, @intCast(@max(size, 0))), r.data.len - r.pos);
        @memcpy(buf[0..n], r.data[r.pos..][0..n]);
        r.pos += n;
        return @intCast(n);
    }

    fn seekCb(ud: ?*anyopaque, off: i64, whence_in: c_int) callconv(.c) i64 {
        const r: *MemReader = @ptrCast(@alignCast(ud.?));
        const len: i64 = @intCast(r.data.len);
        return seekTo(&r.pos, len, off, whence_in);
    }
};

/// SEEK_SET/CUR/END e AVSEEK_SIZE sobre algo de tamanho `len` (-1 = ainda
/// não se sabe).
pub fn seekTo(pos: *usize, len: i64, off: i64, whence_in: c_int) i64 {
    const whence = whence_in & ~seek_force;
    if (whence == seek_size) return len;
    const base: i64 = switch (whence) {
        0 => 0,
        1 => @intCast(pos.*),
        2 => if (len < 0) return -1 else len,
        else => return -1,
    };
    const np = base + off;
    if (np < 0) return -1;
    pos.* = @intCast(np);
    return np;
}

/// Parece MP4/MOV ("ftyp" no byte 4) ou Matroska/WebM (EBML)?
pub fn looksLikeVideo(data: []const u8) bool {
    if (data.len >= 12 and std.mem.eql(u8, data[4..8], "ftyp")) return true;
    return data.len >= 4 and std.mem.eql(u8, data[0..4], "\x1a\x45\xdf\xa3");
}
