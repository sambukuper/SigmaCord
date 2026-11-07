//! QA da largura dos painéis (arrastar, limites, janela encolhendo, tela
//! dividida), das páginas de configurações sem nada sobreposto, da página de
//! novidades, da etiqueta de bot e de abrir banner e ícone grandes.
const std = @import("std");
const c = @import("c");
const App = @import("app.zig").App;
const sigma_ime_scale = &@import("app.zig").sigma_ime_scale;
const R = @import("qa_runner.zig");
const Op = R.Op;
const qa = @import("ui/qa.zig");
const d = @import("ui/draw.zig");
const anim = @import("ui/anim.zig");
const resize = @import("ui/resize.zig");
const mosaic = @import("ui/mosaic.zig");
const updater = @import("net/updater.zig");
const S = @import("ui/settings_state.zig");
const gw = @import("net/fake_gateway.zig");
const types = @import("core/types.zig");
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
fn dragBy(k: []const u8, dx: f32) Op {
    return .{ .drag_by = .{ .from = .{ .mark = k }, .dx = dx } };
}

// --- Largura dos painéis ---------------------------------------------------------

/// Larguras guardadas antes de um arraste e onde a alça estava.
var before_x: f32 = 0;
var before_chat: f32 = 0;

fn panelsDefault(app: *App) void {
    app.st.settings.resetPanels();
}
fn handleX(k: []const u8) f32 {
    const r = qa.find(k) orelse return -1;
    return r.x;
}
fn chatW() f32 {
    return (qa.find("main-area") orelse return 0).w;
}
fn rememberChannels(_: *App) void {
    before_x = handleX("resize:channels");
    before_chat = chatW();
}
fn rememberMembers(_: *App) void {
    before_x = handleX("resize:members");
    before_chat = chatW();
}
fn handlesThere(_: *App) bool {
    return qa.find("resize:channels") != null and qa.find("resize:members") != null;
}
fn lit(_: *App) bool {
    return qa.find("resize-lit:channels") != null;
}
fn notLit(_: *App) bool {
    return qa.find("resize-lit:channels") == null;
}
fn cursorResize(_: *App) bool {
    return c.ImGui_GetMouseCursor() == c.ImGuiMouseCursor_ResizeEW;
}
fn channelsGrew(app: *App) bool {
    return app.st.settings.width_channels == 100 and handleX("resize:channels") == before_x + 100 and chatW() == before_chat - 100;
}
fn channelsMax(app: *App) bool {
    return app.st.settings.width_channels == 240;
}
fn channelsMin(app: *App) bool {
    return app.st.settings.width_channels == -80;
}
fn channelsReset(app: *App) bool {
    return app.st.settings.width_channels == 0 and handleX("resize:channels") == before_x;
}
/// A lista de membros fica à direita: puxar para a esquerda alarga.
fn membersGrew(app: *App) bool {
    return app.st.settings.width_members == 80 and handleX("resize:members") == before_x - 80 and chatW() == before_chat - 80;
}
fn membersMax(app: *App) bool {
    return app.st.settings.width_members == 200;
}
fn membersMin(app: *App) bool {
    return app.st.settings.width_members == -70;
}
fn membersReset(app: *App) bool {
    return app.st.settings.width_members == 0 and handleX("resize:members") == before_x;
}
/// Arrastar e dar duplo clique na alça não seleciona texto nem foca outra coisa.
fn dragLeavesNothing(app: *App) bool {
    return app.st.selection.empty() and app.st.popup == .none and !app.st.selection.dragging;
}
/// Parado com o mouse em cima da alça, nada fica animando (o que anda devagar,
/// como os pontinhos de "digitando" da demonstração, não passa por aqui).
fn handleIdle(_: *App) bool {
    return !anim.active;
}
fn widen(app: *App) void {
    app.st.settings.width_channels = 240;
    app.st.settings.width_members = 200;
}
/// A janela encolheu: a conversa continua usável e o que a pessoa escolheu fica
/// guardado (a tela só está segurando).
fn chatKept(app: *App) bool {
    return chatW() >= resize.min_chat and app.st.settings.width_channels == 240 and app.st.settings.width_members == 200;
}
fn panelsBack(_: *App) bool {
    // 1280 - 72 - 480 - 448 = 280: não cabe tudo; a conversa continua no mínimo.
    return chatW() >= resize.min_chat;
}
/// Arquivo editado à mão, com um número absurdo: a tela limita.
fn absurdWidth(app: *App) void {
    app.st.settings.width_channels = 32767;
    app.st.settings.width_members = -32768;
}
fn absurdClamped(_: *App) bool {
    return chatW() >= resize.min_chat and handleX("resize:channels") > 0 and handleX("resize:channels") < 72 + 240 + 240 + 8;
}
fn setSome(app: *App) void {
    app.st.settings.width_channels = 77;
    app.st.settings.width_members = -33;
    app.st.settings.split_two = 620;
}
fn widthsPersisted(app: *App) bool {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(app.gpa);
    S.write(&app.st.settings, "classico", &out, app.gpa) catch return false;
    return std.mem.indexOf(u8, out.items, "width_channels=77") != null and std.mem.indexOf(u8, out.items, "width_members=-33") != null and std.mem.indexOf(u8, out.items, "split_two=620") != null;
}
fn resetShown(_: *App) bool {
    return qa.find("button:Restaurar larguras") != null;
}
fn panelsAtDefault(app: *App) bool {
    return app.st.settings.panelsAtDefault() and qa.find("button:Restaurar larguras") == null;
}

// Tela dividida.
fn twoPanes(_: *App) bool {
    return mosaic.panes.count == 2 and qa.find("resize:pane2") != null;
}
fn threePanes(_: *App) bool {
    return mosaic.panes.count == 3 and qa.find("resize:pane3a") != null and qa.find("resize:pane3b") != null;
}
fn paneW(i: usize) f32 {
    var b: [16]u8 = undefined;
    const k = std.fmt.bufPrint(&b, "pane:{d}", .{i}) catch return 0;
    return (qa.find(k) orelse return 0).w;
}
fn panesEven(_: *App) bool {
    return @abs(paneW(0) - paneW(1)) <= 2;
}
fn leftBigger(app: *App) bool {
    return app.st.settings.split_two > 600 and paneW(0) > paneW(1) + 100;
}
/// Toda a força para um lado: o outro painel para no mínimo.
fn rightAtMin(_: *App) bool {
    return paneW(1) == resize.min_pane or @abs(paneW(1) - resize.min_pane) <= 2;
}
fn splitReset(app: *App) bool {
    return app.st.settings.split_two == S.split_two_default and panesEven(app);
}
var third_w: f32 = 0;
fn rememberThird(_: *App) void {
    third_w = paneW(2);
}
/// A primeira divisa não mexe no terceiro painel.
fn thirdKept(_: *App) bool {
    return @abs(paneW(2) - third_w) <= 2 and paneW(0) > paneW(1);
}
/// E a segunda não mexe no primeiro.
var first_w: f32 = 0;
fn rememberFirst(_: *App) void {
    first_w = paneW(0);
}
fn firstKept(_: *App) bool {
    return @abs(paneW(0) - first_w) <= 2 and paneW(2) > third_w;
}
fn splitsReset(app: *App) bool {
    const t = &app.st.settings;
    return t.split_three_a == S.split_three_a_default and t.split_three_b == S.split_three_b_default and @abs(paneW(0) - paneW(2)) <= 3;
}
fn noPanes(_: *App) bool {
    return !mosaic.on() and qa.find("resize:pane2") == null;
}
/// Um canal de texto que ainda não está na tela.
fn tOtherChannel(app: *App, b: []u8) []const u8 {
    const active = app.st.activeChannel() orelse return "";
    for ([_]usize{ 4, 5, 6, 7 }) |i| {
        const id = gw.channelId(0, i);
        if (id != active and mosaic.panes.indexOf(id) == null) return std.fmt.bufPrint(b, "channel:{d}", .{id}) catch "";
    }
    return "";
}

