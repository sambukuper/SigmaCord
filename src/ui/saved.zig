//! Tela "Salvas" (Ctrl+Shift+S ou o botão do cabeçalho): as mensagens
//! salvas pelo menu do botão direito, cada uma com uma anotação editável.
//! Também lê e grava o arquivo (~/.config/sigmacord/saved-<conta>.json,
//! com permissão 600: são cópias de conversas). Nada disso vai para o Discord.
const std = @import("std");
const c = @import("c");
const d = @import("draw.zig");
const qa = @import("qa.zig");
const w = @import("widgets.zig");
const icons = @import("icons.zig");
const i18n = @import("i18n.zig");
const popup = @import("popup.zig");
const inbox = @import("inbox.zig");
const saved = @import("../core/saved.zig");
const Id = @import("../core/types.zig").Id;
const fsutil = @import("../platform/fsutil.zig");

/// Anotação sendo editada (0 = nenhuma) e o texto da caixa.
var editing: Id = 0;
var note_buf: [saved.max_note + 1]u8 = @splat(0);
var focus_note = false;

/// Editando uma anotação: o Esc cancela a edição em vez de fechar a tela.
pub fn isEditing() bool {
    return editing != 0;
}

// --- Arquivo ---------------------------------------------------------------------

fn path(buf: []u8, owner: Id) ?[:0]const u8 {
    // O QA nunca mexe na configuração de verdade.
    if (qa.on()) return std.fmt.bufPrintSentinel(buf, "qa-out/saved-{d}.json", .{owner}, 0) catch null;
    var nbuf: [48]u8 = undefined;
    return fsutil.configPath(buf, std.fmt.bufPrint(&nbuf, "saved-{d}.json", .{owner}) catch return null);
}

/// Caminho do arquivo da conta (o QA confere o que foi gravado).
pub fn filePath(buf: []u8, owner: Id) ?[:0]const u8 {
    return path(buf, owner);
}

/// Troca para a lista da conta que entrou. `read_file` false: começa vazia
/// (QA e prints, para serem reprodutíveis).
pub fn load(list: *saved.List, gpa: std.mem.Allocator, owner: Id, read_file: bool) void {
    if (list.owner == owner) return;
    list.clear(gpa);
    list.owner = owner;
    editing = 0;
    if (!read_file) return;
    var buf: [512]u8 = undefined;
    const p = path(&buf, owner) orelse return;
    var size: usize = 0;
    const data = c.SDL_LoadFile(p.ptr, &size) orelse return;
    defer c.SDL_free(data);
    list.read(gpa, @as([*]const u8, @ptrCast(data))[0..size]) catch |err| {
        std.log.warn("mensagens salvas: não consegui ler {s} ({t})", .{ p, err });
        fsutil.keepBroken(p);
    };
}

/// Grava a lista (num arquivo temporário e depois troca, para uma queda no
/// meio não estragar o que já estava salvo).
pub fn persist(list: *const saved.List, gpa: std.mem.Allocator) void {
    if (list.owner == 0) return;
    var buf: [512]u8 = undefined;
    const p = path(&buf, list.owner) orelse return;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    list.write(gpa, &out) catch return;
    if (!fsutil.writePrivate(p, out.items)) std.log.warn("mensagens salvas: não consegui gravar {s}", .{p});
}

// --- Tela ------------------------------------------------------------------------

fn startEdit(it: *const saved.Item) void {
    editing = it.id;
    focus_note = true;
    @memset(&note_buf, 0);
    const n = @min(it.note.len, note_buf.len - 1);
    @memcpy(note_buf[0..n], it.note[0..n]);
}

fn commit(ctx: *d.Ctx) void {
    const id = editing;
    editing = 0;
    const t = std.mem.sliceTo(&note_buf, 0);
    const owned = ctx.st.gpa.dupe(u8, t) catch return;
    ctx.act(.{ .saved_note = .{ .id = id, .text = owned } });
}

