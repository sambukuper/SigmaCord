//! O mascote do SigmaCord desenhado com o ImDrawList, com as mesmas medidas
//! de assets/logo-mark.svg (viewBox 100 110 1200 900), para poder animar cada
//! parte: o corpo surgindo, a estrelinha girando, as pálpebras piscando e o
//! rosto virando para onde o mouse está.
const std = @import("std");
const c = @import("c");
const d = @import("draw.zig");

pub const Rgba = d.Rgba;

/// Cores da marca (as mesmas do SVG).
pub const violet = Rgba.hex(0x8B2CF5);
pub const magenta = Rgba.hex(0xB43CFF);
pub const pink = Rgba.hex(0xF03CFF);
pub const ink = Rgba.hex(0x12061F);
const body_col = Rgba.hex(0x7A0BD0);
const rim_col = Rgba.hex(0xF03CFF);
const shade_col = Rgba.hex(0x4B0790);
const star_col = Rgba.hex(0xFF3CF0);

/// Estado da animação. Tudo em 0..1, menos `look` (-1..1) e `spin` (radianos).
pub const Pose = struct {
    /// Escala do corpo (passa de 1 no "pulo" de entrada).
    body: f32 = 1,
    /// Pálpebras: 1 = o olhar de deboche normal, 0 = fechadas.
    eyes: f32 = 1,
    /// Sorriso torto, crescendo da esquerda para a direita.
    smile: f32 = 1,
    /// Estrelinha: tamanho e giro.
    star: f32 = 1,
    spin: f32 = 0,
    /// Para onde o rosto vira.
    look: [2]f32 = .{ 0, 0 },
    /// Halo atrás do mascote.
    glow: f32 = 1,
    alpha: f32 = 1,
};

/// Transforma pontos do SVG para a tela.
const Xf = struct {
    cx: f32,
    cy: f32,
    k: f32,
    /// Deslocamento extra (o rosto que vira), em unidades do SVG.
    ox: f32 = 0,
    oy: f32 = 0,

    fn p(x: Xf, sx: f32, sy: f32) c.ImVec2 {
        return .{ .x = x.cx + (sx + x.ox - 700) * x.k, .y = x.cy + (sy + x.oy - 560) * x.k };
    }

    /// Escala em torno de um ponto do SVG.
    fn around(x: Xf, px: f32, py: f32, s: f32) Xf {
        const o = x.p(px, py);
        return .{ .cx = o.x + (x.cx - o.x) * s, .cy = o.y + (x.cy - o.y) * s, .k = x.k * s, .ox = x.ox, .oy = x.oy };
    }
};

/// Pinta os vértices criados desde `start` com o degradê da marca de `a` até
/// `b`, mantendo o alpha de cada vértice (a borda suavizada do ImGui).
pub fn gradient(dl: *c.ImDrawList, start: c_int, a: c.ImVec2, b: c.ImVec2, alpha: f32) void {
    const vb = &dl.*.VtxBuffer;
    const dx = b.x - a.x;
    const dy = b.y - a.y;
    const len2 = @max(dx * dx + dy * dy, 1);
    var i: usize = @intCast(start);
    while (i < @as(usize, @intCast(vb.*.Size))) : (i += 1) {
        const vtx = &vb.*.Data[i];
        const t = std.math.clamp(((vtx.pos.x - a.x) * dx + (vtx.pos.y - a.y) * dy) / len2, 0, 1);
        const col = if (t < 0.5) violet.mix(magenta, t * 2) else magenta.mix(pink, (t - 0.5) * 2);
        const va: f32 = @floatFromInt(vtx.col >> 24);
        vtx.col = col.col(va / 255.0 * alpha);
    }
}

/// Halo radial suave: centro com `color`, borda transparente.
pub fn glow(dl: *c.ImDrawList, cx: f32, cy: f32, rx: f32, ry: f32, color: Rgba) void {
    if (color.a <= 0.002 or rx < 1) return;
    const n: c_int = 48;
    const uv = c.ImGui_GetFontTexUvWhitePixel();
    c.ImDrawList_PrimReserve(dl, n * 3, n + 1);
    // Lido depois do PrimReserve: ele pode abrir um comando novo e zerar o índice.
    const base: c_uint = @intCast(dl.*._VtxCurrentIdx);
    c.ImDrawList_PrimWriteVtx(dl, d.v(cx, cy), uv, color.u());
    const edge = color.alpha(0).u();
    var i: c_int = 0;
    while (i < n) : (i += 1) {
        const a = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n)) * std.math.tau;
        c.ImDrawList_PrimWriteVtx(dl, d.v(cx + @cos(a) * rx, cy + @sin(a) * ry), uv, edge);
    }
    i = 0;
    while (i < n) : (i += 1) {
        c.ImDrawList_PrimWriteIdx(dl, @intCast(base));
        c.ImDrawList_PrimWriteIdx(dl, @intCast(base + 1 + @as(c_uint, @intCast(i))));
        c.ImDrawList_PrimWriteIdx(dl, @intCast(base + 1 + @as(c_uint, @intCast(@mod(i + 1, n)))));
    }
}

