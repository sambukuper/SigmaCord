//! Componentes "de assinatura" dos temas.
//!
//! logo:   variant = ascii | wordmark      (logo do app)
//! topbar: barra superior com voltar/avançar entre abas, busca e ajuda
//! crt:    efeito de monitor antigo (linhas de varredura + vinheta), por cima de tudo
//! shape:  círculo, anel, arco, retângulo arredondado ou linha
//! rule:   régua (lisa, tracejada, pontilhada, dupla, "oxford") com ornamento
//! window-controls: fechar, minimizar e maximizar a janela, em três bolinhas
const std = @import("std");
const c = @import("c");
const kdl = @import("../theme/kdl.zig");
const d = @import("draw.zig");
const anim = @import("anim.zig");
const icons = @import("icons.zig");
const i18n = @import("i18n.zig");
const fx = @import("fx.zig");
const qa = @import("qa.zig");
const procgen = @import("procgen.zig");

const ascii_logo = [_][]const u8{
    "┬  ┌─┐┬─┐┌─┐┌─┐┬─┐┌─┐┌─┐┬─┐┌┬┐",
    "│  ├─┤├┬┘├─┘├┤ ├┬┘│  │ │├┬┘ ││",
    "┴─┘┴ ┴┴└─┴  └─┘┴└─└─┘└─┘┴└──┴┘",
};

pub fn logo(ctx: *d.Ctx, n: *const kdl.Node, r: d.Rect) void {
    const dl = ctx.dl;
    if (d.is(n, "variant", "ascii", "wordmark")) {
        const fam = ctx.mono;
        const fs = d.pnum(n, "size", 13);
        const lh = fs * 1.05;
        const w = d.width(fam.get(.regular), fs, ascii_logo[0]);
        const x = r.x + @max(8, (r.w - w) / 2);
        var y = r.y + (r.h - lh * 3) / 2 - 4;
        for (ascii_logo) |ln| {
            d.text(dl, fam.get(.regular), fs, x, y, ctx.col(.accent), ln);
            y += lh;
        }
        const sub = i18n.tr("cliente leve · zig", "lightweight client · zig");
        const sw = d.width(fam.get(.regular), fs - 2, sub);
        d.text(dl, fam.get(.regular), fs - 2, r.x + (r.w - sw) / 2, y + 2, ctx.col(.faint), sub);
        return;
    }
    // Wordmark: balão + nome.
    const fam = ctx.familyFor(n);
    const fs = d.pnum(n, "size", 17);
    const cy = r.y + r.h / 2;
    const bx = r.x + 16;
    d.rect(dl, .{ .x = bx, .y = cy - 9, .w = 22, .h = 16 }, ctx.col(.accent), 7);
    c.ImDrawList_AddTriangleFilled(dl, d.v(bx + 4, cy + 5), d.v(bx + 10, cy + 5), d.v(bx + 2, cy + 11), ctx.col(.accent).u());
    for ([_]f32{ -5, 0, 5 }) |dx| d.circle(dl, bx + 11 + dx, cy - 1, 1.8, ctx.col(.accent_text));
    d.text(dl, fam.get(.bold), fs, bx + 32, d.centerY(r, fs), ctx.col(.text), "SigmaCord");
}

