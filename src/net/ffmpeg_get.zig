//! "Baixar FFmpeg" (Configurações → Chat). O Windows não vem com FFmpeg, então quem pede baixa
//! um pacote fixo, conferido pelo SHA-256, e só as bibliotecas que o app usa ficam na pasta dele.
//! Nada aqui roda sem a pessoa clicar e ler o aviso.
const std = @import("std");
const c = @import("c");
const ffmpeg = @import("../platform/ffmpeg.zig");
const updater = @import("updater.zig");

const alloc = std.heap.c_allocator;

/// A última build de outubro: o projeto guarda a última de cada mês por dois anos.
const repo = "BtbN/FFmpeg-Builds";
const tag = "autobuild-2026-10-31-12-59";
const file = "ffmpeg-n8.1.3-27-g8dca1586f4-win64-lgpl-shared-8.1.zip";
const url = "https://github.com/" ++ repo ++ "/releases/download/" ++ tag ++ "/" ++ file;
const sha256 = "5cef7bc48e513f3cee7c881e8b2999d835541edb1846c3e89443a67f8f8556ab";
const zip_bytes: usize = 80_356_594;
pub const source = "github.com/BtbN/FFmpeg-Builds";
pub const download_mb = 80;
pub const disk_mb = 128;
/// O que o app carrega e o que elas carregam (avfilter e avdevice ficam de fora: 37 MB).
const wanted = [_][]const u8{ "avcodec-62.dll", "avformat-62.dll", "avutil-60.dll", "swresample-6.dll", "swscale-9.dll" };

pub const Phase = enum(u8) { idle, downloading, installing, done, failed };
pub const Failure = enum(u8) { none, network, hash, disk };

var phase_now: std.atomic.Value(Phase) = .init(.idle);
var failure_now: std.atomic.Value(Failure) = .init(.none);
var got_bytes: std.atomic.Value(usize) = .init(0);
/// O QA percorre os estados sem rede; QA_FFMPEG_REAL (só no CI do Windows) baixa de verdade.
pub var qa_no_network = false;

pub fn phase() Phase {
    return phase_now.load(.acquire);
}

pub fn failure() Failure {
    return failure_now.load(.acquire);
}

pub fn percent() u8 {
    return @intCast(@min(got_bytes.load(.monotonic) * 100 / zip_bytes, 100));
}

pub fn start() void {
    switch (phase()) {
        .downloading, .installing => return,
        else => {},
    }
    got_bytes.store(0, .monotonic);
    failure_now.store(.none, .release);
    phase_now.store(.downloading, .release);
    if (qa_no_network) return finish(.done);
    if (c.SDL_CreateThread(run, "ffmpeg-get", null)) |t| c.SDL_DetachThread(t) else {
        failure_now.store(.disk, .release);
        phase_now.store(.failed, .release);
    }
}

fn finish(p: Phase) void {
    if (p == .done) ffmpeg.forget();
    phase_now.store(p, .release);
    updater.wakeUi();
}

fn run(_: ?*anyopaque) callconv(.c) c_int {
    install() catch |e| {
        failure_now.store(switch (e) {
            error.Network, error.NoRelease => .network,
            error.BadHash, error.BadZip => .hash,
            else => .disk,
        }, .release);
        finish(.failed);
        return 0;
    };
    finish(.done);
    return 0;
}

