//! Teclas de atalho sem janela nem interface: converter entre o texto
//! configurado ("ctrl+shift+m"), a combinação de teclas e o rótulo bonito
//! ("Ctrl+Shift+M"). O mesmo texto significa a mesma coisa aqui e nos
//! atalhos dos plugins (plugins/runtime.zig). Quem liga isso à interface é
//! ui/bindings.zig.
const std = @import("std");
/// Só os códigos de tecla do ImGui (build.zig): o módulo completo "c" puxa o
/// SDL, que os testes puros não têm.
const c = @import("imgui_c");

/// Uma combinação: modificadores + tecla do ImGui (0 = nenhuma).
pub const Combo = struct {
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,
    super: bool = false,
    key: c_int = 0,

    pub fn same(a: Combo, b: Combo) bool {
        return a.ctrl == b.ctrl and a.shift == b.shift and a.alt == b.alt and a.super == b.super and a.key == b.key;
    }

    pub fn hasModifier(k: Combo) bool {
        return k.ctrl or k.shift or k.alt or k.super;
    }
};

/// Teclas nomeadas fora de letras, números e F1–F24 (a mesma lista dos
/// plugins, em plugins/host.zig).
const named_keys = [_]struct { n: []const u8, k: c_int }{
    .{ .n = "enter", .k = c.ImGuiKey_Enter },    .{ .n = "space", .k = c.ImGuiKey_Space },
    .{ .n = "tab", .k = c.ImGuiKey_Tab },        .{ .n = "backspace", .k = c.ImGuiKey_Backspace },
    .{ .n = "delete", .k = c.ImGuiKey_Delete },  .{ .n = "insert", .k = c.ImGuiKey_Insert },
    .{ .n = "home", .k = c.ImGuiKey_Home },      .{ .n = "end", .k = c.ImGuiKey_End },
    .{ .n = "pageup", .k = c.ImGuiKey_PageUp },  .{ .n = "pagedown", .k = c.ImGuiKey_PageDown },
    .{ .n = "up", .k = c.ImGuiKey_UpArrow },     .{ .n = "down", .k = c.ImGuiKey_DownArrow },
    .{ .n = "left", .k = c.ImGuiKey_LeftArrow }, .{ .n = "right", .k = c.ImGuiKey_RightArrow },
    .{ .n = ",", .k = c.ImGuiKey_Comma },        .{ .n = ".", .k = c.ImGuiKey_Period },
    .{ .n = "/", .k = c.ImGuiKey_Slash },        .{ .n = ";", .k = c.ImGuiKey_Semicolon },
    .{ .n = "-", .k = c.ImGuiKey_Minus },        .{ .n = "=", .k = c.ImGuiKey_Equal },
};

pub fn isFkey(k: c_int) bool {
    return k >= c.ImGuiKey_F1 and k <= c.ImGuiKey_F24;
}

fn keyCode(name: []const u8) ?c_int {
    if (name.len == 1) {
        const lo = std.ascii.toLower(name[0]);
        if (lo >= 'a' and lo <= 'z') return c.ImGuiKey_A + @as(c_int, lo - 'a');
        if (lo >= '0' and lo <= '9') return c.ImGuiKey_0 + @as(c_int, lo - '0');
        for (named_keys) |x| if (x.n.len == 1 and x.n[0] == name[0]) return x.k;
        return null;
    }
    if (name.len >= 2 and (name[0] == 'f' or name[0] == 'F')) {
        const n = std.fmt.parseInt(u8, name[1..], 10) catch return null;
        if (n >= 1 and n <= 24) return c.ImGuiKey_F1 + @as(c_int, n - 1);
        return null;
    }
    for (named_keys) |x| if (std.ascii.eqlIgnoreCase(x.n, name)) return x.k;
    return null;
}

