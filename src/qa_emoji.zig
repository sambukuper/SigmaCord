//! QA do emoji personalizado, figurinhas, seletor completo e autocompletar
//! (entra na bateria geral do qa_runner.zig). Tudo com os dados da demonstração.
const std = @import("std");
const c = @import("c");
const App = @import("app.zig").App;
const R = @import("qa_runner.zig");
const Op = R.Op;
const qa = @import("ui/qa.zig");
const gw = @import("net/fake_gateway.zig");
const types = @import("core/types.zig");
const rich = @import("ui/rich.zig");
const autocomplete = @import("ui/autocomplete.zig");
const emoji_data = @import("ui/emoji_data.zig");
const StoredMessage = @import("core/store.zig").StoredMessage;
const Id = types.Id;

fn s(name: []const u8) Op {
    return .{ .section = name };
}
fn click(k: []const u8) Op {
    return .{ .click = .{ .mark = k } };
}
fn expect(name: []const u8, f: *const fn (*App) bool) Op {
    return .{ .expect = .{ .name = name, .check = f } };
}
fn key(k: c_int) Op {
    return .{ .key = .{ .key = k } };
}
fn dyn(f: *const fn (*App, []u8) []const u8) Op {
    return .{ .click = .{ .dyn = f } };
}

const geral: Id = gw.emoji_channel;

fn input(app: *App) []const u8 {
    return std.mem.sliceTo(&app.st.input, 0);
}

fn channel(app: *App) ?*@import("core/store.zig").ChannelState {
    return app.store.channel(geral) orelse null;
}

/// A mensagem `back` posições antes do fim, na história original (a de agora
/// pode ter mensagens novas depois: procura pelo texto).
fn findMsg(app: *App, needle: []const u8) ?*StoredMessage {
    const cs = channel(app) orelse return null;
    var i = cs.messages.items.len;
    while (i > 0) {
        i -= 1;
        if (std.mem.indexOf(u8, cs.messages.items[i].msg.raw, needle) != null) return &cs.messages.items[i];
    }
    return null;
}

fn imageReady(app: *App, key_part: []const u8, min_frames: usize) bool {
    var it = app.images.map.iterator();
    while (it.next()) |e| if (std.mem.indexOf(u8, e.key_ptr.*, key_part) != null and e.value_ptr.state == .ready and e.value_ptr.frames.len >= min_frames) return true;
    return false;
}

// --- Emoji na mensagem ------------------------------------------------------------

fn scrollToEmoji(app: *App) void {
    // Rola até a mensagem com emoji ficar à vista.
    const sc = app.st.scrollOf(geral);
    sc.stick_bottom = true;
}

/// Rola para trás até a figurinha e o emoji grande.
fn showJumbo(app: *App) void {
    const sc = app.st.scrollOf(geral);
    sc.stick_bottom = false;
    sc.anchor_id = 0;
    sc.target = @max(sc.target - 640, 0);
    sc.pos = sc.target;
}

