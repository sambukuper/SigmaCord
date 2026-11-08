//! Um tema carregado de um arquivo KDL: paleta, tokens de cor, fontes,
//! estilos nomeados e a árvore de layout. Ver `themes/README.md`.
const std = @import("std");
const kdl = @import("kdl.zig");
const color = @import("color.zig");
pub const fx = @import("fx.zig");
pub const Rgba = color.Rgba;

pub const Token = enum {
    bg,
    rail,
    sidebar,
    surface,
    elevated,
    overlay,
    text,
    muted,
    faint,
    accent,
    accent_text,
    border,
    hover,
    selected,
    online,
    idle,
    dnd,
    danger,
    mention,
    link,
    code_bg,
    bubble_self,
    bubble_self_text,
    bubble_other,
    shadow,
};

pub const Style = struct {
    bg: ?Rgba = null,
    radius: f32 = 0,
    border: ?Rgba = null,
    border_width: f32 = 1,
    /// Tamanho da sombra (0 = sem sombra).
    shadow: f32 = 0,
    /// Cor da borda quando o mouse está em cima (efeito de "foco").
    glow: ?Rgba = null,
    /// Reflexo de vidro no topo (degradê claro + linha de luz).
    sheen: bool = false,
    /// Primitivas novas (gradiente, grão, borda por lado…); null = estilo simples.
    box: ?*const fx.Box = null,
};

pub const Mode = enum { dark, light };

/// Opção que o tema oferece nas Configurações (liga/desliga).
pub const Option = struct {
    name: []const u8,
    label: []const u8,
    description: []const u8 = "",
    /// Versões em inglês (`label-en=`, `description-en=`); vazias = usa as de cima.
    label_en: []const u8 = "",
    description_en: []const u8 = "",
    default: bool = true,
};

pub const LoadOptions = struct {
    wal: ?*const [16]Rgba = null,
    mode: Mode = .dark,
    /// Valores escolhidos pelo usuário para as opções do tema.
    overrides: ?*const std.StringHashMapUnmanaged(bool) = null,
};

/// Cor sobrescrita num pedaço do layout (`c-text="#fff"` num nó).
pub const Override = struct { tok: Token, color: Rgba };

pub const Theme = struct {
    arena: std.heap.ArenaAllocator,
    name: []const u8 = "sem nome",
    description: []const u8 = "",
    description_en: []const u8 = "",
    author: []const u8 = "",
    /// Tipo de miniatura nas configurações (classic, glass, terminal, bubbles, zen).
    preview: []const u8 = "classic",
    colors: std.EnumArray(Token, Rgba),
    roles: [8]Rgba,
    font_ui: [:0]const u8 = "Inter",
    font_mono: [:0]const u8 = "JetBrains Mono",
    font_size: f32 = 16,
    radius: f32 = 6,
    /// Fundo da janela tem transparência (o compositor pode aplicar blur).
    transparent: bool = false,
    styles: std.StringHashMapUnmanaged(Style) = .empty,
    layout: ?*const kdl.Node = null,
    /// O layout tem o painel com o botão de configurações? Sem ele, o cabeçalho põe um.
    has_user_panel: bool = true,
    /// Sobrescritas efetivas de cada nó (já incluindo as dos pais).
    node_colors: std.AutoHashMapUnmanaged(*const kdl.Node, []const Override) = .empty,
    /// Primitivas novas dos nós que usam alguma (`fx.zig`). Vazio na maioria.
    node_fx: std.AutoHashMapUnmanaged(*const kdl.Node, *const fx.NodeFx) = .empty,
    mode: Mode = .dark,
    /// Faixa de título do app (a barra do sistema saiu): altura 0 = o tema
    /// não quer faixa e marca o próprio topo com caption=#true no layout.
    titlebar_h: f32 = 32,
    titlebar_text: []const u8 = "SigmaCord",
    /// Cor de fundo da faixa: um token da paleta (o rail de cada tema).
    titlebar_bg: ?Token = null,
    options: []const Option = &.{},
    option_values: std.StringHashMapUnmanaged(bool) = .empty,

    /// Valor de uma opção do tema (`$nome` nas propriedades, `when="nome"`).
    pub fn option(t: *const Theme, name: []const u8) ?bool {
        return t.option_values.get(name);
    }

    pub fn deinit(t: *Theme) void {
        t.arena.deinit();
    }

    pub fn c(t: *const Theme, tok: Token) Rgba {
        return t.colors.get(tok);
    }

    pub fn style(t: *const Theme, name: ?[]const u8) ?Style {
        const n = name orelse return null;
        return t.styles.get(n);
    }

    pub fn role(t: *const Theme, i: u8) Rgba {
        return t.roles[i % t.roles.len];
    }

    /// Valores atuais dos tokens, na ordem que as expressões guardadas usam.
    pub fn tokenValues(t: *const Theme) []const Rgba {
        return &t.colors.values;
    }

    pub fn nodeFx(t: *const Theme, n: *const kdl.Node) ?*const fx.NodeFx {
        if (t.node_fx.count() == 0) return null;
        return t.node_fx.get(n);
    }
};