/// Copia o caminho que está sendo montado (já em pontos) e o limpa.
fn takePath(dl: *c.ImDrawList, out: []c.ImVec2) usize {
    const path = &dl.*._Path;
    const n: usize = @min(@as(usize, @intCast(path.*.Size)), out.len);
    @memcpy(out[0..n], path.*.Data[0..n]);
    c.ImDrawList_PathClear(dl);
    return n;
}

/// Faixa por dentro da borda do polígono, mais larga onde a borda está
/// virada para `light` (luz de desenho animado, sem precisar de recorte).
fn edgeBand(dl: *c.ImDrawList, poly: []const c.ImVec2, light: [2]f32, width: f32, col: Rgba) void {
    const n = poly.len;
    if (n < 3 or col.a <= 0.002) return;
    // Sentido do polígono, para saber de que lado fica o "para dentro".
    var area: f32 = 0;
    for (0..n) |i| {
        const a = poly[i];
        const b = poly[(i + 1) % n];
        area += a.x * b.y - b.x * a.y;
    }
    const sgn: f32 = if (area > 0) 1 else -1;
    var inner: [400]c.ImVec2 = undefined;
    var fringe: [400]c.ImVec2 = undefined;
    var wk: [400]f32 = undefined;
    for (0..n) |i| {
        const prev = poly[(i + n - 1) % n];
        const next = poly[(i + 1) % n];
        var tx = next.x - prev.x;
        var ty = next.y - prev.y;
        const len = @max(@sqrt(tx * tx + ty * ty), 0.0001);
        tx /= len;
        ty /= len;
        // Normal para fora.
        const ox = ty * sgn;
        const oy = -tx * sgn;
        const facing = ox * light[0] + oy * light[1];
        const k = std.math.clamp((facing - 0.15) / 0.6, 0, 1);
        wk[i] = k * k * (3 - 2 * k);
        const wd = width * wk[i];
        inner[i] = .{ .x = poly[i].x - ox * wd, .y = poly[i].y - oy * wd };
        // 1 px a mais, sumindo: a borda de dentro fica suave.
        const fw = wd + @min(wd, 1.2);
        fringe[i] = .{ .x = poly[i].x - ox * fw, .y = poly[i].y - oy * fw };
    }
    const uv = c.ImGui_GetFontTexUvWhitePixel();
    const u = col.u();
    const clear = col.alpha(0).u();
    for (0..n) |i| {
        const j = (i + 1) % n;
        if (wk[i] < 0.001 and wk[j] < 0.001) continue;
        c.ImDrawList_PrimReserve(dl, 12, 6);
        const base: c_uint = @intCast(dl.*._VtxCurrentIdx);
        c.ImDrawList_PrimWriteVtx(dl, poly[i], uv, u);
        c.ImDrawList_PrimWriteVtx(dl, poly[j], uv, u);
        c.ImDrawList_PrimWriteVtx(dl, inner[j], uv, u);
        c.ImDrawList_PrimWriteVtx(dl, inner[i], uv, u);
        c.ImDrawList_PrimWriteVtx(dl, fringe[j], uv, clear);
        c.ImDrawList_PrimWriteVtx(dl, fringe[i], uv, clear);
        for ([_]c_uint{ 0, 1, 2, 0, 2, 3, 3, 2, 4, 3, 4, 5 }) |o| c.ImDrawList_PrimWriteIdx(dl, @intCast(base + o));
    }
}

// --- Caminhos do SVG -------------------------------------------------------------

