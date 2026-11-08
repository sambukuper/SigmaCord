//! Ícones vetoriais simples desenhados direto no ImDrawList.
const std = @import("std");
const c = @import("c");

const pi = std.math.pi;

fn v(x: f32, y: f32) c.ImVec2 {
    return .{ .x = x, .y = y };
}

fn line(dl: *c.ImDrawList, x1: f32, y1: f32, x2: f32, y2: f32, col: u32, th: f32) void {
    c.ImDrawList_AddLineEx(dl, v(x1, y1), v(x2, y2), col, th, 0);
}

fn arc(dl: *c.ImDrawList, cx: f32, cy: f32, r: f32, a0: f32, a1: f32, col: u32, th: f32) void {
    c.ImDrawList_PathClear(dl);
    c.ImDrawList_PathArcTo(dl, v(cx, cy), r, a0, a1, 0);
    c.ImDrawList_PathStroke(dl, col, th, 0);
}

/// Ícones centrados em (cx, cy), cabendo num quadrado de ~20px.
pub fn mic(dl: *c.ImDrawList, cx: f32, cy: f32, col: u32) void {
    c.ImDrawList_AddRectFilledEx(dl, v(cx - 3.5, cy - 9), v(cx + 3.5, cy + 3), col, 3.5, 0);
    arc(dl, cx, cy - 1, 6.5, 0, pi, col, 1.8);
    line(dl, cx, cy + 5.5, cx, cy + 9, col, 1.8);
    line(dl, cx - 3.5, cy + 9, cx + 3.5, cy + 9, col, 1.8);
}

pub fn headset(dl: *c.ImDrawList, cx: f32, cy: f32, col: u32) void {
    arc(dl, cx, cy + 1, 7.5, pi, 2 * pi, col, 1.9);
    c.ImDrawList_AddRectFilledEx(dl, v(cx - 9, cy), v(cx - 5, cy + 8), col, 2, 0);
    c.ImDrawList_AddRectFilledEx(dl, v(cx + 5, cy), v(cx + 9, cy + 8), col, 2, 0);
}

/// Fone na diagonal (o clássico "telefonar"): o arco e as duas pontas.
pub fn phone(dl: *c.ImDrawList, cx: f32, cy: f32, col: u32) void {
    c.ImDrawList_PathClear(dl);
    c.ImDrawList_PathArcTo(dl, v(cx + 1, cy + 1), 8.5, pi * 0.25, pi * 0.85, 12);
    c.ImDrawList_PathStroke(dl, col, 0, 2.6);
    c.ImDrawList_AddCircleFilled(dl, v(cx - 6, cy - 2), 2.6, col);
    c.ImDrawList_AddCircleFilled(dl, v(cx - 2, cy - 6), 2.6, col);
    line(dl, cx - 5.5, cy - 3, cx - 2.5, cy - 5.5, col, 3);
}

pub fn gear(dl: *c.ImDrawList, cx: f32, cy: f32, col: u32) void {
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        const a = @as(f32, @floatFromInt(i)) * pi / 4.0;
        line(dl, cx + @cos(a) * 5.5, cy + @sin(a) * 5.5, cx + @cos(a) * 8.7, cy + @sin(a) * 8.7, col, 2.8);
    }
    c.ImDrawList_AddCircleEx(dl, v(cx, cy), 5, col, 0, 2.2, 0);
}

/// Alfinete em traço, em pé: chapéu, corpo que abre e a ponta.
pub fn pin(dl: *c.ImDrawList, cx_in: f32, cy_in: f32, col: u32) void {
    const cx = @round(cx_in);
    const cy = @round(cy_in);
    const th: f32 = 1.7;
    const pts = [_]c.ImVec2{
        v(cx - 3.5, cy - 8), v(cx + 3.5, cy - 8), v(cx + 3.5, cy - 6), v(cx + 2.5, cy - 5),
        v(cx + 2.5, cy - 1), v(cx + 6, cy + 2.5), v(cx + 6, cy + 4),   v(cx - 6, cy + 4),
        v(cx - 6, cy + 2.5), v(cx - 2.5, cy - 1), v(cx - 2.5, cy - 5), v(cx - 3.5, cy - 6),
    };
    c.ImDrawList_AddPolyline(dl, &pts[0], pts.len, col, th, c.ImDrawFlags_Closed);
    line(dl, cx, cy + 4, cx, cy + 9, col, th);
}

