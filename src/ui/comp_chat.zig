//! Componentes do topo do chat: `header` e `tabs`.
//! (mensagens e caixa de texto ficam em comp_messages.zig)
//!
//! header:   variant = discord | minimal | tty
//! tabs:     variant = pills | underline | tty
const std = @import("std");
const c = @import("c");
const kdl = @import("../theme/kdl.zig");
const d = @import("draw.zig");
const qa = @import("qa.zig");
const anim = @import("anim.zig");
const w = @import("widgets.zig");
const icons = @import("icons.zig");
const i18n = @import("i18n.zig");
const plugin_panel = @import("plugin_panel.zig");
const engine = @import("../plugins/engine.zig");
const types = @import("../core/types.zig");
const Id = types.Id;

// --- header -----------------------------------------------------------------

pub fn header(ctx: *d.Ctx, n: *const kdl.Node, r: d.Rect) void {
    if (ctx.st.friends) return @import("comp_friends.zig").header(ctx, n, r);
    const fam = ctx.familyFor(n);
    const ch_id = ctx.st.activeChannel() orelse return;
    const cs = ctx.store.channel(ch_id) orelse return;
    const ch = &cs.info;
    const variant = d.pstr(n, "variant", "discord");
    const dl = ctx.dl;
    // Numa DM o nome do canal é o da pessoa: é ela quem pode ser um bot.
    const dm_user = if (ch.guild == 0 and !ch.group) ctx.store.user(ch.recipient) else null;

    if (std.mem.eql(u8, variant, "tty")) {
        var buf: [160]u8 = undefined;
        const t = std.fmt.bufPrint(&buf, "─ {s}{s}{s} ─ {s} ", .{ sigil(ch), ch.name, w.botSuffix(dm_user), ch.topic }) catch ch.name;
        if (dm_user != null and dm_user.?.bot) qa.mark(r, "bot-tag:{d}", .{dm_user.?.id});
        const fs = ctx.th.font_size - 1;
        // O alfinete à direita, em texto como o resto da linha.
        const pl = "[pin]";
        const pw = d.width(fam.get(.bold), fs, pl);
        const pr: d.Rect = .{ .x = r.right() - pw - 8, .y = r.y, .w = pw + 4, .h = r.h };
        // O que fica à direita do título: o alfinete e, se algum plugin tem, os painéis.
        var right_x = pr.x;
        if (plugin_panel.available()) {
            const xl = "[+]";
            const xw = d.width(fam.get(.bold), fs, xl);
            const xr: d.Rect = .{ .x = pr.x - xw - 8, .y = r.y, .w = xw + 4, .h = r.h };
            const xh = d.hit(ctx, 7, xr);
            qa.mark(xr, "header-plugins", .{});
            if (xh.clicked) plugin_panel.toggleAny();
            d.text(dl, fam.get(.bold), fs, xr.x + 2, d.centerY(r, fs), if (xh.hovered or panelOpen()) ctx.col(.text) else ctx.col(.muted), xl);
            d.tip(ctx, xr, i18n.tr("Painéis dos plugins", "Plugin panels"), xh.hovered);
            right_x = xr.x;
        }
        const ph = d.hit(ctx, 6, pr);
        qa.mark(pr, "header-pins", .{});
        if (ph.clicked) ctx.act(.{ .open_pins = ch_id });
        d.text(dl, fam.get(.bold), fs, pr.x + 2, d.centerY(r, fs), if (ph.hovered) ctx.col(.text) else ctx.col(.muted), pl);
        d.tip(ctx, pr, i18n.tr("Mensagens fixadas", "Pinned messages"), ph.hovered);
        const tw = d.textClipped(dl, fam.get(.bold), fs, r.x + 6, d.centerY(r, fs), ctx.col(.accent), t, right_x - r.x - 14);
        const ly = r.y + r.h / 2;
        d.line(dl, r.x + 6 + tw + 4, ly, right_x - 4, ly, ctx.col(.border), 1);
        return;
    }
    if (std.mem.eql(u8, variant, "minimal")) {
        const g = ctx.store.guild(ch.guild);
        var buf: [128]u8 = undefined;
        const t = std.fmt.bufPrint(&buf, "{s}", .{ch.name}) catch "";
        d.text(dl, fam.get(.bold), 22, r.x + 4, r.y + r.h / 2 - 22, ctx.col(.text), t);
        _ = w.botTag(ctx, dl, r.x + 4 + d.width(fam.get(.bold), 22, t), r.y + r.h / 2 - 9, dm_user, false, 1);
        const sub = if (ch.guild == 0) i18n.tr("mensagem direta", "direct message") else d.printClip(&buf, "{s}  ·  {s}", .{ if (g) |x| x.name else "", ch.topic });
        const has_panels = plugin_panel.available();
        const needs_gear = !ctx.th.has_user_panel;
        _ = d.textClipped(dl, fam.get(.regular), 13, r.x + 4, r.y + r.h / 2 + 5, ctx.col(.faint), sub, r.w - (if (has_panels) @as(f32, 156) else 120) - (if (needs_gear) @as(f32, 36) else 0));
        if (ch.guild == 0) callButton(ctx, dl, ch_id, r.right() - (if (has_panels) @as(f32, 248) else 212), r.y + r.h / 2 - 14);
        inboxButtons(ctx, dl, r.right() - 32, r.y + r.h / 2 - 14);
        pinsButton(ctx, dl, ch_id, r.right() - 104, r.y + r.h / 2 - 14);
        if (has_panels) panelsButton(ctx, dl, r.right() - 140, r.y + r.h / 2 - 14);
        if (needs_gear) {
            const gr: d.Rect = .{ .x = r.right() - (if (has_panels) @as(f32, 176) else 140), .y = r.y + r.h / 2 - 14, .w = 28, .h = 28 };
            const gh = d.hit(ctx, 9, gr);
            qa.mark(gr, "header-settings", .{});
            if (gh.clicked) ctx.act(.open_settings);
            icons.gear(dl, gr.x + 14, gr.y + 14, (if (gh.hovered) ctx.col(.text) else ctx.col(.muted)).u());
            d.tip(ctx, gr, i18n.tr("Configurações  (Ctrl+,)", "User Settings  (Ctrl+,)"), gh.hovered);
        }
        return;
    }

    d.text(dl, fam.get(.medium), 22, r.x + 17, d.centerY(r, 22), ctx.col(.faint), sigil(ch));
    // Conversa estreita (painéis alargados, tela dividida): a caixa de busca sai
    // primeiro; os botões ficam, e Ctrl+K continua abrindo a paleta.
    const search_w: f32 = if (r.w < 560) 0 else 180;
    const sx = r.right() - (if (search_w > 0) 16 + search_w else 4);
    // Título longo (post de fórum) corta com "…": os botões e o canal pai ficam.
    // Apertado demais (o próprio painel aberto pode tirar o lugar): o botão sai e o
    // nome do canal fica. Os painéis continuam na paleta e nas configurações.
    const has_panels = plugin_panel.available() and sx - 220 >= r.x + 42 + 60;
    const panels_w: f32 = if (has_panels) 36 else 0;
    const name_room = if (search_w > 0) @max(80, sx - (r.x + 42) - 14 - 214 - 110 - panels_w) else @max(sx - 192 - panels_w - (r.x + 42), 40);
    const name_w = d.textClipped(dl, fam.get(.semibold), 16, r.x + 42, d.centerY(r, 16), ctx.col(.text), ch.name, name_room - w.botTagSpace(ctx, dm_user, false));
    const tx = r.x + 42 + name_w + w.botTag(ctx, dl, r.x + 42 + name_w, r.y + r.h / 2, dm_user, false, 1) + 14;
    // Da direita para a esquerda: busca, membros, buscar mensagens, salvas, caixa de entrada, fixadas.
    // Numa thread, no lugar do tópico: o canal pai, e clicar volta para ele.
    const parent_cs = if (ch.thread != null and ch.parent != null) ctx.store.channel(ch.parent.?) else null;
    if (parent_cs) |pcs| {
        if (sx - tx > 222 + panels_w) {
            var pb: [120]u8 = undefined;
            const lbl = d.printClip(&pb, "{s}{s}", .{ sigil(&pcs.info), pcs.info.name });
            d.rect(dl, .{ .x = tx, .y = r.y + r.h / 2 - 10, .w = 1, .h = 20 }, ctx.col(.border).mix(ctx.col(.text), 0.05), 0);
            const room = sx - tx - 214 - panels_w;
            const pr: d.Rect = .{ .x = tx + 14, .y = r.y + r.h / 2 - 12, .w = @min(d.width(fam.get(.regular), 14, lbl), room), .h = 24 };
            const ph = d.hit(ctx, 6, pr);
            qa.mark(pr, "header-parent", .{});
            if (ph.clicked) ctx.act(.{ .select_channel = pcs.info.id });
            _ = d.textClipped(dl, fam.get(.regular), 14, pr.x, d.centerY(r, 14), if (ph.hovered) ctx.col(.text) else ctx.col(.muted), lbl, room);
        }
    } else if (ch.topic.len > 0 and sx - tx > 222 + panels_w) {
        d.rect(dl, .{ .x = tx, .y = r.y + r.h / 2 - 10, .w = 1, .h = 20 }, ctx.col(.border).mix(ctx.col(.text), 0.05), 0);
        _ = d.textClipped(dl, fam.get(.regular), 14, tx + 14, d.centerY(r, 14), ctx.col(.muted), ch.topic, sx - tx - 214 - panels_w);
    }
    // Com a caixa de busca, a lupa pequena não aparece, e os botões ocupam o lugar dela.
    const no_find: f32 = if (search_w > 0) 36 else 0;
    inboxButtons(ctx, dl, sx - 112 + no_find, r.y + r.h / 2 - 14);
    pinsButton(ctx, dl, ch_id, sx - 184 + no_find, r.y + r.h / 2 - 14);
    if (has_panels) panelsButton(ctx, dl, sx - 220 + no_find, r.y + r.h / 2 - 14);
    if (ch.guild == 0) callButton(ctx, dl, ch_id, sx - 256 + no_find, r.y + r.h / 2 - 14);
    if (search_w > 0) {
        const sr: d.Rect = .{ .x = sx, .y = r.y + r.h / 2 - 13, .w = search_w, .h = 26 };
        const sh = d.hit(ctx, 1, sr);
        qa.mark(sr, "header-find", .{});
        const search = @import("search.zig");
        if (sh.clicked) search.focusOrStart();
        d.tip(ctx, sr, i18n.tr("Buscar mensagens (Ctrl+F)", "Search messages (Ctrl+F)"), sh.hovered);
        const sk = anim.to(anim.id("search", @intFromPtr(n)), if (sh.hovered or search.open) 1 else 0, 20);
        d.rect(dl, sr, ctx.col(.rail).mix(ctx.col(.sidebar), 0.3 + 0.3 * sk), ctx.th.radius);
        if (search.open) d.border(dl, sr, ctx.col(.accent).alpha(0.7), ctx.th.radius, 1);
        const label: []const u8 = if (search.open and search.text().len > 0) search.text() else i18n.tr("Buscar  Ctrl+F", "Search  Ctrl+F");
        _ = d.textClipped(dl, fam.get(.regular), 14, sr.x + 9, d.centerY(sr, 14), ctx.col(.faint).mix(ctx.col(.muted), sk), label, sr.w - 34);
        icons.search(dl, sr.right() - 15, sr.y + 13, ctx.col(.faint).mix(ctx.col(.muted), sk).u());
    } else {
        // Sem lugar para a caixa: a lupa.
        const fr: d.Rect = .{ .x = sx - 76, .y = r.y + r.h / 2 - 14, .w = 28, .h = 28 };
        const fh = d.hit(ctx, 5, fr);
        qa.mark(fr, "header-find", .{});
        if (fh.clicked) @import("search.zig").focusOrStart();
        icons.search(dl, fr.x + 14, fr.y + 14, (if (fh.hovered) ctx.col(.text) else ctx.col(.muted)).u());
        d.tip(ctx, fr, i18n.tr("Buscar mensagens (Ctrl+F)", "Search messages (Ctrl+F)"), fh.hovered);
    }
    const mr: d.Rect = .{ .x = sx - 40, .y = r.y + r.h / 2 - 14, .w = 28, .h = 28 };
    const mh = d.hit(ctx, 2, mr);
    qa.mark(mr, "header-members", .{});
    if (mh.clicked) ctx.st.settings.show_member_list = !ctx.st.settings.show_member_list;
    icons.members(dl, mr.x + 14, mr.y + 14, (if (ctx.st.settings.show_member_list or mh.hovered) ctx.col(.text) else ctx.col(.muted)).u());
    d.tip(ctx, mr, if (ctx.st.settings.show_member_list) i18n.tr("Esconder membros", "Hide Member List") else i18n.tr("Mostrar membros", "Show Member List"), mh.hovered);
    if (d.pflag(n, "divider", true)) d.line(dl, r.x, r.bottom() - 0.5, r.right(), r.bottom() - 0.5, ctx.col(.border), 1);
}