fn inlineMarks(_: *App) bool {
    return qa.find("emoji-inline:900101") != null and qa.find("emoji-inline:900102") != null;
}
fn inlineLoaded(app: *App) bool {
    return imageReady(app, "demo:emoji:900101:0", 1) and imageReady(app, "demo:emoji:900102:0", 1);
}
fn inlineSpans(app: *App) bool {
    const m = findMsg(app, "<:sigma:900101>") orelse return false;
    // Na tela e na busca o texto continua `:nome:`; os IDs saem do texto do Discord.
    if (std.mem.indexOf(u8, m.msg.content, ":sigma:") == null or std.mem.indexOf(u8, m.msg.content, "<:") != null) return false;
    var n: usize = 0;
    for (m.spans) |sp| if (sp.emoji != 0) {
        n += 1;
    };
    return n == 2 and !m.spans[0].flags.jumbo;
}
var inline_h: f32 = 0;
fn saveInlineHeight(app: *App) void {
    inline_h = (findMsg(app, "<:sigma:900101>") orelse return).height;
}
fn heightStable(app: *App) bool {
    const m = findMsg(app, "<:sigma:900101>") orelse return false;
    return inline_h > 0 and m.height == inline_h;
}
fn inlineBoxSize(app: *App) bool {
    _ = app;
    const r = qa.find("emoji-inline:900101") orelse return false;
    return r.w == r.h and r.h >= 16 and r.h < 32;
}
fn jumboBoxSize(app: *App) bool {
    _ = app;
    const r = qa.find("emoji-inline:900103") orelse return false;
    return r.w == 48 and r.h == 48;
}
fn animatedFrames(app: *App) bool {
    return imageReady(app, "demo:emoji:900104:1", 2);
}
var jumbo_h: f32 = 0;
fn jumboTaller(app: *App) bool {
    const big = findMsg(app, "<:ziguana:900103>") orelse return false;
    jumbo_h = big.height;
    return big.spans[0].flags.jumbo and big.height >= 52;
}
fn unicodeJumbo(app: *App) bool {
    const cs = channel(app) orelse return false;
    for (cs.messages.items) |*m| if (std.mem.eql(u8, m.msg.content, "🔥🔥😂")) return m.spans[0].flags.jumbo;
    return false;
}
fn stickerShown(app: *App) bool {
    return imageReady(app, "demo:sticker:900401:1", 2);
}
fn lottieIsText(app: *App) bool {
    const cs = channel(app) orelse return false;
    for (cs.messages.items) |*m| if (std.mem.indexOf(u8, m.msg.content, "wumpus") != null) return m.msg.attachments.len == 0;
    return false;
}

// --- Reações ----------------------------------------------------------------------

fn customReaction(m: *StoredMessage, id: Id) ?*const types.Reaction {
    for (m.reactionSlice()) |*r| if (r.custom == id) return r;
    return null;
}
fn tChipSigma(app: *App, b: []u8) []const u8 {
    const m = findMsg(app, "<:sigma:900101>") orelse return "";
    for (m.reactionSlice(), 0..) |*r, i| if (r.custom == 900101) return std.fmt.bufPrint(b, "chip:{d}:{d}", .{ m.msg.id, i }) catch "";
    return "";
}
fn reactionsArrived(app: *App) bool {
    const m = findMsg(app, "<:sigma:900101>") orelse return false;
    const a = customReaction(m, 900101) orelse return false;
    const anim = customReaction(m, 900104) orelse return false;
    return a.count == 3 and !a.me and anim.animated and imageReady(app, "demo:emoji:900101:0", 1);
}
fn reacted(app: *App) bool {
    const m = findMsg(app, "<:sigma:900101>") orelse return false;
    const a = customReaction(m, 900101) orelse return false;
    return a.count == 4 and a.me and std.mem.eql(u8, a.text(), "sigma");
}
fn unreacted(app: *App) bool {
    const m = findMsg(app, "<:sigma:900101>") orelse return false;
    const a = customReaction(m, 900101) orelse return false;
    return a.count == 3 and !a.me;
}
fn tChipAddInline(app: *App, b: []u8) []const u8 {
    const m = findMsg(app, "<:sigma:900101>") orelse return "";
    return std.fmt.bufPrint(b, "chip-add:{d}", .{m.msg.id}) catch "";
}
fn tHoverInline(app: *App, b: []u8) []const u8 {
    const m = findMsg(app, "<:sigma:900101>") orelse return "";
    return std.fmt.bufPrint(b, "msg:{d}", .{m.msg.id}) catch "";
}
fn tPickCafe(_: *App, _: []u8) []const u8 {
    return "emoji-custom:900105";
}
fn reactedViaPicker(app: *App) bool {
    const m = findMsg(app, "<:sigma:900101>") orelse return false;
    const a = customReaction(m, 900105) orelse return false;
    return a.me and a.count == 1 and app.st.popup == .none;
}

// --- Modo economia ----------------------------------------------------------------

