//! Erros de código enquanto se digita: olha o bloco ``` sob o cursor da caixa de
//! texto, manda o corpo para o servidor da linguagem (net/lsp.zig) e mostra o que
//! voltar: uma lista curta acima da caixa e o sublinhado sobre o texto.
//! Com nenhuma linguagem ligada, tudo aqui para no primeiro teste de `lspAnyOn`.
//! A lista flutua sobre as mensagens: aparecer ou sumir não move nada na tela.
const std = @import("std");
const c = @import("c");
const d = @import("draw.zig");
const qa = @import("qa.zig");
const i18n = @import("i18n.zig");
const autocomplete = @import("autocomplete.zig");
const S = @import("settings_state.zig");
const L = @import("../core/lsp.zig");
const net = @import("../net/lsp.zig");
const engine = @import("../plugins/engine.zig");

extern fn sigma_input_wrap(font: *c.ImFont, size: f32, s: [*]const u8, end: [*]const u8, w: f32) [*]const u8;

/// Há um bloco de uma linguagem ligada sob o cursor.
pub var have_doc = false;
pub var spec: net.Spec = .{};
pub var diags: net.Diagnostics = .{};
/// Linha da caixa onde o corpo do bloco começa (o servidor conta a partir dele).
pub var first_line: u32 = 0;

var seen_hash: u64 = 0;
var seen_cursor: usize = std.math.maxInt(usize);
var seen_active = false;
var body_hash: u64 = 0;
var open_at: usize = 0;
var diag_seen: u32 = 0;
var cfg_hash: u64 = 0;

/// Linhas de erro na lista; o resto vira "+N".
const max_rows = 3;

fn hashText(s: []const u8) u64 {
    return std.hash.Wyhash.hash(0, s);
}

fn forget() void {
    have_doc = false;
    seen_hash = 0;
    seen_cursor = std.math.maxInt(usize);
    seen_active = false;
    body_hash = 0;
    diags.n = 0;
    diags.total = 0;
}

fn configHash(s: *const S.Settings) u64 {
    if (!S.lspAnyOn(s)) return 0;
    var h = std.hash.Wyhash.init(1);
    for (0..L.known.len) |i| {
        h.update(&.{@intFromBool(S.lspOnC(s, i).*)});
        h.update(S.lspCmdC(s, i).slice());
    }
    h.update(s.lsp_plugins_ok.slice());
    if (s.lsp_plugins_ok.len > 0) if (engine.current) |e| {
        for (e.list.items) |p| {
            if (!p.isRunning()) continue;
            for (p.lsp.items) |*srv| {
                h.update(p.name);
                h.update(srv.lang.slice());
                h.update(srv.cmd.bytes());
            }
        }
    };
    return h.final() | 1;
}

/// Uma vez por quadro. Desligou, trocou o comando, tirou o plugin: quem estava
/// rodando para na hora (e quem ainda vale sobe na próxima tecla).
pub fn apply(s: *const S.Settings) void {
    if (cfg_hash == 0 and !S.lspAnyOn(s)) return;
    const h = configHash(s);
    if (h == cfg_hash) return;
    cfg_hash = h;
    net.stopAll();
    forget();
}

/// Botão "Tentar de novo": a próxima olhada na caixa manda o texto outra vez.
pub fn retry(lang: []const u8) void {
    net.retry(lang);
    forget();
}

/// O servidor ligado para esta etiqueta: o comando da pessoa e, sem ele, o de
/// um plugin que ela liberou. Nenhum dos dois: não há servidor, e nada sobe.
pub fn resolve(s: *const S.Settings, tag: []const u8, out: *net.Spec) bool {
    const found = L.findTag(tag);
    if (found) |f| if (S.lspOnC(s, f.index).*) {
        var cmd: L.Command = .{};
        if (L.splitArgv(S.lspCmdC(s, f.index).slice(), &cmd)) {
            out.* = .{ .lang = L.Short.of(L.known[f.index].key), .language_id = L.Short.of(f.tag.id), .ext = L.Short.of(f.tag.ext), .cmd = cmd };
            return true;
        }
    };
    if (s.lsp_plugins_ok.len == 0) return false;
    const e = engine.current orelse return false;
    var low: [16]u8 = undefined;
    if (tag.len > low.len) return false;
    const key: []const u8 = if (found) |f| L.known[f.index].key else std.ascii.lowerString(&low, tag);
    for (e.list.items) |p| {
        if (!p.isRunning()) continue;
        for (p.lsp.items) |*srv| {
            if (!std.mem.eql(u8, L.canonicalLang(srv.lang.slice()), key)) continue;
            const k = L.approvalKey(p.name, srv.lang.slice(), &srv.cmd);
            if (!L.isApproved(s.lsp_plugins_ok.slice(), &k)) continue;
            out.* = .{
                .lang = L.Short.of(key),
                .language_id = L.Short.of(if (found) |f| f.tag.id else key),
                .ext = L.Short.of(if (found) |f| f.tag.ext else key),
                .cmd = srv.cmd,
            };
            return true;
        }
    }
    return false;
}