pub fn topbar(ctx: *d.Ctx, n: *const kdl.Node, r: d.Rect) void {
    const dl = ctx.dl;
    const fam = ctx.familyFor(n);
    const st = ctx.st;
    // Voltar / avançar entre as abas abertas.
    const nav = [_]struct { glyph: []const u8, delta: i32, tip: []const u8, tip_en: []const u8 }{
        .{ .glyph = "←", .delta = -1, .tip = "Aba anterior  (Ctrl+Shift+Tab)", .tip_en = "Previous tab  (Ctrl+Shift+Tab)" },
        .{ .glyph = "→", .delta = 1, .tip = "Próxima aba  (Ctrl+Tab)", .tip_en = "Next tab  (Ctrl+Tab)" },
    };
    var x = r.x + 12;
    for (nav, 0..) |b, i| {
        const br: d.Rect = .{ .x = x, .y = r.y + r.h / 2 - 13, .w = 26, .h = 26 };
        const hb = d.hit(ctx, i, br);
        if (hb.clicked) ctx.act(.{ .next_tab = b.delta });
        if (hb.hovered) d.rect(dl, br, ctx.col(.hover), 5);
        const gw = d.width(fam.get(.bold), 16, b.glyph);
        d.text(dl, fam.get(.bold), 16, br.x + 13 - gw / 2, d.centerY(br, 16), if (hb.hovered) ctx.col(.text) else ctx.col(.muted), b.glyph);
        d.tip(ctx, br, i18n.tr(b.tip, b.tip_en), hb.hovered);
        x += 30;
    }
    // Busca no meio.
    const sw = @min(560, r.w * 0.5);
    const sr: d.Rect = .{ .x = r.x + (r.w - sw) / 2, .y = r.y + r.h / 2 - 14, .w = sw, .h = 28 };
    const sh = d.hit(ctx, 10, sr);
    qa.mark(sr, "header-find", .{});
    if (sh.clicked) @import("search.zig").focusOrStart();
    const k = anim.to(anim.id("topsearch", @intFromPtr(n)), if (sh.hovered) 1 else 0, 20);
    d.rect(dl, sr, ctx.col(.text).alpha(0.12 + 0.06 * k), 7);
    d.border(dl, sr, ctx.col(.text).alpha(0.15 + 0.15 * k), 7, 1);
    icons.search(dl, sr.x + 16, sr.y + 14, ctx.col(.muted).u());
    var buf: [96]u8 = undefined;
    const g = ctx.store.guild(st.guild);
    const label0 = if (g) |x_|
        i18n.fmt(&buf, "Buscar em {s}", "Search {s}", .{x_.name})
    else
        i18n.tr("Buscar em mensagens diretas", "Search Direct Messages");
    const label = if (label0.len == 0) i18n.tr("Buscar", "Search") else label0;
    _ = d.textClipped(dl, fam.get(.medium), 13, sr.x + 30, d.centerY(sr, 13), ctx.col(.muted), label, sr.w - 100);
    const kw = d.width(fam.get(.semibold), 11, "Ctrl F");
    d.text(dl, fam.get(.semibold), 11, sr.right() - kw - 12, d.centerY(sr, 11), ctx.col(.faint), "Ctrl F");
    // Ajuda (abre os atalhos).
    const hr: d.Rect = .{ .x = r.right() - 40, .y = r.y + r.h / 2 - 13, .w = 26, .h = 26 };
    const hh = d.hit(ctx, 11, hr);
    if (hh.clicked) {
        st.settings.page = .atalhos;
        ctx.act(.open_settings);
    }
    c.ImDrawList_AddCircleEx(dl, d.v(hr.x + 13, hr.y + 13), 9, (if (hh.hovered) ctx.col(.text) else ctx.col(.muted)).u(), 0, 1.6, 0);
    const qw = d.width(fam.get(.bold), 12, "?");
    d.text(dl, fam.get(.bold), 12, hr.x + 13 - qw / 2, d.centerY(hr, 12), if (hh.hovered) ctx.col(.text) else ctx.col(.muted), "?");
    d.tip(ctx, hr, i18n.tr("Atalhos de teclado", "Keybinds"), hh.hovered);
}

/// Linhas de varredura e cantos escurecidos, desenhados por cima de tudo.
pub fn crt(ctx: *d.Ctx, n: *const kdl.Node, r: d.Rect) void {
    const fg = ctx.fg;
    const gap = @max(d.pnum(n, "spacing", 3), 1);
    const strength = d.pnum(n, "strength", 0.08);
    var y = r.y;
    const lc = d.Rgba.black.alpha(strength);
    while (y < r.bottom()) : (y += gap) d.line(fg, r.x, y, r.right(), y, lc, 1);
    // Vinheta: as bordas mais escuras, como um tubo de imagem.
    const vw = @min(r.w, r.h) * 0.18;
    const edge = d.Rgba.black.col(0.32);
    c.ImDrawList_AddRectFilledMultiColor(fg, d.v(r.x, r.y), d.v(r.x + vw, r.bottom()), edge, 0, 0, edge);
    c.ImDrawList_AddRectFilledMultiColor(fg, d.v(r.right() - vw, r.y), d.v(r.right(), r.bottom()), 0, edge, edge, 0);
    c.ImDrawList_AddRectFilledMultiColor(fg, d.v(r.x, r.y), d.v(r.right(), r.y + vw), edge, edge, 0, 0);
    c.ImDrawList_AddRectFilledMultiColor(fg, d.v(r.x, r.bottom() - vw), d.v(r.right(), r.bottom()), 0, 0, edge, edge);
}