fn saverOn(app: *App) void {
    app.st.settings.data_saver = true;
}
fn saverOff(app: *App) void {
    app.st.settings.data_saver = false;
}
fn saverText(app: *App) bool {
    if (rich.emoji_images) return false;
    // Sem imagem: nada de marcas, e a mensagem foi medida de novo com `:nome:`.
    return qa.find("emoji-inline:900101") == null and app.images.data_saver;
}
fn saverJumboOff(app: *App) bool {
    const m = findMsg(app, "<:ziguana:900103>") orelse return false;
    return m.height < jumbo_h;
}
fn saverBack(app: *App) bool {
    return rich.emoji_images and app.images.data_saver == false and qa.find("emoji-inline:900101") != null;
}

// --- Seletor ----------------------------------------------------------------------

fn pickerOpen(app: *App) bool {
    return app.st.popup == .emoji and qa.find("emoji-picker") != null and qa.find("emoji:0") != null;
}
fn pickerClosed(app: *App) bool {
    return app.st.popup == .none;
}
fn fewCellsDrawn(_: *App) bool {
    var keys: [400][56]u8 = undefined;
    var lens: [400]u8 = undefined;
    // A tabela tem quase 2000 emojis; desenhadas, só as de uma tela.
    const n = qa.keysWith(&.{"emoji:"}, &keys, &lens);
    return n > 20 and n < 130;
}
fn fullTable(_: *App) bool {
    return emoji_data.count > 1800;
}
fn fontCovers(_: *App) bool {
    // Num sistema com a fonte de emoji atualizada, quase tudo tem desenho.
    return @import("ui/emoji_picker.zig").shownCount() > 1500;
}
fn searchFound(_: *App) bool {
    const joy = emoji_data.byCode("joy") orelse return false;
    var b: [32]u8 = undefined;
    return qa.find(std.fmt.bufPrint(&b, "emoji:{d}", .{joy}) catch "") != null;
}
fn tFlagsCat(_: *App, _: []u8) []const u8 {
    // O último do trilho (as bandeiras): com ou sem "recentes" antes.
    return if (qa.find("emoji-cat:9") != null) "emoji-cat:9" else "emoji-cat:8";
}
fn flagsVisible(_: *App) bool {
    var b: [32]u8 = undefined;
    const br = emoji_data.byCode("brazil") orelse return false;
    _ = br;
    return qa.find(std.fmt.bufPrint(&b, "emoji:{d}", .{emoji_data.categories[8].first}) catch "") != null or qa.find("emoji:1700") != null or qa.find("emoji:1800") != null or qa.find("emoji:1900") != null;
}
fn joyInserted(app: *App) bool {
    return std.mem.indexOf(u8, input(app), "😂") != null and app.st.popup == .none;
}
fn recentSaved(app: *App) bool {
    return std.mem.startsWith(u8, app.st.settings.emoji_recent.slice(), "😂");
}
fn recentShown(app: *App) bool {
    return app.st.popup == .emoji and qa.find("emoji-recent:0") != null;
}
fn serversTab(_: *App) bool {
    return qa.find("emoji-custom:900101") != null;
}
fn localInserted(app: *App) bool {
    return std.mem.indexOf(u8, input(app), ":sigma:") != null and app.st.popup == .none;
}
fn lockedStays(app: *App) bool {
    return app.st.popup == .emoji and app.st.toast.is_error and std.mem.indexOf(u8, app.st.toast.text(), "Nitro") != null;
}
fn clearInput(app: *App) void {
    @memset(&app.st.input, 0);
    app.st.input_sync = true;
    app.st.focus_input = true;
    autocomplete.clearTokens();
}
fn nitroOn(app: *App) void {
    app.store.premium_type = 2;
}
fn nitroOff(app: *App) void {
    app.store.premium_type = 0;
}
fn otherGuildInserted(app: *App) bool {
    return std.mem.indexOf(u8, input(app), ":hypr_rice:") != null and app.st.popup == .none;
}
fn lastSent(app: *App) ?*StoredMessage {
    const cs = app.store.channel(app.st.activeChannel() orelse return null) orelse return null;
    if (cs.messages.items.len == 0) return null;
    return &cs.messages.items[cs.messages.items.len - 1];
}
fn sentHasRaw(app: *App, want: []const u8) bool {
    const m = lastSent(app) orelse return false;
    return !m.pending and std.mem.indexOf(u8, m.msg.editable(), want) != null;
}
fn sentSigma(app: *App) bool {
    const m = lastSent(app) orelse return false;
    return sentHasRaw(app, "<:sigma:900101>") and std.mem.indexOf(u8, m.msg.content, ":sigma:") != null and qa.find("emoji-inline:900101") != null;
}
fn sentOtherGuild(app: *App) bool {
    return sentHasRaw(app, "<:hypr_rice:900201>");
}
fn inputEmpty(app: *App) bool {
    return input(app).len == 0;
}