pub fn search(dl: *c.ImDrawList, cx: f32, cy: f32, col: u32) void {
    c.ImDrawList_AddCircleEx(dl, v(cx - 1.5, cy - 1.5), 5, col, 0, 1.7, 0);
    line(dl, cx + 2, cy + 2, cx + 6, cy + 6, col, 1.7);
}

pub fn speaker(dl: *c.ImDrawList, cx: f32, cy: f32, col: u32) void {
    c.ImDrawList_PathClear(dl);
    c.ImDrawList_PathLineTo(dl, v(cx - 8, cy - 3));
    c.ImDrawList_PathLineTo(dl, v(cx - 4.5, cy - 3));
    c.ImDrawList_PathLineTo(dl, v(cx + 0.5, cy - 7.5));
    c.ImDrawList_PathLineTo(dl, v(cx + 0.5, cy + 7.5));
    c.ImDrawList_PathLineTo(dl, v(cx - 4.5, cy + 3));
    c.ImDrawList_PathLineTo(dl, v(cx - 8, cy + 3));
    c.ImDrawList_PathFillConvex(dl, col, 0);
    arc(dl, cx + 1, cy, 4.5, -pi / 3.5, pi / 3.5, col, 1.7);
    arc(dl, cx + 1, cy, 8, -pi / 3.2, pi / 3.2, col, 1.7);
}

pub fn chevron(dl: *c.ImDrawList, cx: f32, cy: f32, col: u32, open: f32) void {
    // open = 0 aponta para a direita, 1 aponta para baixo.
    const a = open * pi / 2.0;
    const ca = @cos(a);
    const sa = @sin(a);
    const pts = [_][2]f32{ .{ -2, -4 }, .{ 2, 0 }, .{ -2, 4 } };
    var p: [3]c.ImVec2 = undefined;
    for (pts, 0..) |q, i| p[i] = v(cx + q[0] * ca - q[1] * sa, cy + q[0] * sa + q[1] * ca);
    line(dl, p[0].x, p[0].y, p[1].x, p[1].y, col, 1.6);
    line(dl, p[1].x, p[1].y, p[2].x, p[2].y, col, 1.6);
}

pub fn plus(dl: *c.ImDrawList, cx: f32, cy: f32, r: f32, col: u32) void {
    line(dl, cx - r, cy, cx + r, cy, col, 2);
    line(dl, cx, cy - r, cx, cy + r, col, 2);
}

/// Duas pessoas (amigos, lista de membros).
pub fn members(dl: *c.ImDrawList, cx: f32, cy: f32, col: u32) void {
    people(dl, cx, cy, 0.8, 1.7, col);
}

