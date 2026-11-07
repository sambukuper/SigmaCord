//! `messages` e `composer`.
//!
//! messages: variant = cozy | irc | bubbles
//!           avatar = circle | squircle | square | none, avatar-size = 40
//!           spacing = espaço entre grupos (16), font-size
//! composer: variant = box | pill | prompt, typing = mostra "digitando…" (#true)
//!
//! Mensagens: barra de ações ao passar o mouse, botão direito, respostas,
//! reações, "(editado)", seleção de texto com o mouse e Ctrl+C.
const std = @import("std");
const c = @import("c");
const kdl = @import("../theme/kdl.zig");
const d = @import("draw.zig");
const qa = @import("qa.zig");
const anim = @import("anim.zig");
const w = @import("widgets.zig");
const rich = @import("rich.zig");
const icons = @import("icons.zig");
const att = @import("attachments.zig");
const emb = @import("embeds.zig");
const search = @import("search.zig");
const md_preview = @import("md_preview.zig");
const lsp_ui = @import("lsp_ui.zig");
const vim = @import("vim.zig");
const popup = @import("popup.zig");
const mosaic = @import("mosaic.zig");
const autocomplete = @import("autocomplete.zig");
const emoji_img = @import("emoji_img.zig");
const sigil = @import("comp_chat.zig").sigil;
const threads = @import("comp_threads.zig");
const forum = @import("forum.zig");
const store_mod = @import("../core/store.zig");
const types = @import("../core/types.zig");
const i18n = @import("i18n.zig");
const inbox_ui = @import("inbox.zig");
const plugins = @import("../plugins/engine.zig");
const Id = types.Id;
const StoredMessage = store_mod.StoredMessage;

const Variant = enum(u2) { cozy, irc, bubbles };

const Geo = struct {
    variant: Variant,
    fam: *d.Family,
    size: f32,
    line_h: f32,
    avatar: f32,
    shape: w.Shape,
    spacing: f32,
    content_x: f32,
    wrap: f32,
    prefix_w: f32 = 0,
    bubble_max: f32 = 0,
};

const flag_group: u8 = 1;
const flag_day: u8 = 2;
const flag_reply: u8 = 4;
/// Recolhida: pessoa ignorada ou palavra do filtro (core/filtros.zig).
const flag_hidden: u8 = 8;

const reply_h: f32 = 22;
const react_h: f32 = 30;

var flash_id: Id = 0;
var flash_until: i64 = 0;
/// Última mensagem nossa no canal (recebe o "Entregue ✓✓" nas bolhas).
var last_self_id: Id = 0;
var show_ticks = false;

fn geometry(ctx: *d.Ctx, n: *const kdl.Node, r: d.Rect) Geo {
    const variant = std.meta.stringToEnum(Variant, d.pstr(n, "variant", "cozy")) orelse .cozy;
    const fam = ctx.familyFor(n);
    const size = d.pnum(n, "font-size", ctx.th.font_size);
    const avatar_s = d.pstr(n, "avatar", "circle");
    const set = &ctx.st.settings;
    var av: f32 = if (std.mem.eql(u8, avatar_s, "none") or !set.show_avatars) 0 else d.pnum(n, "avatar-size", if (variant == .bubbles) 30 else 40);
    if (set.compact) av = @round(av * 0.6);
    var g: Geo = .{
        .variant = variant,
        .fam = fam,
        .size = size,
        .line_h = @round(size * 1.375),
        .avatar = av,
        .shape = w.shapeOf(avatar_s),
        .spacing = d.pnum(n, "spacing", 16) * (if (set.compact) @as(f32, 0.35) else 1),
        .content_x = 0,
        .wrap = 0,
    };
    switch (variant) {
        .cozy => {
            g.content_x = 16 + (if (av > 0) av + 16 else 0) + (if (d.pflag(n, "margin-line", false)) @as(f32, 22) else 0);
            g.wrap = r.w - g.content_x - 40;
        },
        .irc => {
            g.prefix_w = d.width(fam.get(.regular), size, "[00:00] ") + d.width(fam.get(.bold), size, "thiaguinho") + d.width(fam.get(.regular), size, " │ ");
            g.content_x = 10 + g.prefix_w;
            g.wrap = r.w - g.content_x - 20;
            g.line_h = @round(size * 1.3);
        },
        .bubbles => {
            g.bubble_max = @min(r.w * 0.66, 600);
            g.wrap = g.bubble_max - 28;
        },
    }
    return g;
}

fn textOpts(ctx: *const d.Ctx, g: Geo, self_bubble: bool) rich.Opts {
    return .{
        .family = g.fam,
        .size = g.size,
        .line_h = g.line_h,
        .color = if (self_bubble) ctx.col(.bubble_self_text) else ctx.col(.text).mix(ctx.col(.muted), 0.12),
        .on_accent = self_bubble,
        .reveal_spoilers = ctx.st.settings.show_spoilers,
        .underline_links = ctx.st.settings.underline_links,
    };
}

/// Altura do texto (zero numa mensagem só com anexos).
fn textH(g: Geo, m: *const StoredMessage, t: rich.Measure) f32 {
    if (m.msg.content.len == 0 and (m.msg.attachments.len > 0 or m.msg.embeds.len > 0)) return 0;
    var h = t.h;
    if (m.msg.edited and t.last_x + editedW(g) > g.wrap) h += g.line_h;
    return h;
}

/// Linha "Não enviada · Reenviar · Descartar" embaixo do texto e dos anexos.
fn failedW(g: Geo) f32 {
    const f = g.fam.get(.regular);
    return d.width(f, 12, i18n.tr("Não enviada", "Not sent")) + d.width(f, 12, i18n.tr("Reenviar", "Resend")) + d.width(f, 12, i18n.tr("Descartar", "Discard")) + 40;
}

fn failedRow(ctx: *d.Ctx, dl: *c.ImDrawList, g: Geo, m: *const StoredMessage, x_in: f32, y: f32) void {
    const f = g.fam.get(.regular);
    const ty = y + (g.line_h - 12 * 1.2) / 2;
    var x = x_in;
    const lbl = i18n.tr("Não enviada", "Not sent");
    d.text(dl, f, 12, x, ty, ctx.col(.danger), lbl);
    x += d.width(f, 12, lbl) + 14;
    const channel = m.msg.channel;
    const nonce = m.msg.nonce;
    for ([_][]const u8{ i18n.tr("Reenviar", "Resend"), i18n.tr("Descartar", "Discard") }, 0..) |t, i| {
        const tw = d.width(f, 12, t);
        const hr: d.Rect = .{ .x = x, .y = y, .w = tw, .h = g.line_h };
        const hb = d.hit(ctx, @truncate(nonce ^ (0xFA11_ED00 + i)), hr);
        qa.mark(hr, "failed-{s}:{d}", .{ if (i == 0) "resend" else "discard", nonce });
        d.text(dl, f, 12, x, ty, if (hb.hovered) ctx.col(.text) else ctx.col(.link), t);
        if (hb.hovered) d.line(dl, x, y + g.line_h - 3, x + tw, y + g.line_h - 3, ctx.col(.link), 1);
        if (hb.clicked) ctx.act(if (i == 0) .{ .resend_message = .{ .channel = channel, .nonce = nonce } } else .{ .discard_message = .{ .channel = channel, .nonce = nonce } });
        x += tw + 14;
    }
}

fn editedLabel() []const u8 {
    return i18n.tr("(editado)", "(edited)");
}

fn editedW(g: Geo) f32 {
    return d.width(g.fam.get(.regular), 11, editedLabel()) + 6;
}

fn measure(ctx: *d.Ctx, g: Geo, m: *StoredMessage, flags: u8) f32 {
    // O idioma entra na chave: "(editado)" e "(edited)" têm larguras diferentes.
    // A decoração dos plugins também, quando uma regra ou um plugin mudam.
    const deco_gen: u32 = if (decoIndex(false)) |dx| dx.layout_gen else 0;
    const key: u32 = @as(u32, @intFromEnum(g.variant)) | (@as(u32, ctx.st.theme_gen) << 2) | (@as(u32, flags) << 10) | (@as(u32, @intFromBool(i18n.en())) << 18) | (deco_gen << 19);
    // Uma entrada nova nesta mensagem (uma tradução que chegou) invalida a medida.
    if (decoIndex(true)) |dx| _ = dx.view(m, ctx.store.me);
    if (m.layout_w == g.wrap and m.layout_variant == key) return m.height;
    const self = m.msg.author == ctx.store.me;
    const t = rich.layout(null, ctx.store, ctx.th, m.spans, 0, 0, g.wrap, textOpts(ctx, g, self and g.variant == .bubbles), ctx.mouse);
    var text_h = textH(g, m, t);
    text_h += att.blockHeight(m.msg.attachments, g.wrap, m.msg.content.len > 0);
    text_h += emb.block(ctx, null, m, 0, 0, g.wrap, 1, .{});
    text_h += threads.cardHeight(ctx, m);
    if (decoIndex(true)) |dx| {
        const nh = decoHeight(ctx, g, dx.view(m, ctx.store.me));
        text_h += nh;
    }
    if (m.failed) text_h += g.line_h;
    const group = flags & flag_group != 0;
    const day = flags & flag_day != 0;
    const reply = flags & flag_reply != 0;
    const reacts: f32 = if (m.n_reactions > 0) react_h else 0;
    var h: f32 = 0;
    switch (g.variant) {
        .cozy => {
            if (day) h += 46;
            if (group) {
                h += g.spacing + (if (reply) reply_h else 0);
                const body = g.line_h + text_h + reacts;
                h += @max(body, g.avatar);
            } else h += 1 + text_h + reacts;
            h += 1;
        },
        .irc => {
            if (day) h += g.line_h + 10;
            if (group) h += 4;
            if (reply) h += g.line_h;
            h += text_h + (if (reacts > 0) @as(f32, 26) else 0);
        },
        .bubbles => {
            if (day) h += 46;
            h += if (group) g.spacing + (if (self) @as(f32, 0) else 18) else 3;
            h += (if (reply) reply_h + 4 else 0) + text_h + 14 + reacts;
        },
    }
    m.layout_w = g.wrap;
    m.layout_variant = key;
    m.height = h;
    m.natural_w = @max(@max(t.w, if (m.msg.edited) t.last_x + editedW(g) else 0), att.blockWidth(m.msg.attachments, g.wrap));
    if (m.msg.embeds.len > 0) m.natural_w = @max(m.natural_w, @min(g.wrap, 520));
    if (emb.hasInvite(m)) m.natural_w = @max(m.natural_w, @min(g.wrap, emb.invite_w));
    if (m.msg.thread != 0) m.natural_w = @max(m.natural_w, @min(g.wrap, threads.card_w));
    if (reply and g.variant == .bubbles) m.natural_w = @max(m.natural_w, 180);
    if (m.failed) m.natural_w = @max(m.natural_w, failedW(g));
    if (decoIndex(true)) |dx| {
        // A nota ocupa o que precisar, até a largura da conversa.
        const v = dx.view(m, ctx.store.me);
        for (v.slice()) |*part| m.natural_w = @max(m.natural_w, @min(g.wrap, decoWidth(g, part)));
    }
    return h;
}

// --- Decoração dos plugins (plugins/deco.zig) ---------------------------------------

/// O índice, se tem algo nele (`active_only`). Sem plugins, nem é consultado.
fn decoIndex(active_only: bool) ?*plugins.deco.Index {
    const e = plugins.current orelse return null;
    if (active_only and !e.deco.active()) return null;
    return &e.deco;
}

const note_size_delta: f32 = 1.5;

fn noteFont(g: Geo) *c.ImFont {
    return g.fam.get(.regular);
}

fn badgeW(g: Geo, part: *const plugins.deco.Part) f32 {
    if (part.badge.len == 0) return 0;
    return d.width(g.fam.get(.semibold), 11.5, part.badge) + 14;
}

fn decoWidth(g: Geo, part: *const plugins.deco.Part) f32 {
    const size = g.size - note_size_delta;
    const close: f32 = if (part.note.len > 0 and part.id != 0) 20 else 0;
    return badgeW(g, part) + 10 + d.width(noteFont(g), size, part.note) + close;
}

fn partHeight(g: Geo, part: *const plugins.deco.Part) f32 {
    if (part.note.len == 0) return 22;
    const size = g.size - note_size_delta;
    const tw = @max(g.wrap - 10 - 20 - badgeW(g, part), 60);
    return @max(22, inbox_ui.wrapText(null, noteFont(g), size, 0, 0, tw, part.note, 12, d.Rgba.white) + 6);
}

fn decoHeight(_: *d.Ctx, g: Geo, v: plugins.deco.View) f32 {
    var h: f32 = 0;
    for (v.slice()) |*part| h += partHeight(g, part) + 2;
    return h;
}