pub fn draw(ctx: *d.Ctx) void {
    // Abriu de novo: a edição que ficou pela metade (clicou fora) some.
    if (popup.appearing) editing = 0;
    const r = inbox.panelRect(ctx);
    const dl = popup.beginWindow("##saved", r);
    defer c.ImGui_End();
    ctx.dl = dl;
    inbox.panelFrame(ctx, dl, r);
    const fam = ctx.ui;
    const list = &ctx.st.saved;

    icons.bookmark(dl, r.x + 26, r.y + 27, ctx.col(.text).u(), true);
    const title = i18n.tr("Mensagens salvas", "Saved messages");
    d.text(dl, fam.get(.bold), 17, r.x + 44, r.y + 16, ctx.col(.text), title);
    var cb: [32]u8 = undefined;
    const tw = d.width(fam.get(.bold), 17, title);
    d.text(dl, fam.get(.regular), 13, r.x + 44 + tw + 10, r.y + 20, ctx.col(.faint), std.fmt.bufPrint(&cb, "{d}", .{list.items.items.len}) catch "");
    d.text(dl, fam.get(.regular), 12, r.x + 18, r.y + 46, ctx.col(.faint), i18n.tr("Só neste computador: nada disso vai para o Discord.", "Only on this computer: none of this goes to Discord."));
    d.line(dl, r.x, r.y + 70, r.right(), r.y + 70, ctx.col(.border), 1);

    if (editing != 0 and c.ImGui_IsKeyPressed(c.ImGuiKey_Escape)) editing = 0;

    const body: d.Rect = .{ .x = r.x + 1, .y = r.y + 71, .w = r.w - 2, .h = r.h - 77 };
    const bdl = d.beginRegion(ctx, "##saved-body", body, 0);
    ctx.dl = bdl;
    const o = c.ImGui_GetCursorScreenPos();
    var y = o.y + 10;
    if (list.items.items.len == 0) {
        const t1 = i18n.tr("Nenhuma mensagem salva ainda.", "No saved messages yet.");
        const t2 = i18n.tr("Botão direito numa mensagem → Salvar mensagem.", "Right-click a message → Save Message.");
        const w1 = d.width(fam.get(.bold), 16, t1);
        const w2 = d.width(fam.get(.regular), 13.5, t2);
        d.text(bdl, fam.get(.bold), 16, body.x + (body.w - w1) / 2, y + 70, ctx.col(.text), t1);
        d.text(bdl, fam.get(.regular), 13.5, body.x + @max(12, (body.w - w2) / 2), y + 96, ctx.col(.muted), t2);
        qa.mark(.{ .x = body.x, .y = y + 70, .w = body.w, .h = 44 }, "saved-empty", .{});
        y += 140;
    }
    // Remover é uma ação (aplicada depois do quadro): a lista não muda aqui.
    // Cartões fora da tela só contam a altura (até 500 refazendo a prévia a
    // cada quadro pesava com o painel aberto).
    if (heights_w != body.w or heights_n != list.items.items.len) {
        heights = @splat(0);
        heights_w = body.w;
        heights_n = list.items.items.len;
    }
    for (list.items.items, 0..) |*it, i| {
        const known = if (i < heights.len) heights[i] else 0;
        if (known > 0 and editing != it.id and (y + known < body.y - 64 or y > body.bottom() + 64)) {
            y += known;
            continue;
        }
        const y1 = item(ctx, bdl, body, y, it, i);
        if (i < heights.len) heights[i] = y1 - y;
        y = y1;
    }
    d.endRegion(ctx, y + 6, body.x);
    ctx.dl = dl;
}

var heights: [512]f32 = @splat(0);
var heights_w: f32 = 0;
var heights_n: usize = 0;