pub const ops = [_]Op{
    s("largura dos painéis"),
    click("guild:500000"),
    .{ .run = panelsDefault },
    .{ .wait = 200 },
    expect("os dois painéis têm alça", handlesThere),
    .{ .run = rememberChannels },
    .{ .hover = .{ .mark = "resize:channels" } },
    expect("o mouse na divisa acende a alça", lit),
    expect("e troca o cursor pelo de redimensionar", cursorResize),
    // Depois de a dica aparecer, que é a última coisa a mudar.
    .{ .wait = 900 },
    .{ .expect = .{ .name = "parado em cima da alça, nada fica animando", .check = handleIdle, .timeout_ms = 3000 } },
    .{ .shot = "70-alca" },
    dragBy("resize:channels", 100),
    expect("arrastar alarga a lista de canais e tira da conversa", channelsGrew),
    expect("arrastar não seleciona texto nem abre nada", dragLeavesNothing),
    .{ .shot = "70a-canais-largos" },
    dragBy("resize:channels", 1000),
    expect("a lista de canais tem um máximo", channelsMax),
    dragBy("resize:channels", -2000),
    expect("e um mínimo", channelsMin),
    .{ .shot = "70b-canais-estreitos" },
    .{ .dclick = .{ .mark = "resize:channels" } },
    expect("duplo clique volta ao padrão", channelsReset),
    expect("duplo clique não seleciona nada", dragLeavesNothing),
    .{ .hover = .{ .mark = "composer" } },
    expect("o mouse saiu, a alça apaga", notLit),
    .{ .run = rememberMembers },
    dragBy("resize:members", -80),
    expect("puxar a lista de membros para a esquerda alarga", membersGrew),
    dragBy("resize:members", -1000),
    expect("a lista de membros tem um máximo", membersMax),
    dragBy("resize:members", 2000),
    expect("e um mínimo", membersMin),
    .{ .shot = "70c-membros-estreitos" },
    .{ .dclick = .{ .mark = "resize:members" } },
    expect("duplo clique nos membros volta ao padrão", membersReset),

    s("painéis com a janela encolhendo"),
    .{ .run = widen },
    .{ .wait = 100 },
    expect("com a janela cheia a conversa não fica menor que o mínimo", panelsBack),
    .{ .shot = "71-paineis-no-maximo" },
    .{ .resize = .{ 1100, 700 } },
    .{ .wait = 300 },
    expect("janela menor: a conversa continua usável, e a escolha fica guardada", chatKept),
    .{ .shot = "71a-janela-media" },
    .{ .resize = .{ 860, 600 } },
    .{ .wait = 300 },
    expect("janela pequena: idem", chatKept),
    .{ .shot = "71b-janela-pequena" },
    .{ .resize = .{ 1280, 800 } },
    .{ .wait = 300 },
    .{ .run = absurdWidth },
    .{ .wait = 100 },
    expect("número absurdo no arquivo: a tela limita", absurdClamped),
    .{ .run = setSome },
    expect("as larguras vão para o settings.kdl", widthsPersisted),
    .{ .key = .{ .key = c.ImGuiKey_Comma, .ctrl = true } },
    .{ .wait = 300 },
    click("settings:Aparência"),
    .{ .wait = 100 },
    expect("com larguras mudadas, Aparência oferece restaurar", resetShown),
    click("button:Restaurar larguras"),
    expect("restaurar volta tudo ao padrão do tema", panelsAtDefault),
    key(c.ImGuiKey_Escape),
    .{ .wait = 350 },

    s("largura na tela dividida"),
    .{ .rclick = .{ .dyn = tOtherChannel } },
    click("menu:Abrir ao lado"),
    expect("dois painéis têm uma alça entre eles", twoPanes),
    expect("começam iguais", panesEven),
    dragBy("resize:pane2", 150),
    expect("arrastar aumenta o painel da esquerda", leftBigger),
    .{ .shot = "72-tela-dividida-ajustada" },
    dragBy("resize:pane2", 2000),
    expect("o outro painel para no mínimo", rightAtMin),
    .{ .dclick = .{ .mark = "resize:pane2" } },
    expect("duplo clique volta a dividir igual", splitReset),
    .{ .rclick = .{ .dyn = tOtherChannel } },
    click("menu:Abrir ao lado"),
    expect("três painéis têm duas alças", threePanes),
    .{ .run = rememberThird },
    dragBy("resize:pane3a", 60),
    expect("a primeira divisa não mexe no terceiro painel", thirdKept),
    .{ .run = rememberFirst },
    .{ .run = rememberThird },
    dragBy("resize:pane3b", -40),
    expect("a segunda não mexe no primeiro", firstKept),
    .{ .shot = "72a-tres-paineis" },
    .{ .dclick = .{ .mark = "resize:pane3a" } },
    expect("duplo clique volta os três ao padrão", splitsReset),
    click("pane-close:2"),
    click("pane-close:1"),
    expect("sem tela dividida, sem alça", noPanes),
    .{ .run = panelsDefault },
};

/// Em todo tema: a alça segue o arraste (seja de que lado o painel estiver).
fn themeChannelsMark(_: *App, b: []u8) []const u8 {
    if (qa.find("resize:channels") == null) return "";
    return std.fmt.bufPrint(b, "resize:channels", .{}) catch "";
}
fn themeMembersMark(_: *App, b: []u8) []const u8 {
    if (qa.find("resize:members") == null) return "";
    return std.fmt.bufPrint(b, "resize:members", .{}) catch "";
}
fn rememberBoth(_: *App) void {
    before_x = handleX("resize:channels");
    before_chat = handleX("resize:members");
}
fn channelsFollowed(_: *App) bool {
    return qa.find("resize:channels") == null or handleX("resize:channels") == before_x - 30;
}
fn membersFollowed(_: *App) bool {
    return qa.find("resize:members") == null or handleX("resize:members") == before_chat - 30;
}
fn themeBackToDefault(app: *App) bool {
    return app.st.settings.panelsAtDefault() and (qa.find("resize:channels") == null or handleX("resize:channels") == before_x);
}
fn tChannelsAt(app: *App, b: []u8) []const u8 {
    return themeChannelsMark(app, b);
}

/// Quem tem lista de membros mostra a etiqueta do bot (zen não tem lista).
fn botTaggedInTheme(_: *App) bool {
    return qa.find("member:1012") == null or qa.find("bot-tag:1012") != null;
}