fn panelOpen() bool {
    const e = engine.current orelse return false;
    return e.panel_open != null;
}

/// Telefonar (DM e grupo): toca o ring e entra na call; em call, desliga.
fn callButton(ctx: *d.Ctx, dl: *c.ImDrawList, ch_id: Id, x: f32, y: f32) void {
    const in_call = ctx.st.voice == ch_id;
    const cr: d.Rect = .{ .x = x, .y = y, .w = 28, .h = 28 };
    const ch = d.hit(ctx, 8, cr);
    qa.mark(cr, "header-call", .{});
    if (ch.clicked) ctx.act(.{ .call_dm = ch_id });
    const ink = (if (in_call) ctx.col(.danger) else if (ch.hovered) ctx.col(.text) else ctx.col(.muted)).u();
    icons.phone(dl, cr.x + 14, cr.y + 14, ink);
    d.tip(ctx, cr, if (in_call) i18n.tr("Desligar a chamada", "Leave the call") else i18n.tr("Telefonar", "Call"), ch.hovered);
}

/// Abre e fecha o painel lateral dos plugins (só aparece se algum tem painel).
fn panelsButton(ctx: *d.Ctx, dl: *c.ImDrawList, x: f32, y: f32) void {
    const pr: d.Rect = .{ .x = x, .y = y, .w = 28, .h = 28 };
    const ph = d.hit(ctx, 7, pr);
    qa.mark(pr, "header-plugins", .{});
    if (ph.clicked) plugin_panel.toggleAny();
    const ink = (if (panelOpen() or ph.hovered) ctx.col(.text) else ctx.col(.muted));
    // Uma janela com a faixa do lado, como o painel.
    const box: d.Rect = .{ .x = pr.x + 6, .y = pr.y + 8, .w = 16, .h = 12 };
    d.border(dl, box, ink, 2, 1.4);
    d.rect(dl, .{ .x = box.right() - 6, .y = box.y, .w = 6, .h = box.h }, ink, 1);
    // Algum painel tem novidade (o plugin pôs um número na etiqueta).
    if (engine.current) |e| if (e.n_badges > 0) {
        d.circle(dl, pr.right() - 5, pr.y + 7, 3.5, ctx.col(.danger));
        qa.mark(pr, "header-plugins-badge", .{});
    };
    d.tip(ctx, pr, i18n.tr("Painéis dos plugins", "Plugin panels"), ph.hovered);
}