/// Duas pessoas em traço: a da frente inteira e, ao lado dela, só o que aparece
/// da de trás. Nada se cruza, então o desenho fica limpo em qualquer fundo.
/// Desenhado numa grade de 24, em `s` pixels por unidade, centrado em (cx, cy).
pub fn people(dl: *c.ImDrawList, cx_in: f32, cy_in: f32, s: f32, th: f32, col: u32) void {
    const cx = @round(cx_in);
    const cy = @round(cy_in);
    const P = struct {
        cx: f32,
        cy: f32,
        s: f32,
        fn at(g: @This(), x: f32, y: f32) c.ImVec2 {
            return v(g.cx + (x - 12) * g.s, g.cy + (y - 12) * g.s);
        }
    };
    const g: P = .{ .cx = cx, .cy = cy, .s = s };
    // A cabeça da frente.
    const head = g.at(9, 7);
    c.ImDrawList_AddCircleEx(dl, head, 4 * s, col, 0, th, 0);
    // Os ombros da frente.
    c.ImDrawList_PathClear(dl);
    c.ImDrawList_PathLineTo(dl, g.at(16, 21));
    c.ImDrawList_PathArcTo(dl, g.at(12, 19), 4 * s, 0, -pi / 2.0, 0);
    c.ImDrawList_PathArcTo(dl, g.at(6, 19), 4 * s, -pi / 2.0, -pi, 0);
    c.ImDrawList_PathLineTo(dl, g.at(2, 21));
    c.ImDrawList_PathStroke(dl, col, th, 0);
    // De trás: o lado da cabeça e o ombro.
    arc(dl, g.at(15, 7).x, g.at(15, 7).y, 4 * s, -1.32, 1.32, col, th);
    c.ImDrawList_PathClear(dl);
    c.ImDrawList_PathLineTo(dl, g.at(22, 21));
    c.ImDrawList_PathArcTo(dl, g.at(18, 19), 4 * s, 0, -1.32, 0);
    c.ImDrawList_PathStroke(dl, col, th, 0);
}

/// Duas setas saindo do centro: abrir em tamanho maior.
pub fn expand(dl: *c.ImDrawList, cx_in: f32, cy_in: f32, col: u32) void {
    const cx = @round(cx_in);
    const cy = @round(cy_in);
    const th: f32 = 1.5;
    line(dl, cx + 1, cy - 1, cx + 5, cy - 5, col, th);
    line(dl, cx + 1.5, cy - 5, cx + 5, cy - 5, col, th);
    line(dl, cx + 5, cy - 5, cx + 5, cy - 1.5, col, th);
    line(dl, cx - 1, cy + 1, cx - 5, cy + 5, col, th);
    line(dl, cx - 1.5, cy + 5, cx - 5, cy + 5, col, th);
    line(dl, cx - 5, cy + 5, cx - 5, cy + 1.5, col, th);
}

/// Balão de conversa em traço (mandar mensagem).
pub fn message(dl: *c.ImDrawList, cx_in: f32, cy_in: f32, col: u32) void {
    const cx = @round(cx_in);
    const cy = @round(cy_in);
    const th: f32 = 1.7;
    c.ImDrawList_AddRectEx(dl, v(cx - 7.5, cy - 6.5), v(cx + 7.5, cy + 4.5), col, 3.5, th, 0);
    line(dl, cx - 3.5, cy + 4.5, cx - 5, cy + 8, col, th);
    line(dl, cx - 5, cy + 8, cx - 0.5, cy + 4.5, col, th);
}

/// Cadeado (canal sem acesso).
pub fn lock(dl: *c.ImDrawList, cx: f32, cy: f32, col: u32) void {
    c.ImDrawList_AddRectFilledEx(dl, v(cx - 5.5, cy - 1), v(cx + 5.5, cy + 7), col, 2, 0);
    arc(dl, cx, cy - 1.5, 3.6, pi, 2 * pi, col, 1.8);
    line(dl, cx - 3.6, cy - 1.5, cx - 3.6, cy - 0.5, col, 1.8);
    line(dl, cx + 3.6, cy - 1.5, cx + 3.6, cy - 0.5, col, 1.8);
}

/// Caixa de entrada: uma bandeja com a abertura no meio.
pub fn inbox(dl: *c.ImDrawList, cx: f32, cy: f32, col: u32) void {
    const th: f32 = 1.7;
    line(dl, cx - 8, cy - 6, cx + 8, cy - 6, col, th);
    line(dl, cx - 8, cy - 6, cx - 8, cy + 7, col, th);
    line(dl, cx + 8, cy - 6, cx + 8, cy + 7, col, th);
    line(dl, cx - 8, cy + 7, cx + 8, cy + 7, col, th);
    line(dl, cx - 8, cy + 1, cx - 3.5, cy + 1, col, th);
    line(dl, cx + 3.5, cy + 1, cx + 8, cy + 1, col, th);
    line(dl, cx - 3.5, cy + 1, cx - 2, cy + 3.5, col, th);
    line(dl, cx + 2, cy + 3.5, cx + 3.5, cy + 1, col, th);
    line(dl, cx - 2, cy + 3.5, cx + 2, cy + 3.5, col, th);
}