/// Texto secundário legível em qualquer tema, inclusive os de outras pessoas: o traço fino das
/// letras pequenas já perde contraste, e abaixo disto ele some no fundo. Sobe em direção à cor
/// do texto só o quanto precisa, então a hierarquia texto > muted > faint continua.
fn hasNode(n: *const kdl.Node, name: []const u8) bool {
    if (std.mem.eql(u8, n.name, name)) return true;
    for (n.children) |*ch| if (hasNode(ch, name)) return true;
    return false;
}

fn legibleText(t: *Theme) void {
    const wanted = [_]struct { tok: Token, min: f32 }{ .{ .tok = .muted, .min = 5.5 }, .{ .tok = .faint, .min = 4.5 } };
    const backs = [_]Token{ .bg, .surface, .sidebar, .elevated };
    const text = t.colors.get(.text);
    for (wanted) |w| {
        const base = t.colors.get(w.tok);
        var k: f32 = 0;
        while (k <= 1) : (k += 0.05) {
            const col = base.mix(text, k);
            for (backs) |b| {
                if (col.contrast(t.colors.get(b)) < w.min) break;
            } else {
                t.colors.set(w.tok, col);
                break;
            }
        } else t.colors.set(w.tok, text);
    }
}

pub const fallback_palette = [16]u32{
    0x15161b, 0xe06c75, 0x98c379, 0xe5c07b, 0x7aa2f7, 0xc678dd, 0x56b6c2, 0xd7dae0,
    0x5c6370, 0xe06c75, 0x98c379, 0xe5c07b, 0x7aa2f7, 0xc678dd, 0x56b6c2, 0xf0f2f5,
};

pub const LoadError = error{ SyntaxError, OutOfMemory, InvalidTheme };

pub const Diagnostic = struct {
    line: u32 = 0,
    column: u32 = 0,
    message: []const u8 = "",
};

/// Carrega um tema. `wal` é a paleta do pywal (se houver); o tema decide se
/// usa (`palette "wal"`) ou define a própria.
pub fn load(gpa: std.mem.Allocator, src: []const u8, wal: ?*const [16]Rgba, diag: ?*Diagnostic) LoadError!Theme {
    return loadWith(gpa, src, .{ .wal = wal }, diag);
}

/// Nó vale para o modo atual? (`colors mode=light { … }` só no claro.)
fn forMode(n: *const kdl.Node, mode: Mode) bool {
    const m = n.str("mode") orelse return true;
    return std.mem.eql(u8, m, @tagName(mode));
}

/// Nó de topo vale agora? Respeita `mode=` e `when=`/`unless=` (opções).
fn applies(t: *const Theme, n: *const kdl.Node, mode: Mode) bool {
    if (!forMode(n, mode)) return false;
    if (n.str("when")) |o| if (!(t.option(o) orelse false)) return false;
    if (n.str("unless")) |o| if (t.option(o) orelse false) return false;
    return true;
}