fn leave() void {
    if (!have_doc) return;
    have_doc = false;
    body_hash = 0;
    diags.n = 0;
    diags.total = 0;
    net.clearDoc();
}

fn sync(s: *const S.Settings, text: []const u8, cursor: usize, active: bool) void {
    const blk = L.blockAt(text, cursor) orelse return leave();
    var next: net.Spec = .{};
    if (!resolve(s, blk.tag, &next)) return leave();
    const body = text[blk.body_start..blk.body_end];
    if (body.len > L.max_doc) return leave();
    first_line = blk.first_line;
    const fresh = !have_doc or blk.open != open_at or !next.lang.eql(spec.lang.slice());
    const bh = hashText(body);
    // Só o cursor andou dentro do bloco.
    if (!fresh and bh == body_hash) return;
    // Rascunho de outro canal aparecendo não é digitar.
    if (!active) return;
    open_at = blk.open;
    spec = next;
    body_hash = bh;
    have_doc = true;
    if (fresh) {
        diags.n = 0;
        diags.total = 0;
    }
    // Parado por erro: fica mostrando o erro até a pessoa mexer na configuração.
    if (net.statusOf(next.lang.slice()).state != .failed) net.setDoc(&next, body, fresh);
}

/// Logo depois da caixa de texto no quadro. `frame` é o retângulo dela.
/// `settled`: a caixa já está do tamanho do texto (ela cresce um quadro depois).
pub fn afterInput(ctx: *d.Ctx, dl: *c.ImDrawList, font: *c.ImFont, frame: d.Rect, font_px: f32, active: bool, settled: bool) void {
    const s = &ctx.st.settings;
    if (!S.lspAnyOn(s)) return;
    const text = std.mem.sliceTo(&ctx.st.input, 0);
    const cursor = @min(autocomplete.cursor, text.len);
    const h = hashText(text);
    if (h != seen_hash or cursor != seen_cursor or active != seen_active) {
        seen_hash = h;
        seen_cursor = cursor;
        seen_active = active;
        sync(s, text, cursor, active);
    }
    if (!have_doc) return;
    _ = net.copyDiags(&diag_seen, &diags);
    if (diags.n > 0 and settled) squiggles(ctx, dl, font, frame, font_px, text);
}

// --- Lista acima da caixa -----------------------------------------------------------

fn severityWord(sev: L.Severity) []const u8 {
    return switch (sev) {
        .err => i18n.tr("erro", "error"),
        .warning => i18n.tr("aviso", "warning"),
        .info => "info",
        .hint => i18n.tr("dica", "hint"),
    };
}

fn severityColor(ctx: *d.Ctx, sev: L.Severity) d.Rgba {
    return switch (sev) {
        .err => ctx.col(.danger),
        .warning => ctx.col(.idle),
        .info, .hint => ctx.col(.muted),
    };
}

/// Por que parou, em poucas palavras.
pub fn failureText(buf: []u8, st: *const net.Status) []const u8 {
    return switch (st.failure) {
        .none => "",
        .spawn => i18n.tr("não abriu: confira o comando", "could not start: check the command"),
        .crashed => i18n.fmt(buf, "fechou sozinho (código {d})", "exited by itself (code {d})", .{st.exit_code}),
        .init_timeout => i18n.tr("não respondeu ao iniciar", "did not answer on startup"),
        .protocol => i18n.tr("mandou algo que não é LSP", "sent something that isn't LSP"),
        .write_stall => i18n.tr("parou de ler o que recebe", "stopped reading its input"),
        .flood => i18n.tr("escreveu demais", "wrote too much"),
    };
}

/// O aviso do servidor no lugar da lista: subindo, tentando de novo ou parado.
fn statusRow(buf: []u8, st: *const net.Status) ?[]const u8 {
    var why: [96]u8 = undefined;
    const name = spec.cmd.program();
    return switch (st.state) {
        .starting => i18n.fmt(buf, "{s}: iniciando…", "{s}: starting…", .{name}),
        .retrying => i18n.fmt(buf, "{s}: {s}; tentando de novo", "{s}: {s}; trying again", .{ name, failureText(&why, st) }),
        .failed => i18n.fmt(buf, "{s}: {s}. Veja em Configurações", "{s}: {s}. See Settings", .{ name, failureText(&why, st) }),
        else => null,
    };
}