pub const ops_theme = [_]Op{
    s("alças do tema"),
    expect("o bot leva a etiqueta na lista de membros", botTaggedInTheme),
    .{ .run = panelsDefault },
    .{ .wait = 100 },
    .{ .run = rememberBoth },
    .{ .drag_by = .{ .from = .{ .dyn = themeChannelsMark }, .dx = -30 } },
    expect("a alça dos canais segue o arraste", channelsFollowed),
    .{ .drag_by = .{ .from = .{ .dyn = themeMembersMark }, .dx = -30 } },
    expect("a alça dos membros segue o arraste", membersFollowed),
    .{ .hover = .{ .dyn = tChannelsAt } },
    .{ .wait = 200 },
    .{ .shot = "tema-alca" },
    .{ .dclick = .{ .dyn = themeChannelsMark } },
    .{ .dclick = .{ .dyn = themeMembersMark } },
    expect("duplo clique volta ao que o tema pede", themeBackToDefault),
};

// --- Configurações sem nada sobreposto ------------------------------------------

const page_marks = [_][]const u8{ "pg:", "button:", "toggle:", "select:", "slider:", "seg:", "radio:", "accent:", "theme-card:", "theme-color:", "changelog-version:", "changelog-section:", "changelog-item:" };

fn noOverlap(_: *App) bool {
    return qa.overlapping(&page_marks) == null;
}

fn updateAvailable(_: *App) void {
    updater.qaSet(.available, "v9.9.9");
}
fn updateReady(_: *App) void {
    updater.qaSet(.ready, "v9.9.9");
}
fn updateFailed(_: *App) void {
    updater.qaSet(.failed, "");
}
fn updateIdle(_: *App) void {
    updater.qaSet(.idle, "");
}
fn updateBoth(_: *App) bool {
    const a = qa.find("button:Baixar e instalar") orelse return false;
    const b = qa.find("button:Verificar atualizações") orelse return false;
    return a.y == b.y and b.x >= a.right();
}
fn toggleBelowCheck(_: *App) bool {
    const b = qa.find("button:Verificar atualizações") orelse return false;
    const t = qa.find("toggle:Verificar ao abrir") orelse return false;
    return t.y >= b.bottom();
}
fn scaleUp(app: *App) void {
    app.st.settings.font_scale = 1.3;
}
fn scaleDown(app: *App) void {
    app.st.settings.font_scale = 1.0;
}

// --- Em bateria própria: sair de um servidor muda a lista para o resto do QA -------------

var leaving: Id = 0;
fn tLeaveGuild(_: *App, b: []u8) []const u8 {
    // Fora das pastas (fechadas, não aparecem na barra).
    leaving = gw.guildId(5);
    return std.fmt.bufPrint(b, "guild:{d}", .{leaving}) catch "";
}
fn tLeaveConfirm(app: *App, b: []u8) []const u8 {
    const g = app.store.guild(leaving) orelse return "";
    return std.fmt.bufPrint(b, "menu:Sair de «{s}»", .{g.name}) catch "";
}
fn leaveAsks(app: *App) bool {
    return app.st.popup == .menu and app.st.popup.menu.kind == .guild_leave and app.store.guild(leaving) != null;
}
fn guildGone(app: *App) bool {
    return leaving != 0 and app.store.guild(leaving) == null and app.st.popup != .menu and app.st.guild != leaving;
}
fn guildOpen(app: *App) bool {
    return leaving != 0 and app.st.guild == leaving;
}
fn debugFileHasLine(_: *App) bool {
    const debug_log = @import("platform/debug_log.zig");
    if (!debug_log.isOn()) return false;
    var size: usize = 0;
    const data = c.SDL_LoadFile((debug_log.path() orelse return false).ptr, &size) orelse return false;
    defer c.SDL_free(data);
    return std.mem.indexOf(u8, @as([*]const u8, @ptrCast(data))[0..size], "registro ligado: SigmaCord") != null;
}
fn debugOff(_: *App) bool {
    return !@import("platform/debug_log.zig").isOn();
}

fn gifsTrending(app: *App) bool {
    const l = app.store.gif_results;
    return app.st.popup == .gif and l.state == .ready and l.items.len == 8 and qa.find("gif:7") != null;
}
fn gifsFound(app: *App) bool {
    const l = app.store.gif_results;
    return l.state == .ready and l.items.len == 1 and std.mem.eql(u8, l.items[0].title, "shrug") and qa.find("gif:0") != null;
}
fn gifsFavorites(app: *App) bool {
    const l = app.store.gif_favorites;
    return l.state == .ready and l.items.len == 3 and qa.find("gif:2") != null;
}
fn gifSent(app: *App) bool {
    if (app.st.popup == .gif) return false;
    const ch = app.st.activeChannel() orelse return false;
    const cs = app.store.channel(ch) orelse return false;
    if (cs.messages.items.len == 0) return false;
    const last = cs.messages.items[cs.messages.items.len - 1];
    return std.mem.startsWith(u8, last.msg.content, "https://tenor.com/view/") and std.mem.eql(u8, std.mem.sliceTo(&app.st.input, 0), "ainda escrevendo");
}
/// Prévia de outro site, num endereço que o app nunca baixa: testa o aviso sem usar a rede.
fn gifExternal(app: *App) void {
    const l = app.store.gif_favorites;
    if (l.items.len == 0) return;
    std.heap.c_allocator.free(l.items[0].src);
    l.items[0].src = std.heap.c_allocator.dupe(u8, "https://example.invalid/x.webp") catch "";
}
fn gifAsksPreviews(_: *App) bool {
    return qa.find("gif-previews-on") != null;
}
fn gifPreviewsOn(app: *App) bool {
    return app.st.settings.gif_hosts and qa.find("gif-previews-on") == null;
}
fn gifPreviewsReset(app: *App) void {
    app.st.settings.gif_hosts = false;
}

const ffmpeg_mod = @import("platform/ffmpeg.zig");
const ffmpeg_get = @import("net/ffmpeg_get.zig");

fn ffmpegMissing(_: *App) void {
    // A bateria roda com SIGMACORD_NO_FFMPEG, para isto não depender da máquina.
    ffmpeg_get.qa_no_network = true;
    _ = ffmpeg_mod.get();
}
fn ffmpegNotFound(_: *App) bool {
    return ffmpeg_mod.known() == false and qa.find("button:Baixar FFmpeg") != null;
}
fn ffmpegWarns(_: *App) bool {
    return qa.find("button:Baixar agora") != null and ffmpeg_get.phase() == .idle;
}
fn ffmpegDone(_: *App) bool {
    return ffmpeg_get.phase() == .done;
}

var text_width_before: f32 = 0;
const text_sample = "Mostra o ID das mensagens e põe Copiar ID nos menus";
fn textWidth(app: *App) f32 {
    return d.width(app.fonts.faces.items[0].font, 14, text_sample);
}
fn textStyleSet(app: *App) void {
    text_width_before = textWidth(app);
    app.st.settings.text_weight = 1.5;
    app.st.settings.text_hinting = 1;
}
fn textStyleApplied(app: *App) bool {
    const src = app.fonts.faces.items[0].font.Sources.Data[0];
    if (app.fonts.text_weight != 1.5 or src.*.RasterizerMultiply != 1.5 or src.*.FontLoaderFlags & 31 != 4) return false;
    // Prova de que as letras foram geradas de novo: com as hastes alinhadas, o texto muda de largura.
    return textWidth(app) != text_width_before;
}
fn textStyleDefault(app: *App) bool {
    const src = app.fonts.faces.items[0].font.Sources.Data[0];
    return app.st.settings.text_weight == 1 and src.*.RasterizerMultiply == 1 and src.*.FontLoaderFlags & 31 == 8 and textWidth(app) == text_width_before;
}
const bar_grip: @import("qa_runner.zig").Target = .{ .at = .{ .key = "msg-scrollbar", .fx = 0.5, .fy = 1.4 } };

