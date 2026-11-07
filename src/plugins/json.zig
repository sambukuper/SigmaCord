//! JSON <-> Lua: `sigma.json` e o arquivo do armazenamento de cada plugin.
//! Roda em C, fora do gancho de instruções: os limites vêm do tamanho (texto
//! limitado por quem chama, memória do Lua limitada pelo alocador) e da
//! profundidade (`max_depth`), então não há como travar aqui dentro.
const std = @import("std");
const lua = @import("lua.zig");

pub const max_depth = 32;

pub const Error = error{ TooDeep, TooBig, Unsupported, Invalid, OutOfMemory };

const Out = struct {
    gpa: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    max: usize,

    fn put(o: Out, s: []const u8) Error!void {
        if (o.buf.items.len + s.len > o.max) return error.TooBig;
        try o.buf.appendSlice(o.gpa, s);
    }

    fn byte(o: Out, b: u8) Error!void {
        return o.put(&.{b});
    }
};

/// Texto entre aspas, com os escapes do JSON.
pub fn quote(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), max: usize, s: []const u8) Error!void {
    return quoteTo(.{ .gpa = gpa, .buf = buf, .max = max }, s);
}

fn quoteTo(o: Out, s: []const u8) Error!void {
    try o.byte('"');
    var from: usize = 0;
    for (s, 0..) |ch, i| {
        if (ch >= 0x20 and ch != '"' and ch != '\\') continue;
        try o.put(s[from..i]);
        from = i + 1;
        switch (ch) {
            '"' => try o.put("\\\""),
            '\\' => try o.put("\\\\"),
            '\n' => try o.put("\\n"),
            '\r' => try o.put("\\r"),
            '\t' => try o.put("\\t"),
            else => {
                var b: [6]u8 = undefined;
                try o.put(std.fmt.bufPrint(&b, "\\u{x:0>4}", .{ch}) catch unreachable);
            },
        }
    }
    try o.put(s[from..]);
    try o.byte('"');
}

/// O valor em `idx` vira JSON no fim de `buf` (sem passar de `max` bytes).
/// Só o que tem jeito de voltar igual: texto, número, booleano e tabela (lista
/// 1..n, ou com chaves de texto). Função, nil dentro de lista, NaN: erro.
pub fn encode(L: ?*lua.State, gpa: std.mem.Allocator, buf: *std.ArrayList(u8), max: usize, idx: c_int) Error!void {
    return encodeAt(L, .{ .gpa = gpa, .buf = buf, .max = max }, lua.lua_absindex(L, idx), 0);
}

fn encodeAt(L: ?*lua.State, o: Out, idx: c_int, depth: u8) Error!void {
    if (depth > max_depth) return error.TooDeep;
    switch (lua.lua_type(L, idx)) {
        lua.TNIL => try o.put("null"),
        lua.TBOOLEAN => try o.put(if (lua.lua_toboolean(L, idx) != 0) "true" else "false"),
        lua.TNUMBER => {
            var b: [48]u8 = undefined;
            if (lua.lua_isinteger(L, idx) != 0) {
                try o.put(std.fmt.bufPrint(&b, "{d}", .{lua.lua_tointegerx(L, idx, null)}) catch return error.Invalid);
            } else {
                const f = lua.lua_tonumberx(L, idx, null);
                if (std.math.isNan(f) or std.math.isInf(f)) return error.Unsupported;
                try o.put(std.fmt.bufPrint(&b, "{e}", .{f}) catch return error.Invalid);
            }
        },
        lua.TSTRING => try quoteTo(o, lua.toSlice(L, idx).?),
        lua.TTABLE => try encodeTable(L, o, idx, depth),
        else => return error.Unsupported,
    }
}

