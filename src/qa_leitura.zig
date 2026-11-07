//! QA do estado de leitura, da linha "NOVAS MENSAGENS", das fixadas, do
//! histórico com lacuna, dos links do Discord, dos convites e das menções
//! clicáveis (entra na bateria geral do qa_runner.zig). O que a demonstração
//! "mandou para o Discord" fica em `gw.sent`; as mensagens e os acks "de outro
//! dispositivo" entram pela mesma fila que a rede usa.
const std = @import("std");
const c = @import("c");
const App = @import("app.zig").App;
const R = @import("qa_runner.zig");
const Op = R.Op;
const qa = @import("ui/qa.zig");
const gw = @import("net/fake_gateway.zig");
const types = @import("core/types.zig");
const leitura = @import("core/leitura.zig");
const platform = @import("platform/window.zig");
const Id = types.Id;

const State = @import("core/store.zig").ChannelState;

fn s(name: []const u8) Op {
    return .{ .section = name };
}
fn click(k: []const u8) Op {
    return .{ .click = .{ .mark = k } };
}
fn expect(name: []const u8, f: *const fn (*App) bool) Op {
    return .{ .expect = .{ .name = name, .check = f } };
}
fn slow(name: []const u8, f: *const fn (*App) bool) Op {
    return .{ .expect = .{ .name = name, .check = f, .timeout_ms = 6000 } };
}

const anuncios = gw.channelId(0, 2);
const regras = gw.channelId(0, 1);
const geral = gw.channelId(0, 4);
const memes = gw.channelId(0, 5);
const interface = gw.channelId(0, 10);
const guild0 = gw.guildId(0);
const guild1 = gw.guildId(1);
const longo = gw.channelId(5, 4);
const outro = gw.channelId(1, 4);
const distante = gw.channelId(9, 4);
const dm = gw.dmId(1);

fn cs(app: *App, id: Id) *State {
    return app.store.channel(id).?;
}
fn active(app: *App) *State {
    return cs(app, app.st.activeChannel().?);
}
fn mk(buf: []u8, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.bufPrint(buf, fmt, args) catch "";
}
fn load(a: *std.atomic.Value(u64)) u64 {
    return a.load(.monotonic);
}

var seq: u64 = 0;

/// Mensagem de outra pessoa, como se viesse do Discord.
fn inject(app: *App, channel: Id, reply_to: Id) Id {
    const ca = std.heap.c_allocator;
    seq += 1;
    const id = types.makeSnowflake(gw.nowMs(), 0x3b000 + seq);
    const content = ca.dupe(u8, "chegou agora") catch return 0;
    app.events.push(.{ .message_create = .{ .id = id, .channel = channel, .author = 1003, .timestamp = @divTrunc(gw.nowMs(), 1000), .content = content, .reply_to = reply_to } });
    platform.Window.wake(app.win.wake_type, .gateway);
    return id;
}

fn ackFromElsewhere(app: *App, channel: Id, message: Id) void {
    app.events.push(.{ .read = .{ .channel = channel, .message = message } });
    platform.Window.wake(app.win.wake_type, .gateway);
}

// --- Ao abrir o app ---------------------------------------------------------------

fn startRead(app: *App) bool {
    const c1 = cs(app, anuncios);
    const c2 = cs(app, regras);
    const g = app.store.guild(guild0).?;
    return c1.info.unread and c1.read_id != 0 and !c2.info.unread and app.st.filtros.count(anuncios) == 1 and g.unread and g.mentions >= 1;
}
fn startDm(app: *App) bool {
    return cs(app, dm).info.unread and app.st.filtros.count(dm) == 2 and !cs(app, gw.dmId(0)).info.unread;
}
fn startLine(app: *App) bool {
    return qa.find("new-line") != null and active(app).divider_after != 0;
}

// --- Primeira não lida ------------------------------------------------------------