const ShapeKind = enum { circle, ring, arc, rounded, line };

/// `shape kind=ring color=accent thickness=1.5 size=16`
/// `shape kind=arc start=-90 sweep=270 dot="@text" dot-size=2.5`
/// `shape kind=rounded radius=6 fill="alpha(@accent, 0.1)" color=accent`
/// `shape kind=line angle=0 cap=#true`
pub fn shape(ctx: *d.Ctx, n: *const kdl.Node, r: d.Rect) void {
    const kind = std.meta.stringToEnum(ShapeKind, d.pstr(n, "kind", "circle")) orelse .circle;
    if (qa.on()) qa.mark(r, "shape:{s}", .{@tagName(kind)});
    const dl = ctx.dl;
    const col = fx.nodeColor(ctx, n, "color", .accent);
    const th = d.pnum(n, "thickness", 1.5);
    const size = d.pnum(n, "size", @min(r.w, r.h));
    // Onde ela fica dentro do retângulo do nó.
    const cx = (if (d.is(n, "align", "left", "center")) r.x + size / 2 else if (d.is(n, "align", "right", "center")) r.right() - size / 2 else r.x + r.w / 2) + d.pnum(n, "offset-x", 0);
    const cy = r.y + r.h / 2 + d.pnum(n, "offset-y", 0);
    const rad = @max(size / 2 - th / 2, 0.5);
    switch (kind) {
        .circle => c.ImDrawList_AddCircleFilled(dl, d.v(cx, cy), size / 2, col.u(), 0),
        .ring => {
            if (fx.nodeColorOpt(ctx, n, "fill")) |f| c.ImDrawList_AddCircleFilled(dl, d.v(cx, cy), rad, f.u(), 0);
            c.ImDrawList_AddCircleEx(dl, d.v(cx, cy), rad, col.u(), 0, th, 0);
        },
        .arc => {
            const a0 = std.math.degreesToRadians(d.pnum(n, "start", -90));
            const a1 = a0 + std.math.degreesToRadians(d.pnum(n, "sweep", 270));
            c.ImDrawList_PathClear(dl);
            c.ImDrawList_PathArcTo(dl, d.v(cx, cy), rad, a0, a1, 0);
            c.ImDrawList_PathStroke(dl, col.u(), th, 0);
            // Um ponto na ponta do arco: o satélite do anel.
            if (fx.nodeColorOpt(ctx, n, "dot")) |dc| d.circle(dl, cx + rad * @cos(a1), cy + rad * @sin(a1), d.pnum(n, "dot-size", th * 1.6), dc);
        },
        .rounded => {
            const w = @min(d.pnum(n, "size", r.w), r.w);
            const h = @min(d.pnum(n, "size", r.h), r.h);
            const box: d.Rect = .{ .x = cx - w / 2, .y = cy - h / 2, .w = w, .h = h };
            const radius = d.pnum(n, "radius", 6);
            if (fx.nodeColorOpt(ctx, n, "fill")) |f| d.rect(dl, box, f, radius);
            d.border(dl, box, col, radius, th);
        },
        .line => {
            const ang = std.math.degreesToRadians(d.pnum(n, "angle", 0));
            // Sem `size`, a linha vai de borda a borda do nó.
            const half = if (n.num("size") != null) size / 2 else @abs(r.w / 2 * @cos(ang)) + @abs(r.h / 2 * @sin(ang));
            d.line(dl, cx - half * @cos(ang), cy - half * @sin(ang), cx + half * @cos(ang), cy + half * @sin(ang), col, th);
        },
    }
}