fn encodeTable(L: ?*lua.State, o: Out, idx: c_int, depth: u8) Error!void {
    lua.luaL_checkstack(L, 4, "json");
    const n = lua.lua_rawlen(L, idx);
    // Lista: só as chaves 1..n. Qualquer outra faz dela um objeto.
    var count: u64 = 0;
    var keys_are_text = true;
    lua.lua_pushnil(L);
    while (lua.lua_next(L, idx) != 0) {
        count += 1;
        if (lua.lua_type(L, -2) != lua.TSTRING) keys_are_text = false;
        lua.pop(L, 1);
    }
    if (n > 0 and count == n) {
        try o.byte('[');
        var i: u64 = 1;
        while (i <= n) : (i += 1) {
            if (i > 1) try o.byte(',');
            _ = lua.lua_rawgeti(L, idx, @intCast(i));
            defer lua.pop(L, 1);
            try encodeAt(L, o, lua.lua_gettop(L), depth + 1);
        }
        return o.byte(']');
    }
    if (count == 0) return o.put("{}");
    if (!keys_are_text) return error.Unsupported;
    try o.byte('{');
    var first = true;
    lua.lua_pushnil(L);
    while (lua.lua_next(L, idx) != 0) {
        defer lua.pop(L, 1);
        if (!first) try o.byte(',');
        first = false;
        try quoteTo(o, lua.toSlice(L, -2).?);
        try o.byte(':');
        try encodeAt(L, o, lua.lua_gettop(L), depth + 1);
    }
    try o.byte('}');
}

// --- Leitura ---------------------------------------------------------------------