/// "ctrl+shift+m" → combinação. Modificadores em qualquer ordem, a tecla uma
/// só. null = texto que não dá para entender.
pub fn parse(spec: []const u8) ?Combo {
    var k: Combo = .{};
    var it = std.mem.splitScalar(u8, spec, '+');
    while (it.next()) |raw| {
        const part = std.mem.trim(u8, raw, " ");
        if (std.ascii.eqlIgnoreCase(part, "ctrl") or std.ascii.eqlIgnoreCase(part, "control")) {
            k.ctrl = true;
        } else if (std.ascii.eqlIgnoreCase(part, "shift")) {
            k.shift = true;
        } else if (std.ascii.eqlIgnoreCase(part, "alt")) {
            k.alt = true;
        } else if (std.ascii.eqlIgnoreCase(part, "super") or std.ascii.eqlIgnoreCase(part, "win") or std.ascii.eqlIgnoreCase(part, "meta") or std.ascii.eqlIgnoreCase(part, "cmd")) {
            k.super = true;
        } else if (k.key == 0) {
            k.key = keyCode(part) orelse return null;
        } else return null;
    }
    if (k.key == 0) return null;
    return k;
}

/// A combinação serve de atalho? Qualquer tecla vale — quem captura aceita a
/// tecla que a pessoa apertou. O cuidado fica por conta de quem usa: digitando
/// numa caixa de texto, atalhos sem Ctrl/Alt/Super não disparam (dispatch),
/// e teclas soltas não vão para as teclas globais (syncGlobal), porque elas
/// seriam tomadas de todo o sistema.
pub fn valid(k: Combo) bool {
    return k.key != 0;
}

/// O nome da tecla no atalho salvo: "m", "44", "f2", "enter", ",".
fn keySpec(k: c_int, buf: []u8) []const u8 {
    if (k >= c.ImGuiKey_A and k <= c.ImGuiKey_Z) {
        buf[0] = 'a' + @as(u8, @intCast(k - c.ImGuiKey_A));
        return buf[0..1];
    }
    if (k >= c.ImGuiKey_0 and k <= c.ImGuiKey_9) {
        buf[0] = '0' + @as(u8, @intCast(k - c.ImGuiKey_0));
        return buf[0..1];
    }
    if (isFkey(k)) return std.fmt.bufPrint(buf, "f{d}", .{k - c.ImGuiKey_F1 + 1}) catch "";
    for (named_keys) |x| if (x.k == k) {
        if (x.n.len > buf.len) return "";
        @memcpy(buf[0..x.n.len], x.n);
        return buf[0..x.n.len];
    };
    return "";
}

/// O nome da tecla para mostrar: "M", "F2", "Enter", ",".
fn keyLabel(k: c_int, buf: []u8) []const u8 {
    if (k >= c.ImGuiKey_A and k <= c.ImGuiKey_Z) {
        buf[0] = 'A' + @as(u8, @intCast(k - c.ImGuiKey_A));
        return buf[0..1];
    }
    if (k >= c.ImGuiKey_0 and k <= c.ImGuiKey_9) {
        buf[0] = '0' + @as(u8, @intCast(k - c.ImGuiKey_0));
        return buf[0..1];
    }
    if (isFkey(k)) return std.fmt.bufPrint(buf, "F{d}", .{k - c.ImGuiKey_F1 + 1}) catch "";
    for (named_keys) |x| if (x.k == k) {
        if (x.n.len == 1) {
            buf[0] = x.n[0];
            return buf[0..1];
        }
        if (x.n.len > buf.len) return "";
        buf[0] = std.ascii.toUpper(x.n[0]);
        @memcpy(buf[1..x.n.len], x.n[1..]);
        return buf[0..x.n.len];
    };
    return "";
}

fn join(k: Combo, buf: []u8, comptime tags: []const []const u8, keyFn: *const fn (c_int, []u8) []const u8) []const u8 {
    var n: usize = 0;
    const on = [_]bool{ k.ctrl, k.shift, k.alt, k.super };
    inline for (tags, 0..) |tag, i| {
        if (on[i]) {
            if (n + tag.len > buf.len) return "";
            @memcpy(buf[n..][0..tag.len], tag);
            n += tag.len;
        }
    }
    const kn = keyFn(k.key, buf[n..]);
    n += kn.len;
    return buf[0..n];
}

/// Como a combinação fica no arquivo de configurações: "ctrl+shift+m".
pub fn serialize(k: Combo, buf: []u8) []const u8 {
    return join(k, buf, &.{ "ctrl+", "shift+", "alt+", "super+" }, &keySpec);
}