const RuleKind = enum { solid, dashed, dotted, double, oxford };
const Ornament = enum { none, diamond, dot, ring, star };

/// Um trecho reto da régua, nos dois sentidos. `span` é o comprimento total
/// (para o `fade`), e o trecho só sabe de onde a onde vai.
const RuleSeg = struct { from: f32, to: f32 };

fn ruleSegment(ctx: *d.Ctx, n: *const kdl.Node, r: d.Rect, seg: RuleSeg, kind: RuleKind, vertical: bool, cross: f32, th: f32, col: d.Rgba, fade: bool) void {
    if (seg.to <= seg.from) return;
    const dl = ctx.dl;
    const whole: d.Rect = if (vertical)
        .{ .x = cross, .y = seg.from, .w = th, .h = seg.to - seg.from }
    else
        .{ .x = seg.from, .y = cross, .w = seg.to - seg.from, .h = th };
    const start = dl.*.VtxBuffer.Size;
    if (kind == .dashed or kind == .dotted) {
        // Um quad só, com o tracejado vindo de um ladrilho: não importa o
        // comprimento da régua, são 4 vértices.
        const dash: f32 = if (kind == .dotted) th else d.pnum(n, "dash", 6);
        const gap: f32 = if (kind == .dotted) th * 2 else d.pnum(n, "gap", 4);
        const side = fx.tileSide(ctx, dash + gap);
        const period: f32 = @floatFromInt(side);
        const dash_px: u16 = @intFromFloat(@min(@round(dash), period - 1));
        const spec: procgen.Spec = .{ .dash = .{ .dash = dash_px, .gap = side - dash_px } };
        if (fx.texture(ctx, spec)) |tex| {
            const ua = seg.from / period;
            const ub = seg.to / period;
            const p0 = d.v(whole.x, whole.y);
            const p2 = d.v(whole.right(), whole.bottom());
            if (vertical) {
                c.ImDrawList_AddImageQuadEx(dl, fx.refOf(tex), p0, d.v(p2.x, p0.y), p2, d.v(p0.x, p2.y), d.v(ua, 0), d.v(ua, 1), d.v(ub, 1), d.v(ub, 0), col.u());
            } else {
                c.ImDrawList_AddImageEx(dl, fx.refOf(tex), p0, p2, d.v(ua, 0), d.v(ub, 1), col.u());
            }
        }
    } else {
        d.rect(dl, whole, col, 0);
    }
    if (fade) fadeVerts(dl, start, r, vertical);
}

/// A régua some nas duas pontas, a partir de 22% do comprimento.
fn fadeVerts(dl: *c.ImDrawList, start: c_int, r: d.Rect, vertical: bool) void {
    const vb = &dl.*.VtxBuffer;
    if (start >= vb.Size) return;
    for (vb.Data[@intCast(start)..@intCast(vb.Size)]) |*p| {
        const t = if (vertical) (p.pos.y - r.y) / @max(r.h, 1) else (p.pos.x - r.x) / @max(r.w, 1);
        const k = std.math.clamp(@min(t, 1 - t) / 0.22, 0, 1);
        const a: f32 = @floatFromInt((p.col >> 24) & 0xff);
        p.col = (p.col & 0x00ff_ffff) | (@as(u32, @intFromFloat(a * k)) << 24);
    }
}