fn install() !void {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(alloc);
    try data.ensureTotalCapacity(alloc, zip_bytes);
    updater.fetch(url, &data, zip_bytes + 1024, &got_bytes) catch |e| {
        // A página de download do GitHub às vezes fica fora (504): o mesmo
        // arquivo vai pela API, e o hash abaixo garante que é o mesmo zip.
        if (e == error.NoRelease) return e;
        try updater.fetchGithubReleaseFile(repo, tag, file, &data, zip_bytes + 1024, &got_bytes);
    };

    var want: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&want, sha256) catch unreachable;
    var got: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data.items, &got, .{});
    if (!std.mem.eql(u8, &got, &want)) return error.BadHash;

    phase_now.store(.installing, .release);
    updater.wakeUi();
    var db: [512]u8 = undefined;
    const dir = ffmpeg.localDir(&db) orelse return error.Disk;
    var dz: [520]u8 = undefined;
    if (!c.SDL_CreateDirectory((std.fmt.bufPrintSentinel(&dz, "{s}", .{dir}, 0) catch return error.Disk).ptr)) return error.Disk;
    // Tudo em ".part" antes: uma falha no meio não deixa metade de um FFmpeg na pasta.
    var pb: [600]u8 = undefined;
    var fb: [600]u8 = undefined;
    for (wanted) |name| {
        const body = try unzip(alloc, data.items, name);
        defer alloc.free(body);
        const part = std.fmt.bufPrintSentinel(&pb, "{s}/{s}.part", .{ dir, name }, 0) catch return error.Disk;
        if (!c.SDL_SaveFile(part.ptr, body.ptr, body.len)) return error.Disk;
    }
    for (wanted) |name| {
        const part = std.fmt.bufPrintSentinel(&pb, "{s}/{s}.part", .{ dir, name }, 0) catch return error.Disk;
        const final = std.fmt.bufPrintSentinel(&fb, "{s}/{s}", .{ dir, name }, 0) catch return error.Disk;
        if (!c.SDL_RenamePath(part.ptr, final.ptr)) return error.Disk;
    }
}

fn le16(b: []const u8, at: usize) u16 {
    return std.mem.readInt(u16, b[at..][0..2], .little);
}

fn le32(b: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, b[at..][0..4], .little);
}

/// O conteúdo do arquivo `name`, em qualquer pasta do zip. Sem depender de ferramenta do sistema
/// e sem usar o caminho de dentro do zip: quem escolhe onde gravar é o app.
pub fn unzip(gpa: std.mem.Allocator, zip: []const u8, name: []const u8) ![]u8 {
    if (zip.len < 22) return error.BadZip;
    var e = zip.len - 22;
    while (le32(zip, e) != 0x06054b50) {
        if (e == 0 or zip.len - e > 22 + 65535) return error.BadZip;
        e -= 1;
    }
    const count = le16(zip, e + 10);
    var p: usize = le32(zip, e + 16);
    for (0..count) |_| {
        if (p + 46 > zip.len or le32(zip, p) != 0x02014b50) return error.BadZip;
        const method = le16(zip, p + 10);
        const packed_size: usize = le32(zip, p + 20);
        const size: usize = le32(zip, p + 24);
        const name_len: usize = le16(zip, p + 28);
        const extra_len: usize = le16(zip, p + 30);
        const note_len: usize = le16(zip, p + 32);
        const local: usize = le32(zip, p + 42);
        if (p + 46 + name_len > zip.len) return error.BadZip;
        const path = zip[p + 46..][0..name_len];
        p += 46 + name_len + extra_len + note_len;
        const base = if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| path[i + 1..] else path;
        if (!std.mem.eql(u8, base, name)) continue;

        if (local + 30 > zip.len or le32(zip, local) != 0x04034b50) return error.BadZip;
        const begin = local + 30 + le16(zip, local + 26) + le16(zip, local + 28);
        if (begin + packed_size > zip.len) return error.BadZip;
        const raw = zip[begin..][0..packed_size];
        switch (method) {
            0 => return gpa.dupe(u8, raw),
            8 => {
                const out = try gpa.alloc(u8, size);
                errdefer gpa.free(out);
                var in: std.Io.Reader = .fixed(raw);
                var dec: std.compress.flate.Decompress = .init(&in, .raw, &.{});
                var w: std.Io.Writer = .fixed(out);
                const n = dec.reader.streamRemaining(&w) catch return error.BadZip;
                if (n != size) return error.BadZip;
                return out;
            },
            else => return error.BadZip,
        }
    }
    return error.BadZip;
}