var acks0: u64 = 0;
fn markAcks(_: *App) void {
    acks0 = load(&gw.sent.acks);
}
fn openedAtFirst(app: *App) bool {
    const a = cs(app, interface);
    const r = qa.find("new-line") orelse return false;
    return app.st.activeChannel() == interface and a.history == .loaded and !app.st.scrollOf(interface).stick_bottom and r.y < 300 and a.info.unread and a.divider_seen;
}
fn noAckYet(_: *App) bool {
    return load(&gw.sent.acks) == acks0 or load(&gw.sent.ack_channel) != interface;
}
fn ackedAtBottom(app: *App) bool {
    const a = cs(app, interface);
    return !a.info.unread and load(&gw.sent.ack_channel) == interface and load(&gw.sent.ack_message) == a.info.last_message and load(&gw.sent.ack_viewed) == leitura.lastViewed(gw.nowMs());
}
fn optionOff(app: *App) void {
    app.st.settings.open_at_unread = false;
}
fn optionOn(app: *App) void {
    app.st.settings.open_at_unread = true;
}
fn openedAtEnd(app: *App) bool {
    const a = cs(app, longo);
    return app.st.activeChannel() == longo and a.history == .loaded and app.st.scrollOf(longo).stick_bottom and !a.info.unread;
}
fn barShown(_: *App) bool {
    return qa.find("unread-bar-first") != null and qa.find("unread-bar-read") != null;
}
fn jumpedToFirst(app: *App) bool {
    const r = qa.find("new-line") orelse return false;
    return !app.st.scrollOf(longo).stick_bottom and r.y < 300 and qa.find("unread-bar-first") == null;
}

// --- Marcar como lida no botão -----------------------------------------------------

fn scrollUp(app: *App) void {
    const sc = app.st.scrollOf(app.st.activeChannel().?);
    sc.stick_bottom = false;
    sc.target = 0;
}
fn injectWhileUp(app: *App) void {
    acks0 = load(&gw.sent.acks);
    _ = inject(app, app.st.activeChannel().?, 0);
    _ = inject(app, app.st.activeChannel().?, 0);
}
fn upStaysUnread(app: *App) bool {
    const a = active(app);
    return a.info.unread and a.divider_after != 0 and load(&gw.sent.acks) == acks0 and qa.find("unread-bar-read") != null;
}
fn barRead(app: *App) bool {
    const a = active(app);
    return !a.info.unread and a.divider_after == 0 and qa.find("unread-bar-read") == null and qa.find("new-line") == null;
}

// --- Limite de 3 s ------------------------------------------------------------------

var last_injected: Id = 0;
fn injectOne(app: *App) void {
    acks0 = load(&gw.sent.acks);
    last_injected = inject(app, app.st.activeChannel().?, 0);
}
fn injectTwo(app: *App) void {
    _ = inject(app, app.st.activeChannel().?, 0);
    last_injected = inject(app, app.st.activeChannel().?, 0);
}
fn firstAckNow(_: *App) bool {
    return load(&gw.sent.acks) == acks0 + 1 and load(&gw.sent.ack_message) == last_injected;
}
fn notYet(app: *App) bool {
    return load(&gw.sent.acks) == acks0 + 1 and !active(app).info.unread;
}
fn grouped(_: *App) bool {
    return load(&gw.sent.acks) == acks0 + 2 and load(&gw.sent.ack_message) == last_injected;
}

// --- Sem foco e invisível -------------------------------------------------------------

fn blur(app: *App) void {
    app.qa_blur = true;
}
fn unblur(app: *App) void {
    app.qa_blur = false;
}
fn blurredUnread(app: *App) bool {
    const a = active(app);
    return a.info.unread and a.divider_after != 0 and load(&gw.sent.acks) == acks0;
}
fn focusedRead(app: *App) bool {
    return !active(app).info.unread and load(&gw.sent.acks) > acks0;
}
fn invisible(app: *App) void {
    acks0 = load(&gw.sent.acks);
    app.st.settings.my_status = 3;
}
fn visible(app: *App) void {
    app.st.settings.my_status = 0;
}
fn readAndAcked(app: *App) bool {
    return !active(app).info.unread and load(&gw.sent.acks) > acks0;
}