/// `rule kind=oxford color=text thickness=1`
/// `rule kind=dashed dash=6 gap=4 fade=#true`
/// `rule ornament=diamond ornament-color=accent ornament-size=8`
/// `rule ornament-text="§" font="Liberation Serif"`
/// `rule vertical=#true`
pub fn rule(ctx: *d.Ctx, n: *const kdl.Node, r: d.Rect) void {
    const kind = std.meta.stringToEnum(RuleKind, d.pstr(n, "kind", "solid")) orelse .solid;
    if (qa.on()) qa.mark(r, "rule:{s}", .{@tagName(kind)});
    const vertical = d.pflag(n, "vertical", false);
    const fade = d.pflag(n, "fade", false);
    const th = d.pnum(n, "thickness", 1);
    const col = fx.nodeColor(ctx, n, "color", .border);
    const orn = std.meta.stringToEnum(Ornament, d.pstr(n, "ornament", "none")) orelse .none;
    const orn_text = n.str("ornament-text");
    const has_orn = orn != .none or orn_text != null;
    const osize = d.pnum(n, "ornament-size", 8);
    const start = if (vertical) r.y else r.x;
    const end = if (vertical) r.bottom() else r.right();
    const mid = (start + end) / 2;

    var half_gap: f32 = 0;
    const fam = ctx.familyFor(n);
    if (orn_text) |t| {
        half_gap = d.width(fam.get(.regular), osize, t) / 2 + 8;
    } else if (has_orn) half_gap = osize / 2 + 8;
    half_gap = d.pnum(n, "ornament-gap", half_gap);
    const segs = [2]RuleSeg{ .{ .from = start, .to = if (has_orn) mid - half_gap else end }, .{ .from = mid + half_gap, .to = end } };
    const n_segs: usize = if (has_orn) 2 else 1;

    const center = if (vertical) r.x + r.w / 2 else r.y + r.h / 2;
    for (segs[0..n_segs]) |seg| {
        switch (kind) {
            .double => {
                const total = th * 2 + th + 1;
                const c0 = @round(center - total / 2);
                ruleSegment(ctx, n, r, seg, .solid, vertical, c0, th, col, fade);
                ruleSegment(ctx, n, r, seg, .solid, vertical, c0 + th * 2 + 1, th, col, fade);
            },
            .oxford => {
                // Um fio grosso sobre um fino, como nos jornais.
                const thick = th * 3;
                const total = thick + 2 + th;
                const c0 = @round(center - total / 2);
                ruleSegment(ctx, n, r, seg, .solid, vertical, c0, thick, col, fade);
                ruleSegment(ctx, n, r, seg, .solid, vertical, c0 + thick + 2, th, col, fade);
            },
            else => ruleSegment(ctx, n, r, seg, kind, vertical, @round(center - th / 2), th, col, fade),
        }
    }
    if (!has_orn) return;
    const oc = fx.nodeColor(ctx, n, "ornament-color", .accent);
    const ox = if (vertical) center else mid;
    const oy = if (vertical) mid else center;
    if (orn_text) |t| {
        const w = d.width(fam.get(.regular), osize, t);
        d.text(ctx.dl, fam.get(.regular), osize, ox - w / 2, oy - osize * 0.6, oc, t);
        return;
    }
    const h = osize / 2;
    switch (orn) {
        .diamond => c.ImDrawList_AddQuadFilled(ctx.dl, d.v(ox, oy - h), d.v(ox + h, oy), d.v(ox, oy + h), d.v(ox - h, oy), oc.u()),
        .dot => d.circle(ctx.dl, ox, oy, h, oc),
        .ring => c.ImDrawList_AddCircleEx(ctx.dl, d.v(ox, oy), h, oc.u(), 0, 1.2, 0),
        .star => {
            // Quatro pontas finas, como uma estrela de carta náutica.
            const k = h * 0.28;
            const pts = [8]c.ImVec2{ d.v(ox, oy - h), d.v(ox + k, oy - k), d.v(ox + h, oy), d.v(ox + k, oy + k), d.v(ox, oy + h), d.v(ox - k, oy + k), d.v(ox - h, oy), d.v(ox - k, oy - k) };
            c.ImDrawList_AddConcavePolyFilled(ctx.dl, &pts, 8, oc.u());
        },
        .none => {},
    }
}

/// Quantas vezes o botão de fechar foi pedido no QA (que não pode sair de verdade).
pub var qa_close_requests: u32 = 0;