/// Selo e nota embaixo da mensagem. Retorna a altura usada.
fn decoBlock(ctx: *d.Ctx, dl: *c.ImDrawList, g: Geo, m: *StoredMessage, x: f32, y_in: f32) f32 {
    const dx = decoIndex(true) orelse return 0;
    const v = dx.view(m, ctx.store.me);
    var y = y_in;
    for (v.slice(), 0..) |*part, i| {
        const h = partHeight(g, part);
        const tint = if (part.danger) ctx.col(.danger) else ctx.col(.accent);
        d.rect(dl, .{ .x = x, .y = y + 2, .w = 2, .h = h - 4 }, tint.alpha(if (part.danger) 1 else 0.7), 1);
        if (part.danger) qa.mark(.{ .x = x, .y = y, .w = 2, .h = h }, "deco-danger:{d}", .{m.msg.id});
        var tx = x + 8;
        // A nota de uma mensagem só (não de uma regra) pode ser dispensada. O × fica
        // à esquerda: à direita, a barra de ações da mensagem cobriria ele.
        if (part.note.len > 0 and part.id != 0) {
            const xr: d.Rect = .{ .x = tx, .y = y + 2, .w = 16, .h = 16 };
            const hb = d.hitUnder(ctx, @truncate(m.msg.id ^ (0xDEC0_0000 + i)), xr);
            qa.mark(xr, "deco-close:{d}", .{m.msg.id});
            const ink = if (hb.hovered) ctx.col(.text) else ctx.col(.faint);
            d.line(dl, xr.x + 4, xr.y + 4, xr.right() - 4, xr.bottom() - 4, ink, 1.4);
            d.line(dl, xr.right() - 4, xr.y + 4, xr.x + 4, xr.bottom() - 4, ink, 1.4);
            d.tip(ctx, xr, i18n.tr("Dispensar", "Dismiss"), hb.hovered);
            if (hb.clicked) ctx.act(.{ .deco_dismiss = .{ .run = part.run, .id = part.id } });
            tx += 20;
        }
        if (part.badge.len > 0) {
            const bw = badgeW(g, part);
            const f = g.fam.get(.semibold);
            const br: d.Rect = .{ .x = tx, .y = y + 2, .w = bw, .h = 18 };
            d.rect(dl, br, tint.alpha(if (part.danger) 0.22 else 0.16), 9);
            d.text(dl, f, 11.5, br.x + 7, d.centerY(br, 11.5), ctx.col(.text), part.badge);
            qa.mark(br, "deco-badge:{d}", .{m.msg.id});
            tx += bw + 4;
        }
        if (part.note.len > 0) {
            const size = g.size - note_size_delta;
            const tw = @max(g.wrap - 10 - 20 - badgeW(g, part), 60);
            _ = inbox_ui.wrapText(dl, noteFont(g), size, tx, y + 3, tw, part.note, 12, if (part.danger) ctx.col(.danger) else ctx.col(.muted).mix(ctx.col(.text), 0.35));
            qa.mark(.{ .x = tx, .y = y, .w = tw, .h = h }, "deco-note:{d}", .{m.msg.id});
        }
        y += h + 2;
    }
    return y - y_in;
}

/// Faixa da seleção dentro de uma mensagem.
const SelRange = struct { first: usize, o0: u32, last: usize, o1: u32 };

fn selectionRange(ctx: *d.Ctx, cs: *store_mod.ChannelState) ?SelRange {
    const sel = &ctx.st.selection;
    if (sel.channel != cs.info.id or sel.empty()) return null;
    var ia: ?usize = null;
    var ib: ?usize = null;
    for (cs.messages.items, 0..) |m, i| {
        if (m.msg.id == sel.a_id) ia = i;
        if (m.msg.id == sel.b_id) ib = i;
    }
    var r: SelRange = .{ .first = ia orelse return null, .o0 = sel.a_off, .last = ib orelse return null, .o1 = sel.b_off };
    if (r.first > r.last or (r.first == r.last and r.o0 > r.o1)) {
        std.mem.swap(usize, &r.first, &r.last);
        std.mem.swap(u32, &r.o0, &r.o1);
    }
    return r;
}

pub fn messages(ctx: *d.Ctx, n: *const kdl.Node, r_in: d.Rect) void {
    if (ctx.st.friends) return @import("comp_friends.zig").page(ctx, n, r_in);
    // A bandeja de arquivos fica entre a conversa e a caixa de texto.
    var r = r_in;
    r.h = @max(40, r.h - att.trayHeight(ctx) - md_preview.height(ctx.st) - composer_extra);
    // Tela dividida: cada painel chama `history` com o canal dele.
    if (mosaic.on()) return mosaic.draw(ctx, n, r);
    const ch_id = ctx.st.activeChannel() orelse return;
    history(ctx, n, r, ch_id, "##messages");
}

/// A faixa da direita onde fica a barra de rolagem, por cima da lista.
const scrollbar_zone: f32 = 14;
/// A conversa cuja barra de rolagem está sendo arrastada.
var bar_drag: types.Id = 0;
extern fn sigma_scrollbar_held() bool;