fn scrollAtEnd(app: *App) bool {
    const ch = app.st.activeChannel() orelse return false;
    return app.st.scrollOf(ch).stick_bottom;
}
/// A posição em si não prova nada: ao soltar, as mensagens antigas carregam e ela sobe. O que
/// importa é que saiu do fim: sem o arraste valer fora da faixa, a rolagem voltaria para lá.
/// Chegou perto do início: o que importa é quantas mensagens ficaram abaixo, porque ao soltar
/// as antigas carregam e a posição em si sobe.
fn scrollMoved(app: *App) bool {
    if (scrollAtEnd(app)) return false;
    const ch = app.st.activeChannel() orelse return false;
    const cs = app.store.channel(ch) orelse return false;
    const anchor = app.st.scrollOf(ch).anchor_id;
    for (cs.messages.items, 0..) |m, i| {
        if (m.msg.id == anchor) return cs.messages.items.len - i >= msgs_before * 7 / 10;
    }
    return false;
}
var msgs_before: usize = 0;
fn rememberMessages(app: *App) void {
    const ch = app.st.activeChannel() orelse return;
    const cs = app.store.channel(ch) orelse return;
    msgs_before = cs.messages.items.len;
}
fn scrollBottom(app: *App) void {
    const ch = app.st.activeChannel() orelse return;
    app.st.scrollOf(ch).stick_bottom = true;
}
fn windowFullscreen(app: *App) bool {
    _ = c.SDL_SyncWindow(app.win.window);
    return c.SDL_GetWindowFlags(app.win.window) & c.SDL_WINDOW_FULLSCREEN != 0;
}
fn windowNotFullscreen(app: *App) bool {
    return !windowFullscreen(app);
}
fn composerKept(app: *App) bool {
    return std.mem.eql(u8, std.mem.sliceTo(&app.st.input, 0), "sem enviar");
}

var stylized_w: f32 = 0;
var question_w: f32 = 0;
fn probeLetters(app: *App) void {
    const font = app.fonts.faces.items[0].font;
    stylized_w = d.width(font, 14, "𝗠𝗲𝗺𝗲𝘀");
    question_w = d.width(font, 14, "?????");
    // Javanês: nem a fonte do tema nem as reservas têm.
    _ = d.width(font, 14, "꧁");
}
fn stylizedNotQuestion(_: *App) bool {
    return stylized_w > 0 and stylized_w != question_w;
}
fn lettersNoted(_: *App) bool {
    return std.mem.indexOfScalar(u32, @import("ui/fonts.zig").missingLetters(), 0xA9C1) != null;
}
/// Sem foto de 128 px reduzida na placa de vídeo: a textura tem o tamanho em que aparece.
fn imageExactSize(app: *App) bool {
    return switch (app.images.get("demo:1", 40, 40)) {
        .ready => |t| t.w == 40 and t.h == 25,
        else => false,
    };
}

pub const ops_extras = [_]Op{
    s("botão do FFmpeg, sem rede"),
    .{ .key = .{ .key = c.ImGuiKey_Comma, .ctrl = true } },
    click("settings:Chat"),
    .{ .run = ffmpegMissing },
    .{ .expect = .{ .name = "sem FFmpeg, oferece baixar", .check = ffmpegNotFound, .timeout_ms = 3000 } },
    click("button:Baixar FFmpeg"),
    .{ .expect = .{ .name = "avisa antes de baixar qualquer coisa", .check = ffmpegWarns, .timeout_ms = 2000 } },
    .{ .shot = "ffmpeg-aviso" },
    expect("nada se sobrepõe", noOverlap),
    click("button:Baixar agora"),
    .{ .expect = .{ .name = "e só baixa depois de confirmar", .check = ffmpegDone, .timeout_ms = 2000 } },
    key(c.ImGuiKey_Escape),
    s("seletor de GIFs"),
    click("composer"),
    .{ .text = "ainda escrevendo" },
    click("composer-gif"),
    .{ .expect = .{ .name = "abre com os GIFs em alta", .check = gifsTrending, .timeout_ms = 3000 } },
    .{ .wait = 300 },
    .{ .shot = "gifs-em-alta" },
    expect("nada se sobrepõe", noOverlap),
    .{ .text = "SHRUG" },
    .{ .expect = .{ .name = "a busca filtra", .check = gifsFound, .timeout_ms = 3000 } },
    .{ .key = .{ .key = c.ImGuiKey_A, .ctrl = true } },
    key(c.ImGuiKey_Backspace),
    .{ .expect = .{ .name = "apagar a busca volta aos em alta", .check = gifsTrending, .timeout_ms = 3000 } },
    click("gif-tab:1"),
    .{ .expect = .{ .name = "a aba de favoritos traz os da conta", .check = gifsFavorites, .timeout_ms = 3000 } },
    .{ .shot = "gifs-favoritos" },
    .{ .run = gifExternal },
    .{ .expect = .{ .name = "prévia de fora pede permissão antes de baixar", .check = gifAsksPreviews, .timeout_ms = 2000 } },
    .{ .shot = "gifs-aviso" },
    click("gif-previews-on"),
    .{ .expect = .{ .name = "e o botão liga a opção de verdade", .check = gifPreviewsOn, .timeout_ms = 2000 } },
    .{ .run = gifPreviewsReset },
    click("gif:1"),
    .{ .expect = .{ .name = "clicar manda o link e não mexe no que estava escrito", .check = gifSent, .timeout_ms = 3000 } },
    .{ .key = .{ .key = c.ImGuiKey_A, .ctrl = true } },
    key(c.ImGuiKey_Backspace),
    s("sair do servidor (o que está aberto)"),
    .{ .click = .{ .dyn = tLeaveGuild } },
    expect("o servidor está aberto", guildOpen),
    .{ .rclick = .{ .dyn = tLeaveGuild } },
    click("menu:Sair do servidor"),
    expect("pede confirmação antes de sair", leaveAsks),
    .{ .shot = "sair-confirma" },
    .{ .click = .{ .dyn = tLeaveConfirm } },
    .{ .expect = .{ .name = "o servidor some da lista", .check = guildGone, .timeout_ms = 4000 } },
    s("registro de depuração"),
    .{ .key = .{ .key = c.ImGuiKey_Comma, .ctrl = true } },
    click("settings:Avançado"),
    .{ .wait = 150 },
    .{ .shot = "avancado-depuracao" },
    click("toggle:Salvar registro de depuração"),
    .{ .expect = .{ .name = "ligado, o arquivo começa com a versão e o sistema", .check = debugFileHasLine, .timeout_ms = 3000 } },
    expect("nada se sobrepõe", noOverlap),
    click("toggle:Salvar registro de depuração"),
    .{ .expect = .{ .name = "e desliga", .check = debugOff, .timeout_ms = 2000 } },
    s("opção de texto, ao vivo"),
    .{ .run = textStyleSet },
    .{ .expect = .{ .name = "peso e encaixe mudam sem reiniciar", .check = textStyleApplied, .timeout_ms = 2000 } },
    .{ .shot = "texto-opcao" },
    expect("nada se sobrepõe com o texto mudado", noOverlap),
    click("button:Voltar ao padrão"),
    .{ .expect = .{ .name = "e voltar ao padrão restaura tudo", .check = textStyleDefault, .timeout_ms = 2000 } },
    s("barra de rolagem das mensagens"),
    key(c.ImGuiKey_Escape),
    .{ .wait = 150 },
    expect("a conversa está no fim antes de arrastar", scrollAtEnd),
    .{ .run = rememberMessages },
    // Pega a alça, no fim da barra: um clique no trilho, acima dela, só sobe uma página.
    // Primeiro dentro da faixa: sem isto, uma falha abaixo não diria se foi a faixa.
    .{ .drag = .{ .from = bar_grip, .to = .{ .mark = "msg-scrollbar-top" } } },
    .{ .wait = 100 },
    expect("arrastar a barra sobe", scrollMoved),
    .{ .run = scrollBottom },
    .{ .wait = 300 },
    expect("e volta ao fim", scrollAtEnd),
    // Sobe saindo bem para fora da faixa da barra, como a mão faz.
    .{ .run = rememberMessages },
    .{ .drag = .{ .from = bar_grip, .to = .{ .at = .{ .key = "msg-scrollbar-top", .fx = -60, .fy = 0.5 } } } },
    .{ .wait = 100 },
    expect("arrastar a barra sobe mesmo com o mouse fora dela", scrollMoved),
    .{ .run = scrollBottom },
    .{ .wait = 150 },
    s("tela cheia"),
    key(c.ImGuiKey_Escape),
    click("composer"),
    .{ .text = "sem enviar" },
    .{ .key = .{ .key = c.ImGuiKey_Enter, .alt = true } },
    .{ .expect = .{ .name = "Alt+Enter liga a tela cheia", .check = windowFullscreen, .timeout_ms = 2000 } },
    expect("e não manda o que estava escrito", composerKept),
    .{ .key = .{ .key = c.ImGuiKey_F11 } },
    .{ .expect = .{ .name = "F11 desliga", .check = windowNotFullscreen, .timeout_ms = 2000 } },
    .{ .key = .{ .key = c.ImGuiKey_A, .ctrl = true } },
    key(c.ImGuiKey_Backspace),
    .{ .key = .{ .key = c.ImGuiKey_Comma, .ctrl = true } },
    .{ .wait = 150 },
    s("letras sem fonte"),
    .{ .run = probeLetters },
    .{ .expect = .{ .name = "letra estilizada não vira ?", .check = stylizedNotQuestion, .timeout_ms = 2000 } },
    .{ .expect = .{ .name = "e a escrita sem fonte é anotada para as Configurações", .check = lettersNoted, .timeout_ms = 2000 } },
    .{ .wait = 100 },
    .{ .shot = "letras-sem-fonte" },
    s("imagem no tamanho em que aparece"),
    .{ .expect = .{ .name = "foto reduzida antes de ir para a placa", .check = imageExactSize, .timeout_ms = 3000 } },
    key(c.ImGuiKey_Escape),
};