/// Propriedade booleana que pode apontar para uma opção: `sheen="$brilho"`.
fn flagOrOption(t: *const Theme, n: *const kdl.Node, key: []const u8) ?bool {
    const v = n.prop(key) orelse return null;
    if (v.asString()) |s| if (s.len > 1 and s[0] == '$') {
        if (s[1] == '!') return if (t.option(s[2..])) |o| !o else null;
        return t.option(s[1..]);
    };
    return v.asBool();
}

pub fn loadWith(gpa: std.mem.Allocator, src: []const u8, lo: LoadOptions, diag: ?*Diagnostic) LoadError!Theme {
    const wal = lo.wal;
    var t: Theme = .{
        .mode = lo.mode,
        .arena = std.heap.ArenaAllocator.init(gpa),
        .colors = undefined,
        .roles = undefined,
    };
    errdefer t.arena.deinit();
    const a = t.arena.allocator();

    // Os nós do KDL apontam para o texto: guarda uma cópia junto do tema.
    const owned_src = try a.dupe(u8, src);
    var kd: kdl.Diagnostic = .{};
    const nodes = kdl.parse(a, owned_src, &kd) catch |err| {
        if (diag) |d| d.* = .{ .line = kd.line, .column = kd.column, .message = kd.message };
        return err;
    };

    // Paleta: do pywal, do próprio tema ou a padrão.
    var pal: [16]Rgba = undefined;
    for (fallback_palette, 0..) |v, i| pal[i] = Rgba.hex(v);
    // Opções do tema (vêm antes porque estilos podem depender delas).
    var opts: std.ArrayList(Option) = .empty;
    for (nodes) |*n| {
        if (!std.mem.eql(u8, n.name, "options")) continue;
        for (n.children) |*ch| {
            const oname = (ch.arg(0) orelse return fail(diag, ch, "opção sem nome")).asString() orelse return fail(diag, ch, "nome da opção deve ser string");
            const o: Option = .{
                .name = oname,
                .label = ch.str("label") orelse oname,
                .description = ch.str("description") orelse "",
                .label_en = ch.str("label-en") orelse "",
                .description_en = ch.str("description-en") orelse "",
                .default = ch.flag("default") orelse true,
            };
            try opts.append(a, o);
            const value = if (lo.overrides) |ov| ov.get(oname) orelse o.default else o.default;
            try t.option_values.put(a, oname, value);
        }
    }
    t.options = try opts.toOwnedSlice(a);
    // O modo também vale como condição: `when=modo-claro`, `motion="$modo-escuro"`.
    try t.option_values.put(a, "modo-claro", lo.mode == .light);
    try t.option_values.put(a, "modo-escuro", lo.mode == .dark);

    for (nodes) |*n| {
        if (!std.mem.eql(u8, n.name, "palette") or !applies(&t, n, lo.mode)) continue;
        if (n.arg(0)) |v| if (v.asString()) |s| if (std.mem.eql(u8, s, "wal")) {
            if (wal) |w| pal = w.*;
            continue;
        };
        for (n.args, 0..) |v, i| {
            if (i >= 16) break;
            const s = v.asString() orelse continue;
            pal[i] = color.parseHex(std.mem.trimStart(u8, s, "#")) catch return fail(diag, n, "cor inválida na paleta");
        }
    }

    t.colors = defaults(&pal, lo.mode);
    t.roles = .{ pal[4], pal[1], pal[3], pal[5], pal[6], pal[12], pal[9], pal[13] };
    // No claro, cores de cargo mais escuras para ler bem sobre o branco.
    if (lo.mode == .light) for (&t.roles) |*r| {
        if (r.luma() > 0.45) r.* = r.mix(Rgba.black, 0.35);
    };

    const Look = struct {
        fn f(ctx: *const anyopaque, name: []const u8) ?Rgba {
            const th: *const Theme = @ptrCast(@alignCast(ctx));
            const tok = tokenFromName(name) orelse return null;
            return th.colors.get(tok);
        }
    };
    const resolver: color.Resolver = .{ .palette = &pal, .ctx = &t, .lookup = Look.f };
    var fcx: fx.Cx = .{ .a = a, .palette = &pal, .tokens = tokenIndex };

    for (nodes) |*n| {
        if (!applies(&t, n, lo.mode)) continue;
        if (std.mem.eql(u8, n.name, "theme")) {
            if (n.arg(0)) |v| if (v.asString()) |s| {
                t.name = s;
            };
            t.description = n.str("description") orelse t.description;
            t.description_en = n.str("description-en") orelse t.description_en;
            t.author = n.str("author") orelse t.author;
            t.preview = n.str("preview") orelse t.preview;
        } else if (std.mem.eql(u8, n.name, "colors")) {
            for (n.children) |*ch| {
                const tok = tokenFromName(ch.name) orelse return fail(diag, ch, "token de cor desconhecido");
                const expr = (ch.arg(0) orelse return fail(diag, ch, "faltou a cor")).asString() orelse return fail(diag, ch, "a cor deve ser uma string");
                t.colors.set(tok, color.eval(expr, resolver) catch return fail(diag, ch, "expressão de cor inválida"));
            }
        } else if (std.mem.eql(u8, n.name, "roles")) {
            for (n.args, 0..) |v, i| {
                if (i >= t.roles.len) break;
                const s = v.asString() orelse continue;
                t.roles[i] = color.eval(s, resolver) catch return fail(diag, n, "cor de cargo inválida");
            }
        } else if (std.mem.eql(u8, n.name, "fonts")) {
            if (n.str("ui")) |s| t.font_ui = try a.dupeSentinel(u8, s, 0);
            if (n.str("mono")) |s| t.font_mono = try a.dupeSentinel(u8, s, 0);
            if (n.num("size")) |v| t.font_size = @floatCast(std.math.clamp(v, 6, 72));
        } else if (std.mem.eql(u8, n.name, "metrics")) {
            if (n.num("radius")) |v| t.radius = @floatCast(std.math.clamp(v, 0, 64));
        } else if (std.mem.eql(u8, n.name, "window")) {
            if (n.flag("transparent")) |v| t.transparent = v;
        } else if (std.mem.eql(u8, n.name, "titlebar")) {
            if (n.num("height")) |v| t.titlebar_h = @floatCast(std.math.clamp(v, 0, 120));
            if (n.str("text")) |s2| t.titlebar_text = try a.dupe(u8, s2);
            if (n.str("bg")) |tok| t.titlebar_bg = tokenFromName(tok);
        } else if (std.mem.eql(u8, n.name, "styles")) {
            for (n.children) |*ch| {
                const sname = (ch.arg(0) orelse return fail(diag, ch, "estilo sem nome")).asString() orelse return fail(diag, ch, "nome do estilo deve ser string");
                var st: Style = .{};
                if (ch.str("bg")) |e| st.bg = color.eval(e, resolver) catch return fail(diag, ch, "bg inválido");
                if (ch.str("border")) |e| st.border = color.eval(e, resolver) catch return fail(diag, ch, "border inválido");
                if (ch.str("glow")) |e| st.glow = color.eval(e, resolver) catch return fail(diag, ch, "glow inválido");
                if (ch.num("radius")) |v| st.radius = @floatCast(v);
                if (ch.num("border-width")) |v| st.border_width = @floatCast(v);
                if (ch.num("shadow")) |v| st.shadow = @floatCast(v);
                st.sheen = flagOrOption(&t, ch, "sheen") orelse false;
                st.box = fx.parseBox(&fcx, ch, true) catch |err| return fxFail(err, fcx, diag);
                try t.styles.put(a, sname, st);
            }
        } else if (std.mem.eql(u8, n.name, "layout")) {
            t.layout = n;
        }
    }
    legibleText(&t);
    t.has_user_panel = if (t.layout) |root| hasNode(root, "user-panel") else true;
    if (t.layout == null) return fail(diag, null, "o tema precisa de um nó `layout`");
    try collectOverrides(&t, a, t.layout.?, &.{}, resolver, lo.mode, diag);
    collectFx(&t, a, t.layout.?, &fcx) catch |err| return fxFail(err, fcx, diag);
    t.transparent = t.transparent or t.colors.get(.bg).a < 0.999;
    return t;
}