/// O histórico de um canal, com rolagem própria. `region` é o nome da
/// região do ImGui (um por painel: os IDs dos botões ficam separados).
pub fn history(ctx: *d.Ctx, n: *const kdl.Node, r: d.Rect, ch_id: Id, region: [*:0]const u8) void {
    const cs = ctx.store.channel(ch_id) orelse return;
    // Fórum não tem conversa: a lista de posts entra no lugar.
    if (cs.info.kind == .forum) return forum.page(ctx, n, r, cs, region);
    const g = geometry(ctx, n, r);
    ctx.hot = false;
    vim.page_h = r.h;

    cs.seen_ms = ctx.now_ms;
    if (cs.history == .failed) return loadFailed(ctx, g, r, ch_id);
    // Saiu da memória e voltou para a tela sem passar por "abrir" (a aba ao
    // lado foi fechada, por exemplo): sem isso, o esqueleto ficaria para sempre.
    if (cs.history == .none) ctx.act(.{ .retry_history = ch_id });
    if (cs.history != .loaded) return skeleton(ctx, g, r);

    const msgs = cs.messages.items;
    const st = ctx.st;
    st.offsets.resize(st.gpa, msgs.len) catch return;
    st.groups.resize(st.gpa, msgs.len) catch return;
    // Topo: "carregando mensagens antigas…" ou "começo do canal".
    const top_h: f32 = 52;
    var total: f32 = 8 + top_h;
    // Linha "NOVAS MENSAGENS": fica entre a última lida e a primeira não lida.
    // Sem a última lida carregada, a linha ainda não tem lugar na lista.
    const divider_after = cs.divider_after;
    var first_new: ?usize = null;
    var n_new: u32 = 0;
    const filt = &st.filtros;
    // Sem ignorados nem filtro (o comum), nada fica recolhido: nem pergunta.
    const any_hide = filt.ignored.count() > 0 or filt.filter.items.len > 0;
    const dx = decoIndex(true);
    var prev_hidden = false;
    for (msgs, 0..) |*m, i| {
        var flags: u8 = 0;
        if (m.msg.reply_to != 0) flags |= flag_reply | flag_group;
        if (i == 0) {
            flags |= flag_group | flag_day;
        } else {
            const prev = &msgs[i - 1].msg;
            if (dayOf(&msgs[i - 1]) != dayOf(m)) flags |= flag_day | flag_group;
            if (prev.author != m.msg.author or m.msg.timestamp - prev.timestamp > 420) flags |= flag_group;
            // Depois de uma linha de sistema, a próxima mensagem abre grupo.
            if (prev.system != .none) flags |= flag_group;
        }
        // Linha de sistema ("fulano entrou"): nunca tem cabeçalho de grupo.
        if (m.msg.system != .none) flags &= ~(flag_group | flag_reply);
        // Depois de uma recolhida (ignorado/filtro), começa um grupo novo.
        if (prev_hidden) flags |= flag_group;
        if (divider_after != 0 and m.msg.id > divider_after and m.msg.author != ctx.store.me) {
            n_new += 1;
            if (n_new == 1 and (i > 0 or cs.older == .done)) {
                first_new = i;
                flags |= flag_group;
                total += new_line_h;
            }
        }
        var hide = any_hide and filt.hides(m, ctx.store.me);
        if (!hide) if (dx) |ix| {
            if (ix.collapses(m, ctx.store.me) and !filt.revealed.contains(m.msg.id)) hide = true;
        };
        prev_hidden = hide;
        if (hide) flags |= flag_hidden;
        st.groups.items[i] = flags;
        st.offsets.items[i] = total;
        total += if (hide) collapsedH(g, flags, m) else measure(ctx, g, m, flags);
    }
    // Balão de "digitando" no fim da conversa (tema de bolhas).
    const typing_bubble = g.variant == .bubbles and d.pflag(n, "typing-bubble", false) and cs.typing.items.len > 0;
    const typing_y = total;
    if (typing_bubble) total += 50;
    total += 16;
    show_ticks = d.pflag(n, "ticks", false);
    last_self_id = 0;
    {
        var k = msgs.len;
        while (k > 0) {
            k -= 1;
            if (msgs[k].msg.author == ctx.store.me) {
                last_self_id = if (msgs[k].pending) std.math.maxInt(Id) else msgs[k].msg.id;
                break;
            }
        }
    }

    const sc = st.scrollOf(ch_id);
    const max_scroll = @max(0, total - r.h);
    // A pessoa está lendo lá em cima: nada dali é cortado (ver Store.trim).
    cs.reading = !sc.stick_bottom or cs.detached;
    // Soltou a barra de rolagem: acabou o arraste (ver abaixo).
    if (!c.ImGui_IsMouseDown(0)) bar_drag = 0;
    const dragging_bar = bar_drag == ch_id;
    // Mudou algo acima do que está na tela: mantém no lugar o que estava.
    if (sc.anchor_id != 0 and !sc.stick_bottom and sc.pos >= 0 and !dragging_bar) {
        if (ctx.store.find(cs, sc.anchor_id)) |am| {
            const k = (@intFromPtr(am) - @intFromPtr(msgs.ptr)) / @sizeOf(StoredMessage);
            const delta = st.offsets.items[k] + sc.anchor_off - sc.pos;
            if (delta != 0) {
                sc.pos += delta;
                sc.target += delta;
            }
        }
    }
    // Perto do topo: pede as anteriores (depois de uma falha, com calma).
    // Só depois de soltar a barra: a lista crescendo no meio do arraste muda a proporção dela.
    if (!dragging_bar and cs.older == .idle and ctx.now_ms >= cs.older_retry_ms and msgs.len > 0 and sc.pos >= 0 and sc.pos < r.h * 0.6 + 200) ctx.act(.{ .load_older = ch_id });
    // Lendo o passado, perto do fim do que está carregado: pede as seguintes.
    if (cs.detached and cs.newer == .idle and ctx.now_ms >= cs.newer_retry_ms and msgs.len > 0 and sc.pos >= max_scroll - r.h * 0.6 - 200) ctx.act(.{ .load_newer = ch_id });
    // Pulo para uma mensagem (clique numa resposta): só no painel focado.
    if (st.jump != 0 and st.activeChannel() == ch_id) {
        const found = for (msgs, 0..) |m, i| {
            if (m.msg.id != st.jump) continue;
            sc.target = std.math.clamp(st.offsets.items[i] - r.h / 3, 0, max_scroll);
            sc.stick_bottom = false;
            // Longe: vai direto, sem passar (e baixar) tudo o que tem no caminho.
            if (sc.pos >= 0 and @abs(sc.pos - sc.target) > r.h * 3) sc.pos = sc.target;
            flash_id = st.jump;
            flash_until = ctx.now_ms + 1600;
            break true;
        } else false;
        if (found) {
            st.jump = 0;
            st.jump_asked = 0;
            cs.pos_unread = false;
        } else if (cs.cached) {
            // Ainda no cache do disco: o histórico de verdade pode trazer ela.
        } else if (st.jump_asked != st.jump) {
            // Não está carregada: busca em volta dela.
            st.jump_asked = st.jump;
            ctx.act(.{ .fetch_around = .{ .channel = ch_id, .id = st.jump } });
        } else if (cs.around == .done or cs.around == .failed) {
            if (cs.around == .done)
                st.showToast(ctx.now_ms, false, "essa mensagem não existe mais", "that message no longer exists", .{})
            else
                st.showToast(ctx.now_ms, true, "não consegui carregar essa mensagem", "couldn't load that message", .{});
            st.jump = 0;
            st.jump_asked = 0;
        }
    }
    // Abrir na primeira não lida: a linha no alto da tela. Se ela já cabe na
    // última tela, fica no fim mesmo.
    if (cs.pos_unread and !cs.cached and cs.around != .loading) {
        cs.pos_unread = false;
        if (first_new) |k| {
            const fy = st.offsets.items[k] - new_line_h;
            if (fy < max_scroll) {
                sc.target = @max(0, fy - unread_bar_h - 12);
                sc.pos = sc.target;
                sc.stick_bottom = false;
                sc.anchor_id = 0;
            }
        }
    }
    // No fim da conversa (no presente) com a janela em foco: lida de verdade.
    // Fora disso, o que chegou fica não lido e a linha marca onde começa.
    if (cs.info.unread) {
        const at_present = sc.stick_bottom and !cs.detached and !cs.cached and !cs.pos_unread and cs.around != .loading and (st.jump == 0 or st.activeChannel() != ch_id);
        if (at_present and st.window_focused and !cs.hold_unread) {
            ctx.act(.{ .channel_seen = ch_id });
        } else if (cs.divider_after == 0) {
            cs.divider_after = @max(cs.read_id, 1);
            cs.divider_seen = false;
        }
    }
    // Com as configurações (ou um popup) por cima, a roda rola elas, não a conversa.
    const hovered = ctx.hovering(r) and ctx.st.popup == .none and !st.settings.open and !autocomplete.over(ctx) and !@import("resize.zig").over(ctx);
    if (sc.pos < 0 or sc.stick_bottom) {
        sc.target = max_scroll;
        if (sc.pos < 0) sc.pos = max_scroll;
    }
    if (hovered and ctx.io.*.MouseWheel != 0) {
        sc.target -= ctx.io.*.MouseWheel * 120;
        sc.stick_bottom = false;
    }
    sc.target = std.math.clamp(sc.target, 0, max_scroll);
    // (Fora do presente, o fim da lista não é o fim da conversa.)
    if (sc.target >= max_scroll - 1 and !cs.detached) sc.stick_bottom = true;
    // Longe do fim e indo para lá (a conversa trocou, "Ir para o fim"): vai
    // direto. Passar por centenas de mensagens baixaria cada imagem do caminho.
    if (sc.stick_bottom and max_scroll - sc.pos > r.h * 3) sc.pos = max_scroll;
    sc.pos = anim.step(sc.pos, sc.target, 18);

    c.ImGui_SetNextWindowScroll(d.v(-1, sc.pos));
    const dl = d.beginRegion(ctx, region, r, c.ImGuiWindowFlags_NoScrollWithMouse);
    const fade_start = dl.*.VtxBuffer.Size;
    var s = c.ImGui_GetScrollY();
    // Arrastando a barra de rolagem desta conversa. Quem diz é o ImGui, não a posição do mouse: o
    // arraste vale até soltar, com o mouse em qualquer lugar, e um clique perto da borda não conta.
    // A alça de redimensionar painéis fica colada na barra: puxar ela não rola a conversa.
    if (sigma_scrollbar_held() and (bar_drag == ch_id or !@import("resize.zig").over(ctx))) {
        bar_drag = ch_id;
        if (@abs(s - sc.pos) > 1) {
            sc.pos = s;
            sc.target = s;
            sc.stick_bottom = s >= max_scroll - 1 and !cs.detached;
        }
    }
    c.ImGui_Dummy(d.v(r.w - 12, total));
    // Primeiro quadro da conversa: o ImGui ainda não sabe a altura e prende a
    // rolagem bem longe de onde ela está. Sem isso, desenharia (e baixaria) o
    // topo da conversa à toa. Uns pixels de diferença são normais: fica.
    if (s < sc.pos - r.h) s = sc.pos;

    const base = r.y - s + @max(0, r.h - total);
    var lo: usize = 0;
    var hi: usize = msgs.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (st.offsets.items[mid] + msgs[mid].height < s) lo = mid + 1 else hi = mid;
    }
    if (lo < msgs.len) {
        sc.anchor_id = msgs[lo].msg.id;
        sc.anchor_off = sc.pos - st.offsets.items[lo];
    } else sc.anchor_id = 0;

    // Papel pautado: linhas que rolam junto com a conversa + margem vermelha.
    if (d.pflag(n, "ruled", false)) {
        const lh = g.line_h;
        var ly = base + 8 + @floor(s / lh) * lh;
        while (ly < r.bottom()) : (ly += lh) d.line(dl, r.x, ly, r.right(), ly, ctx.col(.accent).mix(ctx.col(.link), 0.6).alpha(0.1), 1);
    }
    if (d.pflag(n, "margin-line", false)) {
        const mx = r.x + g.content_x - 12;
        d.line(dl, mx, r.y, mx, r.bottom(), ctx.col(.accent).alpha(0.35), 1);
        d.line(dl, mx + 3, r.y, mx + 3, r.bottom(), ctx.col(.accent).alpha(0.18), 1);
    }

    topOfChannel(ctx, dl, g, cs, r, base + 8, top_h);
    // Os botões flutuantes pedem o mouse antes das mensagens: o que estiver
    // embaixo (uma imagem, a barra de ações) não pega o mesmo clique.
    var show_bar = divider_after != 0 and !cs.divider_seen and !cs.cached and !cs.pos_unread and n_new > 0;
    if (show_bar) if (first_new) |k| {
        const fy = st.offsets.items[k] - new_line_h;
        if (@abs(sc.pos - sc.target) < 2 and fy >= sc.pos and fy < sc.pos + r.h) {
            cs.divider_seen = true;
            show_bar = false;
        }
    };
    const none: d.Hit = .{ .hovered = false, .clicked = false, .held = false, .middle = false, .right = false, .ctrl = false };
    const bar = barRects(g, r);
    const first_hit = if (show_bar) d.hit(ctx, 0xF10A7_01, bar.first) else none;
    const read_hit = if (show_bar) d.hit(ctx, 0xF10A7_02, bar.read) else none;
    const present_hit = if (cs.detached) d.hit(ctx, 0xF10A7_03, presentRect(r)) else none;
    const bottom_r: d.Rect = .{ .x = r.right() - 52, .y = r.bottom() - 52, .w = 36, .h = 36 };
    const bottom_hit = if (!sc.stick_bottom) d.hit(ctx, 0xF10A7_04, bottom_r) else none;
    const over_float = first_hit.hovered or read_hit.hovered or present_hit.hovered or bottom_hit.hovered;
    if (first_new) |k| newLine(ctx, dl, g, r, base + st.offsets.items[k] - new_line_h);

    const sel = selectionRange(ctx, cs);
    var probe: rich.Probe = .{ .x = ctx.mouse.x, .y = ctx.mouse.y };
    var probe_idx: ?usize = null;
    var i = lo;
    while (i < msgs.len) : (i += 1) {
        const oy = st.offsets.items[i];
        if (oy > s + r.h) break;
        const y = base + oy;
        if (st.groups.items[i] & flag_hidden != 0) {
            drawCollapsed(ctx, dl, g, &msgs[i], st.groups.items[i], r, y);
            qa.mark(.{ .x = r.x, .y = y, .w = r.w, .h = msgs[i].height }, "msg:{d}", .{msgs[i].msg.id});
            continue;
        }
        const under = hovered and !over_float and ctx.mouse.y >= y and ctx.mouse.y < y + msgs[i].height;
        if (under) probe_idx = i;
        var from: u32 = 1;
        var to: u32 = 0;
        if (sel) |sr| if (i >= sr.first and i <= sr.last) {
            from = if (i == sr.first) sr.o0 else 0;
            to = if (i == sr.last) sr.o1 else emb.textLen(&msgs[i]);
        };
        drawMessage(ctx, dl, g, &msgs[i], st.groups.items[i], r, y, under, from, to, if (under) &probe else null);
        qa.mark(.{ .x = r.x, .y = y, .w = r.w, .h = msgs[i].height }, "msg:{d}", .{msgs[i].msg.id});
        qa.mark(.{ .x = r.x, .y = y, .w = r.w, .h = msgs[i].height }, "msg-index:{d}", .{msgs.len - 1 - i});
    }

    if (typing_bubble) {
        const ty = base + typing_y + 10;
        const uid = cs.typing.items[0].user;
        const left: f32 = r.x + 20;
        if (g.avatar > 0) @import("widgets.zig").avatar(ctx, dl, left + g.avatar / 2, ty + 18, g.avatar, uid, g.shape, null, 1);
        const bx = left + (if (g.avatar > 0) g.avatar + 10 else 0);
        const br: d.Rect = .{ .x = bx, .y = ty, .w = 64, .h = 36 };
        d.rect(dl, br, ctx.col(.bubble_other), 18);
        w.typingDots(dl, br.x + 24, br.y + 19, ctx.col(.muted), ctx.now_ms);
    }

    // Botão fixo do topo enquanto a primeira não lida não apareceu na tela.
    if (show_bar) unreadBar(ctx, dl, g, bar, ch_id, n_new, first_new == null, first_hit, read_hit);
    if (cs.around == .loading) loadingPill(ctx, dl, g, r);
    if (cs.detached) presentBar(ctx, dl, g, r, ch_id, present_hit);

    qa.mark(.{ .x = r.right() - 5, .y = r.y + r.h - 60, .w = 4, .h = 40 }, "msg-scrollbar", .{});
    qa.mark(.{ .x = r.right() - 5, .y = r.y + 40, .w = 4, .h = 40 }, "msg-scrollbar-top", .{});

    // Seleção de texto e botão direito.
    if (probe_idx) |pi| {
        const m = &msgs[pi];
        const off = probe.out orelse (if (ctx.mouse.x < r.x + g.content_x) @as(u32, 0) else emb.textLen(m));
        if (!ctx.hot) {
            // Link no caminho: já pediu a mãozinha, e ela vale mais que o cursor de texto.
            if (probe.out != null and c.ImGui_GetMouseCursor() != c.ImGuiMouseCursor_Hand) c.ImGui_SetMouseCursor(c.ImGuiMouseCursor_TextInput);
            // A barra de rolagem fica por cima da lista: quem a arrasta não está selecionando.
            if (c.ImGui_IsMouseClicked(0) and ctx.mouse.x < r.right() - scrollbar_zone) {
                st.selection = .{ .channel = ch_id, .a_id = m.msg.id, .a_off = off, .b_id = m.msg.id, .b_off = off, .dragging = true };
                if (c.ImGui_IsMouseDoubleClicked(0)) selectWord(st, m, off);
            }
            if (c.ImGui_IsMouseClicked(1)) ctx.popup(.{ .menu = .{ .kind = .message, .id = m.msg.id, .x = ctx.mouse.x, .y = ctx.mouse.y } });
        }
        // Entre as linhas de um cartão não há texto sob o mouse: fica onde estava.
        const in_gap = probe.out == null and m.msg.embeds.len > 0 and st.selection.b_id == m.msg.id;
        if (st.selection.dragging and st.selection.channel == ch_id and c.ImGui_IsMouseDown(0) and !c.ImGui_IsMouseDoubleClicked(0) and !in_gap) {
            st.selection.b_id = m.msg.id;
            st.selection.b_off = off;
        }
    }
    if (st.selection.dragging and !c.ImGui_IsMouseDown(0)) st.selection.dragging = false;
    if (!st.selection.empty() and st.selection.channel == ch_id and ctx.io.*.KeyCtrl and c.ImGui_IsKeyPressed(c.ImGuiKey_C) and !ctx.io.*.WantTextInput) {
        if (popup.selectionText(ctx)) |txt| ctx.act(.{ .copy = txt });
    }
    channelFade(ctx, dl, fade_start, region, ch_id, r);
    // Voltar para o fim: desenhado dentro da própria região (fica por baixo
    // das configurações e de menus) e com o clique direto pelo mouse.
    if (!sc.stick_bottom) {
        const br = bottom_r;
        const hb = bottom_hit;
        qa.mark(br, "jump-bottom", .{});
        d.shadow(dl, br, 18, 8, ctx.col(.shadow));
        d.circle(dl, br.x + 18, br.y + 18, 18, if (hb.hovered) ctx.col(.accent) else ctx.col(.elevated));
        icons.chevron(dl, br.x + 18, br.y + 19, (if (hb.hovered) ctx.col(.accent_text) else ctx.col(.text)).u(), 1);
        d.tip(ctx, br, i18n.tr("Ir para o fim", "Jump to present"), hb.hovered);
        if (hb.clicked) {
            if (cs.detached) {
                ctx.act(.{ .jump_present = ch_id });
            } else {
                sc.stick_bottom = true;
                sc.target = max_scroll;
            }
        }
    }
    c.ImGui_EndChild();
}

const new_line_h: f32 = 24;
const unread_bar_h: f32 = 30;

/// A linha vermelha "NOVAS MENSAGENS" entre a última lida e a primeira não lida.
fn newLine(ctx: *d.Ctx, dl: *c.ImDrawList, g: Geo, r: d.Rect, y: f32) void {
    const col = ctx.col(.danger);
    const label = i18n.tr("NOVAS MENSAGENS", "NEW MESSAGES");
    const font = g.fam.get(.bold);
    const fs: f32 = 11;
    const tw = d.width(font, fs, label);
    const cy = y + new_line_h / 2;
    const right = r.right() - 20;
    const pill: d.Rect = .{ .x = right - tw - 12, .y = cy - 8, .w = tw + 12, .h = 16 };
    d.line(dl, r.x + 16, cy, pill.x, cy, col, 1);
    d.rect(dl, pill, col, @min(4, ctx.th.radius + 1));
    d.text(dl, font, fs, pill.x + 6, d.centerY(pill, fs), d.Rgba.white, label);
    qa.mark(.{ .x = r.x, .y = y, .w = r.w, .h = new_line_h }, "new-line", .{});
}

const BarRects = struct { bar: d.Rect, first: d.Rect, read: d.Rect };

fn barRects(g: Geo, r: d.Rect) BarRects {
    const bar: d.Rect = .{ .x = r.x + 12, .y = r.y + 6, .w = r.w - 36, .h = unread_bar_h };
    const read_w = d.width(g.fam.get(.semibold), 13, i18n.tr("marcar como lida", "mark as read")) + 24;
    return .{
        .bar = bar,
        .first = .{ .x = bar.x, .y = bar.y, .w = bar.w - read_w, .h = bar.h },
        .read = .{ .x = bar.right() - read_w, .y = bar.y, .w = read_w, .h = bar.h },
    };
}