var place_x: f32 = 0;
var place_bottom: f32 = 0;
var place_w: f32 = 0;
var place_fam: ?*d.Family = null;

/// A caixa de texto diz onde a lista fica (com a base em `bottom`).
pub fn place(fam: *d.Family, x: f32, bottom: f32, w: f32) void {
    place_fam = fam;
    place_x = x;
    place_bottom = bottom;
    place_w = w;
}

/// Desenhada no fim do quadro principal, por cima da conversa (como a lista do
/// autocompletar). Não encolhe as mensagens: aparecer não move nada.
pub fn panel(ctx: *d.Ctx) void {
    const fam = place_fam orelse return;
    place_fam = null;
    if (!have_doc or !S.lspAnyOn(&ctx.st.settings)) return;
    const x = place_x;
    const bottom = place_bottom;
    const w = place_w;
    _ = net.copyDiags(&diag_seen, &diags);
    const st = net.statusOf(spec.lang.slice());
    var sbuf: [160]u8 = undefined;
    const status = if (diags.n == 0) statusRow(&sbuf, &st) else null;
    const shown = @min(diags.n, max_rows);
    const more = diags.total -| shown;
    if (shown == 0 and status == null) return;
    const row_h: f32 = 20;
    const pad: f32 = 6;
    const rows: f32 = @floatFromInt(shown + @as(usize, if (status != null) 1 else 0) + @as(usize, if (more > 0) 1 else 0));
    const h = rows * row_h + pad * 2;
    const r: d.Rect = .{ .x = x, .y = bottom - h, .w = w, .h = h };
    qa.mark(r, "lsp-panel", .{});
    // Uma região filha: fica acima da conversa e não tira o foco do campo.
    const outer_pad: f32 = 10;
    const outer = r.inset(-outer_pad, -outer_pad);
    c.ImGui_SetCursorScreenPos(d.v(outer.x, outer.y));
    _ = c.ImGui_BeginChild("##lsp-panel", d.v(outer.w, outer.h), 0, c.ImGuiWindowFlags_NoBackground | c.ImGuiWindowFlags_NoScrollbar | c.ImGuiWindowFlags_NoScrollWithMouse | c.ImGuiWindowFlags_NoNav | c.ImGuiWindowFlags_NoInputs);
    defer c.ImGui_EndChild();
    const dl = c.ImGui_GetWindowDrawList();
    const radius = @max(ctx.th.radius + 4, 4);
    d.shadow(dl, r, radius, 8, ctx.col(.shadow).alpha(0.5));
    d.rect(dl, r, ctx.col(.elevated).mix(ctx.col(.surface), 0.35), radius);
    d.border(dl, r, ctx.col(.border), radius, 1);
    var y = r.y + pad;
    const fs: f32 = 13;
    const reg = fam.get(.regular);
    const bold = fam.get(.semibold);
    if (status) |t| {
        qa.mark(.{ .x = r.x, .y = y, .w = r.w, .h = row_h }, "lsp-status", .{});
        _ = d.textClipped(dl, reg, fs, r.x + 12, y + 2, if (st.state == .failed) ctx.col(.danger) else ctx.col(.muted), t, r.w - 24);
        y += row_h;
    }
    for (diags.items[0..shown], 0..) |*g, i| {
        const row: d.Rect = .{ .x = r.x, .y = y, .w = r.w, .h = row_h };
        const color = severityColor(ctx, g.severity);
        // A linha da caixa: quem digita conta do começo da mensagem.
        const line = first_line +| g.line +| 1;
        qa.mark(row, "lsp-diag:{d}:L{d}:{t}", .{ i, line, g.severity });
        var nb: [24]u8 = undefined;
        const num = std.fmt.bufPrint(&nb, "L{d}", .{line}) catch "";
        var tx = r.x + 12;
        d.text(dl, bold, fs, tx, y + 2, ctx.col(.muted), num);
        tx += @max(d.width(bold, fs, num) + 8, 36);
        const word = severityWord(g.severity);
        d.text(dl, bold, fs, tx, y + 2, color, word);
        tx += @max(d.width(bold, fs, word) + 8, 48);
        _ = d.textClipped(dl, reg, fs, tx, y + 2, ctx.col(.text), g.message(), r.right() - 12 - tx);
        y += row_h;
    }
    if (more > 0) {
        var mb: [32]u8 = undefined;
        d.text(dl, reg, fs, r.x + 12, y + 2, ctx.col(.faint), i18n.fmt(&mb, "+{d} no bloco", "+{d} in this block", .{more}));
    }
}