/// Percorre o layout juntando `c-<token>=cor`, que valem para o nó e seus filhos.
/// `cl-…` vale só no modo claro e `cd-…` só no escuro.
fn collectOverrides(t: *Theme, a: std.mem.Allocator, n: *const kdl.Node, inherited: []const Override, r: color.Resolver, mode: Mode, diag: ?*Diagnostic) LoadError!void {
    var list: std.ArrayList(Override) = .empty;
    try list.appendSlice(a, inherited);
    for (n.props) |p| {
        const name = if (std.mem.startsWith(u8, p.key, "c-"))
            p.key[2..]
        else if (std.mem.startsWith(u8, p.key, "cl-") and mode == .light)
            p.key[3..]
        else if (std.mem.startsWith(u8, p.key, "cd-") and mode == .dark)
            p.key[3..]
        else
            continue;
        const tok = tokenFromName(name) orelse return fail(diag, n, "token de cor desconhecido em c-…");
        const expr = p.value.asString() orelse return fail(diag, n, "a cor deve ser uma string");
        const col = color.eval(expr, r) catch return fail(diag, n, "expressão de cor inválida");
        try list.append(a, .{ .tok = tok, .color = col });
    }
    const effective = try list.toOwnedSlice(a);
    if (effective.len > 0) try t.node_colors.put(a, n, effective);
    for (n.children) |*ch| try collectOverrides(t, a, ch, effective, r, mode, diag);
}