/// Alfinete: abre o painel de mensagens fixadas do canal.
fn pinsButton(ctx: *d.Ctx, dl: *c.ImDrawList, ch_id: Id, x: f32, y: f32) void {
    const pr: d.Rect = .{ .x = x, .y = y, .w = 28, .h = 28 };
    const ph = d.hit(ctx, 6, pr);
    qa.mark(pr, "header-pins", .{});
    if (ph.clicked) ctx.act(.{ .open_pins = ch_id });
    const open = ctx.st.popup == .pins;
    icons.pin(dl, pr.x + 14, pr.y + 14, (if (open or ph.hovered) ctx.col(.text) else ctx.col(.muted)).u());
    d.tip(ctx, pr, i18n.tr("Mensagens fixadas", "Pinned messages"), ph.hovered);
}

/// Caixa de entrada (com o número de não lidas) e mensagens salvas, da
/// direita para a esquerda a partir de `right_x` (o canto do mais à direita).
fn inboxButtons(ctx: *d.Ctx, dl: *c.ImDrawList, right_x: f32, y: f32) void {
    const ir: d.Rect = .{ .x = right_x - 36, .y = y, .w = 28, .h = 28 };
    const ih = d.hit(ctx, 3, ir);
    qa.mark(ir, "header-inbox", .{});
    if (ih.clicked) ctx.act(.toggle_inbox);
    const open = ctx.st.popup == .inbox;
    icons.inbox(dl, ir.x + 14, ir.y + 14, (if (open or ih.hovered) ctx.col(.text) else ctx.col(.muted)).u());
    const n = @import("inbox.zig").unreadCount(ctx);
    if (n > 0) {
        var nb: [8]u8 = undefined;
        const lbl = std.fmt.bufPrint(&nb, "{d}", .{@min(n, 99)}) catch "";
        const font = ctx.ui.get(.bold);
        const lw = d.width(font, 10.5, lbl);
        const bw = @max(15, lw + 8);
        const br: d.Rect = .{ .x = ir.right() - bw + 4, .y = ir.y - 2, .w = bw, .h = 15 };
        d.rect(dl, br.inset(-2, -2), ctx.col(.surface), 9);
        d.rect(dl, br, ctx.col(.danger), 7.5);
        d.text(dl, font, 10.5, br.x + (bw - lw) / 2, br.y + 0.5, d.Rgba.white, lbl);
    }
    d.tip(ctx, ir, i18n.tr("Caixa de entrada  Ctrl+I", "Inbox  Ctrl+I"), ih.hovered);

    const sr: d.Rect = .{ .x = right_x, .y = y, .w = 28, .h = 28 };
    const sh = d.hit(ctx, 4, sr);
    qa.mark(sr, "header-saved", .{});
    if (sh.clicked) ctx.act(.toggle_saved);
    const sopen = ctx.st.popup == .saved;
    icons.bookmark(dl, sr.x + 14, sr.y + 14, (if (sopen or sh.hovered) ctx.col(.text) else ctx.col(.muted)).u(), sopen);
    d.tip(ctx, sr, i18n.tr("Mensagens salvas  Ctrl+Shift+S", "Saved messages  Ctrl+Shift+S"), sh.hovered);
}