/// `window-controls size=12 gap=8 color="#ff5f57" color2="#febc2e" color3="#28c840"`
/// Três botões de verdade: fecha o app, minimiza e maximiza/restaura a janela.
/// Sem foco ficam apagados; com o mouse em cima mostram o símbolo.
pub fn windowControls(ctx: *d.Ctx, n: *const kdl.Node, r: d.Rect) void {
    const size = d.pnum(n, "size", 12);
    const gap = d.pnum(n, "gap", 8);
    const cols = [3]d.Rgba{ fx.nodeColor(ctx, n, "color", .danger), fx.nodeColor(ctx, n, "color2", .idle), fx.nodeColor(ctx, n, "color3", .online) };
    const cy = r.y + r.h / 2;
    const total = size * 3 + gap * 2;
    const x0 = if (d.is(n, "align", "center", "left")) r.x + (r.w - total) / 2 else if (d.is(n, "align", "right", "left")) r.right() - total else r.x;
    controlsDraw(ctx, x0, cy, size, gap, cols);
}

/// Os três botões numa posição já resolvida (a faixa de título chama direto).
pub fn controlsDraw(ctx: *d.Ctx, x0: f32, cy: f32, size: f32, gap: f32, cols: [3]d.Rgba) void {
    const total = size * 3 + gap * 2;
    // Os botões ficam de fora do arrasto da barra de título.
    @import("../platform/window.zig").excludeHit(x0 - 4, cy - size / 2 - 4, total + 8, size + 8);
    const tips = [3][2][]const u8{ .{ "Fechar", "Close" }, .{ "Minimizar", "Minimize" }, .{ "Maximizar", "Zoom" } };
    const marks = [3][]const u8{ "close", "minimize", "zoom" };
    const win = c.SDL_GetRenderWindow(ctx.images.renderer);
    const focused = !ctx.io.*.AppFocusLost;
    const hot = ctx.hovering(.{ .x = x0 - 4, .y = cy - size / 2 - 4, .w = total + 8, .h = size + 8 });
    for (0..3) |i| {
        const cx = x0 + size / 2 + @as(f32, @floatFromInt(i)) * (size + gap);
        const br: d.Rect = .{ .x = cx - size / 2 - gap / 2, .y = cy - size / 2 - 3, .w = size + gap, .h = size + 6 };
        const h = d.hit(ctx, 9100 + i, br);
        qa.mark(br, "winctl:{s}", .{marks[i]});
        const col = if (focused or hot) cols[i] else ctx.col(.faint).alpha(0.55);
        d.circle(ctx.dl, cx, cy, size / 2, col);
        c.ImDrawList_AddCircleEx(ctx.dl, d.v(cx, cy), size / 2 - 0.25, d.Rgba.black.col(0.14), 0, 0.5, 0);
        if (hot) {
            const ink = d.Rgba.black.alpha(0.62);
            const k = size * 0.2;
            switch (i) {
                0 => {
                    d.line(ctx.dl, cx - k, cy - k, cx + k, cy + k, ink, 1.2);
                    d.line(ctx.dl, cx - k, cy + k, cx + k, cy - k, ink, 1.2);
                },
                1 => d.line(ctx.dl, cx - k * 1.3, cy, cx + k * 1.3, cy, ink, 1.4),
                else => {
                    d.line(ctx.dl, cx - k * 1.3, cy, cx + k * 1.3, cy, ink, 1.2);
                    d.line(ctx.dl, cx, cy - k * 1.3, cx, cy + k * 1.3, ink, 1.2);
                },
            }
        }
        d.tip(ctx, br, i18n.tr(tips[i][0], tips[i][1]), h.hovered);
        if (!h.clicked) continue;
        switch (i) {
            0 => {
                if (qa.on()) {
                    qa_close_requests += 1;
                } else {
                    // Igual ao botão do sistema: pode ser ficar na bandeja.
                    var ev = std.mem.zeroes(c.SDL_Event);
                    ev.type = c.SDL_EVENT_WINDOW_CLOSE_REQUESTED;
                    if (win) |w| ev.window.windowID = c.SDL_GetWindowID(w);
                    _ = c.SDL_PushEvent(&ev);
                }
            },
            1 => if (win) |w| {
                _ = c.SDL_MinimizeWindow(w);
            },
            else => if (win) |w| {
                if (c.SDL_GetWindowFlags(w) & c.SDL_WINDOW_MAXIMIZED != 0) {
                    _ = c.SDL_RestoreWindow(w);
                } else {
                    _ = c.SDL_MaximizeWindow(w);
                }
            },
        }
    }
}