/// Primitivas novas de cada nó do layout (`gradient=`, `label … tracking=`, …).
fn collectFx(t: *Theme, a: std.mem.Allocator, n: *const kdl.Node, cx: *fx.Cx) fx.Error!void {
    for (n.children) |*ch| {
        const bg_is_token = if (ch.str("bg")) |s| tokenFromName(s) != null else true;
        if (try fx.parseNode(cx, ch, bg_is_token)) |x| try t.node_fx.put(a, ch, x);
        // Os `span` são parte do `label`, não nós do layout.
        if (!std.mem.eql(u8, ch.name, "label")) try collectFx(t, a, ch, cx);
    }
}

fn fxFail(err: fx.Error, cx: fx.Cx, diag: ?*Diagnostic) LoadError {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    const p = cx.problem orelse return error.InvalidTheme;
    return fail(diag, p.node, p.message);
}

fn tokenIndex(name: []const u8) ?u8 {
    const tok = tokenFromName(name) orelse return null;
    return @intCast(@intFromEnum(tok));
}

fn fail(diag: ?*Diagnostic, n: ?*const kdl.Node, msg: []const u8) LoadError {
    if (diag) |d| d.* = .{ .line = if (n) |x| x.line else 0, .message = msg };
    return error.InvalidTheme;
}

pub fn tokenFromName(name: []const u8) ?Token {
    var buf: [32]u8 = undefined;
    if (name.len > buf.len) return null;
    for (name, 0..) |ch, i| buf[i] = if (ch == '-') '_' else ch;
    return std.meta.stringToEnum(Token, buf[0..name.len]);
}

/// Tokens derivados da paleta; o tema sobrescreve o que quiser.
fn defaults(pal: *const [16]Rgba, mode: Mode) std.EnumArray(Token, Rgba) {
    if (mode == .light) return lightDefaults(pal);
    const bg = pal[0];
    const fg = pal[15];
    const black = Rgba.black;
    var e = std.EnumArray(Token, Rgba).initUndefined();
    e.set(.bg, bg.mix(fg, 0.035));
    e.set(.rail, bg.mix(black, 0.38));
    e.set(.sidebar, bg.mix(black, 0.18));
    e.set(.surface, bg.mix(fg, 0.035));
    e.set(.elevated, bg.mix(fg, 0.085));
    e.set(.overlay, bg.mix(black, 0.55));
    e.set(.text, fg);
    e.set(.muted, fg.mix(bg, 0.42));
    e.set(.faint, fg.mix(bg, 0.62));
    e.set(.accent, pal[4]);
    e.set(.accent_text, if (pal[4].luma() > 0.6) black else Rgba.white);
    e.set(.border, fg.alpha(0.08));
    e.set(.hover, fg.alpha(0.05));
    e.set(.selected, fg.alpha(0.10));
    e.set(.online, Rgba.hex(0x45b36b));
    e.set(.idle, Rgba.hex(0xe5a83b));
    e.set(.dnd, Rgba.hex(0xe5484d));
    e.set(.danger, Rgba.hex(0xe5484d));
    e.set(.mention, pal[4]);
    e.set(.link, pal[4].mix(fg, 0.25));
    e.set(.code_bg, bg.mix(black, 0.45));
    e.set(.bubble_self, pal[4]);
    e.set(.bubble_self_text, if (pal[4].luma() > 0.6) black else Rgba.white);
    e.set(.bubble_other, bg.mix(fg, 0.1));
    e.set(.shadow, black.alpha(0.35));
    return e;
}