// --- Outro dispositivo --------------------------------------------------------------

fn beforeOther(app: *App) bool {
    return cs(app, distante).info.unread;
}
fn otherDevice(app: *App) void {
    ackFromElsewhere(app, distante, cs(app, distante).info.last_message);
}
fn clearedHere(app: *App) bool {
    return !cs(app, distante).info.unread and app.st.filtros.count(distante) == 0 and !app.store.guild(gw.guildId(9)).?.unread;
}

// --- Marcar como não lida -----------------------------------------------------------

var unread_from: Id = 0;
var manual0: u64 = 0;
fn pickUnread(app: *App) void {
    const a = active(app);
    const n = a.messages.items.len;
    unread_from = a.messages.items[n - 3].msg.id;
    manual0 = load(&gw.sent.manual_acks);
    app.st.popup = .{ .menu = .{ .kind = .message, .id = unread_from, .x = 400, .y = 200 } };
}
fn markedUnread(app: *App) bool {
    const a = active(app);
    const n = a.messages.items.len;
    return a.info.unread and a.hold_unread and a.read_id == a.messages.items[n - 4].msg.id and load(&gw.sent.manual_acks) == manual0 + 1 and load(&gw.sent.manual_message) == a.read_id and qa.find("new-line") != null;
}
fn stillUnread(app: *App) bool {
    return active(app).info.unread;
}
fn readAfterReturn(app: *App) bool {
    return !cs(app, geral).info.unread and !cs(app, geral).hold_unread;
}

var bulks0: u64 = 0;
fn markBulk(_: *App) void {
    bulks0 = load(&gw.sent.bulks);
}
fn guildMenu(app: *App) void {
    app.st.popup = .{ .menu = .{ .kind = .guild, .id = guild1, .x = 200, .y = 200 } };
}
fn serverRead(app: *App) bool {
    const g = app.store.guild(guild1).?;
    return !g.unread and g.mentions == 0 and !cs(app, outro).info.unread and load(&gw.sent.bulks) == bulks0 + 1 and load(&gw.sent.bulk_len) >= 1;
}

// --- Fixadas e histórico com lacuna ---------------------------------------------------

fn panelOpen(app: *App) bool {
    const l = app.store.pins.getPtr(app.st.activeChannel().?) orelse return false;
    return app.st.popup == .pins and l.state == .loaded and l.items.items.len == 3 and qa.find("pins-panel") != null;
}
fn oldPin(app: *App) Id {
    const l = app.store.pins.getPtr(geral) orelse return 0;
    var id: Id = std.math.maxInt(Id);
    for (l.items.items) |m| id = @min(id, m.msg.id);
    return id;
}
fn tOldPin(app: *App, b: []u8) []const u8 {
    return mk(b, "pin-open:{d}", .{oldPin(app)});
}
var old_id: Id = 0;
var around0: u64 = 0;
fn rememberOld(app: *App) void {
    old_id = oldPin(app);
    around0 = load(&gw.sent.arounds);
}
fn jumpedAround(app: *App) bool {
    const a = cs(app, geral);
    var b: [64]u8 = undefined;
    return app.st.popup == .none and app.st.jump == 0 and a.detached and a.around == .done and app.store.find(a, old_id) != null and load(&gw.sent.arounds) == around0 + 1 and qa.find(mk(&b, "msg:{d}", .{old_id})) != null and qa.find("present-bar") != null;
}
var n0: usize = 0;
fn olderOnGap(app: *App) bool {
    // A página em volta tem 50; pode já ter vindo mais ao abrir (tela com folga).
    return active(app).messages.items.len > 50 and active(app).detached;
}
fn scrollEnd(app: *App) void {
    const sc = app.st.scrollOf(app.st.activeChannel().?);
    n0 = active(app).messages.items.len;
    sc.target = 1e9;
}
fn newerOnGap(app: *App) bool {
    const a = active(app);
    return a.messages.items.len > n0 and a.detached and !app.st.scrollOf(a.info.id).stick_bottom;
}
var live_id: Id = 0;
fn injectLive(app: *App) void {
    n0 = active(app).messages.items.len;
    live_id = inject(app, geral, 0);
}
fn liveCounted(app: *App) bool {
    const a = active(app);
    return a.info.last_message == live_id and a.info.unread and a.messages.items.len == n0 and load(&gw.sent.ack_message) != live_id;
}
fn backToPresent(app: *App) bool {
    const a = active(app);
    return !a.detached and app.st.scrollOf(a.info.id).stick_bottom and qa.find("present-bar") == null and qa.find("msg-index:0") != null;
}