/// "N novas mensagens · ir para a primeira" e "marcar como lida", fixo no topo.
fn unreadBar(ctx: *d.Ctx, dl: *c.ImDrawList, g: Geo, rects: BarRects, ch: Id, n: u32, more: bool, fh: d.Hit, rh: d.Hit) void {
    const bar = rects.bar;
    const first = rects.first;
    const read = rects.read;
    const font = g.fam.get(.semibold);
    const fs: f32 = 13;
    const read_lbl = i18n.tr("marcar como lida", "mark as read");
    qa.mark(first, "unread-bar-first", .{});
    qa.mark(read, "unread-bar-read", .{});
    const radius = @min(8, ctx.th.radius + 2);
    d.shadow(dl, bar, radius, 8, ctx.col(.shadow).alpha(0.5));
    d.rect(dl, bar, ctx.col(.accent), radius);
    const ink = ctx.col(.accent_text);
    if (fh.hovered) d.rectFlags(dl, first, ink.alpha(0.12), radius, c.ImDrawFlags_RoundCornersLeft);
    if (rh.hovered) d.rectFlags(dl, read, ink.alpha(0.12), radius, c.ImDrawFlags_RoundCornersRight);
    var buf: [96]u8 = undefined;
    const plus: []const u8 = if (more) "+" else "";
    const t = if (n == 1 and !more)
        i18n.tr("1 nova mensagem · ir para a primeira", "1 new message · jump to the first")
    else
        i18n.fmt(&buf, "{d}{s} novas mensagens · ir para a primeira", "{d}{s} new messages · jump to the first", .{ n, plus });
    _ = d.textClipped(dl, font, fs, first.x + 12, d.centerY(bar, fs), ink, t, first.w - 18);
    d.line(dl, read.x, bar.y + 7, read.x, bar.bottom() - 7, ink.alpha(0.35), 1);
    d.text(dl, font, fs, read.x + 12, d.centerY(bar, fs), ink, read_lbl);
    if (fh.clicked) ctx.act(.{ .jump_first_unread = ch });
    if (rh.clicked) ctx.act(.{ .mark_read = ch });
}

/// Buscando em volta de uma mensagem: o aviso fica por cima do que está na tela.
fn loadingPill(ctx: *d.Ctx, dl: *c.ImDrawList, g: Geo, r: d.Rect) void {
    const label = i18n.tr("Carregando…", "Loading…");
    const font = g.fam.get(.semibold);
    const tw = d.width(font, 13, label);
    const p: d.Rect = .{ .x = r.x + (r.w - tw - 28) / 2, .y = r.y + 44, .w = tw + 28, .h = 28 };
    d.rect(dl, p, ctx.col(.elevated), 14);
    d.border(dl, p, ctx.col(.border), 14, 1);
    d.text(dl, font, 13, p.x + 14, d.centerY(p, 13), ctx.col(.text), label);
    qa.mark(p, "around-loading", .{});
}

fn presentRect(r: d.Rect) d.Rect {
    return .{ .x = r.x + 12, .y = r.bottom() - 42, .w = @max(120, r.w - 80), .h = 30 };
}

/// Fora do presente: as mensagens de agora não estão aqui.
fn presentBar(ctx: *d.Ctx, dl: *c.ImDrawList, g: Geo, r: d.Rect, ch: Id, hb: d.Hit) void {
    const font = g.fam.get(.semibold);
    const fs: f32 = 13;
    const bar = presentRect(r);
    qa.mark(bar, "present-bar", .{});
    const radius = @min(8, ctx.th.radius + 2);
    d.shadow(dl, bar, radius, 8, ctx.col(.shadow).alpha(0.5));
    d.rect(dl, bar, if (hb.hovered) ctx.col(.accent) else ctx.col(.elevated), radius);
    d.border(dl, bar, ctx.col(.border), radius, 1);
    const lbl = i18n.tr("Voltar ao presente", "Jump to present");
    const lw = d.width(font, fs, lbl);
    const ink = if (hb.hovered) ctx.col(.accent_text) else ctx.col(.text);
    _ = d.textClipped(dl, g.fam.get(.regular), fs, bar.x + 12, d.centerY(bar, fs), if (hb.hovered) ink else ctx.col(.muted), i18n.tr("Você está vendo mensagens antigas", "You're viewing older messages"), bar.w - lw - 36);
    d.text(dl, font, fs, bar.right() - lw - 12, d.centerY(bar, fs), ink, lbl);
    if (hb.clicked) ctx.act(.{ .jump_present = ch });
}

/// Trocou de canal (em cada painel): a conversa nova entra com um fade curto
/// e sobe alguns pixels, em vez de aparecer de supetão.
var fades: [4]struct { region: usize = 0, ch: Id = 0, t0: i64 = 0 } = @splat(.{});

fn channelFade(ctx: *d.Ctx, dl: *c.ImDrawList, start: c_int, region: [*:0]const u8, ch: Id, r: d.Rect) void {
    if (anim.instant) return;
    const key = @intFromPtr(region);
    const slot = for (&fades) |*f| {
        if (f.region == key or f.region == 0) break f;
    } else &fades[0];
    if (slot.region != key or slot.ch != ch) {
        // Primeira vez deste painel: sem animação (o app acabou de abrir).
        const first = slot.region != key;
        slot.* = .{ .region = key, .ch = ch, .t0 = if (first) 0 else ctx.now_ms };
    }
    const k = d.easeOut(@as(f32, @floatFromInt(ctx.now_ms - slot.t0)) / 160);
    if (k >= 1) return;
    anim.active = true;
    d.transformVerts(dl, start, d.v(r.x, r.y), 1, 10 * (1 - k), 0.25 + 0.75 * k);
}

/// Altura de uma mensagem recolhida: só uma linha (e o separador do dia).
fn collapsedH(g: Geo, flags: u8, m: *StoredMessage) f32 {
    const day = flags & flag_day != 0;
    const h: f32 = switch (g.variant) {
        .irc => (if (day) g.line_h + 10 else 0) + g.line_h + 4,
        else => (if (day) @as(f32, 46) else 0) + 30,
    };
    // Quando for mostrada, mede de novo do zero.
    m.layout_w = -1;
    m.height = h;
    return h;
}

/// "Mensagem de alguém ignorado — mostrar" no lugar da mensagem.
fn drawCollapsed(ctx: *d.Ctx, dl: *c.ImDrawList, g: Geo, m: *StoredMessage, flags: u8, r: d.Rect, y_in: f32) void {
    var y = y_in;
    const fam = g.fam;
    const irc = g.variant == .irc;
    if (flags & flag_day != 0) {
        if (irc) {
            daySeparator(ctx, dl, fam, r, y + (g.line_h + 10) / 2, m.msg.timestamp, true);
            y += g.line_h + 10;
        } else {
            daySeparator(ctx, dl, fam, r, y + 23, m.msg.timestamp, false);
            y += 46;
        }
    }
    const row_h: f32 = if (irc) g.line_h + 4 else 30;
    const cy = y + row_h / 2;
    const x = switch (g.variant) {
        .cozy => r.x + g.content_x,
        .irc => r.x + 10,
        .bubbles => r.x + 20,
    };
    const ignored = ctx.st.filtros.isIgnored(m.msg.author);
    // Quem recolheu pode dizer por quê (filtro de um plugin).
    var lb: [120]u8 = undefined;
    const plugin_label: []const u8 = if (decoIndex(true)) |ix| ix.view(m, ctx.store.me).label else "";
    const label = if (ignored)
        i18n.tr("Mensagem de alguém ignorado — ", "Message from someone you ignored — ")
    else if (plugin_label.len > 0)
        d.printClip(&lb, "{s} — ", .{plugin_label})
    else
        i18n.tr("Mensagem filtrada — ", "Filtered message — ");
    const fs: f32 = 13;
    const lw = d.width(fam.get(.italic), fs, label);
    d.text(dl, fam.get(.italic), fs, x, cy - fs * 0.6, ctx.col(.faint), label);
    const show = i18n.tr("mostrar", "show");
    const sw = d.width(fam.get(.semibold), fs, show);
    const sr: d.Rect = .{ .x = x + lw - 2, .y = cy - 11, .w = sw + 4, .h = 22 };
    const hb = d.hit(ctx, @truncate(m.msg.id ^ 0x41DE_5EE), sr);
    qa.mark(sr, "hidden-show:{d}", .{m.msg.id});
    const lc = if (hb.hovered) ctx.col(.text) else ctx.col(.link);
    d.text(dl, fam.get(.semibold), fs, x + lw, cy - fs * 0.6, lc, show);
    if (hb.hovered) d.line(dl, x + lw, cy + fs * 0.55, x + lw + sw, cy + fs * 0.55, lc, 1);
    if (hb.clicked) ctx.st.filtros.reveal(ctx.st.gpa, m.msg.id);
    qa.mark(.{ .x = r.x, .y = y, .w = r.w, .h = row_h }, "hidden:{d}", .{m.msg.id});
}

fn selectWord(st: anytype, m: *const StoredMessage, off: u32) void {
    const word = emb.wordAt(m, off);
    st.selection.a_off = word[0];
    st.selection.b_off = word[1];
    st.selection.dragging = false;
}

fn topOfChannel(ctx: *d.Ctx, dl: *c.ImDrawList, g: Geo, cs: anytype, r: d.Rect, y: f32, h: f32) void {
    const fam = g.fam;
    const x = r.x + g.content_x;
    switch (cs.older) {
        .loading, .idle => {
            // Três pontinhos enquanto a página chega.
            if (cs.older == .loading) w.typingDots(dl, r.x + r.w / 2 - 7, y + h / 2, ctx.col(.muted), ctx.now_ms);
        },
        .done => {
            var buf: [128]u8 = undefined;
            const t = if (cs.info.guild == 0)
                i18n.fmt(&buf, "Este é o começo da conversa com {s}.", "This is the beginning of your conversation with {s}.", .{cs.info.name})
            else if (cs.info.thread != null)
                i18n.fmt(&buf, "Este é o começo da thread {s}", "This is the start of the thread {s}", .{cs.info.name})
            else
                i18n.fmt(&buf, "Este é o começo de #{s}.", "This is the start of #{s}.", .{cs.info.name});
            _ = d.textClipped(dl, fam.get(.semibold), 15, x, y + h / 2 - 10, ctx.col(.muted), t, r.w - g.content_x - 16);
        },
    }
    qa.mark(.{ .x = r.x, .y = y, .w = r.w, .h = h }, "channel-top", .{});
}

/// A conversa não carregou (sem rede, 5xx, sem permissão).
fn loadFailed(ctx: *d.Ctx, g: Geo, r: d.Rect, ch_id: Id) void {
    const dl = ctx.dl;
    const f = g.fam.get(.medium);
    const msg = i18n.tr("Não consegui carregar as mensagens.", "Couldn't load the messages.");
    const again = i18n.tr("Tentar de novo", "Try again");
    const cy = r.y + r.h / 2;
    d.text(dl, f, 15, r.x + (r.w - d.width(f, 15, msg)) / 2, cy - 30, ctx.col(.muted), msg);
    const bw = d.width(f, 14, again) + 28;
    const br: d.Rect = .{ .x = r.x + (r.w - bw) / 2, .y = cy, .w = bw, .h = 32 };
    const hb = d.hitRaw(ctx, br);
    qa.mark(br, "history-retry", .{});
    d.rect(dl, br, if (hb.hovered) ctx.col(.accent) else ctx.col(.elevated), ctx.th.radius);
    d.text(dl, f, 14, br.x + 14, d.centerY(br, 14), if (hb.hovered) ctx.col(.accent_text) else ctx.col(.text), again);
    if (hb.clicked) ctx.act(.{ .retry_history = ch_id });
}

fn skeleton(ctx: *d.Ctx, g: Geo, r: d.Rect) void {
    // Sem conexão a resposta não vem tão cedo: fica parado em vez de animar.
    if (ctx.store.connection == .ready) anim.every(50);
    const phase = @as(f32, @floatFromInt(@mod(ctx.now_ms, 1400))) / 1400.0;
    var y = r.bottom() - 40;
    var k: usize = 0;
    while (y > r.y + 20) : (k += 1) {
        const pulse = 0.05 + 0.04 * @sin((phase + @as(f32, @floatFromInt(k)) * 0.12) * std.math.tau);
        const col = ctx.col(.text).alpha(pulse);
        const wfrac = 0.35 + @as(f32, @floatFromInt((k * 37) % 50)) / 100.0;
        const x0 = r.x + (if (g.variant == .bubbles) @as(f32, 20) else 16);
        if (g.avatar > 0 and g.variant == .cozy) d.circle(ctx.dl, x0 + g.avatar / 2, y - 6, g.avatar / 2, col);
        const tx = x0 + (if (g.variant == .cozy and g.avatar > 0) g.avatar + 16 else 0);
        d.rect(ctx.dl, .{ .x = tx, .y = y - 18, .w = 90, .h = 10 }, col, 5);
        d.rect(ctx.dl, .{ .x = tx, .y = y - 2, .w = (r.w - tx + r.x - 60) * wfrac, .h = 10 }, col, 5);
        y -= 62;
    }
}

fn snippet(buf: []u8, s: []const u8) []const u8 {
    var n: usize = 0;
    for (s) |ch| {
        if (n >= buf.len) break;
        buf[n] = if (ch == '\n') ' ' else ch;
        n += 1;
    }
    // Não termina no meio de um caractere UTF-8.
    while (n > 0 and n < s.len and (s[n] & 0xC0) == 0x80) n -= 1;
    return buf[0..n];
}

/// Texto citado numa resposta: o da original, ou só um aviso se ela está
/// recolhida (ignorado/filtro).
fn quotedText(ctx: *d.Ctx, m: *StoredMessage) []const u8 {
    if (ctx.st.filtros.hides(m, ctx.store.me)) return i18n.tr("mensagem recolhida", "collapsed message");
    if (decoIndex(true)) |ix| if (ix.collapses(m, ctx.store.me) and !ctx.st.filtros.revealed.contains(m.msg.id)) return i18n.tr("mensagem recolhida", "collapsed message");
    return m.msg.content;
}

