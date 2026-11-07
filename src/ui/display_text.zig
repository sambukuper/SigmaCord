//! Tipografia de display do `label`: tracking de verdade (letra por letra, em vez
//! de espaços no texto), runs com cor/peso/tamanho próprios na mesma linha e na
//! mesma linha de base, sombra (com desfoque), contorno e gradiente no texto.
//! Só labels que pedem alguma dessas coisas passam por aqui.
const std = @import("std");
const c = @import("c");
const kdl = @import("../theme/kdl.zig");
const theme_mod = @import("../theme/theme.zig");
const tfx = theme_mod.fx;
const d = @import("draw.zig");
const fx = @import("fx.zig");
const i18n = @import("i18n.zig");
const qa = @import("qa.zig");

const max_runs = 12;

extern fn sigma_font_ascent(font: *c.ImFont, size: f32) f32;

const Run = struct {
    text: []const u8,
    font: *c.ImFont,
    size: f32,
    color: d.Rgba,
    tracking: f32,
    width: f32,
    ascent: f32,
    /// Avanço de cada letra deste run dentro de `Advances`: sombra e contorno
    /// desenham o texto várias vezes, e medir só precisa de uma.
    first_adv: usize = 0,
};

/// Avanços das letras com tracking de um label. O que passar disso é medido na hora.
const Advances = struct {
    v: [64]f32 = undefined,
    n: usize = 0,
};

fn familyFor(ctx: *const d.Ctx, name: ?[]const u8) *d.Family {
    const f = name orelse return ctx.ui;
    if (std.mem.eql(u8, f, "mono")) return ctx.mono;
    if (std.mem.eql(u8, f, "ui")) return ctx.ui;
    return ctx.fonts.find(f) orelse ctx.ui;
}

fn glyphLen(s: []const u8) usize {
    const n = std.unicode.utf8ByteSequenceLength(s[0]) catch 1;
    return @min(n, s.len);
}

/// Largura com tracking: nada depois da última letra, para centralizar certo.
fn trackedWidth(font: *c.ImFont, size: f32, s: []const u8, tracking: f32, advs: *Advances) f32 {
    if (tracking == 0) return d.width(font, size, s);
    var w: f32 = 0;
    var i: usize = 0;
    var glyphs: f32 = 0;
    while (i < s.len) {
        const n = glyphLen(s[i..]);
        const adv = d.width(font, size, s[i .. i + n]);
        if (advs.n < advs.v.len) {
            advs.v[advs.n] = adv;
            advs.n += 1;
        }
        w += adv;
        glyphs += 1;
        i += n;
    }
    return w + tracking * d.text_scale * @max(glyphs - 1, 0);
}

/// Monta os runs do label. Retorna quantos couberam.
fn build(ctx: *const d.Ctx, tx: *const tfx.TextFx, out: *[max_runs]Run, advs: *Advances) usize {
    const toks = ctx.th.tokenValues();
    const base_color = if (tx.color) |e| e.eval(toks) else ctx.col(.muted);
    const count = @min(tx.spans.len, max_runs);
    for (tx.spans[0..count], 0..) |sp, i| {
        const fam = familyFor(ctx, sp.font orelse tx.font);
        const w: d.Weight = @enumFromInt(@intFromEnum(sp.weight orelse tx.weight));
        const font = fam.get(w);
        const size = sp.size orelse tx.size;
        const tracking = sp.tracking orelse tx.tracking;
        const text = if (sp.text_en.len > 0) i18n.tr(sp.text, sp.text_en) else sp.text;
        const first_adv = advs.n;
        out[i] = .{
            .text = text,
            .font = font,
            .size = size,
            .color = if (sp.color) |e| e.eval(toks) else base_color,
            .tracking = tracking * d.text_scale,
            .width = trackedWidth(font, size, text, tracking, advs),
            .ascent = sigma_font_ascent(font, d.fontPx(size)),
            .first_adv = first_adv,
        };
    }
    return count;
}

fn rawText(dl: *c.ImDrawList, font: *c.ImFont, sz: f32, x: f32, y: f32, col: u32, s: []const u8) void {
    const b: [*]const u8 = s.ptr;
    c.ImDrawList_AddTextImFontPtrEx(dl, font, sz, d.v(@round(x), @round(y)), col, b, b + s.len, 0, null);
}