var mine_pin: Id = 0;
fn pinMenu(app: *App) void {
    const a = active(app);
    var i = a.messages.items.len;
    while (i > 0) {
        i -= 1;
        const m = &a.messages.items[i];
        if (m.msg.id != 0 and !m.msg.pinned and m.msg.system == .none) {
            mine_pin = m.msg.id;
            break;
        }
    }
    app.st.popup = .{ .menu = .{ .kind = .message, .id = mine_pin, .x = 400, .y = 200 } };
}
fn pinned(app: *App) bool {
    const m = app.store.find(active(app), mine_pin) orelse return false;
    return m.msg.pinned;
}
fn pinListed(app: *App) bool {
    const l = app.store.pins.getPtr(geral) orelse return false;
    if (l.state != .loaded or app.st.popup != .pins) return false;
    for (l.items.items) |m| if (m.msg.id == mine_pin) return true;
    return false;
}
fn tRemovePin(_: *App, b: []u8) []const u8 {
    return mk(b, "pin-remove:{d}", .{mine_pin});
}
fn pinGone(app: *App) bool {
    const m = app.store.find(active(app), mine_pin) orelse return false;
    if (m.msg.pinned) return false;
    const l = app.store.pins.getPtr(geral) orelse return false;
    if (l.state != .loaded) return false;
    for (l.items.items) |x| if (x.msg.id == mine_pin) return false;
    return true;
}
fn closePopup(app: *App) void {
    app.st.popup = .none;
}
fn noPinInOtherGuild(_: *App) bool {
    return qa.find("menu:Fixar mensagem") == null and qa.find("menu:Responder") != null;
}
fn menuOnOtherGuild(app: *App) void {
    const a = active(app);
    app.st.popup = .{ .menu = .{ .kind = .message, .id = a.messages.items[a.messages.items.len - 1].msg.id, .x = 400, .y = 200 } };
}

// --- Resposta antiga ------------------------------------------------------------------

var reply_id: Id = 0;
fn injectOldReply(app: *App) void {
    old_id = oldPin(app);
    around0 = load(&gw.sent.arounds);
    reply_id = inject(app, geral, old_id);
}
/// A fixada antiga de #geral: a primeira da lista.
fn oldEpoch(app: *App) i64 {
    const id = oldPin(app);
    return types.snowflakeTime(id) + 40 * 86_400_000;
}
fn tReplyLine(_: *App, b: []u8) []const u8 {
    return mk(b, "reply-line:{d}", .{reply_id});
}
fn replyJumped(app: *App) bool {
    const a = cs(app, geral);
    return app.st.jump == 0 and a.detached and app.store.find(a, old_id) != null and load(&gw.sent.arounds) == around0 + 1;
}

// --- Links ------------------------------------------------------------------------------

