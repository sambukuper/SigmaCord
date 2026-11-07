//! Rascunho por canal: o texto digitado e não enviado fica guardado quando
//! se troca de canal e volta quando se volta. Sobrevive a fechar o app
//! (~/.config/sigmacord/drafts.kdl, ao lado do settings.kdl, só para o
//! usuário: chmod 600). Enviar apaga.
const std = @import("std");
const c = @import("c");
const kdl = @import("../theme/kdl.zig");
const quoted = @import("../core/filtros.zig").quoted;
const Id = @import("../core/types.zig").Id;

/// Teto de conversas com rascunho (o arquivo nunca cresce sem limite).
const max_drafts = 300;

pub const Drafts = struct {
    /// Canal -> texto (alocado com o gpa do estado).
    map: std.AutoArrayHashMapUnmanaged(Id, []u8) = .empty,
    /// Canal cujo texto está na caixa agora.
    current: Id = 0,
    /// Mudou desde a última vez que foi salvo.
    dirty: bool = false,

    pub fn deinit(dr: *Drafts, gpa: std.mem.Allocator) void {
        for (dr.map.values()) |v| gpa.free(v);
        dr.map.deinit(gpa);
    }

    pub fn get(dr: *const Drafts, ch: Id) ?[]const u8 {
        return dr.map.get(ch);
    }

    /// Guarda (texto vazio apaga).
    pub fn put(dr: *Drafts, gpa: std.mem.Allocator, ch: Id, text: []const u8) void {
        if (std.mem.trim(u8, text, " \t\r\n").len == 0) return dr.remove(gpa, ch);
        if (dr.map.getPtr(ch)) |v| {
            if (std.mem.eql(u8, v.*, text)) return;
            const owned = gpa.dupe(u8, text) catch return;
            gpa.free(v.*);
            v.* = owned;
        } else {
            if (dr.map.count() >= max_drafts) return;
            const owned = gpa.dupe(u8, text) catch return;
            dr.map.put(gpa, ch, owned) catch return gpa.free(owned);
        }
        dr.dirty = true;
    }

    pub fn remove(dr: *Drafts, gpa: std.mem.Allocator, ch: Id) void {
        const kv = dr.map.fetchOrderedRemove(ch) orelse return;
        gpa.free(kv.value);
        dr.dirty = true;
    }

    /// A caixa de texto passou para o canal `ch` (0 = nenhum): guarda o
    /// texto do anterior e traz o do novo para `input` (terminado em 0).
    /// `keep_old` = false quando a caixa tinha outra coisa (uma edição).
    /// Retorna true se trocou.
    pub fn switchTo(dr: *Drafts, gpa: std.mem.Allocator, ch: Id, input: []u8, keep_old: bool) bool {
        if (ch == dr.current) return false;
        if (dr.current != 0 and keep_old) dr.put(gpa, dr.current, std.mem.sliceTo(input, 0));
        dr.current = ch;
        const saved = if (ch != 0) dr.get(ch) orelse "" else "";
        var n = @min(saved.len, input.len - 1);
        while (n > 0 and n < saved.len and (saved[n] & 0xC0) == 0x80) n -= 1;
        @memcpy(input[0..n], saved[0..n]);
        @memset(input[n..], 0);
        return true;
    }

    /// `draft "500005" "texto"` por linha (o ID vai como texto).
    pub fn write(dr: *const Drafts, out: *std.ArrayList(u8), gpa: std.mem.Allocator) !void {
        try out.appendSlice(gpa, "// rascunhos do SigmaCord: o que foi digitado e não enviado\n");
        for (dr.map.keys(), dr.map.values()) |ch, text| {
            try out.print(gpa, "draft \"{d}\" ", .{ch});
            try quoted(out, gpa, text);
            try out.append(gpa, '\n');
        }
    }

    /// false: o arquivo não é KDL válido.
    pub fn parse(dr: *Drafts, gpa: std.mem.Allocator, src: []const u8) bool {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const nodes = kdl.parse(arena.allocator(), src, null) catch return false;
        for (nodes) |*n| {
            if (!std.mem.eql(u8, n.name, "draft")) continue;
            const id_s = (n.arg(0) orelse continue).asString() orelse continue;
            const text = (n.arg(1) orelse continue).asString() orelse continue;
            const ch = std.fmt.parseInt(Id, id_s, 10) catch continue;
            dr.put(gpa, ch, text);
        }
        dr.dirty = false;
        return true;
    }

    pub fn load(dr: *Drafts, gpa: std.mem.Allocator, path: [:0]const u8) void {
        var size: usize = 0;
        const data = c.SDL_LoadFile(path.ptr, &size) orelse return;
        defer c.SDL_free(data);
        if (!dr.parse(gpa, @as([*]const u8, @ptrCast(data))[0..size])) @import("../platform/fsutil.zig").keepBroken(path);
    }

    /// Salva (só para o dono do arquivo: pode ter texto de uma DM).
    pub fn save(dr: *Drafts, gpa: std.mem.Allocator, path: [:0]const u8) void {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        dr.write(&out, gpa) catch return;
        // Só deixa de estar pendente se gravou (senão tenta de novo depois).
        if (@import("../platform/fsutil.zig").writePrivate(path, out.items)) dr.dirty = false;
    }
};

test "rascunho por canal: troca, volta e vai pelo arquivo" {
    const gpa = std.testing.allocator;
    var dr: Drafts = .{};
    defer dr.deinit(gpa);
    var input: [32]u8 = @splat(0);
    _ = dr.switchTo(gpa, 10, &input, true);
    @memcpy(input[0..9], "oi \"todo\"");
    _ = dr.switchTo(gpa, 20, &input, true);
    try std.testing.expectEqualStrings("", std.mem.sliceTo(&input, 0));
    @memcpy(input[0..5], "linha");
    input[5] = '\n';
    _ = dr.switchTo(gpa, 10, &input, true);
    try std.testing.expectEqualStrings("oi \"todo\"", std.mem.sliceTo(&input, 0));

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try dr.write(&out, gpa);
    var back: Drafts = .{};
    defer back.deinit(gpa);
    try std.testing.expect(back.parse(gpa, out.items));
    try std.testing.expectEqualStrings("oi \"todo\"", back.get(10).?);
    try std.testing.expectEqualStrings("linha\n", back.get(20).?);
    back.put(gpa, 10, "  ");
    try std.testing.expect(back.get(10) == null);
}