/// Marcador de página (mensagens salvas). `filled` = já salva.
pub fn bookmark(dl: *c.ImDrawList, cx: f32, cy: f32, col: u32, filled: bool) void {
    const pts = [_]c.ImVec2{ v(cx - 5.5, cy - 8), v(cx + 5.5, cy - 8), v(cx + 5.5, cy + 8), v(cx, cy + 3.5), v(cx - 5.5, cy + 8) };
    if (filled) {
        // O recorte de baixo deixa o polígono côncavo: vai em triângulos.
        c.ImDrawList_AddTriangleFilled(dl, pts[0], pts[1], pts[2], col);
        c.ImDrawList_AddTriangleFilled(dl, pts[0], pts[2], pts[3], col);
        c.ImDrawList_AddTriangleFilled(dl, pts[0], pts[3], pts[4], col);
        return;
    }
    c.ImDrawList_AddPolyline(dl, &pts[0], pts.len, col, 1.7, c.ImDrawFlags_Closed);
}

/// Fórum: um balão com duas linhas de texto.
pub fn forum(dl: *c.ImDrawList, cx: f32, cy: f32, col: u32) void {
    const th: f32 = 1.7;
    c.ImDrawList_AddRectEx(dl, v(cx - 7.5, cy - 7), v(cx + 7.5, cy + 4.5), col, 3, th, 0);
    line(dl, cx - 3.5, cy + 4.5, cx - 5, cy + 8, col, th);
    line(dl, cx - 5, cy + 8, cx - 0.5, cy + 4.5, col, th);
    line(dl, cx - 4, cy - 3.5, cx + 4, cy - 3.5, col, th);
    line(dl, cx - 4, cy + 0.5, cx + 1.5, cy + 0.5, col, th);
}

/// Canal de mídia: uma foto com uma montanha e o sol.
pub fn media(dl: *c.ImDrawList, cx: f32, cy: f32, col: u32) void {
    const th: f32 = 1.7;
    c.ImDrawList_AddRectEx(dl, v(cx - 8, cy - 6.5), v(cx + 8, cy + 6.5), col, 2.5, th, 0);
    line(dl, cx - 6, cy + 4, cx - 1.5, cy - 1, col, th);
    line(dl, cx - 1.5, cy - 1, cx + 2, cy + 2.5, col, th);
    line(dl, cx + 2, cy + 2.5, cx + 3.8, cy + 0.8, col, th);
    line(dl, cx + 3.8, cy + 0.8, cx + 6, cy + 4, col, th);
    c.ImDrawList_AddCircleFilled(dl, v(cx + 3.5, cy - 3), 1.5, col, 0);
}

/// Thread: o balão pequeno com uma linha saindo dele.
pub fn thread(dl: *c.ImDrawList, cx: f32, cy: f32, col: u32) void {
    const th: f32 = 1.6;
    c.ImDrawList_AddRectEx(dl, v(cx - 7, cy - 6), v(cx + 7, cy + 3), col, 2.5, th, 0);
    line(dl, cx - 3, cy + 3, cx - 4.5, cy + 6.5, col, th);
    line(dl, cx - 4.5, cy + 6.5, cx, cy + 3, col, th);
    c.ImDrawList_AddCircleFilled(dl, v(cx - 3, cy - 1.5), 1, col, 0);
    c.ImDrawList_AddCircleFilled(dl, v(cx, cy - 1.5), 1, col, 0);
    c.ImDrawList_AddCircleFilled(dl, v(cx + 3, cy - 1.5), 1, col, 0);
}