fn lineTo(dl: *c.ImDrawList, x: Xf, sx: f32, sy: f32) void {
    c.ImDrawList_PathLineTo(dl, x.p(sx, sy));
}
fn quadTo(dl: *c.ImDrawList, x: Xf, x1: f32, y1: f32, x2: f32, y2: f32) void {
    c.ImDrawList_PathBezierQuadraticCurveTo(dl, x.p(x1, y1), x.p(x2, y2), 0);
}
fn cubicTo(dl: *c.ImDrawList, x: Xf, x1: f32, y1: f32, x2: f32, y2: f32, x3: f32, y3: f32) void {
    c.ImDrawList_PathBezierCubicCurveTo(dl, x.p(x1, y1), x.p(x2, y2), x.p(x3, y3), 0);
}

/// O corpo (`#lc-body` no SVG).
fn bodyPath(dl: *c.ImDrawList, x: Xf) void {
    lineTo(dl, x, 340, 258);
    lineTo(dl, x, 568, 188);
    lineTo(dl, x, 625, 268);
    quadTo(dl, x, 700, 262, 778, 268);
    lineTo(dl, x, 838, 182);
    quadTo(dl, x, 960, 200, 1048, 248);
    cubicTo(dl, x, 1180, 420, 1260, 620, 1262, 812);
    cubicTo(dl, x, 1180, 880, 1080, 920, 985, 945);
    lineTo(dl, x, 930, 830);
    quadTo(dl, x, 700, 850, 482, 802);
    lineTo(dl, x, 428, 938);
    cubicTo(dl, x, 320, 910, 220, 870, 148, 830);
    cubicTo(dl, x, 150, 620, 220, 420, 340, 258);
}

/// Olho: a linha da pálpebra (p0→p1) fica parada e a curva de baixo sobe
/// até ela quando `open` vai a 0.
const Eye = struct { p0: [2]f32, p1: [2]f32, c1: [2]f32, c2: [2]f32, m: [2]f32, c3: [2]f32, c4: [2]f32 };
const eyes = [2]Eye{
    .{ .p0 = .{ 338, 600 }, .p1 = .{ 660, 548 }, .c1 = .{ 640, 640 }, .c2 = .{ 590, 702 }, .m = .{ 482, 705 }, .c3 = .{ 400, 705 }, .c4 = .{ 346, 662 } },
    .{ .p0 = .{ 698, 540 }, .p1 = .{ 1068, 455 }, .c1 = .{ 1086, 540 }, .c2 = .{ 1048, 612 }, .m = .{ 950, 614 }, .c3 = .{ 842, 614 }, .c4 = .{ 736, 600 } },
};

fn eyePath(dl: *c.ImDrawList, x: Xf, e: Eye, open: f32) void {
    const lid = struct {
        fn at(ev: Eye, q: [2]f32, o: f32) [2]f32 {
            const t = std.math.clamp((q[0] - ev.p0[0]) / (ev.p1[0] - ev.p0[0]), 0, 1);
            const ly = ev.p0[1] + (ev.p1[1] - ev.p0[1]) * t;
            return .{ q[0], ly + (q[1] - ly) * o };
        }
    }.at;
    const c1 = lid(e, e.c1, open);
    const c2 = lid(e, e.c2, open);
    const m = lid(e, e.m, open);
    const c3 = lid(e, e.c3, open);
    const c4 = lid(e, e.c4, open);
    lineTo(dl, x, e.p0[0], e.p0[1]);
    lineTo(dl, x, e.p1[0], e.p1[1]);
    cubicTo(dl, x, c1[0], c1[1], c2[0], c2[1], m[0], m[1]);
    cubicTo(dl, x, c3[0], c3[1], c4[0], c4[1], e.p0[0], e.p0[1]);
}

/// Estrela de quatro pontas em volta de (1095, 298), girando `spin`.
fn starPath(dl: *c.ImDrawList, x: Xf, s: f32, spin: f32) void {
    const pts = [_][2]f32{
        .{ 1095, 160 }, .{ 1105, 250 }, .{ 1120, 282 }, .{ 1240, 296 },
        .{ 1130, 310 }, .{ 1112, 340 }, .{ 1110, 436 },
        .{ 1100, 340 }, .{ 1080, 322 }, .{ 940, 322 },
        .{ 1060, 306 }, .{ 1088, 272 }, .{ 1095, 160 },
    };
    const cx: f32 = 1095;
    const cy: f32 = 298;
    const cs = @cos(spin);
    const sn = @sin(spin);
    var q: [13][2]f32 = undefined;
    for (pts, 0..) |pt, i| {
        const dx = (pt[0] - cx) * s;
        const dy = (pt[1] - cy) * s;
        q[i] = .{ cx + dx * cs - dy * sn, cy + dx * sn + dy * cs };
    }
    lineTo(dl, x, q[0][0], q[0][1]);
    var i: usize = 1;
    while (i + 2 < q.len) : (i += 3) cubicTo(dl, x, q[i][0], q[i][1], q[i + 1][0], q[i + 1][1], q[i + 2][0], q[i + 2][1]);
}