// --- Autocompletar ----------------------------------------------------------------

fn listOpen(_: *App) bool {
    return autocomplete.open() and qa.find("autocomplete") != null and qa.find("ac:0") != null;
}
fn listClosed(_: *App) bool {
    return !autocomplete.open() and qa.find("autocomplete") == null;
}
fn listAtSecond(_: *App) bool {
    return autocomplete.selected() == 1;
}
var saved_msgs: usize = 0;
var saved_searches: u32 = 0;
fn saveState(app: *App) void {
    const cs = app.store.channel(app.st.activeChannel() orelse return) orelse return;
    saved_msgs = cs.messages.items.len;
    saved_searches = autocomplete.searches;
}
fn noSearchWhileIdle(_: *App) bool {
    return autocomplete.searches == saved_searches and autocomplete.open();
}
fn enterDidNotSend(app: *App) bool {
    const cs = app.store.channel(app.st.activeChannel() orelse return false) orelse return false;
    return cs.messages.items.len == saved_msgs and input(app).len > 0;
}
fn escapeKept(app: *App) bool {
    return !autocomplete.open() and std.mem.eql(u8, input(app), "@an") and app.st.reply_to == 0;
}
fn renameBia(app: *App) void {
    app.store.apply(.{ .user_update = .{ .id = 1003, .name = std.heap.c_allocator.dupe(u8, "Bia de Souza") catch return } }, 0) catch {};
}
fn renameBack(app: *App) void {
    app.store.apply(.{ .user_update = .{ .id = 1003, .name = std.heap.c_allocator.dupe(u8, "kaique") catch return } }, 0) catch {};
}
fn biaInserted(app: *App) bool {
    return std.mem.eql(u8, input(app), "@Bia de Souza ") and !autocomplete.open();
}
fn biaSent(app: *App) bool {
    const m = lastSent(app) orelse return false;
    return !m.pending and std.mem.eql(u8, m.msg.content, "<@1003> oi");
}
fn handTypedSpace(app: *App) bool {
    const m = lastSent(app) orelse return false;
    return !m.pending and std.mem.eql(u8, m.msg.content, "e <@1003> de novo");
}
fn channelInserted(app: *App) bool {
    return std.mem.eql(u8, input(app), "#geral ");
}
fn channelSent(app: *App) bool {
    const m = lastSent(app) orelse return false;
    return !m.pending and std.mem.eql(u8, m.msg.content, "<#500005>");
}
fn roleFound(_: *App) bool {
    return autocomplete.count() > 0;
}
fn everyoneSent(app: *App) bool {
    const m = lastSent(app) orelse return false;
    return !m.pending and std.mem.startsWith(u8, m.msg.content, "@everyone");
}
fn roleSent(app: *App) bool {
    const m = lastSent(app) orelse return false;
    return !m.pending and std.mem.startsWith(u8, m.msg.content, "<@&");
}
fn unicodeInserted(app: *App) bool {
    return std.mem.eql(u8, input(app), "😂 ");
}
fn customInserted(app: *App) bool {
    return std.mem.eql(u8, input(app), ":sigma: ");
}
fn customSent(app: *App) bool {
    return sentHasRaw(app, "<:sigma:900101>");
}
fn lockedInList(app: *App) bool {
    return autocomplete.open() and app.st.toast.is_error and std.mem.eql(u8, input(app), ":hypr");
}
fn commandListed(_: *App) bool {
    return autocomplete.open() and autocomplete.count() >= 1;
}
fn commandInserted(app: *App) bool {
    return std.mem.startsWith(u8, input(app), "/") and input(app)[input(app).len - 1] == ' ';
}
fn middleInsert(app: *App) bool {
    return std.mem.eql(u8, input(app), "oi @ana.exe tudo");
}
fn newLineWithList(app: *App) bool {
    return std.mem.indexOfScalar(u8, input(app), '\n') != null;
}

