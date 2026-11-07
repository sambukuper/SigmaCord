//! A versão do app e o que dá para decidir sem rede sobre uma atualização:
//! comparar versões, ler o SHA256SUMS e conferir a assinatura dele.
const std = @import("std");

pub const number = "0.7.0";

/// Chave pública das versões publicadas. A privada não está no repositório:
/// uma atualização que não foi assinada com ela não é instalada.
pub const release_key_hex = "44f1bace054778757bc3f1eceb750bbfa9491b98f9c049063df080f971c3b229";

const Triple = struct { major: u32, minor: u32, patch: u32 };

fn parse(tag_in: []const u8) ?Triple {
    const tag = if (tag_in.len > 0 and tag_in[0] == 'v') tag_in[1..] else tag_in;
    var it = std.mem.splitScalar(u8, tag, '.');
    const a = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
    const b = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
    const p = it.next() orelse "0";
    const c = std.fmt.parseInt(u32, p, 10) catch return null;
    if (it.next() != null) return null;
    return .{ .major = a, .minor = b, .patch = c };
}

/// `tag` é mais nova que `current`? Versão que não dá para ler nunca é.
pub fn newer(tag: []const u8, current: []const u8) bool {
    const t = parse(tag) orelse return false;
    const n = parse(current) orelse return false;
    if (t.major != n.major) return t.major > n.major;
    if (t.minor != n.minor) return t.minor > n.minor;
    return t.patch > n.patch;
}

/// O hash de `name` num arquivo no formato do `sha256sum`.
pub fn sumFor(sums: []const u8, name: []const u8) ?[32]u8 {
    var lines = std.mem.tokenizeAny(u8, sums, "\r\n");
    while (lines.next()) |line| {
        var parts = std.mem.tokenizeAny(u8, line, " *");
        const hex = parts.next() orelse continue;
        const file = parts.next() orelse continue;
        if (!std.mem.eql(u8, file, name) or hex.len != 64) continue;
        var out: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&out, hex) catch return null;
        return out;
    }
    return null;
}

/// `sig_hex`: a assinatura Ed25519 de `sums`, em hexadecimal.
pub fn signatureOk(sums: []const u8, sig_hex: []const u8, key_hex: []const u8) bool {
    const Ed = std.crypto.sign.Ed25519;
    var key: [Ed.PublicKey.encoded_length]u8 = undefined;
    var sig: [Ed.Signature.encoded_length]u8 = undefined;
    _ = std.fmt.hexToBytes(&key, std.mem.trim(u8, key_hex, " \r\n")) catch return false;
    _ = std.fmt.hexToBytes(&sig, std.mem.trim(u8, sig_hex, " \r\n")) catch return false;
    const pk = Ed.PublicKey.fromBytes(key) catch return false;
    Ed.Signature.fromBytes(sig).verify(sums, pk) catch return false;
    return true;
}

test "comparar versões" {
    const t = std.testing;
    try t.expect(newer("v0.5.1", "0.5.0"));
    try t.expect(newer("0.6", "0.5.9"));
    try t.expect(newer("v1.0.0", "0.99.99"));
    try t.expect(!newer("v0.5.0", "0.5.0"));
    try t.expect(!newer("v0.4.9", "0.5.0"));
    try t.expect(!newer("nightly", "0.5.0"));
    try t.expect(!newer("v0.5.0-rc1", "0.4.0"));
    try t.expect(!newer("v1.2.3.4", "0.1.0"));
}

test "SHA256SUMS" {
    const t = std.testing;
    const sums = "abababababababababababababababababababababababababababababababab  sigmacord-linux-x86_64\r\n" ++ "cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd *SDL3.dll\n";
    try t.expectEqual(@as(u8, 0xab), sumFor(sums, "sigmacord-linux-x86_64").?[0]);
    try t.expectEqual(@as(u8, 0xcd), sumFor(sums, "SDL3.dll").?[31]);
    try t.expect(sumFor(sums, "outro") == null);
    try t.expect(sumFor("curto  a\n", "a") == null);
}

test "assinatura: só a chave certa e o texto certo" {
    const t = std.testing;
    const Ed = std.crypto.sign.Ed25519;
    const kp = try Ed.KeyPair.generateDeterministic(@splat(7));
    const msg = "abc  sigmacord\n";
    const sig = try kp.sign(msg, null);
    var sb: [128]u8 = undefined;
    var kb: [64]u8 = undefined;
    const sig_hex = std.fmt.bufPrint(&sb, "{x}", .{&sig.toBytes()}) catch unreachable;
    const key_hex = std.fmt.bufPrint(&kb, "{x}", .{&kp.public_key.toBytes()}) catch unreachable;
    try t.expect(signatureOk(msg, sig_hex, key_hex));
    try t.expect(!signatureOk("abd  sigmacord\n", sig_hex, key_hex));
    const other = try Ed.KeyPair.generateDeterministic(@splat(9));
    var ob: [64]u8 = undefined;
    const other_hex = std.fmt.bufPrint(&ob, "{x}", .{&other.public_key.toBytes()}) catch unreachable;
    try t.expect(!signatureOk(msg, sig_hex, other_hex));
    try t.expect(!signatureOk(msg, "zz", key_hex));
}