/// Modo claro derivado da mesma paleta: papel quase branco com um toque da
/// cor de fundo, tinta escura e destaque escurecido para ter contraste.
fn lightDefaults(pal: *const [16]Rgba) std.EnumArray(Token, Rgba) {
    const white = Rgba.white;
    const black = Rgba.black;
    const tint = pal[0];
    const bg = white.mix(tint, 0.035);
    const ink = tint.mix(black, 0.55).mix(pal[15], 0.05);
    const accent = if (pal[4].luma() > 0.5) pal[4].mix(black, 0.3) else pal[4];
    var e = std.EnumArray(Token, Rgba).initUndefined();
    e.set(.bg, bg);
    e.set(.rail, white.mix(tint, 0.12));
    e.set(.sidebar, white.mix(tint, 0.07));
    e.set(.surface, bg);
    e.set(.elevated, white.mix(tint, 0.09));
    e.set(.overlay, white);
    e.set(.text, ink);
    e.set(.muted, ink.mix(bg, 0.4));
    e.set(.faint, ink.mix(bg, 0.6));
    e.set(.accent, accent);
    e.set(.accent_text, if (accent.luma() > 0.6) black else white);
    e.set(.border, ink.alpha(0.1));
    e.set(.hover, ink.alpha(0.05));
    e.set(.selected, accent.alpha(0.13));
    e.set(.online, Rgba.hex(0x23a55a));
    e.set(.idle, Rgba.hex(0xd08a12));
    e.set(.dnd, Rgba.hex(0xd83a42));
    e.set(.danger, Rgba.hex(0xd83a42));
    e.set(.mention, accent);
    e.set(.link, accent.mix(black, 0.1));
    e.set(.code_bg, bg.mix(ink, 0.07));
    e.set(.bubble_self, accent);
    e.set(.bubble_self_text, if (accent.luma() > 0.6) black else white);
    e.set(.bubble_other, white.mix(tint, 0.1));
    e.set(.shadow, black.alpha(0.12));
    return e;
}

test "modo claro, opções e cores por modo" {
    const src =
        \\options { option "brilho" label="Brilho" default=#false }
        \\colors { accent "#ff0000" }
        \\colors mode=light { accent "#00ff00" }
        \\styles { style "card" sheen="$brilho" }
        \\layout { column cl-text="#0000ff" { messages } }
    ;
    var dark = try loadWith(std.testing.allocator, src, .{ .mode = .dark }, null);
    defer dark.deinit();
    try std.testing.expectEqual(@as(f32, 1), dark.c(.accent).r);
    try std.testing.expect(!dark.style("card").?.sheen);
    try std.testing.expect(dark.node_colors.count() == 0);

    var ov: std.StringHashMapUnmanaged(bool) = .empty;
    defer ov.deinit(std.testing.allocator);
    try ov.put(std.testing.allocator, "brilho", true);
    var light = try loadWith(std.testing.allocator, src, .{ .mode = .light, .overrides = &ov }, null);
    defer light.deinit();
    try std.testing.expectEqual(@as(f32, 1), light.c(.accent).g);
    try std.testing.expect(light.style("card").?.sheen);
    try std.testing.expect(light.option("brilho").?);
    try std.testing.expect(light.c(.bg).luma() > 0.9);
}

test "carrega tema com tokens, estilos e layout" {
    const src =
        \\theme "teste" description="só um teste"
        \\palette "#000000" "#ff0000"
        \\colors {
        \\    accent "wal:1"
        \\    surface "mix(@accent, black, 0.5)"
        \\}
        \\fonts ui="JetBrains Mono" size=14
        \\styles { style "card" bg="@surface" radius=12 glow="@accent" }
        \\layout { row { messages } }
    ;
    var t = try load(std.testing.allocator, src, null, null);
    defer t.deinit();
    try std.testing.expectEqualStrings("teste", t.name);
    try std.testing.expectEqual(@as(f32, 1), t.c(.accent).r);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), t.c(.surface).r, 0.01);
    try std.testing.expectEqual(@as(f32, 12), t.style("card").?.radius);
    try std.testing.expectEqualStrings("JetBrains Mono", t.font_ui);
    try std.testing.expect(t.layout != null);
}