/// Como a combinação aparece na tela: "Ctrl+Shift+M".
pub fn format(k: Combo, buf: []u8) []const u8 {
    return join(k, buf, &.{ "Ctrl+", "Shift+", "Alt+", "Super+" }, &keyLabel);
}

/// Todas as teclas que a captura da página de atalhos aceita: letras,
/// números, F1–F24 e as nomeadas. Modificadores sozinhos não contam.
pub fn captureCandidates() []const c_int {
    const S = struct {
        const arr = blk: {
            const total = 26 + 10 + 24 + named_keys.len;
            var out: [total]c_int = undefined;
            var n: usize = 0;
            for (0..26) |i| {
                out[n] = c.ImGuiKey_A + @as(c_int, @intCast(i));
                n += 1;
            }
            for (0..10) |i| {
                out[n] = c.ImGuiKey_0 + @as(c_int, @intCast(i));
                n += 1;
            }
            for (0..24) |i| {
                out[n] = c.ImGuiKey_F1 + @as(c_int, @intCast(i));
                n += 1;
            }
            for (named_keys) |x| {
                out[n] = x.k;
                n += 1;
            }
            break :blk out[0..n].*;
        };
    };
    return &S.arr;
}

test "texto e combinação vão e voltam" {
    const t = std.testing;
    const cases = [_][]const u8{ "ctrl+shift+m", "ctrl+k", "f2", "f11", "ctrl+,", "ctrl+w", "alt+1", "shift+f2", "ctrl+tab", "super+7", "ctrl+enter" };
    for (cases) |spec| {
        const k = parse(spec) orelse return error.TestUnexpectedResult;
        try t.expect(valid(k));
        var buf: [48]u8 = undefined;
        try t.expectEqualStrings(spec, serialize(k, &buf));
        var fb: [48]u8 = undefined;
        try t.expect(format(k, &fb).len > 0);
    }
}

test "rótulo bonito das teclas" {
    var buf: [48]u8 = undefined;
    try std.testing.expectEqualStrings("Ctrl+Shift+M", format(parse("ctrl+shift+m").?, &buf));
    var b2: [48]u8 = undefined;
    try std.testing.expectEqualStrings("F2", format(parse("f2").?, &b2));
    var b3: [48]u8 = undefined;
    try std.testing.expectEqualStrings("Ctrl+,", format(parse("ctrl+,").?, &b3));
}

test "o que pode virar atalho" {
    // Qualquer tecla vale: letra solta, com Shift, nomeada, F…
    try std.testing.expect(valid(parse("m").?));
    try std.testing.expect(valid(parse("shift+5").?));
    try std.testing.expect(valid(parse("enter").?));
    try std.testing.expect(valid(parse("-").?));
    try std.testing.expect(valid(parse("ctrl+v").?));
    try std.testing.expect(valid(parse("ctrl+shift+v").?));
    try std.testing.expect(valid(parse("f9").?));
    // Tecla desconhecida e só modificadores não.
    try std.testing.expect(parse("tecla") == null);
    try std.testing.expect(parse("ctrl+shift") == null);
    try std.testing.expect(parse("") == null);
    // Maiúsculas e "win" também valem.
    const k = parse("Win+7").?;
    try std.testing.expect(k.super and k.key == c.ImGuiKey_0 + 7);
}

test "mesma combinação dos dois lados" {
    const a = parse("ctrl+shift+d").?;
    const b = parse("CTRL+SHIFT+D").?;
    try std.testing.expect(Combo.same(a, b));
    try std.testing.expect(!Combo.same(a, parse("ctrl+shift+e").?));
}

test "a lista de captura cobre tudo que o texto entende" {
    var buf: [48]u8 = undefined;
    for (captureCandidates()) |code| {
        var k: Combo = .{ .key = code, .ctrl = true };
        const spec = serialize(k, &buf);
        const back = parse(spec) orelse return error.TestUnexpectedResult;
        try std.testing.expect(back.key == code);
        k.ctrl = false;
        // Sem modificador também é atalho válido hoje; só modificadores
        // sozinhos é que não (e eles nem estão na lista).
        try std.testing.expect(valid(parse(serialize(k, &buf)).?));
    }
}