/// Linha "↱ @fulano  texto da mensagem original" (clicável).
fn replyLine(ctx: *d.Ctx, dl: *c.ImDrawList, g: Geo, m: *const StoredMessage, x: f32, y: f32, max_w: f32, spine_x: ?f32, on_accent: bool) void {
    var buf: [160]u8 = undefined;
    const fam = g.fam;
    const found = ctx.store.findNear(m.msg.channel, m.msg.reply_to);
    const rr: d.Rect = .{ .x = x, .y = y, .w = max_w, .h = reply_h };
    const hb = d.hitUnder(ctx, @truncate(m.msg.id ^ 0x5151), rr);
    qa.mark(rr, "reply-line:{d}", .{m.msg.id});
    // Não carregada: a lista busca em volta dela.
    if (hb.clicked) ctx.act(.{ .jump_to = m.msg.reply_to });
    // Botão direito em qualquer parte da mensagem abre o menu dela.
    if (hb.right) ctx.popup(.{ .menu = .{ .kind = .message, .id = m.msg.id, .x = ctx.mouse.x, .y = ctx.mouse.y } });
    if (spine_x) |sx| {
        // A "curvinha" ligando o avatar à mensagem respondida.
        c.ImDrawList_PathClear(dl);
        c.ImDrawList_PathLineTo(dl, d.v(sx, y + reply_h));
        c.ImDrawList_PathLineTo(dl, d.v(sx, y + 14));
        c.ImDrawList_PathArcTo(dl, d.v(sx + 6, y + 14), 6, std.math.pi, std.math.pi * 1.5, 0);
        c.ImDrawList_PathLineTo(dl, d.v(x - 4, y + 8));
        c.ImDrawList_PathStroke(dl, ctx.col(.faint).alpha(0.6).u(), 2, 0);
    }
    const muted = if (on_accent) ctx.col(.bubble_self_text).alpha(0.75) else ctx.col(.muted);
    if (found) |f| {
        const u = ctx.store.user(f.m.msg.author);
        var xx = x;
        if (g.avatar > 0) {
            w.avatar(ctx, dl, xx + 8, y + 9, 16, f.m.msg.author, .circle, null, 1);
            xx += 20;
        }
        const name = if (u) |uu| uu.name else "?";
        const nc = if (on_accent) ctx.col(.bubble_self_text) else w.nameColor(ctx, guildOf(ctx, f.m.msg.channel), f.m.msg.author);
        const nm = std.fmt.bufPrint(buf[0..40], "@{s}", .{name}) catch name;
        d.text(dl, fam.get(.semibold), 13, xx, y + 1, nc, nm);
        xx += d.width(fam.get(.semibold), 13, nm);
        if (!on_accent) xx += w.botTag(ctx, dl, xx, y + 9, u, false, 1);
        xx += 6;
        _ = d.textClipped(dl, fam.get(.regular), 13, xx, y + 1, if (hb.hovered) ctx.col(.text) else muted, snippet(buf[40..], quotedText(ctx, f.m)), max_w - (xx - x));
    } else {
        d.text(dl, fam.get(.italic), 13, x, y + 1, muted, i18n.tr("mensagem original não carregada", "Original message could not be loaded"));
    }
}

/// `:nome:` de uma reação personalizada (modo economia, dica do mouse).
fn colonName(buf: []u8, rc: *const types.Reaction) []const u8 {
    return std.fmt.bufPrint(buf, ":{s}:", .{rc.text()}) catch rc.text();
}

fn emojiW(ctx: *d.Ctx, rc: *const types.Reaction) f32 {
    if (rc.custom == 0) return 16;
    if (emoji_img.enabled(ctx)) return 18;
    var nb: [40]u8 = undefined;
    return d.width(ctx.ui.get(.medium), 12, colonName(&nb, rc));
}

fn reactions(ctx: *d.Ctx, dl: *c.ImDrawList, m: *StoredMessage, x: f32, y: f32, show_add: bool, right_to_left: bool, right: f32) void {
    var buf: [24]u8 = undefined;
    const fam = ctx.ui;
    var xx = x;
    var widths: [9]f32 = undefined;
    var total: f32 = 0;
    for (m.reactionSlice(), 0..) |*rc, i| {
        const cnt = std.fmt.bufPrint(&buf, "{d}", .{rc.count}) catch "";
        widths[i] = 6 + emojiW(ctx, rc) + 6 + d.width(fam.get(.semibold), 13, cnt) + 10;
        total += widths[i] + 4;
    }
    if (right_to_left) xx = right - total - (if (show_add) @as(f32, 36) else 0);
    for (m.reactionSlice(), 0..) |*rc, i| {
        const cnt = std.fmt.bufPrint(&buf, "{d}", .{rc.count}) catch "";
        const cr: d.Rect = .{ .x = xx, .y = y + 3, .w = widths[i], .h = 24 };
        const hb = d.hit(ctx, @truncate((m.msg.id *% 31) +% i), cr);
        // Só o que dá para clicar: atrás do cabeçalho ou da caixa, o clique seria deles.
        if (qa.on()) {
            const lo = c.ImDrawList_GetClipRectMin(dl);
            const hi = c.ImDrawList_GetClipRectMax(dl);
            if (cr.y + cr.h / 2 > lo.y and cr.y + cr.h / 2 < hi.y) qa.mark(cr, "chip:{d}:{d}", .{ m.msg.id, i });
        }
        if (hb.clicked) ctx.act(.{ .react = .{ .id = m.msg.id, .emoji = rc.* } });
        if (hb.right) ctx.popup(.{ .menu = .{ .kind = .message, .id = m.msg.id, .x = ctx.mouse.x, .y = ctx.mouse.y } });
        const bg = if (rc.me) ctx.col(.accent).alpha(0.2) else ctx.col(.elevated);
        const cr_r = @min(8, ctx.th.radius + 2);
        d.rect(dl, cr, if (hb.hovered) bg.mix(ctx.col(.text), 0.06) else bg, cr_r);
        if (rc.me or hb.hovered) d.border(dl, cr, if (rc.me) ctx.col(.accent) else ctx.col(.border).mix(ctx.col(.text), 0.1), cr_r, 1);
        if (rc.custom != 0) {
            var nb: [40]u8 = undefined;
            const shown = colonName(&nb, rc);
            if (emoji_img.enabled(ctx)) {
                emoji_img.draw(ctx, dl, rc.custom, rc.animated, .{ .x = cr.x + 6, .y = cr.y + 3, .w = 18, .h = 18 }, 1, hb.hovered, true);
            } else d.text(dl, fam.get(.medium), 12, cr.x + 6, d.centerY(cr, 12), ctx.col(.text).mix(ctx.col(.muted), 0.3), shown);
            d.tip(ctx, cr, shown, hb.hovered);
        } else {
            // Sequência (família, bandeira): cada pedaço é um desenho; cabe no lugar.
            const pick = @import("emoji_picker.zig");
            const g = pick.drawable(rc.text());
            const es = pick.fitSize(fam.get(.regular), g.slice(), 15, 18);
            d.text(dl, fam.get(.regular), es, cr.x + 6, cr.y + 12 - es * 0.67, d.Rgba.white, g.slice());
        }
        d.text(dl, fam.get(.semibold), 13, cr.x + 12 + emojiW(ctx, rc), d.centerY(cr, 13), if (rc.me) ctx.col(.accent).mix(ctx.col(.text), 0.3) else ctx.col(.muted), cnt);
        xx += cr.w + 4;
    }
    if (show_add) {
        const ar: d.Rect = .{ .x = xx, .y = y + 3, .w = 32, .h = 24 };
        const hb = d.hit(ctx, @truncate(m.msg.id ^ 0xadd), ar);
        qa.mark(ar, "chip-add:{d}", .{m.msg.id});
        d.rect(dl, ar, ctx.col(.elevated).alpha(if (hb.hovered) 1 else 0.6), @min(8, ctx.th.radius + 2));
        icons.plus(dl, ar.x + 16, ar.y + 12, 4.5, ctx.col(.muted).u());
        if (hb.clicked) ctx.popup(.{ .emoji = .{ .target = m.msg.id, .x = ar.x + 200, .y = ar.y } });
    }
}

/// Barra flutuante com reações rápidas, responder, editar e "mais".
fn toolbar(ctx: *d.Ctx, dl: *c.ImDrawList, m: *const StoredMessage, right: f32, top: f32) void {
    const own = m.msg.author == ctx.store.me and m.msg.id != 0;
    const items = [_]struct { glyph: []const u8, emoji: bool, show: bool }{
        .{ .glyph = "👍", .emoji = true, .show = true },
        .{ .glyph = "😂", .emoji = true, .show = true },
        .{ .glyph = "🔥", .emoji = true, .show = true },
        .{ .glyph = "↩", .emoji = false, .show = true },
        .{ .glyph = "✎", .emoji = false, .show = own },
        .{ .glyph = "⋯", .emoji = false, .show = true },
    };
    var count: f32 = 0;
    for (items) |it| {
        if (it.show) count += 1;
    }
    // Sem plugin com botão aqui, custa só esta comparação.
    const n_plugin: usize = if (plugins.current) |e| @min(e.n_toolbar, max_toolbar_plugins) else 0;
    count += @floatFromInt(n_plugin);
    const bw: f32 = 32;
    const tr: d.Rect = .{ .x = right - count * bw - 8, .y = top, .w = count * bw + 8, .h = 36 };
    d.shadow(dl, tr, 8, 8, ctx.col(.shadow).alpha(0.6));
    d.rect(dl, tr, ctx.col(.overlay), @max(ctx.th.radius, 4));
    d.border(dl, tr, ctx.col(.border), @max(ctx.th.radius, 4), 1);
    var x = tr.x + 4;
    for (items, 0..) |it, i| {
        if (!it.show) continue;
        // Os dos plugins ficam antes do "mais".
        if (i == items.len - 1 and n_plugin > 0) x = toolbarPlugins(ctx, dl, m, x, tr.y + 2, bw);
        const br: d.Rect = .{ .x = x, .y = tr.y + 2, .w = bw, .h = 32 };
        const hb = d.hit(ctx, @truncate((m.msg.id *% 7) +% i + 900), br);
        qa.mark(br, "tb:{d}:{d}", .{m.msg.id, i});
        if (hb.hovered) d.rect(dl, br, ctx.col(.hover).mix(ctx.col(.text), 0.05), 5);
        const fs: f32 = if (it.emoji) 18 else 17;
        const font = ctx.ui.get(if (it.emoji) .regular else .bold);
        const gw = d.width(font, fs, it.glyph);
        d.text(dl, font, fs, br.x + bw / 2 - gw / 2, d.centerY(br, fs), if (it.emoji) d.Rgba.white else (if (hb.hovered) ctx.col(.text) else ctx.col(.muted)), it.glyph);
        if (hb.clicked) switch (i) {
            0, 1, 2 => ctx.act(.{ .react = .{ .id = m.msg.id, .emoji = types.Reaction.init(it.glyph) } }),
            3 => ctx.act(.{ .reply = m.msg.id }),
            4 => ctx.act(.{ .edit_message = m.msg.id }),
            else => ctx.popup(.{ .menu = .{ .kind = .message, .id = m.msg.id, .x = br.x, .y = br.bottom() } }),
        };
        x += bw;
    }
}

/// Botões de plugin que cabem na barra, somando todos os plugins.
const max_toolbar_plugins = 3;

fn toolbarPlugins(ctx: *d.Ctx, dl: *c.ImDrawList, m: *const StoredMessage, x_in: f32, y: f32, bw: f32) f32 {
    const e = plugins.current orelse return x_in;
    var x = x_in;
    // A posição entre todas as entradas de mensagem (a mesma ordem do menu).
    var index: usize = 0;
    var shown: usize = 0;
    for (e.list.items) |p| {
        if (!p.isRunning()) continue;
        for (p.menus.items) |*entry| {
            if (entry.kind != .message) continue;
            defer index += 1;
            if (entry.toolbar.len == 0 or shown >= max_toolbar_plugins) continue;
            const br: d.Rect = .{ .x = x, .y = y, .w = bw, .h = 32 };
            const hb = d.hit(ctx, @truncate((m.msg.id *% 7) +% shown + 920), br);
            qa.mark(br, "tb-plugin:{s}", .{entry.en});
            if (hb.hovered) d.rect(dl, br, ctx.col(.hover).mix(ctx.col(.text), 0.05), 5);
            const font = ctx.ui.get(.regular);
            const gw = d.width(font, 18, entry.toolbar);
            d.text(dl, font, 18, br.x + bw / 2 - gw / 2, d.centerY(br, 18), d.Rgba.white, entry.toolbar);
            d.tip(ctx, br, i18n.tr(entry.pt, entry.en), hb.hovered);
            if (hb.clicked) @import("popup.zig").pluginEntry(ctx, .message, index, m.msg.id, br.x, br.bottom());
            shown += 1;
            x += bw;
        }
    }
    return x;
}

/// Nome/avatar clicável. O ID inclui a mensagem: a mesma pessoa aparece em
/// várias mensagens visíveis e IDs repetidos impedem o ImGui de clicar.
fn nameHit(ctx: *d.Ctx, uid: Id, msg_id: Id, r: d.Rect, salt: u64) void {
    const hb = d.hit(ctx, @truncate(msg_id *% 1_000_003 +% uid *% 131 +% salt), r);
    qa.mark(r, "user:{d}", .{uid});
    if (hb.clicked) ctx.popup(.{ .profile = .{ .user = uid, .x = r.right() + 4, .y = r.y } });
    if (hb.right) ctx.popup(.{ .menu = .{ .kind = .user, .id = uid, .x = ctx.mouse.x, .y = ctx.mouse.y } });
}

fn dayOf(m: *StoredMessage) i64 {
    if (m.day == std.math.minInt(i64)) m.day = w.localTime(m.msg.timestamp).day_index;
    return m.day;
}