/// Desenha todos os runs a partir de (x, base). `over` troca a cor (sombra, contorno).
fn pass(dl: *c.ImDrawList, runs: []const Run, advs: *const Advances, x0: f32, base: f32, gap: f32, over: ?d.Rgba) void {
    var x = x0;
    for (runs) |run| {
        const sz = d.fontPx(run.size);
        const y = base - run.ascent;
        const col = (over orelse run.color).u();
        if (run.tracking == 0) {
            if (run.text.len > 0) rawText(dl, run.font, sz, x, y, col, run.text);
        } else {
            var gx = x;
            var i: usize = 0;
            var k = run.first_adv;
            while (i < run.text.len) {
                const n = glyphLen(run.text[i..]);
                const g = run.text[i .. i + n];
                rawText(dl, run.font, sz, gx, y, col, g);
                gx += (if (k < advs.n) advs.v[k] else d.width(run.font, run.size, g)) + run.tracking;
                k += 1;
                i += n;
            }
        }
        x += run.width + gap;
    }
}

const ring8 = [8][2]f32{ .{ 1, 0 }, .{ 0.7, 0.7 }, .{ 0, 1 }, .{ -0.7, 0.7 }, .{ -1, 0 }, .{ -0.7, -0.7 }, .{ 0, -1 }, .{ 0.7, -0.7 } };

/// `label text=… tracking=… shadow=… { span "01" size=18; span "CANAIS" }`
pub fn label(ctx: *d.Ctx, n: *const kdl.Node, r: d.Rect, tx: *const tfx.TextFx) void {
    var buf: [max_runs]Run = undefined;
    var advs: Advances = .{};
    const runs = buf[0..build(ctx, tx, &buf, &advs)];
    if (runs.len == 0) return;
    const gap = d.pnum(n, "span-gap", 0);
    var total: f32 = gap * @as(f32, @floatFromInt(runs.len - 1));
    var biggest = runs[0];
    for (runs) |run| {
        total += run.width;
        if (run.size > biggest.size) biggest = run;
    }
    const x = if (d.is(n, "align", "center", "left")) r.x + (r.w - total) / 2 else if (d.is(n, "align", "right", "left")) r.right() - total - 10 else r.x + 10;
    // Todos na mesma linha de base: a do maior, centralizado como o label simples.
    const base = d.centerY(r, biggest.size) + biggest.ascent;
    const toks = ctx.th.tokenValues();
    const dl = ctx.dl;

    if (tx.shadow) |e| {
        const col = e.eval(toks);
        if (tx.shadow_blur > 0) {
            // Desfoque barato: anéis de cópias fracas, do mais largo ao mais justo.
            const layers: usize = @intFromFloat(@min(@ceil(tx.shadow_blur), 4));
            for (0..layers) |li| {
                const k = 1 - @as(f32, @floatFromInt(li)) / @as(f32, @floatFromInt(layers));
                const rad = tx.shadow_blur * k;
                for (ring8) |o| pass(dl, runs, &advs, x + tx.shadow_x + o[0] * rad, base + tx.shadow_y + o[1] * rad, gap, col.alpha(0.16 + 0.1 * (1 - k)));
            }
        } else pass(dl, runs, &advs, x + tx.shadow_x, base + tx.shadow_y, gap, col);
    }
    if (tx.outline) |e| {
        const col = e.eval(toks);
        for (ring8) |o| pass(dl, runs, &advs, x + o[0] * tx.outline_width, base + o[1] * tx.outline_width, gap, col);
    }
    const start = dl.*.VtxBuffer.Size;
    pass(dl, runs, &advs, x, base, gap, null);
    if (tx.gradient) |g| {
        const box: d.Rect = .{ .x = x, .y = base - biggest.ascent, .w = total, .h = biggest.size * d.text_scale };
        fx.Stops.of(ctx, g).shade(dl, start, box);
    }
    if (qa.on()) qa.mark(.{ .x = x, .y = base - biggest.ascent, .w = total, .h = biggest.size * d.text_scale }, "display:{s}", .{runs[0].text});
}