// --- tabs -------------------------------------------------------------------

pub fn tabs(ctx: *d.Ctx, n: *const kdl.Node, r: d.Rect) void {
    const fam = ctx.familyFor(n);
    const variant = d.pstr(n, "variant", "pills");
    const tty = std.mem.eql(u8, variant, "tty");
    const underline = std.mem.eql(u8, variant, "underline");
    const dl = ctx.dl;
    const fs: f32 = if (tty) ctx.th.font_size - 1 else 14;
    var x = r.x + (if (tty) @as(f32, 4) else 8);
    var buf: [96]u8 = undefined;

    for (ctx.st.tabs.items, 0..) |id, i| {
        const cs = ctx.store.channel(id) orelse continue;
        const g = ctx.store.guild(cs.info.guild);
        const active = i == ctx.st.tab;
        const lbl = if (tty)
            d.printClip(&buf, " {d}:{s}{s} ", .{ i + 1, sigil(&cs.info), cs.info.name })
        else
            d.printClip(&buf, "{s}{s}", .{ sigil(&cs.info), cs.info.name });
        const font = fam.get(if (active) .semibold else .medium);
        const tw = d.width(font, fs, lbl);
        const acr = if (g) |x_| x_.acronym else "DM";
        const acr_w = if (tty) 0 else d.width(fam.get(.bold), 10, acr) + 10;
        const tab_w = if (tty) tw else tw + acr_w + 40;
        if (x + tab_w > r.right() - 40) break;
        const h: f32 = if (tty) r.h else r.h - 10;
        const tr: d.Rect = .{ .x = x, .y = r.y + (r.h - h) / 2, .w = tab_w, .h = h };
        const hb = d.hit(ctx, i, tr);
        qa.mark(tr, "tab:{d}", .{i});
        if (hb.clicked) ctx.act(.{ .focus_tab = i });
        if (hb.middle) ctx.act(.{ .close_tab = i });
        const k = anim.to(anim.id("tab", id), if (active) 1 else if (hb.hovered) 0.4 else 0, 20);

        if (tty) {
            if (active) d.rect(dl, tr, ctx.col(.accent), 0) else if (hb.hovered) d.rect(dl, tr, ctx.col(.hover), 0);
            d.text(dl, font, fs, x, d.centerY(tr, fs), if (active) ctx.col(.accent_text) else if (cs.info.unread) ctx.col(.text) else ctx.col(.muted), lbl);
            x += tab_w + 2;
            continue;
        }
        if (underline) {
            d.rect(dl, tr, ctx.col(.hover).alpha(k * 0.6), ctx.th.radius);
            if (k > 0.5) d.rect(dl, .{ .x = tr.x + 10, .y = r.bottom() - 2, .w = tr.w - 20, .h = 2 }, ctx.col(.accent).alpha((k - 0.5) * 2), 1);
        } else {
            d.rect(dl, tr, ctx.col(.selected).alpha(k), tr.h / 2);
            if (active) d.border(dl, tr, ctx.col(.accent).alpha(0.45), tr.h / 2, 1);
        }
        // Sigla do servidor + nome do canal.
        const ar: d.Rect = .{ .x = tr.x + 8, .y = tr.y + tr.h / 2 - 9, .w = acr_w, .h = 18 };
        d.rect(dl, ar, (if (g) |gg| ctx.th.role(gg.color) else ctx.col(.accent)).alpha(0.75), 5);
        d.text(dl, fam.get(.bold), 10, ar.x + 5, d.centerY(ar, 10), d.Rgba.white, acr);
        const tc = if (active) ctx.col(.text) else if (cs.info.unread) ctx.col(.text).mix(ctx.col(.muted), 0.2) else ctx.col(.muted);
        d.text(dl, font, fs, ar.right() + 6, d.centerY(tr, fs), tc, lbl);
        // Fechar.
        if (ctx.st.tabs.items.len > 1 and (hb.hovered or active)) {
            const cx = tr.right() - 14;
            const cy = tr.y + tr.h / 2;
            const cr: d.Rect = .{ .x = cx - 8, .y = cy - 8, .w = 16, .h = 16 };
            const over = ctx.hovering(cr);
            if (over) d.circle(dl, cx, cy, 8, ctx.col(.hover).mix(ctx.col(.text), 0.1));
            const xc = if (over) ctx.col(.text) else ctx.col(.faint);
            d.line(dl, cx - 3.5, cy - 3.5, cx + 3.5, cy + 3.5, xc, 1.5);
            d.line(dl, cx + 3.5, cy - 3.5, cx - 3.5, cy + 3.5, xc, 1.5);
            if (over and c.ImGui_IsMouseClicked(0)) ctx.act(.{ .close_tab = i });
        }
        x += tab_w + 6;
    }
    // Nova aba (abre a paleta).
    const pr: d.Rect = .{ .x = x, .y = r.y + r.h / 2 - 12, .w = 24, .h = 24 };
    const ph = d.hit(ctx, 999, pr);
    qa.mark(pr, "tab-plus", .{});
    if (ph.clicked) ctx.act(.open_palette);
    d.tip(ctx, pr, i18n.tr("Abrir canal em nova aba", "Open channel in a new tab"), ph.hovered);
    const pk = anim.to(anim.id("tab-plus", @intFromPtr(n)), if (ph.hovered) 1 else 0, 20);
    if (tty) {
        d.text(dl, fam.get(.bold), fs, pr.x + 4, d.centerY(pr, fs), ctx.col(.muted).mix(ctx.col(.text), pk), "+");
    } else {
        d.circle(dl, pr.x + 12, pr.y + 12, 12, ctx.col(.hover).alpha(pk * 2));
        icons.plus(dl, pr.x + 12, pr.y + 12, 5, ctx.col(.muted).mix(ctx.col(.text), pk).u());
    }
}

pub fn sigil(ch: *const types.Channel) []const u8 {
    if (ch.thread != null) return "↳";
    if (ch.kind == .forum) return "≡";
    return if (ch.guild == 0) "@" else "#";
}