/// Ícone de uma linha de sistema: entrou (seta verde), saiu (vermelha)…
fn systemIcon(ctx: *d.Ctx, dl: *c.ImDrawList, fam: *d.Family, kind: types.SystemKind, cx: f32, cy: f32) void {
    const glyph: []const u8 = switch (kind) {
        .join => "→",
        .leave => "←",
        .call => "☎",
        .pin => "📌",
        .boost => "✦",
        .edit => "✎",
        else => "•",
    };
    const col = switch (kind) {
        .join => ctx.col(.online),
        .leave => ctx.col(.danger),
        .boost => ctx.col(.accent),
        else => ctx.col(.muted),
    };
    const fs: f32 = 16;
    const tw = d.width(fam.get(.bold), fs, glyph);
    d.text(dl, fam.get(.bold), fs, cx - tw / 2, cy - fs * 0.62, col, glyph);
}

fn guildOf(ctx: *const d.Ctx, channel: types.Id) types.Id {
    return if (ctx.store.channel(channel)) |cs| cs.info.guild else 0;
}

fn drawMessage(ctx: *d.Ctx, dl: *c.ImDrawList, g: Geo, m: *StoredMessage, flags: u8, r: d.Rect, y_in: f32, under: bool, sel_from: u32, sel_to: u32, probe: ?*rich.Probe) void {
    var y = y_in;
    var buf: [96]u8 = undefined;
    const group = flags & flag_group != 0;
    const day = flags & flag_day != 0;
    const reply = flags & flag_reply != 0;
    const u = ctx.store.user(m.msg.author);
    const name = if (u) |x| x.name else "?";
    const role_col = w.nameColor(ctx, guildOf(ctx, m.msg.channel), m.msg.author);
    const alpha: f32 = if (m.pending) 0.5 else 1;
    const fam = g.fam;
    const self = m.msg.author == ctx.store.me;
    var o = textOpts(ctx, g, self and g.variant == .bubbles);
    o.color = o.color.alpha(alpha);
    // Apagada (registro ligado): o texto fica avermelhado.
    if (m.deleted) o.color = o.color.mix(ctx.col(.danger), 0.55);
    // Linha de sistema: texto cinza.
    if (m.msg.system != .none) o.color = ctx.col(.muted);
    o.base = m.msg.content.ptr;
    o.sel_from = sel_from;
    o.sel_to = sel_to;
    o.probe = probe;
    // Blocos de código com o botão "Copiar".
    o.ctx = ctx;
    o.msg_id = m.msg.id;
    const show_bar = under and ctx.st.popup == .none and !ctx.st.selection.dragging and m.msg.id != 0;

    // Destaque ao pular para esta mensagem.
    const flash = if (m.msg.id == flash_id and ctx.now_ms < flash_until) blk: {
        anim.active = true;
        break :blk @as(f32, @floatFromInt(flash_until - ctx.now_ms)) / 1600.0;
    } else 0;
    // Menção a mim: faixa amarela à esquerda, como no Discord.
    // Palavra de alerta (Configurações → Alertas e filtros) destaca igual.
    var mentions_me = ctx.st.filtros.flags(m) & @import("../core/filtros.zig").bit_alert != 0;
    for (m.spans) |sp| if (sp.mention == .user and sp.mention.user == ctx.store.me) {
        mentions_me = true;
    };

    switch (g.variant) {
        .cozy => {
            if (day) {
                daySeparator(ctx, dl, fam, r, y + 23, m.msg.timestamp, false);
                y += 46;
            }
            const row: d.Rect = .{ .x = r.x, .y = y, .w = r.w, .h = m.height - (if (day) @as(f32, 46) else 0) };
            if (mentions_me) {
                d.rect(dl, row, ctx.col(.idle).alpha(0.08), 0);
                d.rect(dl, .{ .x = r.x, .y = row.y, .w = 2, .h = row.h }, ctx.col(.idle), 0);
            }
            if (under) d.rect(dl, row, d.Rgba.black.alpha(0.07), 0);
            if (flash > 0) d.rect(dl, row, ctx.col(.accent).alpha(0.25 * flash), 0);
            const tx = r.x + g.content_x;
            if (group) {
                y += g.spacing;
                if (reply) {
                    replyLine(ctx, dl, g, m, tx, y, g.wrap, if (g.avatar > 0) r.x + 16 + g.avatar / 2 else null, false);
                    y += reply_h;
                }
                if (g.avatar > 0) {
                    const ar: d.Rect = .{ .x = r.x + 16, .y = y, .w = g.avatar, .h = g.avatar };
                    w.avatar(ctx, dl, ar.x + g.avatar / 2, ar.y + g.avatar / 2, g.avatar, m.msg.author, g.shape, null, alpha);
                    nameHit(ctx, m.msg.author, m.msg.id, ar, 1);
                }
                const nw = d.width(fam.get(.semibold), g.size, name);
                const nr: d.Rect = .{ .x = tx, .y = y, .w = nw, .h = g.line_h };
                nameHit(ctx, m.msg.author, m.msg.id, nr, 2);
                d.text(dl, fam.get(.semibold), g.size, tx, y + (g.line_h - g.size * 1.2) / 2, role_col.alpha(alpha), name);
                if (ctx.hovering(nr)) d.line(dl, tx, nr.bottom() - 2, tx + nw, nr.bottom() - 2, role_col, 1);
                const tag_w = w.botTag(ctx, dl, tx + nw, y + g.line_h / 2, u, false, alpha);
                const stp = w.stamp(&buf, m.msg.timestamp, @divTrunc(ctx.now_ms, 1000));
                d.text(dl, fam.get(.medium), 12, tx + nw + tag_w + 8, y + (g.line_h - 12 * 1.2) / 2 + 1, ctx.col(.faint), stp);
                stampTip(ctx, under, m, .{ .x = tx + nw + tag_w + 8, .y = y, .w = d.width(fam.get(.medium), 12, stp), .h = g.line_h });
                y += g.line_h;
            } else {
                y += 1;
                if (m.msg.system != .none) {
                    systemIcon(ctx, dl, fam, m.msg.system, r.x + 16 + @max(g.avatar, 24) / 2, y + g.line_h / 2);
                } else if (under and g.avatar > 0) {
                    const ck = w.clock(&buf, m.msg.timestamp);
                    const sw = d.width(fam.get(.medium), 11, ck);
                    d.text(dl, fam.get(.medium), 11, r.x + 16 + g.avatar / 2 - sw / 2, y + 5, ctx.col(.faint), ck);
                    stampTip(ctx, under, m, .{ .x = r.x + 16 + g.avatar / 2 - sw / 2, .y = y + 3, .w = sw, .h = 16 });
                }
            }
            const t = rich.layout(dl, ctx.store, ctx.th, m.spans, tx, y, g.wrap, o, ctx.mouse);
            editedMark(ctx, dl, g, m, tx, y, t);
            if (m.msg.content.len > 0) qa.mark(.{ .x = tx, .y = y, .w = @max(t.w, 4), .h = t.h }, "msgtext:{d}", .{m.msg.id});
            const th = textH(g, m, t);
            att.draw(ctx, dl, m, tx, y + th, g.wrap, alpha);
            var ah = att.blockHeight(m.msg.attachments, g.wrap, m.msg.content.len > 0);
            ah += emb.block(ctx, dl, m, tx, y + th + ah, g.wrap, alpha, .{ .from = sel_from, .to = sel_to, .probe = probe });
            ah += threads.card(ctx, dl, m, tx, y + th + ah, g.wrap);
            ah += decoBlock(ctx, dl, g, m, tx, y + th + ah);
            if (m.failed) failedRow(ctx, dl, g, m, tx, y + th + ah);
            if (m.n_reactions > 0) reactions(ctx, dl, m, tx, y + th + ah, under, false, 0);
            if (ctx.st.settings.developer_mode and under) {
                const idt = std.fmt.bufPrint(&buf, "id {d}", .{m.msg.id}) catch "";
                const iw = d.width(fam.get(.regular), 11, idt);
                d.text(dl, fam.get(.regular), 11, r.right() - iw - 14, row.bottom() - 16, ctx.col(.faint), idt);
            }
            if (show_bar) toolbar(ctx, dl, m, r.right() - 16, row.y - 16 + (if (group) g.spacing else 0));
        },
        .irc => {
            if (day) {
                daySeparator(ctx, dl, fam, r, y + (g.line_h + 10) / 2, m.msg.timestamp, true);
                y += g.line_h + 10;
            }
            if (group) y += 4;
            const row: d.Rect = .{ .x = r.x, .y = y, .w = r.w, .h = m.height - (y - y_in) };
            if (under) d.rect(dl, row, ctx.col(.hover), 0);
            if (flash > 0) d.rect(dl, row, ctx.col(.accent).alpha(0.25 * flash), 0);
            if (mentions_me) d.rect(dl, .{ .x = r.x, .y = row.y, .w = 2, .h = row.h }, ctx.col(.mention), 0);
            if (reply) {
                const found = ctx.store.findNear(m.msg.channel, m.msg.reply_to);
                const ru = if (found) |f| ctx.store.user(f.m.msg.author) else null;
                var rb: [160]u8 = undefined;
                var sb: [60]u8 = undefined;
                const line = std.fmt.bufPrint(&rb, "↳ {s}: {s}", .{ if (ru) |x| x.name else "?", if (found) |f| snippet(&sb, quotedText(ctx, f.m)) else "…" }) catch "";
                const lr: d.Rect = .{ .x = r.x + g.content_x, .y = y, .w = g.wrap, .h = g.line_h };
                const hb = d.hitUnder(ctx, @truncate(m.msg.id ^ 0x5151), lr);
                qa.mark(lr, "reply-line:{d}", .{m.msg.id});
                if (hb.clicked) ctx.act(.{ .jump_to = m.msg.reply_to });
                if (hb.right) ctx.popup(.{ .menu = .{ .kind = .message, .id = m.msg.id, .x = ctx.mouse.x, .y = ctx.mouse.y } });
                _ = d.textClipped(dl, fam.get(.regular), g.size - 1, lr.x, d.centerY(lr, g.size - 1), if (hb.hovered) ctx.col(.text) else ctx.col(.faint), line, lr.w);
                y += g.line_h;
            }
            const ty = y + (g.line_h - g.size * 1.2) / 2;
            var x = r.x + 10;
            const ts = std.fmt.bufPrint(&buf, "[{s}] ", .{w.clock(buf[64..], m.msg.timestamp)}) catch "";
            d.text(dl, fam.get(.regular), g.size, x, ty, ctx.col(.faint), ts);
            stampTip(ctx, under, m, .{ .x = x, .y = y, .w = d.width(fam.get(.regular), g.size, ts), .h = g.line_h });
            x += d.width(fam.get(.regular), g.size, ts);
            const col_w = g.prefix_w - d.width(fam.get(.regular), g.size, "[00:00] ") - d.width(fam.get(.regular), g.size, " │ ");
            // A coluna do nome é justificada à direita: o sinal de bot fica antes dele.
            const mark_w = w.botMarkSpace(fam.get(.bold), g.size, u);
            const name_col_w = @max(col_w - mark_w, 24);
            const nw = @min(d.width(fam.get(.bold), g.size, name), name_col_w);
            const nick_col = if (group) role_col else role_col.alpha(0.35);
            nameHit(ctx, m.msg.author, m.msg.id, .{ .x = x + col_w - nw, .y = y, .w = nw, .h = g.line_h }, 3);
            _ = d.textClipped(dl, fam.get(.bold), g.size, x + col_w - nw, ty, nick_col.alpha(alpha), name, name_col_w);
            w.botMark(ctx, dl, fam.get(.bold), g.size, x + col_w - nw - mark_w, y, g.line_h, u, (if (group) @as(f32, 1) else 0.35) * alpha);
            x += col_w;
            d.text(dl, fam.get(.regular), g.size, x, ty, ctx.col(.border).mix(ctx.col(.faint), 0.6), " │ ");
            const t = rich.layout(dl, ctx.store, ctx.th, m.spans, r.x + g.content_x, y, g.wrap, o, ctx.mouse);
            editedMark(ctx, dl, g, m, r.x + g.content_x, y, t);
            if (m.msg.content.len > 0) qa.mark(.{ .x = r.x + g.content_x, .y = y, .w = @max(t.w, 4), .h = t.h }, "msgtext:{d}", .{m.msg.id});
            const th = textH(g, m, t);
            att.draw(ctx, dl, m, r.x + g.content_x, y + th, g.wrap, alpha);
            var ah = att.blockHeight(m.msg.attachments, g.wrap, m.msg.content.len > 0);
            ah += emb.block(ctx, dl, m, r.x + g.content_x, y + th + ah, g.wrap, alpha, .{ .from = sel_from, .to = sel_to, .probe = probe });
            ah += threads.card(ctx, dl, m, r.x + g.content_x, y + th + ah, g.wrap);
            ah += decoBlock(ctx, dl, g, m, r.x + g.content_x, y + th + ah);
            if (m.failed) failedRow(ctx, dl, g, m, r.x + g.content_x, y + th + ah);
            if (m.n_reactions > 0) reactions(ctx, dl, m, r.x + g.content_x, y + th + ah - 2, under, false, 0);
            if (show_bar) toolbar(ctx, dl, m, r.right() - 12, row.y - 2);
        },
        .bubbles => {
            if (day) {
                daySeparator(ctx, dl, fam, r, y + 23, m.msg.timestamp, false);
                y += 46;
            }
            const left_pad: f32 = 20 + (if (g.avatar > 0) g.avatar + 10 else 0);
            if (group) {
                y += g.spacing;
                if (!self) {
                    const nw = d.width(fam.get(.semibold), 13, name);
                    nameHit(ctx, m.msg.author, m.msg.id, .{ .x = r.x + left_pad + 6, .y = y, .w = nw, .h = 16 }, 4);
                    d.text(dl, fam.get(.semibold), 13, r.x + left_pad + 6, y, role_col, name);
                    _ = w.botTag(ctx, dl, r.x + left_pad + 6 + nw, y + 8, u, false, 1);
                    y += 18;
                }
            } else y += 3;
            const reacts: f32 = if (m.n_reactions > 0) react_h else 0;
            const bw = @min(m.natural_w, g.wrap) + 28;
            const bh = m.height - (y - y_in) - reacts;
            const bx = if (self) r.right() - 24 - bw else r.x + left_pad;
            const br: d.Rect = .{ .x = bx, .y = y, .w = bw, .h = bh };
            const fill = if (self) ctx.col(.bubble_self) else ctx.col(.bubble_other);
            d.rect(dl, br, fill.alpha(alpha), 18);
            if (!group) d.rectFlags(dl, .{ .x = if (self) br.right() - 18 else br.x, .y = br.y, .w = 18, .h = 18 }, fill.alpha(alpha), 5, if (self) c.ImDrawFlags_RoundTopRight else c.ImDrawFlags_RoundTopLeft);
            if (flash > 0) d.border(dl, br.inset(-3, -3), ctx.col(.accent).alpha(flash), 20, 2);
            if (!self and g.avatar > 0 and group) {
                const ar: d.Rect = .{ .x = r.x + 20, .y = br.y, .w = g.avatar, .h = g.avatar };
                w.avatar(ctx, dl, ar.x + g.avatar / 2, ar.y + g.avatar / 2, g.avatar, m.msg.author, g.shape, null, alpha);
                nameHit(ctx, m.msg.author, m.msg.id, ar, 5);
            }
            var ty = br.y + 7;
            if (reply) {
                d.rect(dl, .{ .x = br.x + 10, .y = ty, .w = 3, .h = reply_h - 2 }, if (self) ctx.col(.bubble_self_text).alpha(0.6) else ctx.col(.accent), 2);
                var gg = g;
                gg.avatar = 0;
                replyLine(ctx, dl, gg, m, br.x + 18, ty, bw - 30, null, self);
                ty += reply_h + 4;
            }
            const t = rich.layout(dl, ctx.store, ctx.th, m.spans, br.x + 14, ty, g.wrap, o, ctx.mouse);
            editedMark(ctx, dl, g, m, br.x + 14, ty, t);
            if (m.msg.content.len > 0) qa.mark(.{ .x = br.x + 14, .y = ty, .w = @max(t.w, 4), .h = t.h }, "msgtext:{d}", .{m.msg.id});
            att.draw(ctx, dl, m, br.x + 14, ty + textH(g, m, t), g.wrap, alpha);
            const below = textH(g, m, t) + att.blockHeight(m.msg.attachments, g.wrap, m.msg.content.len > 0);
            var eh = emb.block(ctx, dl, m, br.x + 14, ty + below, g.wrap, alpha, .{ .from = sel_from, .to = sel_to, .probe = probe });
            eh += threads.card(ctx, dl, m, br.x + 14, ty + below + eh, g.wrap);
            eh += decoBlock(ctx, dl, g, m, br.x + 14, ty + below + eh);
            if (m.failed) failedRow(ctx, dl, g, m, br.x + 14, ty + below + eh);
            if (m.n_reactions > 0) reactions(ctx, dl, m, br.x, br.bottom(), under, self, br.right());
            if (ctx.hovering(br)) {
                const ck = w.clock(&buf, m.msg.timestamp);
                const sw = d.width(fam.get(.medium), 11, ck);
                const sx = if (self) br.x - sw - 8 else br.right() + 8;
                d.text(dl, fam.get(.medium), 11, sx, br.y + br.h / 2 - 7, ctx.col(.faint), ck);
                stampTip(ctx, under, m, .{ .x = sx, .y = br.y + br.h / 2 - 9, .w = sw, .h = 18 });
            }
            // "Entregue ✓✓" embaixo da nossa última mensagem.
            if (show_ticks and self and (m.msg.id == last_self_id or (m.pending and last_self_id == std.math.maxInt(Id)))) {
                const tick = if (m.failed) i18n.tr("Não enviada", "Not sent") else if (m.pending) i18n.tr("Enviando…", "Sending…") else i18n.tr("Entregue ✓✓", "Delivered ✓✓");
                const tw = d.width(fam.get(.medium), 11, tick);
                const tick_y = br.bottom() + (if (m.n_reactions > 0) react_h else 0) + 1;
                d.text(dl, fam.get(.medium), 11, br.right() - tw - 4, tick_y, if (m.failed) ctx.col(.danger) else if (m.pending) ctx.col(.faint) else ctx.col(.accent), tick);
            }
            if (show_bar) toolbar(ctx, dl, m, if (self) br.x - 50 else @min(br.right() + 180, r.right() - 12), br.y - 12);
        },
    }
}