const Reader = struct {
    s: []const u8,
    at: usize = 0,

    fn skipSpace(r: *Reader) void {
        while (r.at < r.s.len) : (r.at += 1) switch (r.s[r.at]) {
            ' ', '\t', '\n', '\r' => {},
            else => return,
        };
    }

    fn peek(r: *Reader) ?u8 {
        return if (r.at < r.s.len) r.s[r.at] else null;
    }

    fn take(r: *Reader, ch: u8) bool {
        r.skipSpace();
        if (r.peek() == ch) {
            r.at += 1;
            return true;
        }
        return false;
    }

    fn word(r: *Reader, w: []const u8) bool {
        if (!std.mem.startsWith(u8, r.s[r.at..], w)) return false;
        r.at += w.len;
        return true;
    }

    /// Fatia do número, se é um número em JSON.
    fn number(r: *Reader) ?[]const u8 {
        const from = r.at;
        if (r.peek() == '-') r.at += 1;
        const d0 = r.at;
        while (r.peek()) |ch| : (r.at += 1) if (!std.ascii.isDigit(ch)) break;
        if (r.at == d0) return null;
        if (r.peek() == '.') {
            r.at += 1;
            const d1 = r.at;
            while (r.peek()) |ch| : (r.at += 1) if (!std.ascii.isDigit(ch)) break;
            if (r.at == d1) return null;
        }
        if (r.peek() == 'e' or r.peek() == 'E') {
            r.at += 1;
            if (r.peek() == '+' or r.peek() == '-') r.at += 1;
            const d2 = r.at;
            while (r.peek()) |ch| : (r.at += 1) if (!std.ascii.isDigit(ch)) break;
            if (r.at == d2) return null;
        }
        return r.s[from..r.at];
    }

    /// Texto (já depois da abertura) para `buf`, sem as aspas e sem os escapes.
    fn string(r: *Reader, gpa: std.mem.Allocator, buf: *std.ArrayList(u8)) Error![]const u8 {
        buf.clearRetainingCapacity();
        if (!r.take('"')) return error.Invalid;
        while (true) {
            const ch = r.peek() orelse return error.Invalid;
            r.at += 1;
            switch (ch) {
                '"' => return buf.items,
                '\\' => {
                    const e = r.peek() orelse return error.Invalid;
                    r.at += 1;
                    switch (e) {
                        '"', '\\', '/' => try buf.append(gpa, e),
                        'n' => try buf.append(gpa, '\n'),
                        'r' => try buf.append(gpa, '\r'),
                        't' => try buf.append(gpa, '\t'),
                        'b' => try buf.append(gpa, 8),
                        'f' => try buf.append(gpa, 12),
                        'u' => try r.unicode(gpa, buf),
                        else => return error.Invalid,
                    }
                },
                else => {
                    if (ch < 0x20) return error.Invalid;
                    try buf.append(gpa, ch);
                },
            }
        }
    }

    fn hex4(r: *Reader) ?u21 {
        if (r.at + 4 > r.s.len) return null;
        const v = std.fmt.parseInt(u16, r.s[r.at..][0..4], 16) catch return null;
        r.at += 4;
        return v;
    }

    fn unicode(r: *Reader, gpa: std.mem.Allocator, buf: *std.ArrayList(u8)) Error!void {
        var cp = r.hex4() orelse return error.Invalid;
        if (cp >= 0xD800 and cp < 0xDC00) {
            // Par substituto: sem a segunda metade, vira o caractere de troca.
            if (r.word("\\u")) {
                const lo = r.hex4() orelse return error.Invalid;
                cp = if (lo >= 0xDC00 and lo < 0xE000) 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00) else 0xFFFD;
            } else cp = 0xFFFD;
        } else if (cp >= 0xDC00 and cp < 0xE000) cp = 0xFFFD;
        var b: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &b) catch return error.Invalid;
        try buf.appendSlice(gpa, b[0..n]);
    }

    /// Anda por um valor sem montar nada.
    fn skip(r: *Reader, gpa: std.mem.Allocator, buf: *std.ArrayList(u8), depth: u8) Error!void {
        if (depth > max_depth) return error.TooDeep;
        r.skipSpace();
        const ch = r.peek() orelse return error.Invalid;
        switch (ch) {
            '"' => _ = try r.string(gpa, buf),
            '{' => {
                r.at += 1;
                if (r.take('}')) return;
                while (true) {
                    r.skipSpace();
                    _ = try r.string(gpa, buf);
                    if (!r.take(':')) return error.Invalid;
                    try r.skip(gpa, buf, depth + 1);
                    if (r.take('}')) return;
                    if (!r.take(',')) return error.Invalid;
                }
            },
            '[' => {
                r.at += 1;
                if (r.take(']')) return;
                while (true) {
                    try r.skip(gpa, buf, depth + 1);
                    if (r.take(']')) return;
                    if (!r.take(',')) return error.Invalid;
                }
            },
            't' => if (!r.word("true")) return error.Invalid,
            'f' => if (!r.word("false")) return error.Invalid,
            'n' => if (!r.word("null")) return error.Invalid,
            else => _ = r.number() orelse return error.Invalid,
        }
    }

    /// Monta o valor na pilha do Lua.
    fn push(r: *Reader, L: ?*lua.State, gpa: std.mem.Allocator, buf: *std.ArrayList(u8), depth: u8) Error!void {
        if (depth > max_depth) return error.TooDeep;
        lua.luaL_checkstack(L, 4, "json");
        r.skipSpace();
        const ch = r.peek() orelse return error.Invalid;
        switch (ch) {
            '"' => lua.pushSlice(L, try r.string(gpa, buf)),
            '{' => {
                r.at += 1;
                lua.newtable(L);
                if (r.take('}')) return;
                while (true) {
                    r.skipSpace();
                    lua.pushSlice(L, try r.string(gpa, buf));
                    if (!r.take(':')) return error.Invalid;
                    try r.push(L, gpa, buf, depth + 1);
                    lua.lua_rawset(L, -3);
                    if (r.take('}')) return;
                    if (!r.take(',')) return error.Invalid;
                }
            },
            '[' => {
                r.at += 1;
                lua.newtable(L);
                if (r.take(']')) return;
                var i: lua.Integer = 1;
                while (true) : (i += 1) {
                    try r.push(L, gpa, buf, depth + 1);
                    lua.lua_rawseti(L, -2, i);
                    if (r.take(']')) return;
                    if (!r.take(',')) return error.Invalid;
                }
            },
            't' => {
                if (!r.word("true")) return error.Invalid;
                lua.lua_pushboolean(L, 1);
            },
            'f' => {
                if (!r.word("false")) return error.Invalid;
                lua.lua_pushboolean(L, 0);
            },
            'n' => {
                if (!r.word("null")) return error.Invalid;
                lua.lua_pushnil(L);
            },
            else => {
                const num = r.number() orelse return error.Invalid;
                if (std.fmt.parseInt(i64, num, 10)) |v| {
                    lua.lua_pushinteger(L, v);
                } else |_| {
                    lua.lua_pushnumber(L, std.fmt.parseFloat(f64, num) catch return error.Invalid);
                }
            },
        }
    }
};