fn clearOpened(_: *App) void {
    @import("ui/attachments.zig").last_opened_len = 0;
}
fn linkMark(buf: []u8, app: *App, needle: []const u8) []const u8 {
    const a = active(app);
    var i = a.messages.items.len;
    while (i > 0) {
        i -= 1;
        const m = &a.messages.items[i];
        for (m.spans) |sp| if (sp.flags.link and std.mem.indexOf(u8, sp.text, needle) != null) {
            return mk(buf, "link:{s}", .{sp.text[0..@min(sp.text.len, 48)]});
        };
    }
    return "";
}
/// Traz para a tela a mensagem com os links e as menções da demonstração.
fn showLinks(app: *App) void {
    const a = active(app);
    for (a.messages.items) |m| if (std.mem.indexOf(u8, m.msg.content, "ptb.discord.com") != null) {
        app.st.jump = m.msg.id;
    };
}
fn tMsgLink(app: *App, b: []u8) []const u8 {
    return linkMark(b, app, "discord.com/channels");
}
fn tPtbLink(app: *App, b: []u8) []const u8 {
    return linkMark(b, app, "ptb.discord.com");
}
fn linkInApp(app: *App) bool {
    const a = cs(app, interface);
    const old = gw.oldPinId(interface, oldEpoch(app));
    return app.st.activeChannel() == interface and a.detached and app.store.find(a, old) != null and @import("ui/attachments.zig").last_opened_len == 0 and app.st.jump == 0;
}
fn ptbInApp(app: *App) bool {
    return app.st.activeChannel() == memes and @import("ui/attachments.zig").last_opened_len == 0;
}
fn invitesShown(app: *App) bool {
    const a = app.store.invites.get("sigma") orelse return false;
    const b = app.store.invites.get("zigbr") orelse return false;
    return a.state == .ok and b.state == .ok and qa.find("invite:sigma") != null and qa.find("invite:zigbr") != null and qa.find("invite-go:sigma") != null and qa.find("invite-go:zigbr") == null;
}
// Outras seções também mostram convites: o que vale é um pedido por código conhecido.
fn oneFetchEach(app: *App) bool {
    return load(&gw.sent.invite_fetches) == app.store.invites.count();
}
fn inviteBrowser(_: *App) bool {
    const att = @import("ui/attachments.zig");
    return std.mem.eql(u8, att.last_opened[0..att.last_opened_len], "https://discord.gg/zigbr");
}

// --- Menções ----------------------------------------------------------------------------

fn tMention(_: *App, b: []u8) []const u8 {
    return mk(b, "mention:{d}", .{@as(Id, 1001)});
}
fn tChannelMention(_: *App, b: []u8) []const u8 {
    return mk(b, "mention-channel:{d}", .{geral});
}
fn profileFromMention(app: *App) bool {
    return app.st.popup == .profile and app.st.popup.profile.user == 1001;
}
fn channelFromMention(app: *App) bool {
    return app.st.activeChannel() == geral;
}
fn tStamp(app: *App, b: []u8) []const u8 {
    const a = active(app);
    var i = a.messages.items.len;
    while (i > 0) {
        i -= 1;
        var mb: [64]u8 = undefined;
        const key = mk(&mb, "msg:{d}", .{a.messages.items[i].msg.id});
        if (qa.find(key)) |r| if (r.y > 100 and r.y < 600) return mk(b, "msg:{d}", .{a.messages.items[i].msg.id});
    }
    return "";
}
fn hoverStamp(app: *App) bool {
    const a = active(app);
    for (a.messages.items) |m| {
        var mb: [64]u8 = undefined;
        if (qa.find(mk(&mb, "stamp:{d}", .{m.msg.id})) != null) return true;
    }
    return false;
}
fn stampTarget(app: *App, b: []u8) []const u8 {
    const a = active(app);
    for (a.messages.items) |m| {
        var mb: [64]u8 = undefined;
        const key = mk(&mb, "stamp:{d}", .{m.msg.id});
        if (qa.find(key) != null) return mk(b, "stamp:{d}", .{m.msg.id});
    }
    return "";
}

/// Logo depois do READY, antes de qualquer outro roteiro mexer.
pub const startup = [_]Op{
    s("estado de leitura ao abrir"),
    .{ .expect = .{ .name = "read_state: não lido e menção de cada canal, e o servidor acompanha", .check = startRead, .timeout_ms = 4000 } },
    expect("mensagem direta com não lidas conta cada uma como menção", startDm),
    .{ .expect = .{ .name = "a conversa aberta mostra a linha NOVAS MENSAGENS", .check = startLine, .timeout_ms = 4000 } },
};