/// Mouse em cima do horário: a data completa. Só na mensagem sob o mouse.
fn stampTip(ctx: *d.Ctx, under: bool, m: *const StoredMessage, r: d.Rect) void {
    if (!under) return;
    qa.mark(r, "stamp:{d}", .{m.msg.id});
    if (!ctx.hovering(r)) return;
    var buf: [96]u8 = undefined;
    d.tip(ctx, r, w.fullDate(&buf, m.msg.timestamp), true);
}

fn editedMark(ctx: *d.Ctx, dl: *c.ImDrawList, g: Geo, m: *const StoredMessage, x: f32, y: f32, t: rich.Measure) void {
    if (!m.msg.edited and !m.deleted) return;
    const ew = editedW(g);
    const wraps = t.last_x + ew > g.wrap;
    const ex = if (wraps) x else x + t.last_x + 6;
    const ey = y + t.h - g.line_h + (if (wraps) g.line_h else 0);
    // Registro de mensagens: "(apagada)" em vermelho, e o texto original
    // de uma editada aparece com o mouse em cima do "(editado)".
    const lbl = if (m.deleted) i18n.tr("(apagada)", "(deleted)") else editedLabel();
    const col = if (m.deleted) ctx.col(.danger) else if (m.original != null) ctx.col(.muted) else ctx.col(.faint);
    const lr: d.Rect = .{ .x = ex, .y = ey, .w = d.width(g.fam.get(.regular), 11, lbl), .h = g.line_h };
    d.text(dl, g.fam.get(.regular), 11, ex, ey + (g.line_h - 13) / 2, col, lbl);
    if (m.original) |o| if (ctx.hovering(lr)) {
        var buf: [200]u8 = undefined;
        const n = d.utf8Prefix(o, 120).len;
        const tip = i18n.fmt(&buf, "antes: {s}{s}", "before: {s}{s}", .{ o[0..n], if (o.len > n) "…" else "" });
        d.tip(ctx, lr, tip, true);
    };
}

fn daySeparator(ctx: *d.Ctx, dl: *c.ImDrawList, fam: *d.Family, r: d.Rect, mid: f32, ts: i64, tty: bool) void {
    var buf: [64]u8 = undefined;
    const lbl = w.dayLabel(&buf, ts);
    const font = fam.get(.semibold);
    const fs: f32 = if (tty) ctx.th.font_size - 2 else 12;
    const lw = d.width(font, fs, lbl);
    const lx = if (tty) r.x + 40 else r.x + r.w / 2 - lw / 2;
    const lc = ctx.col(.border).mix(ctx.col(.text), 0.04);
    d.line(dl, r.x + 16, mid, lx - 10, mid, lc, 1);
    d.line(dl, lx + lw + 10, mid, r.right() - 16, mid, lc, 1);
    d.text(dl, font, fs, lx, mid - fs * 0.6, ctx.col(.faint), lbl);
}

// --- composer ---------------------------------------------------------------

fn inputCallback(data: [*c]c.ImGuiInputTextCallbackData) callconv(.c) c_int {
    const st: *@import("state.zig").State = @ptrCast(@alignCast(data.*.UserData));
    if (st.input_sync) {
        st.input_sync = false;
        c.ImGuiInputTextCallbackData_DeleteChars(data, 0, data.*.BufTextLen);
        c.ImGuiInputTextCallbackData_InsertChars(data, 0, &st.input, null);
        // O autocompletar pediu o cursor logo depois do que entrou.
        if (autocomplete.pending_cursor) |p| {
            autocomplete.pending_cursor = null;
            const at: c_int = @intCast(@min(p, @as(usize, @intCast(data.*.BufTextLen))));
            data.*.CursorPos = at;
            data.*.SelectionStart = at;
            data.*.SelectionEnd = at;
        }
    }
    autocomplete.cursor = @intCast(@max(data.*.CursorPos, 0));
    return 0;
}

/// Altura a mais da caixa de texto (as linhas além da primeira). Ela cresce
/// para cima e a conversa encolhe junto (`messages`).
pub var composer_extra: f32 = 0;
const composer_max_lines = 10;