test "erro de tema aponta a linha" {
    var d: Diagnostic = .{};
    try std.testing.expectError(error.InvalidTheme, load(std.testing.allocator, "colors {\n  nao-existe \"#fff\"\n}\nlayout { messages }", null, &d));
    try std.testing.expectEqual(@as(u32, 2), d.line);
}

test "cores sobrescritas valem para os filhos" {
    var t = try load(std.testing.allocator,
        \\layout { column c-text="#ff0000" { messages; row c-muted="#00ff00" { composer } } }
    , null, null);
    defer t.deinit();
    const col = &t.layout.?.children[0];
    const msgs = &col.children[0];
    const comp = &col.children[1].children[0];
    try std.testing.expectEqual(@as(usize, 1), t.node_colors.get(msgs).?.len);
    try std.testing.expectEqual(@as(usize, 2), t.node_colors.get(comp).?.len);
}

test "primitivas novas: estilo, nó e erro com a linha" {
    var t = try load(std.testing.allocator,
        \\styles {
        \\    style "simples" bg="@surface" radius=4
        \\    style "rico" bg="@surface" gradient="@surface @elevated" grain="alpha(@text, 0.05)" hover-bg="@hover"
        \\}
        \\layout {
        \\    stack {
        \\        starfield color=faint color2="alpha(@accent, 0.5)"
        \\        column grain="alpha(@text, 0.04)" {
        \\            label text="a" tracking=3
        \\            label text="b"
        \\            row height=1 bg="alpha(@accent, 0.4)"
        \\            row height=2 bg=sidebar
        \\        }
        \\    }
        \\}
    , null, null);
    defer t.deinit();
    try std.testing.expect(t.style("simples").?.box == null);
    try std.testing.expect(t.style("rico").?.box.?.gradient != null);
    const stack = &t.layout.?.children[0];
    try std.testing.expect(t.nodeFx(&stack.children[0]).?.color("color2") != null);
    const col = &stack.children[1];
    try std.testing.expect(t.nodeFx(col).?.box.?.grain != null);
    try std.testing.expect(t.nodeFx(&col.children[0]).?.text != null);
    try std.testing.expect(t.nodeFx(&col.children[1]) == null);
    try std.testing.expect(t.nodeFx(&col.children[2]).?.bg != null);
    try std.testing.expect(t.nodeFx(&col.children[3]) == null);
    // A expressão acompanha os tokens do momento (cor escolhida, `c-…`).
    const e = t.style("rico").?.box.?.gradient.?.stops[0];
    t.colors.set(.surface, Rgba.hex(0x102030));
    try std.testing.expectApproxEqAbs(@as(f32, 0x20) / 255.0, e.eval(t.tokenValues()).g, 0.001);

    var d: Diagnostic = .{};
    try std.testing.expectError(error.InvalidTheme, load(std.testing.allocator, "layout {\n  row {\n    label tracking=2 color=\"@nada\"\n  }\n}", null, &d));
    try std.testing.expectEqual(@as(u32, 3), d.line);
}

test "modo vale como condição" {
    var t = try loadWith(std.testing.allocator, "layout { messages }", .{ .mode = .light }, null);
    defer t.deinit();
    try std.testing.expect(t.option("modo-claro").?);
    try std.testing.expect(!t.option("modo-escuro").?);
    try std.testing.expectEqual(@as(usize, 0), t.options.len);
}