const test_zip = "\x50\x4b\x03\x04\x14\x00\x00\x00\x00\x00\x00\x00\x21\x00\x51\x22\xc7\x1a\x07\x00\x00\x00\x07\x00\x00\x00\x12\x00\x00\x00\x70\x61\x63\x6f\x74\x65\x2f\x4c\x49\x43\x45\x4e\x53\x45\x2e\x74\x78\x74\x6c\x69\x63\x65\x6e\x63\x61\x50\x4b\x03\x04\x14\x00\x00\x00\x08\x00\x00\x00\x21\x00\x89\x8a\x0c\xf9\x07\x00\x00\x00\x26\x00\x00\x00\x18\x00\x00\x00\x70\x61\x63\x6f\x74\x65\x2f\x62\x69\x6e\x2f\x61\x76\x75\x74\x69\x6c\x2d\x36\x30\x2e\x64\x6c\x6c\xcb\xcf\x54\xc8\x27\x8c\x00\x50\x4b\x03\x04\x14\x00\x00\x00\x00\x00\x00\x00\x21\x00\xac\x32\xb6\x88\x03\x00\x00\x00\x03\x00\x00\x00\x17\x00\x00\x00\x70\x61\x63\x6f\x74\x65\x2f\x62\x69\x6e\x2f\x67\x75\x61\x72\x64\x61\x64\x6f\x2e\x64\x6c\x6c\x63\x72\x75\x50\x4b\x01\x02\x14\x03\x14\x00\x00\x00\x00\x00\x00\x00\x21\x00\x51\x22\xc7\x1a\x07\x00\x00\x00\x07\x00\x00\x00\x12\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x80\x01\x00\x00\x00\x00\x70\x61\x63\x6f\x74\x65\x2f\x4c\x49\x43\x45\x4e\x53\x45\x2e\x74\x78\x74\x50\x4b\x01\x02\x14\x03\x14\x00\x00\x00\x08\x00\x00\x00\x21\x00\x89\x8a\x0c\xf9\x07\x00\x00\x00\x26\x00\x00\x00\x18\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x80\x01\x37\x00\x00\x00\x70\x61\x63\x6f\x74\x65\x2f\x62\x69\x6e\x2f\x61\x76\x75\x74\x69\x6c\x2d\x36\x30\x2e\x64\x6c\x6c\x50\x4b\x01\x02\x14\x03\x14\x00\x00\x00\x00\x00\x00\x00\x21\x00\xac\x32\xb6\x88\x03\x00\x00\x00\x03\x00\x00\x00\x17\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x80\x01\x74\x00\x00\x00\x70\x61\x63\x6f\x74\x65\x2f\x62\x69\x6e\x2f\x67\x75\x61\x72\x64\x61\x64\x6f\x2e\x64\x6c\x6c\x50\x4b\x05\x06\x00\x00\x00\x00\x03\x00\x03\x00\xcb\x00\x00\x00\xac\x00\x00\x00\x00\x00";

test "tira do zip pelo nome, comprimido ou guardado" {
    const gpa = std.testing.allocator;
    const a = try unzip(gpa, test_zip, "avutil-60.dll");
    defer gpa.free(a);
    try std.testing.expectEqualStrings("oi oi oi oi oi oi oi oi oi oi oi oi oi", a);
    const b = try unzip(gpa, test_zip, "guardado.dll");
    defer gpa.free(b);
    try std.testing.expectEqualStrings("cru", b);
    try std.testing.expectError(error.BadZip, unzip(gpa, test_zip, "nao-existe.dll"));
}

test "zip cortado ou adulterado dá erro, sem ler fora do lugar" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.BadZip, unzip(gpa, "", "x"));
    try std.testing.expectError(error.BadZip, unzip(gpa, test_zip[0 .. test_zip.len - 30], "avutil-60.dll"));
    // Diretório apontando para fora do arquivo.
    var bad = test_zip.*;
    std.mem.writeInt(u32, bad[bad.len - 6..][0..4], 0xFFFF_FF00, .little);
    try std.testing.expectError(error.BadZip, unzip(gpa, &bad, "avutil-60.dll"));
    // Tamanho declarado maior que o real.
    var big = test_zip.*;
    const cd = std.mem.readInt(u32, big[big.len - 6..][0..4], .little);
    std.mem.writeInt(u32, big[cd + 55 + 46 + 18 + 24 ..][0..4], 4096, .little);
    try std.testing.expectError(error.BadZip, unzip(gpa, &big, "avutil-60.dll"));
}