pub fn composer(ctx: *d.Ctx, n: *const kdl.Node, r_in: d.Rect) void {
    if (ctx.st.friends) return;
    const ch_id = ctx.st.activeChannel() orelse return;
    const cs = ctx.store.channel(ch_id) orelse return;
    // No lugar da caixa: "Novo post" num fórum, o aviso numa thread sem permissão.
    if (cs.info.kind == .forum or (cs.info.thread != null and !ctx.store.canSend(&cs.info))) {
        composer_extra = 0;
        vim.composer_active = false;
        return forum.composerBand(ctx, n, r_in, cs);
    }
    const grown = composer_extra;
    const r: d.Rect = .{ .x = r_in.x, .y = r_in.y - grown, .w = r_in.w, .h = r_in.h + grown };
    const fam = ctx.familyFor(n);
    const variant = d.pstr(n, "variant", "box");
    const dl = ctx.dl;
    const st = ctx.st;
    const prompt = std.mem.eql(u8, variant, "prompt");
    const pill = std.mem.eql(u8, variant, "pill");

    // Arquivos que vão junto (acima de tudo que fica preso na caixa).
    const tray_h = att.trayHeight(ctx);
    if (tray_h > 0) {
        const extra: f32 = if (st.reply_to != 0 or st.editing != 0) 32 else 0;
        att.tray(ctx, dl, .{ .x = r.x + (if (pill) @as(f32, 18) else 0), .y = r.y - extra - tray_h, .w = r.w - (if (pill) @as(f32, 36) else 0), .h = tray_h - (if (extra > 0) @as(f32, 2) else 0) });
    }

    // Barra "Respondendo a…" / "Editando…" presa em cima da caixa.
    var top = r.y;
    if (st.reply_to != 0 or st.editing != 0) {
        const bar: d.Rect = .{ .x = r.x + (if (pill) @as(f32, 18) else 0), .y = r.y - 32, .w = r.w - (if (pill) @as(f32, 36) else 0), .h = 34 };
        d.rectFlags(dl, bar, ctx.col(.rail).mix(ctx.col(.elevated), 0.5), @max(ctx.th.radius + 4, 4), c.ImDrawFlags_RoundTop);
        var buf: [128]u8 = undefined;
        const t = if (st.editing != 0)
            i18n.tr3("Editando mensagem  ·  Esc cancela  ·  Enter salva", "Editing message  ·  Esc to cancel  ·  Enter to save", "メッセージを編集中  ·  Escでキャンセル  ·  Enterで保存")
        else blk: {
            const f = ctx.store.findAny(st.reply_to);
            const u = if (f) |x| ctx.store.user(x.m.msg.author) else null;
            if (u) |x| break :blk i18n.fmt(&buf, "Respondendo a {s}", "Replying to {s}", .{x.name});
            break :blk i18n.tr3("Respondendo a mensagem", "Replying to a message", "メッセージに返信中");
        };
        d.text(dl, fam.get(.medium), 13, bar.x + 14, bar.y + 8, ctx.col(.muted), t);
        const xr: d.Rect = .{ .x = bar.right() - 30, .y = bar.y + 5, .w = 22, .h = 22 };
        const hb = d.hit(ctx, 9, xr);
        qa.mark(xr, "compose-cancel", .{});
        const xc = if (hb.hovered) ctx.col(.text) else ctx.col(.faint);
        d.circle(dl, xr.x + 11, xr.y + 11, 9, if (hb.hovered) ctx.col(.hover) else ctx.col(.faint).alpha(0.25));
        d.line(dl, xr.x + 7, xr.y + 7, xr.x + 15, xr.y + 15, xc, 1.6);
        d.line(dl, xr.x + 15, xr.y + 7, xr.x + 7, xr.y + 15, xc, 1.6);
        if (hb.clicked) ctx.act(.cancel_compose);
        top = bar.y;
    }

    // Prévia do markdown, acima de tudo que fica preso na caixa.
    {
        const typing_gap: f32 = if (d.pflag(n, "typing", true) and cs.typing.items.len > 0) 22 else 6;
        const inset: f32 = if (pill) 18 else 0;
        md_preview.draw(ctx, dl, fam, r.x + inset, top - tray_h - typing_gap, r.w - inset * 2, typing_gap);
        const preview_h = md_preview.height(st);
        lsp_ui.place(fam, r.x + inset, top - tray_h - (if (preview_h > 0) preview_h + 4 else typing_gap), r.w - inset * 2);
    }

    if (d.pflag(n, "typing", true) and cs.typing.items.len > 0) {
        const u = ctx.store.user(cs.typing.items[0].user);
        var buf: [96]u8 = undefined;
        const who = if (u) |x| x.name else i18n.tr3("alguém", "someone", "誰か");
        const t = i18n.fmt(&buf, "{s} está digitando", "{s} is typing", .{who});
        const ty = top - 19;
        const tx = r.x + (if (prompt) @as(f32, 10) else 6);
        w.typingDots(dl, tx + 4, ty + 8, ctx.col(.muted), ctx.now_ms);
        d.text(dl, fam.get(.semibold), 13, tx + 24, ty, ctx.col(.muted), t);
    }

    var input_x: f32 = r.x + 48;
    var input_r = r.right() - 96;
    if (prompt) {
        d.line(dl, r.x, r.y + 0.5, r.right(), r.y + 0.5, ctx.col(.border), 1);
        const me = ctx.store.user(ctx.store.me);
        var buf: [96]u8 = undefined;
        const p = std.fmt.bufPrint(&buf, "{s}@{s}{s} {s} ", .{ if (me) |x| x.name else i18n.tr3("eu", "me", "自分"), sigil(&cs.info), cs.info.name, if (st.editing != 0) "✎" else if (st.reply_to != 0) "↩" else "❯" }) catch "❯ ";
        const fs = ctx.th.font_size;
        d.text(dl, fam.get(.bold), fs, r.x + 10, d.centerY(r, fs), ctx.col(.accent), p);
        input_x = r.x + 10 + d.width(fam.get(.bold), fs, p);
        const gw = d.width(fam.get(.bold), fs, "[gif]") + 8;
        input_r = r.right() - 80 - gw;
        const gr: d.Rect = .{ .x = r.right() - 72 - gw, .y = r.y + r.h / 2 - 13, .w = gw, .h = 26 };
        const gh = d.hit(ctx, 40, gr);
        qa.mark(gr, "composer-gif", .{});
        d.text(dl, fam.get(.bold), fs, gr.x + 4, d.centerY(gr, fs), if (gh.hovered) ctx.col(.accent) else ctx.col(.muted), "[gif]");
        if (gh.clicked) ctx.popup(.{ .gif = .{ .x = gr.right(), .y = r.y } });
        d.tip(ctx, gr, i18n.tr("GIFs", "GIFs"), gh.hovered);
        const pr: d.Rect = .{ .x = r.right() - 70, .y = r.y + r.h / 2 - 13, .w = 30, .h = 26 };
        const ph = d.hit(ctx, 1, pr);
        qa.mark(pr, "composer-attach", .{});
        d.text(dl, fam.get(.bold), fs, pr.x + 4, d.centerY(pr, fs), if (ph.hovered) ctx.col(.accent) else ctx.col(.muted), "[+]");
        if (ph.clicked) ctx.act(.pick_files);
        d.tip(ctx, pr, i18n.tr3("Anexar arquivo", "Attach File", "ファイルを添付"), ph.hovered);
        const er: d.Rect = .{ .x = r.right() - 36, .y = r.y + r.h / 2 - 13, .w = 26, .h = 26 };
        const eh = d.hit(ctx, 2, er);
        qa.mark(er, "composer-emoji", .{});
        d.text(dl, fam.get(.regular), 18, er.x + 4, er.y + 2, d.Rgba.white.alpha(if (eh.hovered) 1 else 0.6), "😊");
        if (eh.clicked) ctx.popup(.{ .emoji = .{ .target = 0, .x = er.right(), .y = r.y } });
    } else {
        const radius = if (pill) r.h / 2 else ctx.th.radius + 4;
        const flags: c_int = if (st.reply_to != 0 or st.editing != 0) c.ImDrawFlags_RoundBottom else 0;
        d.rectFlags(dl, r, ctx.col(.elevated), radius, flags);
        const ar: d.Rect = .{ .x = r.x + 10, .y = r.y + r.h / 2 - 14, .w = 28, .h = 28 };
        const ah = d.hit(ctx, 1, ar);
        qa.mark(ar, "composer-attach", .{});
        const ak = anim.to(anim.id("attach", @intFromPtr(n)), if (ah.hovered) 1 else 0, 24);
        d.circle(dl, ar.x + 14, ar.y + 14, 11.5, ctx.col(.muted).mix(ctx.col(.text), ak));
        icons.plus(dl, ar.x + 14, ar.y + 14, 5.5, ctx.col(.elevated).u());
        if (ah.clicked) ctx.act(.pick_files);
        d.tip(ctx, ar, i18n.tr3("Anexar arquivo", "Attach File", "ファイルを添付"), ah.hovered);
        const ex = r.right() - (if (pill) @as(f32, 84) else 40);
        const gr: d.Rect = .{ .x = ex - 36, .y = r.y + r.h / 2 - 11, .w = 32, .h = 22 };
        const gh = d.hit(ctx, 40, gr);
        qa.mark(gr, "composer-gif", .{});
        const gif_ink = if (gh.hovered) ctx.col(.text) else ctx.col(.muted);
        d.border(dl, gr, gif_ink, 5, 1.5);
        d.text(dl, fam.get(.bold), 11, gr.x + (gr.w - d.width(fam.get(.bold), 11, "GIF")) / 2, d.centerY(gr, 11), gif_ink, "GIF");
        if (gh.clicked) ctx.popup(.{ .gif = .{ .x = gr.right(), .y = r.y } });
        d.tip(ctx, gr, i18n.tr("GIFs", "GIFs"), gh.hovered);
        const er: d.Rect = .{ .x = ex, .y = r.y + r.h / 2 - 14, .w = 28, .h = 28 };
        const eh = d.hit(ctx, 2, er);
        qa.mark(er, "composer-emoji", .{});
        const ek = anim.to(anim.id("emoji", @intFromPtr(n)), if (eh.hovered) 1 else 0, 20);
        const es: f32 = 20 + 2 * ek;
        d.text(dl, fam.get(.regular), es, ex + 14 - es / 2, r.y + r.h / 2 - es * 0.6, d.Rgba.white.alpha(0.55 + 0.45 * ek), "😊");
        if (eh.clicked) ctx.popup(.{ .emoji = .{ .target = 0, .x = er.right(), .y = r.y } });
        d.tip(ctx, er, i18n.tr("Emojis", "Emoji"), eh.hovered);
        if (pill) {
            const sr: d.Rect = .{ .x = r.right() - 44, .y = r.y + r.h / 2 - 17, .w = 34, .h = 34 };
            const sh = d.hit(ctx, 3, sr);
            qa.mark(sr, "composer-send", .{});
            const sk = anim.to(anim.id("send", @intFromPtr(n)), if (sh.hovered) 1 else 0, 20);
            d.circle(dl, sr.x + 17, sr.y + 17, 17, ctx.col(.accent).mix(d.Rgba.white, sk * 0.12));
            const ink = ctx.col(.accent_text).u();
            c.ImDrawList_AddTriangleFilled(dl, d.v(sr.x + 11, sr.y + 10), d.v(sr.x + 25, sr.y + 17), d.v(sr.x + 11, sr.y + 24), ink);
            if (sh.clicked) submit(ctx);
            d.tip(ctx, sr, i18n.tr("Enviar  (Enter)", "Send  (Enter)"), sh.hovered);
        }
        input_r = gr.x - 6;
    }

    const fs = ctx.th.font_size;
    const font_px = d.fontPx(fs);
    const input_w = @max(40, input_r - input_x);
    const frame_h = font_px + 8 + grown;
    // Quantas linhas o texto ocupa: a caixa cresce até `composer_max_lines`
    // (depois rola por dentro). A medida vale para o próximo quadro.
    {
        const len = std.mem.indexOfScalar(u8, &st.input, 0) orelse st.input.len;
        const pad_x = c.ImGui_GetStyle().*.FramePadding.x;
        var lines: f32 = 1;
        if (len > 0) {
            const b: [*]const u8 = &st.input;
            const sz = c.ImFont_CalcTextSizeAEx(fam.get(.regular), font_px, std.math.floatMax(f32), input_w - pad_x * 2 - 16, b, b + len, null);
            lines = @round(sz.y / font_px);
            if (st.input[len - 1] == '\n') lines += 1;
        }
        const want = (std.math.clamp(lines, 1, composer_max_lines) - 1) * font_px;
        if (want != composer_extra) {
            composer_extra = want;
            anim.active = true;
        }
    }
    c.ImGui_PushFontFloat(fam.get(.regular), font_px);
    const input_y = r.y + (r.h - frame_h) / 2;
    c.ImGui_SetCursorScreenPos(d.v(input_x, input_y));
    qa.mark(.{ .x = input_x, .y = r.y, .w = input_w, .h = r.h }, "composer", .{});
    if (st.focus_input and !st.palette.open and !st.settings.open and st.popup == .none) {
        c.ImGui_SetKeyboardFocusHere();
        st.focus_input = false;
    }
    var hint_buf: [96]u8 = undefined;
    const hint = if (prompt) "" else if (cs.info.guild == 0)
        i18n.fmtZ(&hint_buf, "Conversar com @{s}", "Message @{s}", .{cs.info.name})
    else
        i18n.fmtZ(&hint_buf, "Conversar em {s}{s}", "Message {s}{s}", .{ sigil(&cs.info), cs.info.name });
    // A caixa vazia mostra a dica (a multilinha do ImGui não tem).
    if (st.input[0] == 0 and hint.len > 0) d.text(dl, fam.get(.regular), fs, input_x + c.ImGui_GetStyle().*.FramePadding.x, input_y + 4, ctx.col(.faint), hint);
    // Enter envia; Shift+Enter (ou Ctrl+Enter) abre uma linha nova.
    const flags = c.ImGuiInputTextFlags_EnterReturnsTrue | c.ImGuiInputTextFlags_CallbackAlways | c.ImGuiInputTextFlags_CtrlEnterForNewLine | c.ImGuiInputTextFlags_WordWrap;
    // Navegação vim: Esc sai da caixa e o texto fica (o ImGui desfaria).
    const keep = vim.escapeKeepsText(st);
    // O ImGui solta a caixa no próprio quadro do Esc: depois dele ela já não
    // está ativa. É preciso lembrar como estava antes.
    const was_active = vim.composer_active;
    var kept: @TypeOf(st.input) = undefined;
    if (keep) kept = st.input;
    if (c.ImGui_InputTextMultilineEx("##composer", &st.input, st.input.len, d.v(input_w, frame_h), flags, inputCallback, st))
        // Alt+Enter é tela cheia (ui/root.zig): não manda a mensagem.
        if (!ctx.io.*.KeyAlt) submit(ctx);
    // Avisa o Discord quando o texto muda (o app limita a um a cada 8 s).
    if (c.ImGui_IsItemEdited() and st.input[0] != 0) ctx.act(.{ .typing = ch_id });
    const active = c.ImGui_IsItemActive();
    lsp_ui.afterInput(ctx, dl, fam.get(.regular), .{ .x = input_x, .y = input_y, .w = input_w, .h = frame_h }, font_px, active, grown == composer_extra);
    // Seta para cima com a caixa vazia: edita a última mensagem.
    if (active and st.input[0] == 0 and c.ImGui_IsKeyPressed(c.ImGuiKey_UpArrow)) st.edit_last = true;
    if (keep) st.input = kept;
    vim.composer_active = active;
    c.ImGui_PopFont();
    // A lista fica acima de tudo que está preso na caixa.
    {
        const inset: f32 = if (pill) 18 else 0;
        autocomplete.update(ctx, ch_id, active, .{ .x = r.x + inset, .y = top - tray_h, .w = r.w - inset * 2, .h = 0 });
    }
    // Ctrl+V com imagem copiada (print, imagem do navegador): vira anexo.
    if (active and ctx.io.*.KeyCtrl and c.ImGui_IsKeyPressed(c.ImGuiKey_V)) {
        const has_image = @import("../platform/window.zig").clipboardImage() != null;
        const has_text = c.SDL_HasClipboardText();
        if (has_image and !has_text) ctx.act(.paste_image);
        if (qa.on() or @import("../platform/debug_log.zig").isOn()) std.log.info("colar: imagem {}, texto {}", .{ has_image, has_text });
    }
    // Esc cancela a edição (ou a resposta), com ou sem foco na caixa. A lista de
    // sugestões aberta e os painéis por cima pegam o Esc primeiro.
    const over_it = autocomplete.open() or st.popup != .none or st.palette.open or st.settings.open or search.open;
    if (c.ImGui_IsKeyPressed(c.ImGuiKey_Escape) and (st.reply_to != 0 or st.editing != 0) and !over_it and (active or was_active or !ctx.io.*.WantTextInput)) ctx.act(.cancel_compose);

    if (st.edit_last) {
        st.edit_last = false;
        var i = cs.messages.items.len;
        while (i > 0) {
            i -= 1;
            const m = &cs.messages.items[i];
            if (m.msg.author == ctx.store.me and m.msg.id != 0) {
                ctx.act(.{ .edit_message = m.msg.id });
                break;
            }
        }
    }
}

fn submit(ctx: *d.Ctx) void {
    const st = ctx.st;
    const len = std.mem.indexOfScalar(u8, &st.input, 0) orelse st.input.len;
    const s = std.mem.trim(u8, st.input[0..len], " \t\r\n");
    if (s.len > 0 or (st.uploads.items.len > 0 and st.editing == 0)) {
        const owned = st.gpa.dupe(u8, s) catch return;
        ctx.act(if (st.editing != 0) .{ .save_edit = owned } else .{ .send_message = owned });
    }
    @memset(&st.input, 0);
    st.input_sync = true;
    st.focus_input = true;
}