/// Desenha o mascote centrado em (cx, cy) com `size` pixels de largura.
pub fn draw(dl: *c.ImDrawList, cx: f32, cy: f32, size: f32, pose: Pose) void {
    const A = pose.alpha;
    if (A <= 0.002) return;
    const base: Xf = .{ .cx = cx, .cy = cy, .k = size / 1200 };
    const k = base.k;

    // Halo atrás de tudo.
    glow(dl, cx, cy + 30 * k, 640 * k * @max(pose.body, 0.2), 480 * k * @max(pose.body, 0.2), violet.alpha(0.45 * pose.glow * A));

    if (pose.body > 0.001) {
        // O corpo cresce a partir do meio de baixo.
        const x = base.around(700, 700, pose.body);
        // O corpo em roxo; depois faixas por dentro do contorno: luz rosa
        // onde a borda olha para cima/direita, sombra onde olha para baixo/esquerda.
        bodyPath(dl, x);
        var poly: [400]c.ImVec2 = undefined;
        const n = takePath(dl, &poly);
        c.ImDrawList_AddConcavePolyFilled(dl, &poly, @intCast(n), body_col.alpha(A).u());
        edgeBand(dl, poly[0..n], .{ 0.55, -0.83 }, 52 * x.k, rim_col.alpha(A));
        edgeBand(dl, poly[0..n], .{ -0.6, 0.8 }, 70 * x.k, shade_col.alpha(A));
        // Contorno.
        bodyPath(dl, x);
        c.ImDrawList_PathStroke(dl, ink.alpha(A).u(), 26 * x.k, c.ImDrawFlags_Closed);

        // Rosto: vira um pouco para onde o mouse está.
        var face = x;
        face.ox = std.math.clamp(pose.look[0], -1, 1) * 26;
        face.oy = std.math.clamp(pose.look[1], -1, 1) * 16;
        const open = std.math.clamp(pose.eyes, 0, 1.2);
        for (eyes) |e| {
            if (open < 0.06) {
                // Fechado: só o risco da pálpebra.
                c.ImDrawList_AddLineEx(dl, face.p(e.p0[0], e.p0[1]), face.p(e.p1[0], e.p1[1]), ink.alpha(A).u(), 16 * x.k, 0);
                continue;
            }
            eyePath(dl, face, e, open);
            c.ImDrawList_PathFillConcave(dl, ink.alpha(A).u());
        }
        if (pose.smile > 0.001) {
            // O sorriso cresce a partir do canto esquerdo.
            const sm = struct {
                fn at(px: f32, s: f32) f32 {
                    return 728 + (px - 728) * s;
                }
            }.at;
            const s = pose.smile;
            lineTo(dl, face, sm(728, s), 742);
            cubicTo(dl, face, sm(830, s), 742 - 20 * s, sm(922, s), 742 - 42 * s, sm(980, s), 742 - 90 * s);
            cubicTo(dl, face, sm(988, s), 742 - 74 * s, sm(980, s), 742 - 62 * s, sm(962, s), 742 - 52 * s);
            cubicTo(dl, face, sm(900, s), 742 - 20 * s, sm(822, s), 742, sm(732, s), 750);
            c.ImDrawList_PathFillConcave(dl, ink.alpha(A).u());
        }
    }

    // Estrelinha (fica fora do "pulo" do corpo para poder entrar depois).
    if (pose.star > 0.001) {
        const sc = base.p(1095, 298);
        glow(dl, sc.x, sc.y, 170 * k * pose.star, 170 * k * pose.star, star_col.alpha(0.4 * pose.glow * A));
        starPath(dl, base, pose.star, pose.spin);
        c.ImDrawList_PathFillConcave(dl, star_col.alpha(A).u());
        starPath(dl, base, pose.star, pose.spin);
        c.ImDrawList_PathStroke(dl, ink.alpha(A).u(), 18 * k, c.ImDrawFlags_Closed);
    }
}

/// Mascote pequeno e parado ("Sobre", barra de título).
pub fn still(dl: *c.ImDrawList, cx: f32, cy: f32, size: f32) void {
    draw(dl, cx, cy, size, .{ .glow = 0.6 });
}