// --- Só no CI do Windows (QA_SUITE=ffmpeg): baixa e carrega o FFmpeg de verdade ---------

fn ffmpegRealLoads(_: *App) bool {
    if (ffmpeg_get.phase() == .failed) return true;
    if (ffmpeg_get.phase() != .done) return false;
    return ffmpeg_mod.get() != null;
}
fn ffmpegRealOk(_: *App) bool {
    return ffmpeg_get.phase() == .done and ffmpeg_mod.known() == true;
}
fn ffmpegRealStart(_: *App) void {
    ffmpeg_get.start();
}

pub const ops_ffmpeg = [_]Op{
    s("baixar, conferir e carregar o FFmpeg de verdade"),
    .{ .run = ffmpegRealStart },
    .{ .expect = .{ .name = "o download termina", .check = ffmpegRealLoads, .timeout_ms = 300_000 } },
    expect("as bibliotecas carregam e a versão bate", ffmpegRealOk),
};

fn uiBig(app: *App) void {
    app.st.settings.ui_scale = 1.5;
}
fn uiNormal(app: *App) void {
    app.st.settings.ui_scale = 1;
}
fn uiFractional(app: *App) void {
    app.st.settings.ui_scale = 1.25;
}
fn uiIs110(app: *App) bool {
    return @abs(app.st.settings.ui_scale - 1.1) < 0.001 and @abs(app.io.*.DisplayFramebufferScale.x - 1.1) < 0.01;
}
/// A janela é a mesma: em pontos ela encolhe, e o desenho sai 1,5 vez maior.
fn uiIsBig(app: *App) bool {
    // As letras saem da resolução nova, não de um bitmap de 100% esticado.
    for (app.fonts.faces.items) |e| if (e.font.*.CurrentRasterizerDensity != app.io.*.DisplayFramebufferScale.x) return false;
    return @abs(app.io.*.DisplaySize.x - 1280.0 / 1.5) < 2 and @abs(app.io.*.DisplayFramebufferScale.x - 1.5) < 0.01;
}
fn uiIsNormal(app: *App) bool {
    return app.io.*.DisplaySize.x == 1280 and app.io.*.DisplayFramebufferScale.x == 1;
}
/// O valor do slider já está valendo no desenho: o arraste terminou.
fn uiDragged(app: *App) bool {
    const v = app.st.settings.ui_scale;
    return v > 1.2 and v < 1.8 and app.ui_size == v and @abs(app.io.*.DisplayFramebufferScale.x - v) < 0.01;
}

/// Antes de um texto pedir, nenhuma fonte de outra escrita foi procurada.
pub fn scriptsNotLoaded(app: *App) bool {
    return !app.fonts.scripts_tried;
}
/// As fontes reserva entraram em todas as fontes do atlas (sem CJK no sistema, como no CI, não há o que mesclar).
pub fn scriptsLoaded(app: *App) bool {
    if (!app.fonts.scripts_tried) return false;
    if (app.fonts.cjk_n == 0) return true;
    for (app.fonts.faces.items) |e| if (!c.ImFont_IsGlyphInFont(e.font, 0x3042)) return false;
    return true;
}

const ui_slider = "slider:Tamanho da interface";