/// Um valor JSON inteiro em `text` vira um valor na pilha do Lua. Com erro, o que
/// sobrou na pilha fica para quem chama limpar (lua_settop).
pub fn decode(L: ?*lua.State, gpa: std.mem.Allocator, buf: *std.ArrayList(u8), text: []const u8) Error!void {
    var r: Reader = .{ .s = text };
    try r.push(L, gpa, buf, 0);
    r.skipSpace();
    if (r.at != text.len) return error.Invalid;
}

/// O texto é um JSON válido?
pub fn valid(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), text: []const u8) bool {
    var r: Reader = .{ .s = text };
    r.skip(gpa, buf, 0) catch return false;
    r.skipSpace();
    return r.at == text.len;
}

/// Anda pelas chaves do objeto de cima e devolve o texto de cada valor, sem montar
/// nada (o arquivo do armazenamento guarda o valor em JSON mesmo).
pub const Fields = struct {
    r: Reader,
    gpa: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    tmp: *std.ArrayList(u8),
    first: bool = true,

    pub fn init(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), tmp: *std.ArrayList(u8), text: []const u8) Error!Fields {
        var r: Reader = .{ .s = text };
        if (!r.take('{')) return error.Invalid;
        return .{ .r = r, .gpa = gpa, .buf = buf, .tmp = tmp };
    }

    pub const Field = struct { key: []const u8, value: []const u8 };

    /// `key` vale até a próxima chamada. null = acabou.
    pub fn next(f: *Fields) Error!?Field {
        if (f.first) {
            f.first = false;
            if (f.r.take('}')) return f.end();
        } else {
            if (f.r.take('}')) return f.end();
            if (!f.r.take(',')) return error.Invalid;
        }
        f.r.skipSpace();
        const key = try f.r.string(f.gpa, f.buf);
        if (!f.r.take(':')) return error.Invalid;
        f.r.skipSpace();
        const from = f.r.at;
        try f.r.skip(f.gpa, f.tmp, 1);
        return .{ .key = key, .value = f.r.s[from..f.r.at] };
    }

    fn end(f: *Fields) Error!?Field {
        f.r.skipSpace();
        if (f.r.at != f.r.s.len) return error.Invalid;
        return null;
    }
};

test "json: valid e campos de um objeto" {
    const gpa = std.testing.allocator;
    var a: std.ArrayList(u8) = .empty;
    defer a.deinit(gpa);
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(gpa);
    try std.testing.expect(valid(gpa, &a, "{\"a\": [1, 2.5e3, \"x\\n\"], \"b\": null}"));
    for ([_][]const u8{ "", "{", "[1,]", "{\"a\"}", "tru", "01x", "\"\x01\"", "{} x" }) |bad| try std.testing.expect(!valid(gpa, &a, bad));
    var deep: [200]u8 = undefined;
    @memset(&deep, '[');
    try std.testing.expect(!valid(gpa, &a, &deep));

    var f = try Fields.init(gpa, &a, &b, " { \"a\\u00e3\" : [1, {\"x\":2}] , \"b\": \"t\" } ");
    const one = (try f.next()).?;
    try std.testing.expectEqualStrings("aã", one.key);
    try std.testing.expectEqualStrings("[1, {\"x\":2}]", one.value);
    const two = (try f.next()).?;
    try std.testing.expectEqualStrings("b", two.key);
    try std.testing.expectEqualStrings("\"t\"", two.value);
    try std.testing.expect((try f.next()) == null);
    var e = try Fields.init(gpa, &a, &b, "{}");
    try std.testing.expect((try e.next()) == null);
    try std.testing.expectError(error.Invalid, Fields.init(gpa, &a, &b, "[1]"));
}

test "json: aspas e controle" {
    const gpa = std.testing.allocator;
    var a: std.ArrayList(u8) = .empty;
    defer a.deinit(gpa);
    try quote(gpa, &a, 100, "a\"b\\c\nd\x01é");
    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\\nd\\u0001é\"", a.items);
    a.clearRetainingCapacity();
    try std.testing.expectError(error.TooBig, quote(gpa, &a, 3, "abcdef"));
}
