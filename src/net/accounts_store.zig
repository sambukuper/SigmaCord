//! Onde ficam as contas guardadas: a lista (core/accounts.zig) em
//! ~/.config/sigmacord/accounts e o token de cada uma no chaveiro do
//! sistema, uma entrada por conta:
//!
//!   secret-tool store --label='SigmaCord (conta ID)' service sigmacord-account account ID
//!
//! Sem chaveiro, em ~/.config/sigmacord/tokens/ID (pasta 700, arquivo 600),
//! como o token único de antes. A entrada antiga (`service sigmacord`,
//! discord.zig) continua valendo para a conta que já estava nela.
//!
//! O serviço tem outro nome de propósito: `secret-tool clear service
//! sigmacord` (o "Sair" de antes) casa com qualquer entrada que tenha esse
//! atributo, e apagaria todas as contas de uma vez.
//!
//! O token nunca vai para a linha de comando (vai pela entrada padrão do
//! secret-tool) e o comando só leva o ID, que é um número.
const std = @import("std");
const sys = @import("../platform/sys.zig");
const c = @import("c");
const accounts = @import("../core/accounts.zig");
const discord = @import("discord.zig");
const fsutil = @import("../platform/fsutil.zig");
const Id = @import("../core/types.zig").Id;

const alloc = std.heap.c_allocator;

pub var list: accounts.List = .{};
/// QA e prints: nada vai para o disco nem para o chaveiro.
pub var memory_only = false;
/// Conta da sessão aberta agora (0 = nenhuma ainda).
pub var session: Id = 0;

fn listPath(buf: []u8) ?[:0]const u8 {
    return fsutil.configPath(buf, "accounts");
}

fn tokenPath(buf: []u8, id: Id) ?[:0]const u8 {
    var nbuf: [40]u8 = undefined;
    return fsutil.configPath(buf, std.fmt.bufPrint(&nbuf, "tokens/{d}", .{id}) catch return null);
}

pub fn load() void {
    if (memory_only) return;
    var buf: [512]u8 = undefined;
    const path = listPath(&buf) orelse return;
    var size: usize = 0;
    const data = c.SDL_LoadFile(path.ptr, &size) orelse return;
    defer c.SDL_free(data);
    list = accounts.List.parse(@as([*]const u8, @ptrCast(data))[0..size]);
}

pub fn save() void {
    if (memory_only) return;
    var buf: [512]u8 = undefined;
    const path = listPath(&buf) orelse return;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    list.write(&out, alloc) catch return;
    _ = fsutil.writePrivate(path, out.items);
}

fn trimmed(raw: []const u8) ?[:0]u8 {
    const s = std.mem.trim(u8, raw, " \n\r\t");
    if (s.len <= 20) return null;
    return alloc.dupeSentinel(u8, s, 0) catch null;
}

/// Token guardado de uma conta (alocado; quem recebe zera e libera).
pub fn tokenFor(acc: *const accounts.Account) ?[:0]u8 {
    if (memory_only) return null;
    if (acc.legacy) return discord.loadSavedToken();
    var cbuf: [160]u8 = undefined;
    if (sys.windows) {
        const target = credTarget(&cbuf, acc.id) orelse return null;
        var buf: [256]u8 = undefined;
        defer std.crypto.secureZero(u8, &buf);
        if (sys.credRead(target.ptr, &buf)) |s| if (trimmed(s)) |t| return t;
    } else {
        const cmd = std.fmt.bufPrintSentinel(&cbuf, "secret-tool lookup service sigmacord-account account {d} 2>/dev/null", .{acc.id}, 0) catch return null;
        if (c.popen(cmd.ptr, "r")) |f| {
            var buf: [256]u8 = undefined;
            const n = c.fread(&buf, 1, buf.len, f);
            _ = c.pclose(f);
            defer std.crypto.secureZero(u8, &buf);
            if (trimmed(buf[0..n])) |t| return t;
        }
    }
    var pbuf: [512]u8 = undefined;
    const path = tokenPath(&pbuf, acc.id) orelse return null;
    if (!sys.ownerOnly(path.ptr)) return null;
    var size: usize = 0;
    const data = c.SDL_LoadFile(path.ptr, &size) orelse return null;
    defer {
        std.crypto.secureZero(u8, @as([*]u8, @ptrCast(data))[0..size]);
        c.SDL_free(data);
    }
    return trimmed(@as([*]const u8, @ptrCast(data))[0..size]);
}

pub const Saved = enum { keyring, file, failed };

/// Nome da entrada no Gerenciador de Credenciais do Windows.
fn credTarget(buf: []u8, id: Id) ?[:0]const u8 {
    return std.fmt.bufPrintSentinel(buf, "SigmaCord/account/{d}", .{id}, 0) catch null;
}

/// Guarda o token de uma conta (no chaveiro; sem ele, num arquivo 600).
pub fn storeToken(id: Id, token: []const u8) Saved {
    if (memory_only) return .failed;
    var cbuf: [200]u8 = undefined;
    var pbuf: [512]u8 = undefined;
    const path = tokenPath(&pbuf, id);
    if (sys.windows) {
        const target = credTarget(&cbuf, id) orelse return .failed;
        if (sys.credWrite(target.ptr, "SigmaCord", token)) {
            if (path) |p| _ = c.unlink(p.ptr);
            return .keyring;
        }
    } else {
        const cmd = std.fmt.bufPrintSentinel(&cbuf, "secret-tool store --label='SigmaCord (conta {d})' service sigmacord-account account {d} 2>/dev/null", .{ id, id }, 0) catch return .failed;
        if (c.popen(cmd.ptr, "w")) |f| {
            const wrote = c.fwrite(token.ptr, 1, token.len, f);
            if (c.pclose(f) == 0 and wrote == token.len) {
                // Não deixa cópia velha em arquivo.
                if (path) |p| _ = c.unlink(p.ptr);
                return .keyring;
            }
        }
    }
    const p = path orelse return .failed;
    return if (fsutil.writePrivate(p, token)) .file else .failed;
}

/// Apaga o token de uma conta (do chaveiro e do arquivo).
pub fn forgetToken(acc: *const accounts.Account) void {
    if (memory_only) return;
    if (acc.legacy) return discord.forgetToken();
    var cbuf: [160]u8 = undefined;
    if (sys.windows) {
        if (credTarget(&cbuf, acc.id)) |target| sys.credDelete(target.ptr);
    } else if (std.fmt.bufPrintSentinel(&cbuf, "secret-tool clear service sigmacord-account account {d} 2>/dev/null", .{acc.id}, 0)) |cmd| {
        if (c.popen(cmd.ptr, "r")) |f| _ = c.pclose(f);
    } else |_| {}
    var pbuf: [512]u8 = undefined;
    if (tokenPath(&pbuf, acc.id)) |p| _ = c.unlink(p.ptr);
}

/// Token para abrir o app: a conta usada da última vez, depois qualquer
/// outra guardada. `id` recebe de qual conta veio.
pub fn startupTokenFrom(from: *accounts.List, id: *Id) ?[:0]u8 {
    if (from.find(from.active)) |a| if (tokenFor(a)) |t| {
        id.* = a.id;
        return t;
    };
    for (from.slice()) |*a| if (a.id != from.active) if (tokenFor(a)) |t| {
        id.* = a.id;
        return t;
    };
    return null;
}