pub const ops = [_]Op{
    s("primeira não lida"),
    click("guild:500000"),
    click("channel:500005"),
    .{ .run = markAcks },
    click("channel:500011"),
    .{ .expect = .{ .name = "canal com muitas não lidas abre na primeira, com a linha em cima", .check = openedAtFirst, .timeout_ms = 3000 } },
    expect("no meio das não lidas ainda não confirma a leitura", noAckYet),
    .{ .shot = "50-novas-mensagens" },
    .{ .run = markAcks },
    click("jump-bottom"),
    slow("chegar no fim confirma a leitura com a última mensagem e o last_viewed", ackedAtBottom),
    .{ .shot = "51-convites" },

    s("opção: abrir no fim e botão do topo"),
    .{ .run = optionOff },
    click("guild:505000"),
    click("channel:505005"),
    .{ .expect = .{ .name = "com a opção desligada, abre no fim", .check = openedAtEnd, .timeout_ms = 3000 } },
    expect("o botão do topo oferece ir para a primeira", barShown),
    .{ .shot = "52-botao-do-topo" },
    click("unread-bar-first"),
    expect("ir para a primeira leva até a linha e o botão some", jumpedToFirst),
    .{ .run = optionOn },

    s("marcar como lida no botão"),
    click("guild:500000"),
    click("channel:500005"),
    .{ .wait = 3200 },
    .{ .run = scrollUp },
    .{ .wait = 200 },
    .{ .run = injectWhileUp },
    .{ .wait = 200 },
    expect("rolado para cima, o que chega fica não lido, sem ack, e o botão aparece", upStaysUnread),
    click("unread-bar-read"),
    expect("marcar como lida limpa, some a linha e o botão", barRead),

    s("no máximo um ack por canal a cada 3 s"),
    click("jump-bottom"),
    .{ .wait = 3400 },
    .{ .run = injectOne },
    expect("o primeiro sai na hora", firstAckNow),
    .{ .run = injectTwo },
    .{ .wait = 400 },
    expect("os seguintes esperam (mas a conversa já está lida)", notYet),
    slow("saem juntos, na última mensagem", grouped),

    s("janela sem foco e invisível"),
    .{ .wait = 3200 },
    .{ .run = blur },
    .{ .run = injectOne },
    .{ .wait = 300 },
    expect("janela sem foco: fica não lido, sem ack e com a linha", blurredUnread),
    .{ .run = unblur },
    expect("a janela volta: lido e confirmado", focusedRead),
    .{ .wait = 3200 },
    .{ .run = invisible },
    .{ .run = injectOne },
    .{ .wait = 300 },
    expect("invisível: lido e confirmado (o status não muda a leitura)", readAndAcked),
    .{ .run = visible },

    s("outro dispositivo"),
    expect("#geral de outro servidor começa não lido", beforeOther),
    .{ .run = otherDevice },
    expect("MESSAGE_ACK de outro dispositivo limpa o não lido e as menções", clearedHere),

    s("marcar como não lida"),
    .{ .run = pickUnread },
    click("menu:Marcar como não lida"),
    expect("ack manual na mensagem anterior, canal não lido e com a linha", markedUnread),
    .{ .shot = "53-marcada-nao-lida" },
    .{ .wait = 400 },
    expect("e fica assim: não confirma sozinho", stillUnread),
    click("channel:500006"),
    click("channel:500005"),
    slow("saiu e voltou: lido de novo", readAfterReturn),

    s("marcar servidor como lido"),
    .{ .run = markBulk },
    // Pedido pela pessoa vale mesmo sem foco, e mesmo invisível.
    .{ .run = blur },
    .{ .run = invisible },
    .{ .run = guildMenu },
    click("menu:Marcar como lido"),
    expect("POST ack-bulk com os canais e o servidor limpo, mesmo sem foco e invisível", serverRead),
    .{ .run = unblur },
    .{ .run = visible },

    s("mensagens fixadas"),
    click("header-pins"),
    .{ .expect = .{ .name = "alfinete abre o painel com as fixadas", .check = panelOpen, .timeout_ms = 3000 } },
    .{ .shot = "54-fixadas" },
    .{ .run = rememberOld },
    .{ .click = .{ .dyn = tOldPin } },
    .{ .expect = .{ .name = "clicar numa antiga busca em volta dela e abre ali", .check = jumpedAround, .timeout_ms = 3000 } },
    .{ .shot = "55-historico-com-lacuna" },
    .{ .run = scrollUp },
    .{ .expect = .{ .name = "fora do presente, as antigas continuam carregando", .check = olderOnGap, .timeout_ms = 3000 } },
    .{ .run = scrollEnd },
    .{ .expect = .{ .name = "e o fim da lista busca as mais novas", .check = newerOnGap, .timeout_ms = 3000 } },
    .{ .run = injectLive },
    .{ .expect = .{ .name = "mensagem ao vivo não entra no passado: só conta", .check = liveCounted, .timeout_ms = 2000 } },
    click("present-bar"),
    .{ .expect = .{ .name = "voltar ao presente", .check = backToPresent, .timeout_ms = 3000 } },
    .{ .run = pinMenu },
    click("menu:Fixar mensagem"),
    expect("Fixar pelo menu da mensagem", pinned),
    click("header-pins"),
    .{ .expect = .{ .name = "a nova aparece no painel", .check = pinListed, .timeout_ms = 3000 } },
    .{ .click = .{ .dyn = tRemovePin } },
    .{ .expect = .{ .name = "desafixar pelo painel", .check = pinGone, .timeout_ms = 3000 } },
    .{ .run = closePopup },
    .{ .wait = 100 },
    click("guild:501000"),
    .{ .wait = 500 },
    .{ .run = menuOnOtherGuild },
    .{ .wait = 100 },
    expect("sem gerenciar mensagens, o menu não oferece fixar", noPinInOtherGuild),
    .{ .run = closePopup },

    s("resposta a uma mensagem antiga"),
    click("guild:500000"),
    click("channel:500005"),
    .{ .run = injectOldReply },
    .{ .wait = 300 },
    .{ .click = .{ .dyn = tReplyLine } },
    .{ .expect = .{ .name = "clicar na resposta busca a original e abre ali", .check = replyJumped, .timeout_ms = 3000 } },
    click("present-bar"),
    .{ .wait = 300 },

    s("links do Discord"),
    click("channel:500011"),
    .{ .wait = 300 },
    .{ .run = clearOpened },
    .{ .click = .{ .dyn = tMsgLink } },
    .{ .expect = .{ .name = "link de mensagem abre aqui, na mensagem, sem navegador", .check = linkInApp, .timeout_ms = 3000 } },
    click("present-bar"),
    .{ .wait = 400 },
    expect("cartões de convite com nome e membros; quem já é membro pode ir para o servidor", invitesShown),
    expect("cada convite é buscado uma vez só", oneFetchEach),
    .{ .click = .{ .mark = "invite-open:zigbr" } },
    expect("Abrir no navegador leva o link de convite (nada de entrar pelo app)", inviteBrowser),
    .{ .run = clearOpened },
    .{ .run = showLinks },
    .{ .wait = 400 },
    .{ .click = .{ .dyn = tPtbLink } },
    expect("link do ptb. também abre aqui", ptbInApp),

    s("menções e horário"),
    click("channel:500011"),
    .{ .wait = 300 },
    .{ .run = showLinks },
    .{ .wait = 400 },
    .{ .click = .{ .dyn = tMention } },
    expect("clicar em @alguém abre o cartão de perfil", profileFromMention),
    .{ .run = closePopup },
    .{ .wait = 100 },
    .{ .hover = .{ .dyn = tStamp } },
    .{ .wait = 100 },
    expect("mensagem sob o mouse marca o horário", hoverStamp),
    .{ .hover = .{ .dyn = stampTarget } },
    .{ .wait = 350 },
    .{ .shot = "56-data-completa" },
    .{ .click = .{ .dyn = tChannelMention } },
    expect("clicar em #canal abre o canal", channelFromMention),
};