// --- Sublinhado no texto ----------------------------------------------------------

/// Faixa de bytes de um diagnóstico no texto da caixa. Linha que não existe mais
/// (o texto mudou e a resposta ainda não veio): null.
fn byteRange(text: []const u8, g: *const L.Diag) ?[2]usize {
    if (g.line >= 4096) return null;
    const n = first_line + g.line;
    const line = L.lineAt(text, n) orelse return null;
    const base = @intFromPtr(line.ptr) - @intFromPtr(text.ptr);
    const a = L.utf16ToByte(line, g.col);
    var b = if (g.end_line == g.line) L.utf16ToByte(line, g.end_col) else line.len;
    // Faixa vazia: o caractere dali, inteiro.
    if (b <= a) b = a + (if (a < line.len) std.unicode.utf8ByteSequenceLength(line[a]) catch 1 else 1);
    return .{ base + a, base + b };
}

/// O ImGui quebra as linhas desta caixa com `ImFontCalcWordWrapPositionEx`, na
/// largura interna menos a barra de rolagem (imgui_widgets.cpp, `wrap_width`). As
/// linhas e as colunas aqui saem da mesma conta, então o traço cai no lugar. Se o
/// texto precisa rolar dentro da caixa, a posição dependeria do estado interno da
/// caixa: aí fica só a lista.
fn squiggles(ctx: *d.Ctx, dl: *c.ImDrawList, font: *c.ImFont, frame: d.Rect, font_px: f32, text: []const u8) void {
    if (text.len == 0) return;
    const style = c.ImGui_GetStyle();
    const pad_x = style.*.FramePadding.x;
    const pad_y = style.*.FramePadding.y;
    const wrap_w = @max(1, frame.w - pad_x * 2 - style.*.ScrollbarSize);
    const start: [*]const u8 = text.ptr;
    const end: [*]const u8 = text.ptr + text.len;

    var ranges: [L.max_diags]?[2]usize = undefined;
    for (diags.items[0..diags.n], 0..) |*g, i| ranges[i] = byteRange(text, g);

    const visible = @floor((frame.h - pad_y * 2) / font_px + 0.25);
    var pass: u8 = 0;
    while (pass < 2) : (pass += 1) {
        var row: f32 = 0;
        var at: usize = 0;
        while (at < text.len) : (row += 1) {
            const stop_ptr = sigma_input_wrap(font, font_px, start + at, end, wrap_w);
            var stop = @intFromPtr(stop_ptr) - @intFromPtr(start);
            if (stop <= at and text[at] != '\n') stop = at + 1;
            if (pass == 1) {
                const y = frame.y + pad_y + row * font_px + font_px - 1;
                for (diags.items[0..diags.n], ranges[0..diags.n]) |*g, range| {
                    const rg = range orelse continue;
                    if (rg[0] > stop or rg[1] <= at) continue;
                    if (rg[0] == stop and stop < text.len and text[stop] != '\n') continue;
                    const a = @max(rg[0], at);
                    const b = @min(rg[1], stop);
                    const x0 = frame.x + pad_x + rowWidth(font, font_px, text[at..a]);
                    var x1 = frame.x + pad_x + rowWidth(font, font_px, text[at..b]);
                    // Erro depois do último caractere: marca o tamanho de uma letra.
                    if (x1 < x0 + font_px * 0.5) x1 = x0 + font_px * 0.5;
                    zigzag(dl, x0, x1, y, severityColor(ctx, g.severity));
                }
            }
            at = if (stop < text.len and text[stop] == '\n') stop + 1 else stop;
        }
        if (pass == 0 and row > visible) return;
    }
    qa.mark(frame, "lsp-squiggles", .{});
}

fn rowWidth(font: *c.ImFont, font_px: f32, s: []const u8) f32 {
    if (s.len == 0) return 0;
    const b: [*]const u8 = s.ptr;
    return c.ImFont_CalcTextSizeAEx(font, font_px, std.math.floatMax(f32), 0, b, b + s.len, null).x;
}

fn zigzag(dl: *c.ImDrawList, x0: f32, x1: f32, y: f32, color: d.Rgba) void {
    const step: f32 = 2.5;
    var x = x0;
    var up = false;
    while (x < x1) : (x += step) {
        const nx = @min(x + step, x1);
        const y0: f32 = if (up) y - 1.5 else y;
        const y1: f32 = if (up) y else y - 1.5;
        d.line(dl, x, y0, nx, y1, color, 1);
        up = !up;
    }
}