/// Na bateria geral os plugins já estão carregados; sozinho, carrega um.
fn ensureCommand(app: *App) void {
    if (app.plugins.n_commands > 0) return;
    const src = "sigma.command('/qaemoji', function() end)";
    _ = c.SDL_CreateDirectory("qa-out/plugins");
    _ = c.SDL_SaveFile("qa-out/plugins/qaemoji.lua", src.ptr, src.len);
    app.plugins.reload();
    _ = c.SDL_RemovePath("qa-out/plugins/qaemoji.lua");
}

pub const ops = [_]Op{
    s("emoji personalizado na mensagem"),
    click("guild:500000"),
    click("channel:500005"),
    .{ .run = scrollToEmoji },
    .{ .wait = 300 },
    .{ .expect = .{ .name = "mensagem com emoji personalizado guarda o ID em cada trecho", .check = inlineSpans, .timeout_ms = 3000 } },
    .{ .expect = .{ .name = "emoji aparece como imagem no meio do texto", .check = inlineMarks, .timeout_ms = 3000 } },
    .{ .run = saveInlineHeight },
    .{ .expect = .{ .name = "a imagem do emoji chega", .check = inlineLoaded, .timeout_ms = 4000 } },
    expect("a altura da mensagem não muda quando a imagem chega", heightStable),
    expect("emoji no texto tem o tamanho da linha", inlineBoxSize),
    expect("mensagem só de emoji fica grande (48 px)", jumboBoxSize),
    expect("mensagem só de emoji é mais alta", jumboTaller),
    expect("só emoji Unicode também fica grande", unicodeJumbo),
    .{ .expect = .{ .name = "emoji animado tem vários quadros", .check = animatedFrames, .timeout_ms = 4000 } },
    .{ .shot = "60-emoji-inline" },
    // A figurinha fica mais para cima: só baixa quando aparece na tela.
    .{ .run = showJumbo },
    .{ .expect = .{ .name = "figurinha desenhada como imagem", .check = stickerShown, .timeout_ms = 4000 } },
    expect("figurinha Lottie mostra o nome", lottieIsText),
    .{ .wait = 250 },
    .{ .shot = "60b-emoji-grande-figurinha" },
    .{ .run = scrollToEmoji },
    .{ .wait = 250 },

    s("reações personalizadas"),
    .{ .expect = .{ .name = "reação personalizada com imagem", .check = reactionsArrived, .timeout_ms = 3000 } },
    dyn(tChipSigma),
    expect("reagir com emoji personalizado", reacted),
    .{ .shot = "61-emoji-reacao" },
    dyn(tChipSigma),
    expect("tirar a reação personalizada", unreacted),
    .{ .hover = .{ .dyn = tHoverInline } },
    .{ .wait = 80 },
    dyn(tChipAddInline),
    expect("adicionar reação abre o seletor", pickerOpen),
    click("emoji-tab:1"),
    expect("aba Servidores mostra os emojis", serversTab),
    dyn(tPickCafe),
    expect("reagir pelo seletor com emoji personalizado", reactedViaPicker),

    s("modo economia"),
    .{ .run = saverOn },
    .{ .wait = 200 },
    .{ .expect = .{ .name = "modo economia: emoji vira :nome:, sem imagem", .check = saverText, .timeout_ms = 2000 } },
    expect("modo economia: sem tamanho grande", saverJumboOff),
    .{ .shot = "62-emoji-economia" },
    .{ .run = saverOff },
    .{ .expect = .{ .name = "desligar volta a mostrar a imagem", .check = saverBack, .timeout_ms = 2000 } },

    s("seletor de emoji"),
    expect("a tabela tem a lista Unicode inteira", fullTable),
    click("composer-emoji"),
    expect("abre o seletor", pickerOpen),
    expect("só desenha o que está visível", fewCellsDrawn),
    expect("a fonte desenha quase toda a tabela", fontCovers),
    .{ .shot = "63-emoji-seletor" },
    .{ .click = .{ .dyn = tFlagsCat } },
    .{ .expect = .{ .name = "categoria pula para a seção", .check = flagsVisible, .timeout_ms = 2000 } },
    .{ .shot = "64-emoji-bandeiras" },
    .{ .text = "joy" },
    .{ .expect = .{ .name = "busca acha pelo nome", .check = searchFound, .timeout_ms = 2000 } },
    .{ .shot = "65-emoji-busca" },
    key(c.ImGuiKey_Enter),
    expect("Enter na busca escolhe o primeiro", joyInserted),
    expect("recentes guardados nas configurações", recentSaved),
    .{ .run = clearInput },
    click("composer-emoji"),
    expect("recentes aparecem na próxima vez", recentShown),
    click("emoji-tab:1"),
    expect("aba Servidores", serversTab),
    .{ .shot = "66-emoji-servidores" },
    click("emoji-custom:900201"),
    expect("sem Nitro, emoji de outro servidor é bloqueado com aviso", lockedStays),
    click("emoji-custom:900101"),
    expect("emoji deste servidor entra como :nome:", localInserted),
    click("composer"),
    key(c.ImGuiKey_Enter),
    .{ .expect = .{ .name = "enviar vira <:nome:id> e aparece como imagem", .check = sentSigma, .timeout_ms = 3000 } },
    .{ .run = nitroOn },
    click("composer-emoji"),
    click("emoji-tab:1"),
    click("emoji-custom:900201"),
    expect("com Nitro, emoji de outro servidor entra", otherGuildInserted),
    click("composer"),
    key(c.ImGuiKey_Enter),
    .{ .expect = .{ .name = "e vai como <:nome:id>", .check = sentOtherGuild, .timeout_ms = 3000 } },
    .{ .run = nitroOff },
    click("composer-emoji"),
    expect("abre de novo", pickerOpen),
    .{ .text = "zzz" },
    .{ .wait = 80 },
    .{ .shot = "65b-emoji-nada" },
    key(c.ImGuiKey_Escape),
    expect("Esc fecha o seletor, mesmo com a busca em foco", pickerClosed),

    s("autocompletar"),
    .{ .run = clearInput },
    .{ .wait = 80 },
    .{ .text = "@an" },
    .{ .expect = .{ .name = "@ abre a lista acima da caixa", .check = listOpen, .timeout_ms = 2000 } },
    .{ .shot = "67-autocompletar-pessoas" },
    .{ .run = saveState },
    .{ .wait = 150 },
    expect("parada, a lista não busca de novo", noSearchWhileIdle),
    key(c.ImGuiKey_Escape),
    expect("Esc fecha e o texto fica", escapeKept),
    .{ .text = "a" },
    .{ .wait = 60 },
    .{ .run = clearInput },
    .{ .wait = 60 },
    .{ .run = renameBia },
    .{ .text = "@bia" },
    .{ .expect = .{ .name = "acha nome com espaço", .check = listOpen, .timeout_ms = 2000 } },
    .{ .run = saveState },
    key(c.ImGuiKey_Enter),
    expect("Enter escolhe em vez de enviar", enterDidNotSend),
    expect("o nome entra com espaços", biaInserted),
    .{ .text = "oi" },
    key(c.ImGuiKey_Enter),
    .{ .expect = .{ .name = "vira <@id> ao enviar, mesmo com espaço no nome", .check = biaSent, .timeout_ms = 3000 } },
    .{ .text = "e @Bia de Souza de novo" },
    key(c.ImGuiKey_Enter),
    .{ .expect = .{ .name = "digitado à mão também vira menção", .check = handTypedSpace, .timeout_ms = 3000 } },
    .{ .run = renameBack },
    .{ .text = "#ger" },
    .{ .expect = .{ .name = "# abre a lista de canais", .check = listOpen, .timeout_ms = 2000 } },
    .{ .shot = "68-autocompletar-canais" },
    key(c.ImGuiKey_Tab),
    expect("Tab escolhe o canal", channelInserted),
    key(c.ImGuiKey_Enter),
    .{ .expect = .{ .name = "vira <#id>", .check = channelSent, .timeout_ms = 3000 } },
    .{ .text = "@every" },
    .{ .expect = .{ .name = "@everyone aparece para quem pode", .check = listOpen, .timeout_ms = 2000 } },
    click("ac:0"),
    .{ .wait = 80 },
    click("composer"),
    key(c.ImGuiKey_Enter),
    .{ .expect = .{ .name = "clique na lista escolhe e @everyone vai como texto", .check = everyoneSent, .timeout_ms = 3000 } },
    .{ .text = "@Membr" },
    .{ .expect = .{ .name = "cargo mencionável na lista", .check = roleFound, .timeout_ms = 2000 } },
    key(c.ImGuiKey_Enter),
    key(c.ImGuiKey_Enter),
    .{ .expect = .{ .name = "cargo vira <@&id>", .check = roleSent, .timeout_ms = 3000 } },
    .{ .text = ":jo" },
    .{ .expect = .{ .name = ":ab abre os emojis", .check = listOpen, .timeout_ms = 2000 } },
    .{ .shot = "69-autocompletar-emoji" },
    .{ .run = clearInput },
    .{ .wait = 60 },
    .{ .text = ":joy" },
    .{ .expect = .{ .name = ":joy na lista", .check = listOpen, .timeout_ms = 2000 } },
    key(c.ImGuiKey_Enter),
    expect("emoji Unicode entra direto", unicodeInserted),
    .{ .run = clearInput },
    .{ .wait = 60 },
    .{ .text = ":sig" },
    .{ .expect = .{ .name = "emoji personalizado na lista", .check = listOpen, .timeout_ms = 2000 } },
    key(c.ImGuiKey_Enter),
    expect("personalizado entra como :nome:", customInserted),
    key(c.ImGuiKey_Enter),
    .{ .expect = .{ .name = "e vai como <:nome:id>", .check = customSent, .timeout_ms = 3000 } },
    .{ .text = ":hypr" },
    .{ .expect = .{ .name = "emoji travado aparece marcado", .check = listOpen, .timeout_ms = 2000 } },
    .{ .shot = "70-autocompletar-travado" },
    key(c.ImGuiKey_Enter),
    expect("sem Nitro, escolher avisa e não insere", lockedInList),
    .{ .run = clearInput },
    .{ .wait = 60 },
    .{ .run = ensureCommand },
    .{ .text = "/" },
    .{ .expect = .{ .name = "/ lista os comandos dos plugins", .check = commandListed, .timeout_ms = 2000 } },
    .{ .shot = "71-autocompletar-comandos" },
    key(c.ImGuiKey_Enter),
    expect("escolher entra com o nome do comando", commandInserted),
    .{ .run = clearInput },
    .{ .wait = 60 },
    .{ .text = "@an" },
    .{ .expect = .{ .name = "lista aberta de novo", .check = listOpen, .timeout_ms = 2000 } },
    key(c.ImGuiKey_DownArrow),
    expect("seta para baixo anda na lista", listAtSecond),
    key(c.ImGuiKey_UpArrow),
    .{ .key = .{ .key = c.ImGuiKey_Enter, .shift = true } },
    .{ .expect = .{ .name = "Shift+Enter abre linha nova mesmo com a lista", .check = newLineWithList, .timeout_ms = 2000 } },
    .{ .run = clearInput },
    .{ .wait = 60 },
    expect("caixa vazia no fim", inputEmpty),
};