/// Um cartão: de onde veio, autor e texto, a anotação e os botões.
fn item(ctx: *d.Ctx, dl: *c.ImDrawList, body: d.Rect, y0: f32, it: *const saved.Item, index: usize) f32 {
    const fam = ctx.ui;
    const x = body.x + 12;
    const wd = body.w - 24;
    var y = y0;
    const card_top = y;
    const inner = x + 12;
    const iw = wd - 24;
    y += 10;

    // De onde veio + data.
    var lb: [160]u8 = undefined;
    const where = if (it.guild == 0)
        (std.fmt.bufPrint(&lb, "@{s}", .{it.channel_name}) catch it.channel_name)
    else
        (std.fmt.bufPrint(&lb, "#{s}  ·  {s}", .{ it.channel_name, it.guild_name }) catch it.channel_name);
    var tb: [48]u8 = undefined;
    const when = w.stamp(&tb, it.timestamp, @divTrunc(ctx.now_ms, 1000));
    const ww = d.width(fam.get(.regular), 12, when);
    _ = d.textClipped(dl, fam.get(.semibold), 12, inner, y, ctx.col(.muted), where, iw - ww - 12);
    d.text(dl, fam.get(.regular), 12, inner + iw - ww, y, ctx.col(.faint), when);
    y += 22;

    // Autor e texto.
    const gid = it.guild;
    w.avatar(ctx, dl, inner + 12, y + 12, 24, it.author, .circle, null, 1);
    const saved_nw = d.textClipped(dl, fam.get(.semibold), 14, inner + 32, y + 2, w.nameColor(ctx, gid, it.author), it.author_name, iw - 32 - w.botTagSpace(ctx, ctx.store.user(it.author), false));
    _ = w.botTag(ctx, dl, inner + 32 + saved_nw, y + 10, ctx.store.user(it.author), false, 1);
    y += 24;
    var pb: [600]u8 = undefined;
    const sm: @import("../core/store.zig").StoredMessage = .{ .msg = .{ .id = it.id, .channel = it.channel, .author = it.author, .timestamp = it.timestamp, .content = it.content }, .spans = it.spans };
    const text = inbox.previewText(ctx, &pb, &sm);
    y += inbox.wrapText(dl, fam.get(.regular), 14, inner + 32, y, iw - 32, text, 4, ctx.col(.text).mix(ctx.col(.muted), 0.15));
    y += 8;

    // Anotação.
    const nx = inner;
    const nw = iw;
    if (editing == it.id) {
        const ir: d.Rect = .{ .x = nx, .y = y, .w = nw, .h = 34 };
        d.rect(dl, ir, ctx.col(.elevated), @max(ctx.th.radius, 4));
        d.border(dl, ir, ctx.col(.accent).alpha(0.7), @max(ctx.th.radius, 4), 1);
        qa.mark(ir, "saved-note-input", .{});
        c.ImGui_PushFontFloat(fam.get(.regular), 14);
        c.ImGui_SetCursorScreenPos(d.v(ir.x + 10, ir.y + 8));
        c.ImGui_SetNextItemWidth(ir.w - 20);
        if (focus_note) {
            c.ImGui_SetKeyboardFocusHere();
            focus_note = false;
        }
        const hint = i18n.trZ("Escreva uma anotação… (Enter salva, Esc cancela)", "Write a note… (Enter saves, Esc cancels)");
        if (c.ImGui_InputTextWithHint("##note", hint.ptr, &note_buf, note_buf.len, c.ImGuiInputTextFlags_EnterReturnsTrue)) commit(ctx);
        c.ImGui_PopFont();
        y += 40;
        const sl = i18n.tr("Salvar anotação", "Save note");
        const sr: d.Rect = .{ .x = nx, .y = y, .w = inbox.buttonWidth(ctx, sl), .h = 26 };
        qa.mark(sr, "saved-note-save", .{});
        if (inbox.button(ctx, dl, 3000 + index * 8, sr, sl, false)) commit(ctx);
        const cl = i18n.tr("Cancelar", "Cancel");
        const cr: d.Rect = .{ .x = sr.right() + 8, .y = y, .w = inbox.buttonWidth(ctx, cl), .h = 26 };
        qa.mark(cr, "saved-note-cancel", .{});
        if (inbox.button(ctx, dl, 3000 + index * 8 + 1, cr, cl, false)) editing = 0;
        y += 34;
    } else {
        const has = it.note.len > 0;
        const text_h = if (has) inbox.wrapText(null, fam.get(.italic), 13.5, nx + 12, y, nw - 16, it.note, 6, ctx.col(.text)) else 20;
        const nr: d.Rect = .{ .x = nx, .y = y, .w = nw, .h = text_h + 8 };
        const hb = d.hit(ctx, 3000 + index * 8 + 2, nr);
        qa.mark(nr, "saved-note:{d}", .{it.id});
        if (hb.hovered) d.rect(dl, nr, ctx.col(.hover), @max(ctx.th.radius - 2, 3));
        if (has) {
            d.rect(dl, .{ .x = nx, .y = y + 2, .w = 3, .h = text_h + 4 }, ctx.col(.accent), 1.5);
            _ = inbox.wrapText(dl, fam.get(.italic), 13.5, nx + 12, y + 4, nw - 16, it.note, 6, ctx.col(.text).mix(ctx.col(.accent), 0.2));
        } else {
            d.text(dl, fam.get(.medium), 13, nx + 4, y + 4, if (hb.hovered) ctx.col(.text) else ctx.col(.faint), i18n.tr("+ Adicionar anotação", "+ Add a note"));
        }
        if (hb.clicked) startEdit(it);
        d.tip(ctx, nr, if (has) i18n.tr("Editar anotação", "Edit note") else i18n.tr("Adicionar anotação", "Add a note"), hb.hovered and has);
        y += nr.h + 8;

        // Ações.
        const labels = [_][]const u8{ i18n.tr("Ir para a mensagem", "Jump to message"), i18n.tr("Copiar link", "Copy link"), i18n.tr("Remover", "Remove") };
        var bx = nx;
        for (labels, 0..) |lbl, k| {
            const br: d.Rect = .{ .x = bx, .y = y, .w = inbox.buttonWidth(ctx, lbl), .h = 26 };
            switch (k) {
                0 => qa.mark(br, "saved-open:{d}", .{it.id}),
                1 => qa.mark(br, "saved-link:{d}", .{it.id}),
                else => qa.mark(br, "saved-remove:{d}", .{it.id}),
            }
            if (inbox.button(ctx, dl, 3000 + index * 8 + 3 + k, br, lbl, k == 2)) switch (k) {
                0 => inbox.openMessage(ctx, it.channel, it.id),
                1 => if (ctx.st.gpa.dupe(u8, it.link)) |s| ctx.act(.{ .copy = s }) else |_| {},
                else => ctx.act(.{ .unsave_message = it.id }),
            };
            bx = br.right() + 8;
        }
        y += 34;
    }
    const card: d.Rect = .{ .x = x, .y = card_top, .w = wd, .h = y - card_top };
    d.border(dl, card, ctx.col(.border), @max(ctx.th.radius, 6), 1);
    return y + 10;
}