pub const ops_ui_size = [_]Op{
    s("tamanho da interface"),
    expect("a página de idioma, com o nome em japonês, traz as fontes reserva", scriptsLoaded),
    .{ .key = .{ .key = c.ImGuiKey_Comma, .ctrl = true } },
    .{ .wait = 300 },
    click("settings:Aparência"),
    .{ .wait = 150 },
    // O clique leva até o slider; o arraste é o de quem usa, e só vale ao soltar.
    .{ .click = .{ .at = .{ .key = ui_slider, .fx = 0.2, .fy = 0.5 } } },
    .{ .wait = 200 },
    .{ .drag = .{ .from = .{ .at = .{ .key = ui_slider, .fx = 0.2, .fy = 0.5 } }, .to = .{ .at = .{ .key = ui_slider, .fx = 0.6, .fy = 0.5 } } } },
    .{ .wait = 200 },
    expect("arrastar o slider muda a interface ao soltar", uiDragged),
    .{ .run = uiBig },
    .{ .wait = 200 },
    expect("aumenta a interface inteira", uiIsBig),
    expect("nada se sobrepõe com a interface maior", noOverlap),
    .{ .shot = "interface-150" },
    .{ .run = uiNormal },
    .{ .wait = 200 },
    expect("volta ao normal", uiIsNormal),
    .{ .run = uiFractional },
    .{ .wait = 250 },
    .{ .shot = "interface-125" },
    .{ .run = uiNormal },
    .{ .wait = 200 },
    s("Ctrl + , Ctrl - e Ctrl 0"),
    .{ .key = .{ .key = c.ImGuiKey_Equal, .ctrl = true } },
    .{ .wait = 150 },
    expect("Ctrl + aumenta 10%", uiIs110),
    .{ .shot = "interface-110" },
    expect("nada se sobrepõe em 110%", noOverlap),
    .{ .key = .{ .key = c.ImGuiKey_Minus, .ctrl = true } },
    .{ .wait = 150 },
    expect("Ctrl - diminui", uiIsNormal),
    .{ .key = .{ .key = c.ImGuiKey_Equal, .ctrl = true } },
    .{ .key = .{ .key = c.ImGuiKey_Equal, .ctrl = true } },
    .{ .wait = 150 },
    .{ .key = .{ .key = c.ImGuiKey_0, .ctrl = true } },
    .{ .wait = 150 },
    expect("Ctrl 0 volta ao normal", uiIsNormal),
    key(c.ImGuiKey_Escape),
    .{ .wait = 350 },
};

// --- A janela do IME ---------------------------------------------------------------------

fn raiseWindow(app: *App) void {
    _ = c.SDL_RaiseWindow(app.win.window);
}

/// O que o SDL entrega ao IME está em coordenadas da janela, e a interface, em pontos. Com
/// escala do sistema, só num X de verdade: `QA_SUITE=ime` e SDL_VIDEO_X11_SCALING_FACTOR.
/// (O cursor começa um pouco antes da marcação da caixa.)
fn imeInPlace(app: *App) bool {
    const k = app.uiScale();
    if (@abs(sigma_ime_scale.* - k) > 0.01) return false;
    if (c.SDL_GetKeyboardFocus() == null) return true;
    var r: c.SDL_Rect = undefined;
    var cursor: c_int = 0;
    if (!c.SDL_GetTextInputArea(app.win.window, &r, &cursor)) return false;
    const box = qa.find("composer") orelse return false;
    if (c.SDL_getenv("QA_DEBUG") != null) std.debug.print("[ime] escala {d:.2}, área {d},{d} altura {d}, caixa em pontos {d:.0},{d:.0} até {d:.0},{d:.0}\n", .{ k, r.x, r.y, r.h, box.x, box.y, box.right(), box.bottom() });
    const x: f32 = @floatFromInt(r.x);
    const y: f32 = @floatFromInt(r.y);
    return x >= (box.x - 4) * k and x <= box.right() * k and y >= box.y * k and y <= box.bottom() * k and r.h > 0;
}

pub const ops_ime = [_]Op{
    s("janela do IME"),
    .{ .run = raiseWindow },
    .{ .wait = 200 },
    click("composer"),
    expect("a janela do IME fica sobre a caixa de texto", imeInPlace),
    .{ .run = uiBig },
    .{ .wait = 200 },
    expect("com a interface maior também", imeInPlace),
    .{ .run = uiNormal },
    .{ .wait = 200 },
    key(c.ImGuiKey_Escape),
};

const check = expect("nada se sobrepõe na página", noOverlap);

fn pageOps(comptime name: []const u8, comptime slug: []const u8) [4]Op {
    return .{ click("settings:" ++ name), .{ .wait = 120 }, expect("nada se sobrepõe em " ++ name, noOverlap), .{ .shot = "73p-" ++ slug } };
}

pub const ops_pages = [_]Op{
    s("configurações sem nada sobreposto"),
    .{ .key = .{ .key = c.ImGuiKey_Comma, .ctrl = true } },
    .{ .wait = 300 },
    click("settings:Atualizações"),
    .{ .wait = 150 },
    .{ .run = updateIdle },
    .{ .wait = 100 },
    expect("o botão de verificar vem antes do interruptor", toggleBelowCheck),
    expect("Atualizações: nada se sobrepõe", noOverlap),
    .{ .shot = "73-atualizacoes" },
    .{ .run = updateAvailable },
    .{ .wait = 100 },
    expect("com versão nova, os dois botões ficam lado a lado", updateBoth),
    expect("Atualizações com versão nova: nada se sobrepõe", noOverlap),
    .{ .shot = "73a-atualizacoes-disponivel" },
    .{ .run = updateReady },
    .{ .wait = 100 },
    expect("Atualizações pedindo para reiniciar: nada se sobrepõe", noOverlap),
    .{ .run = updateFailed },
    .{ .wait = 100 },
    expect("Atualizações com erro: nada se sobrepõe", noOverlap),
    .{ .run = updateIdle },
    .{ .run = scaleUp },
    .{ .wait = 150 },
    expect("com o texto em 130%: nada se sobrepõe", noOverlap),
    .{ .shot = "73b-atualizacoes-130" },
    .{ .run = scaleDown },
    .{ .resize = .{ 860, 600 } },
    .{ .wait = 250 },
    expect("janela pequena: nada se sobrepõe", noOverlap),
    .{ .shot = "73c-atualizacoes-pequena" },
    .{ .resize = .{ 1280, 800 } },
    .{ .wait = 200 },
} ++ pageOps("Minha conta", "conta") ++ pageOps("Privacidade", "privacidade") ++ pageOps("Alertas e filtros", "filtros") ++ pageOps("Aparência", "aparencia") ++ pageOps("Acessibilidade", "acessibilidade") ++ pageOps("Chat", "chat") ++ pageOps("Voz", "voz") ++ pageOps("Notificações", "notificacoes") ++ pageOps("Atalhos de teclado", "atalhos") ++ pageOps("Idioma", "idioma") ++ pageOps("Avançado", "avancado") ++ pageOps("Desempenho", "desempenho") ++ pageOps("Erros no código", "lsp") ++ pageOps("Plugins", "plugins") ++ pageOps("Sobre", "sobre") ++ [_]Op{
    key(c.ImGuiKey_Escape),
    .{ .wait = 350 },
};

/// Em todo tema: as páginas redesenhadas (cada tema tem a sua fonte).
pub const ops_pages_theme = [_]Op{
    s("atualizações e novidades no tema"),
    .{ .key = .{ .key = c.ImGuiKey_Comma, .ctrl = true } },
    .{ .wait = 300 },
    click("settings:Atualizações"),
    .{ .wait = 120 },
    check,
    .{ .shot = "tema-atualizacoes" },
    click("settings:Novidades"),
    .{ .wait = 120 },
    check,
    .{ .shot = "tema-novidades" },
    key(c.ImGuiKey_Escape),
    .{ .wait = 350 },
};

// --- Novidades --------------------------------------------------------------------

