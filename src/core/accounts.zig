//! Contas guardadas para a troca rápida (menu do usuário). Só o que aparece
//! no menu: ID, nome e avatar vistos no READY. O token de cada conta fica
//! no chaveiro do sistema (net/accounts_store.zig), nunca aqui.
//!
//! Arquivo (~/.config/sigmacord/accounts, permissão 600), uma linha por
//! registro, campos separados por tabulação:
//!
//!   active  <id>
//!   account <id> <legado 0|1> <avatar> <nome>
//!
//! "Legado": o token é a entrada antiga, de antes das várias contas
//! (`secret-tool … service sigmacord` ou ~/.config/sigmacord/token).
const std = @import("std");
const Id = @import("types.zig").Id;

pub const max_accounts = 8;

pub const Account = struct {
    id: Id,
    legacy: bool = false,
    name_buf: [64]u8 = undefined,
    name_len: u8 = 0,
    avatar_buf: [64]u8 = undefined,
    avatar_len: u8 = 0,

    pub fn name(a: *const Account) []const u8 {
        return a.name_buf[0..a.name_len];
    }
    pub fn avatar(a: *const Account) []const u8 {
        return a.avatar_buf[0..a.avatar_len];
    }

    /// Copia o texto tirando tabulações e quebras (que estragariam a linha)
    /// e cortando sem partir um caractere UTF-8 no meio.
    fn put(buf: []u8, s: []const u8) u8 {
        var n = @min(s.len, buf.len);
        while (n > 0 and n < s.len and (s[n] & 0xC0) == 0x80) n -= 1;
        for (s[0..n], 0..) |ch, i| buf[i] = if (ch == '\t' or ch == '\n' or ch == '\r') ' ' else ch;
        return @intCast(n);
    }

    pub fn setName(a: *Account, s: []const u8) void {
        a.name_len = put(&a.name_buf, s);
    }
    pub fn setAvatar(a: *Account, s: []const u8) void {
        a.avatar_len = put(&a.avatar_buf, s);
    }
};

pub const List = struct {
    items: [max_accounts]Account = undefined,
    len: usize = 0,
    /// Conta usada da última vez (a que entra ao abrir o app).
    active: Id = 0,

    pub fn slice(l: *List) []Account {
        return l.items[0..l.len];
    }

    pub fn find(l: *List, id: Id) ?*Account {
        for (l.items[0..l.len]) |*a| if (a.id == id) return a;
        return null;
    }

    /// Acrescenta ou atualiza. null = lista cheia.
    pub fn upsert(l: *List, id: Id, name: []const u8, avatar: []const u8, legacy: bool) ?*Account {
        const a = l.find(id) orelse blk: {
            if (l.len == max_accounts) return null;
            l.items[l.len] = .{ .id = id };
            l.len += 1;
            break :blk &l.items[l.len - 1];
        };
        a.setName(name);
        a.setAvatar(avatar);
        a.legacy = legacy;
        return a;
    }

    pub fn remove(l: *List, id: Id) bool {
        for (l.items[0..l.len], 0..) |a, i| if (a.id == id) {
            std.mem.copyForwards(Account, l.items[i .. l.len - 1], l.items[i + 1 .. l.len]);
            l.len -= 1;
            if (l.active == id) l.active = if (l.len > 0) l.items[0].id else 0;
            return true;
        };
        return false;
    }

    pub fn parse(text: []const u8) List {
        var l: List = .{};
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            var f = std.mem.splitScalar(u8, std.mem.trimEnd(u8, line, "\r"), '\t');
            const kind = f.next() orelse continue;
            const id = std.fmt.parseInt(Id, f.next() orelse continue, 10) catch continue;
            if (id == 0) continue;
            if (std.mem.eql(u8, kind, "active")) {
                l.active = id;
            } else if (std.mem.eql(u8, kind, "account")) {
                const legacy = std.mem.eql(u8, f.next() orelse "0", "1");
                const avatar = f.next() orelse "";
                const name = f.rest();
                _ = l.upsert(id, name, avatar, legacy);
            }
        }
        if (l.active != 0 and l.find(l.active) == null) l.active = 0;
        return l;
    }

    pub fn write(l: *const List, out: *std.ArrayList(u8), gpa: std.mem.Allocator) !void {
        try out.appendSlice(gpa, "# contas do SigmaCord (os tokens ficam no chaveiro do sistema, nunca aqui)\n");
        if (l.active != 0) try out.print(gpa, "active\t{d}\n", .{l.active});
        for (l.items[0..l.len]) |*a| try out.print(gpa, "account\t{d}\t{s}\t{s}\t{s}\n", .{ a.id, if (a.legacy) "1" else "0", a.avatar(), a.name() });
    }
};

test "contas vão e voltam pelo arquivo" {
    var l: List = .{};
    _ = l.upsert(111, "ana\tcom tab", "abc", false);
    _ = l.upsert(222, "rsha", "", true);
    l.active = 222;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try l.write(&out, std.testing.allocator);
    var back = List.parse(out.items);
    try std.testing.expectEqual(@as(usize, 2), back.len);
    try std.testing.expectEqual(@as(Id, 222), back.active);
    try std.testing.expectEqualStrings("ana com tab", back.find(111).?.name());
    try std.testing.expectEqualStrings("abc", back.find(111).?.avatar());
    try std.testing.expect(back.find(222).?.legacy);
    try std.testing.expect(back.remove(222));
    try std.testing.expectEqual(@as(Id, 111), back.active);
    try std.testing.expect(!back.remove(999));
    // Linhas estragadas são ignoradas.
    const junk = List.parse("account\tabc\t0\t\tx\nactive\t5\n\n\taccount");
    try std.testing.expectEqual(@as(usize, 0), junk.len);
    try std.testing.expectEqual(@as(Id, 0), junk.active);
}