/// A versão instalada, a mais nova da página: o teste não muda a cada release.
fn tNewest(_: *App, b: []u8) []const u8 {
    return std.fmt.bufPrint(b, "changelog-version:{s}", .{updater.current}) catch "";
}
fn newestItem() bool {
    var b: [64]u8 = undefined;
    const k = std.fmt.bufPrint(&b, "changelog-item:{s}:0", .{updater.current}) catch return false;
    return qa.find(k) != null;
}
fn changelogReal(_: *App) bool {
    // O conteúdo de verdade do CHANGELOG, no idioma da interface, sem o título do arquivo.
    return qa.find("changelog-section:Chamadas") != null and qa.find("changelog-section:Correções") != null and newestItem();
}
fn currentMarked(_: *App) bool {
    var b: [64]u8 = undefined;
    const k = std.fmt.bufPrint(&b, "changelog-current:{s}", .{updater.current}) catch return false;
    return qa.find(k) != null;
}
fn oldClosed(_: *App) bool {
    return qa.find("changelog-version:0.4.0") != null and qa.find("changelog-item:0.4.0:0") == null;
}
fn oldOpen(_: *App) bool {
    return qa.find("changelog-item:0.4.0:0") != null;
}
fn newClosed(_: *App) bool {
    var b: [64]u8 = undefined;
    return qa.find(tNewest(undefined, &b)) != null and !newestItem();
}
fn newOpen(_: *App) bool {
    return newestItem();
}
fn linesOrdered(_: *App) bool {
    var k: [64]u8 = undefined;
    const a = qa.find(tNewest(undefined, &k)) orelse return false;
    const b = qa.find("changelog-version:0.4.0") orelse return false;
    return b.y > a.bottom();
}

pub const ops_changelog = [_]Op{
    s("página de novidades"),
    .{ .key = .{ .key = c.ImGuiKey_Comma, .ctrl = true } },
    .{ .wait = 300 },
    click("settings:Novidades"),
    .{ .wait = 150 },
    expect("mostra o CHANGELOG de verdade, em seções", changelogReal),
    expect("a versão instalada está marcada", currentMarked),
    expect("a versão mais antiga começa fechada", oldClosed),
    expect("uma versão vem depois da outra", linesOrdered),
    check,
    .{ .shot = "74-novidades" },
    .{ .click = .{ .dyn = tNewest } },
    expect("clicar fecha a versão", newClosed),
    click("changelog-version:0.4.0"),
    expect("clicar abre a versão", oldOpen),
    .{ .wait = 150 },
    check,
    .{ .shot = "74a-novidades-fechada" },
    click("changelog-version:0.4.0"),
    .{ .click = .{ .dyn = tNewest } },
    expect("e volta como estava", newOpen),
    key(c.ImGuiKey_Escape),
    .{ .wait = 350 },
};

// --- Etiqueta de bot ----------------------------------------------------------------

fn botInMessages(_: *App) bool {
    return qa.find("user:1012") != null and qa.find("bot-tag:1012") != null and qa.find("bot-verified:1012") != null;
}
fn tBot(_: *App, b: []u8) []const u8 {
    return std.fmt.bufPrint(b, "user:{d}", .{gw.bot_user}) catch "";
}
fn botInMemberList(_: *App) bool {
    const m = qa.find("member:1012") orelse return false;
    const t = qa.find("bot-tag:1012") orelse return false;
    return t.x >= m.x and t.right() <= m.right() + 1 and t.y >= m.y and t.bottom() <= m.bottom() + 1;
}
fn plainBotNoCheck(_: *App) bool {
    return qa.find("bot-tag:1013") != null and qa.find("bot-verified:1013") == null;
}
fn humanNoTag(_: *App) bool {
    return qa.find("member:1001") != null and qa.find("bot-tag:1001") == null;
}
fn tBotMember(_: *App, b: []u8) []const u8 {
    return std.fmt.bufPrint(b, "member:{d}", .{gw.bot_user}) catch "";
}
fn tBotDm(_: *App, b: []u8) []const u8 {
    return std.fmt.bufPrint(b, "channel:{d}", .{gw.bot_dm}) catch "";
}
fn profileWithTag(app: *App) bool {
    return app.st.popup == .profile and qa.find("bot-tag:1012") != null;
}
fn botDmTagged(_: *App) bool {
    const row = qa.find("channel:900011") orelse return false;
    _ = row;
    return qa.find("bot-tag:1012") != null and qa.find("dm-profile") != null;
}
fn jumpToWebhook(app: *App) void {
    const id = app.st.activeChannel() orelse return;
    const cs = app.store.channel(id) orelse return;
    for (cs.messages.items) |*m| if (m.msg.author == gw.webhook_user) {
        app.st.jump = m.msg.id;
    };
}
fn tWebhook(_: *App, b: []u8) []const u8 {
    return std.fmt.bufPrint(b, "user:{d}", .{gw.webhook_user}) catch "";
}
fn webhookTagged(_: *App) bool {
    var b: [40]u8 = undefined;
    const k = std.fmt.bufPrint(&b, "bot-tag:{d}", .{gw.webhook_user}) catch return false;
    return qa.find(k) != null;
}
/// O cartão de um webhook não finge que é uma conta: nada de mandar mensagem.
fn webhookCard(app: *App) bool {
    var b: [40]u8 = undefined;
    const k = std.fmt.bufPrint(&b, "bot-tag:{d}", .{gw.webhook_user}) catch return false;
    return app.st.popup == .profile and qa.find(k) != null and !app.store.profiles.contains(gw.webhook_user);
}
fn webhookMenu(app: *App) bool {
    return app.st.popup == .menu and qa.find("menu:Perfil") != null and qa.find("menu:Mensagem") == null;
}
fn scrollBack(app: *App) void {
    if (app.st.activeChannel()) |id| app.st.scrollOf(id).stick_bottom = true;
}
fn popupClosed(app: *App) bool {
    return app.st.popup == .none;
}

/// Um canal comum, com as mensagens de bot da demonstração (o de emoji não tem).
fn tBotChannel(_: *App, b: []u8) []const u8 {
    return std.fmt.bufPrint(b, "channel:{d}", .{gw.channelId(0, 6)}) catch "";
}
fn historyLoaded(app: *App) bool {
    const id = app.st.activeChannel() orelse return false;
    const cs = app.store.channel(id) orelse return false;
    return id == gw.channelId(0, 6) and cs.history == .loaded;
}

pub const ops_bots = [_]Op{
    s("etiqueta de bot"),
    click("guild:500000"),
    .{ .click = .{ .dyn = tBotChannel } },
    expect("canal com bots aberto", historyLoaded),
    .{ .run = scrollBack },
    .{ .wait = 400 },
    expect("bot verificado na conversa: etiqueta com o ✓", botInMessages),
    expect("na lista de membros, dentro da linha", botInMemberList),
    expect("bot comum: etiqueta sem o ✓", plainBotNoCheck),
    expect("e quem não é bot, sem nada", humanNoTag),
    .{ .shot = "75-bots" },
    .{ .click = .{ .dyn = tBotMember } },
    expect("no cartão de perfil", profileWithTag),
    .{ .shot = "75a-perfil-bot" },
    key(c.ImGuiKey_Escape),
    expect("Esc fecha", popupClosed),
    .{ .run = jumpToWebhook },
    .{ .expect = .{ .name = "mensagem de webhook também leva a etiqueta", .check = webhookTagged, .timeout_ms = 4000 } },
    .{ .shot = "75b-webhook" },
    .{ .click = .{ .dyn = tWebhook } },
    expect("webhook não é conta: cartão sem pedir perfil", webhookCard),
    key(c.ImGuiKey_Escape),
    expect("Esc fecha", popupClosed),
    .{ .rclick = .{ .dyn = tWebhook } },
    expect("menu do webhook sem \"Mensagem\"", webhookMenu),
    key(c.ImGuiKey_Escape),
    .{ .run = scrollBack },
    click("guild:0"),
    .{ .wait = 200 },
    .{ .click = .{ .dyn = tBotDm } },
    expect("na DM com o bot: lista e painel de perfil", botDmTagged),
    .{ .shot = "75c-dm-bot" },
    click("guild:500000"),
};

// --- Banner e ícone grandes --------------------------------------------------------

/// O segundo servidor da demonstração tem banner e ícone.
fn tBannerGuild(_: *App, b: []u8) []const u8 {
    return std.fmt.bufPrint(b, "guild:{d}", .{gw.guildId(1)}) catch "";
}
fn bannerAreaShown(_: *App) bool {
    return qa.find("guild-banner") != null and qa.find("guild-banner-open") != null;
}
fn viewerOpen(app: *App) bool {
    return app.st.viewer != null and qa.find("viewer") != null;
}
/// Abriu o banner, em tamanho cheio (o da imagem, não o da faixa), sem abrir o menu.
fn bannerInViewer(app: *App) bool {
    const v = app.st.viewer orelse return false;
    return std.mem.eql(u8, v.url[0..v.url_len], "demo:2") and v.original and v.w == 720 and v.h == 720 and app.st.popup == .none;
}
fn viewerClosed(app: *App) bool {
    return app.st.viewer == null;
}
fn guildMenuNotViewer(app: *App) bool {
    return app.st.popup == .menu and app.st.popup.menu.kind == .guild and app.st.viewer == null;
}
fn iconInViewer(app: *App) bool {
    const v = app.st.viewer orelse return false;
    return std.mem.startsWith(u8, v.url[0..v.url_len], "demo:icon:") and v.original and app.st.popup == .none;
}
fn avatarInViewer(app: *App) bool {
    const v = app.st.viewer orelse return false;
    return std.mem.startsWith(u8, v.url[0..v.url_len], "demo:av:") and v.original;
}
fn profileBannerInViewer(app: *App) bool {
    const v = app.st.viewer orelse return false;
    return std.mem.eql(u8, v.url[0..v.url_len], "demo:1") and v.original;
}
fn fullProfile(app: *App) bool {
    return app.st.popup == .profile_full and app.st.viewer == null;
}
fn tAnaMember(_: *App, b: []u8) []const u8 {
    return std.fmt.bufPrint(b, "member:{d}", .{1001}) catch "";
}
fn profileOpen(app: *App) bool {
    return app.st.popup == .profile and qa.find("profile-banner") != null;
}
fn tDmAna(_: *App, b: []u8) []const u8 {
    return std.fmt.bufPrint(b, "channel:{d}", .{gw.dmId(0)}) catch "";
}
fn dmProfileAvatar(_: *App) bool {
    return qa.find("dm-profile-avatar") != null;
}
fn userMenu(app: *App) bool {
    return app.st.popup == .menu and app.st.popup.menu.kind == .user and qa.find("menu:Ver foto de perfil") != null;
}

pub const ops_viewer = [_]Op{
    s("banner e ícone grandes"),
    .{ .click = .{ .dyn = tBannerGuild } },
    .{ .expect = .{ .name = "o servidor mostra o banner, com a área de abrir", .check = bannerAreaShown, .timeout_ms = 3000 } },
    .{ .hover = .{ .mark = "guild-banner-open" } },
    .{ .wait = 200 },
    .{ .shot = "76-banner-hover" },
    click("guild-banner-open"),
    .{ .expect = .{ .name = "clicar no banner abre ele inteiro, sem o menu do servidor", .check = bannerInViewer, .timeout_ms = 3000 } },
    .{ .wait = 200 },
    .{ .shot = "76a-banner-grande" },
    key(c.ImGuiKey_Escape),
    expect("Esc fecha o visualizador", viewerClosed),
    .{ .wait = 250 },
    click("guild-header"),
    expect("clicar no nome continua abrindo o menu do servidor", guildMenuNotViewer),
    click("menu:Ver banner"),
    .{ .expect = .{ .name = "o menu do servidor abre o banner", .check = bannerInViewer, .timeout_ms = 3000 } },
    key(c.ImGuiKey_Escape),
    expect("Esc fecha", viewerClosed),
    .{ .wait = 250 },
    .{ .rclick = .{ .mark = "guild-header" } },
    click("menu:Ver ícone"),
    .{ .expect = .{ .name = "e o ícone do servidor", .check = iconInViewer, .timeout_ms = 3000 } },
    .{ .wait = 200 },
    .{ .shot = "76b-icone-grande" },
    key(c.ImGuiKey_Escape),
    expect("Esc fecha", viewerClosed),
    .{ .wait = 250 },
    .{ .click = .{ .dyn = tAnaMember } },
    .{ .expect = .{ .name = "cartão de quem tem banner", .check = profileOpen, .timeout_ms = 3000 } },
    click("profile-full"),
    expect("o botão do canto do banner abre o perfil grande, não o banner", fullProfile),
    key(c.ImGuiKey_Escape),
    .{ .wait = 250 },
    .{ .click = .{ .dyn = tAnaMember } },
    .{ .expect = .{ .name = "cartão de novo", .check = profileOpen, .timeout_ms = 3000 } },
    click("profile-banner"),
    .{ .expect = .{ .name = "o banner da pessoa abre inteiro", .check = profileBannerInViewer, .timeout_ms = 3000 } },
    key(c.ImGuiKey_Escape),
    .{ .wait = 250 },
    key(c.ImGuiKey_Escape),
    .{ .wait = 250 },
    .{ .rclick = .{ .dyn = tAnaMember } },
    expect("o menu de alguém com foto oferece abrir", userMenu),
    click("menu:Ver foto de perfil"),
    .{ .expect = .{ .name = "e abre a foto", .check = avatarInViewer, .timeout_ms = 3000 } },
    key(c.ImGuiKey_Escape),
    .{ .wait = 250 },
    click("guild:0"),
    .{ .wait = 200 },
    .{ .click = .{ .dyn = tDmAna } },
    expect("no painel de perfil da DM, a foto é clicável", dmProfileAvatar),
    click("dm-profile-avatar"),
    .{ .expect = .{ .name = "e abre grande", .check = avatarInViewer, .timeout_ms = 3000 } },
    key(c.ImGuiKey_Escape),
    .{ .wait = 250 },
    click("dm-profile-name"),
    expect("o nome abre o perfil completo", fullProfile),
    key(c.ImGuiKey_Escape),
    .{ .wait = 250 },
    click("guild:500000"),
};

// --- Ícones ---------------------------------------------------------------------------

pub const ops_icons = [_]Op{
    s("ícones das mensagens diretas"),
    click("guild:0"),
    .{ .wait = 200 },
    click("friends"),
    .{ .wait = 300 },
    .{ .shot = "77-icones-dms" },
    .{ .hover = .{ .mark = "friend:1001" } },
    .{ .wait = 150 },
    .{ .shot = "77a-icones-amigos" },
    click("guild:500000"),
};

/// Só com esta bateria sozinha: na geral, um `/shrug` já mostrou um ツ antes.
pub const ops_no_scripts = [_]Op{
    s("fontes de outras escritas"),
    expect("sem texto de outra escrita, nenhuma fonte reserva", scriptsNotLoaded),
};

pub const all = ops ++ ops_pages ++ ops_ui_size ++ ops_ime ++ ops_changelog ++ ops_bots ++ ops_viewer ++ ops_icons;
