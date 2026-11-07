//! QA das listas flutuantes (ui/dropdown.zig), do fechar para a bandeja e do
//! pedido de reinício. Aqui a bandeja é de mentira (`tray.fake`): o ícone de
//! verdade, o menu e o segundo SigmaCord quem testa é tools/qa_bandeja.py, com
//! processos reais e um painel falso no D-Bus.
//!
//! `QA_SUITE=bandeja` roda isto. As baterias `bandeja-*` terminam com o app
//! saindo no meio do roteiro: quem confere o código de saída e o tempo é
//! tools/qa_bandeja.sh.
const std = @import("std");
const c = @import("c");
const App = @import("app.zig").App;
const R = @import("qa_runner.zig");
const Op = R.Op;
const qa = @import("ui/qa.zig");
const tray = @import("platform/tray.zig");
const platform = @import("platform/window.zig");
const settings_voz = @import("ui/settings_voz.zig");
const voz_audio = @import("net/voz_audio.zig");
const Rect = @import("theme/layout.zig").Rect;

fn s(name: []const u8) Op {
    return .{ .section = name };
}
fn click(k: []const u8) Op {
    return .{ .click = .{ .mark = k } };
}
fn expect(name: []const u8, f: *const fn (*App) bool) Op {
    return .{ .expect = .{ .name = name, .check = f } };
}
fn run(f: *const fn (*App) void) Op {
    return .{ .run = f };
}
fn shot(name: []const u8) Op {
    return .{ .shot = name };
}
const esc: Op = .{ .key = .{ .key = c.ImGuiKey_Escape } };

// --- Listas flutuantes -------------------------------------------------------

var page_y: f32 = 0;
var sens_before: u8 = 0;

fn openVoz(app: *App) void {
    app.st.settings.open = true;
    app.st.settings.page = .voz;
}
fn vozPage(_: *App) bool {
    return qa.find("voz-mic") != null and qa.find("voz-vol:10") != null;
}
fn rememberPage(app: *App) void {
    page_y = (qa.find("voz-vol:10") orelse return).y;
    sens_before = app.st.settings.voice_sens;
}
fn micListOpen(_: *App) bool {
    return qa.find("dropdown") != null and qa.find("voz-mic-opt:0") != null;
}
fn outListOpen(_: *App) bool {
    return qa.find("dropdown") != null and qa.find("voz-out-opt:0") != null;
}
fn pageNotPushed(_: *App) bool {
    const vol = qa.find("voz-vol:10") orelse return false;
    return vol.y == page_y and qa.find("dropdown") != null;
}
fn listClosedSettingsOpen(app: *App) bool {
    return qa.find("dropdown") == null and app.st.settings.open;
}
fn clickDidNotPassThrough(app: *App) bool {
    return qa.find("dropdown") == null and app.st.settings.voice_sens == sens_before;
}
fn manyDevices(_: *App) void {
    settings_voz.qaManyDevices(16);
}
fn restoreDevices(app: *App) void {
    settings_voz.qaManyDevices(0);
    app.st.settings.voice_mic = .{};
}

/// A lista toda dentro da janela, com o resto rolando por dentro.
fn listCapped(app: *App) bool {
    const list = qa.find("dropdown") orelse return false;
    const last = qa.find("voz-mic-opt:16") orelse return false;
    return list.bottom() <= app.io.*.DisplaySize.y and list.y >= 0 and list.h >= 60 and last.y > list.bottom();
}
fn listCoversPage(_: *App) bool {
    const list = qa.find("dropdown") orelse return false;
    const vol = qa.find("voz-vol:10") orelse return false;
    return list.contains(vol.x + 8, vol.y + 8) and vol.y == page_y;
}

var last_opt_y: f32 = 0;
fn wheelDown(app: *App) void {
    const list = qa.find("dropdown") orelse return;
    last_opt_y = (qa.find("voz-mic-opt:16") orelse return).y;
    c.ImGuiIO_AddMousePosEvent(app.io, list.x + 30, list.y + 30);
    c.ImGuiIO_AddMouseWheelEvent(app.io, 0, -3);
}
fn listScrolled(_: *App) bool {
    const y = (qa.find("voz-mic-opt:16") orelse return false).y;
    return y < last_opt_y and pageStill();
}
fn pageStill() bool {
    const vol = qa.find("voz-vol:10") orelse return false;
    return vol.y == page_y;
}
fn listFlipped(_: *App) bool {
    const list = qa.find("dropdown") orelse return false;
    const box = qa.find("voz-mic") orelse return false;
    return list.bottom() <= box.y and list.y >= 0;
}
fn picked(app: *App) bool {
    return qa.find("dropdown") == null and std.mem.eql(u8, app.st.settings.voice_mic.slice(), "Microfone de teste 1");
}

var color_y: f32 = 0;
fn openLooks(app: *App) void {
    app.st.settings.open = true;
    app.st.settings.page = .aparencia;
}
fn rememberColors(_: *App) void {
    color_y = (qa.find("theme-color:12") orelse return).y;
}
fn colorEditorOpen(_: *App) bool {
    return qa.find("dropdown") != null and qa.find("theme-color-input") != null and qa.find("button:Aplicar") != null;
}
fn colorGridStill(_: *App) bool {
    const cell = qa.find("theme-color:12") orelse return false;
    return cell.y == color_y;
}
fn colorEditorClosed(app: *App) bool {
    return qa.find("dropdown") == null and qa.find("theme-color-input") == null and app.st.settings.open;
}
fn closeSettings(app: *App) void {
    app.st.settings.open = false;
}

// O perfil de quem pode dar cargos: na demonstração, só virando dono do servidor.
const demo_guild: u64 = 500000;
var owner_before: u64 = 0;
var role_y: f32 = 0;
fn becomeOwner(app: *App) void {
    const g = @constCast(app.store.guild(demo_guild) orelse return);
    owner_before = g.owner;
    g.owner = app.store.me;
}
fn stopBeingOwner(app: *App) void {
    const g = @constCast(app.store.guild(demo_guild) orelse return);
    g.owner = owner_before;
    app.st.popup = .none;
}
fn cardOpen(_: *App) bool {
    return qa.find("role-add") != null;
}
fn rememberRoleButton(_: *App) void {
    role_y = (qa.find("role-add") orelse return).y;
}
fn roleListOpen(_: *App) bool {
    const add = qa.find("role-add") orelse return false;
    return qa.find("dropdown") != null and add.y == role_y;
}
fn roleListClosedCardOpen(app: *App) bool {
    return qa.find("dropdown") == null and app.st.popup != .none;
}

// --- Bandeja -----------------------------------------------------------------

fn pushClose(app: *App) void {
    var e = std.mem.zeroes(c.SDL_Event);
    e.type = c.SDL_EVENT_WINDOW_CLOSE_REQUESTED;
    e.window.windowID = c.SDL_GetWindowID(app.win.window);
    _ = c.SDL_PushEvent(&e);
}
fn trayOk(_: *App) void {
    // QA_TRAY_REAL: o SDL_CreateTray de verdade (com um painel falso no D-Bus).
    tray.fake = if (c.SDL_getenv("QA_TRAY_REAL") != null) null else true;
}
fn trayFails(_: *App) void {
    tray.fake = false;
}
fn wakeShow(app: *App) void {
    platform.Window.wake(app.win.wake_type, .show);
}
fn wakeQuit(app: *App) void {
    platform.Window.wake(app.win.wake_type, .quit);
}
fn hiddenFlag(app: *App) bool {
    return c.SDL_GetWindowFlags(app.win.window) & c.SDL_WINDOW_HIDDEN != 0;
}
pub fn isHidden(app: *App) bool {
    return hiddenFlag(app) and tray.active();
}
fn isShown(app: *App) bool {
    return !hiddenFlag(app) and !tray.active();
}
/// A rede continua sendo atendida com a janela escondida.
fn keepsWorking(app: *App) bool {
    return hiddenFlag(app) and app.store.ready;
}
fn optionOnByDefault(app: *App) bool {
    return app.st.settings.close_to_tray;
}
fn openAdvanced(app: *App) void {
    app.st.settings.open = true;
    app.st.settings.page = .avancado;
}
fn optionOff(app: *App) bool {
    return !app.st.settings.close_to_tray;
}
fn optionShown(_: *App) bool {
    return qa.find("toggle:Fechar para a bandeja") != null;
}
/// Opção desligada: a janela nem chega a esconder. Sem sair daqui, porque esta
/// bateria continua; o sair de verdade é da bateria `bandeja-sair`.
fn neverHere(_: *App) bool {
    return false;
}
fn inVoice(app: *App) bool {
    return app.st.voice != null;
}
fn demand(app: *App) void {
    app.restart_wanted = true;
}

pub const ops = [_]Op{
    s("listas flutuantes: dispositivos de voz"),
    run(openVoz),
    expect("página de voz aberta", vozPage),
    // A página entra com um leve zoom, e o robô rola até o que vai clicar (na
    // bateria geral ela pode estar rolada): mede depois de assentar e de rolar.
    .{ .wait = 500 },
    click("voz-mic"),
    esc,
    .{ .wait = 200 },
    run(rememberPage),
    click("voz-mic"),
    expect("o microfone abre a lista", micListOpen),
    expect("a lista não empurra a página", pageNotPushed),
    shot("dropdown-voz"),
    esc,
    expect("Esc fecha a lista e não as configurações", listClosedSettingsOpen),
    click("voz-out"),
    expect("a saída abre a lista", outListOpen),
    click("voz-sens"),
    expect("clicar fora fecha sem clicar no que está embaixo", clickDidNotPassThrough),

    s("listas flutuantes: perto da borda"),
    run(manyDevices),
    click("voz-mic"),
    expect("muitos dispositivos: a altura fica limitada e cabe na janela", listCapped),
    expect("a lista fica por cima da página", listCoversPage),
    shot("dropdown-rola"),
    run(wheelDown),
    expect("a rodinha rola a lista e a página fica parada", listScrolled),
    esc,
    expect("Esc fecha a lista rolada", listClosedSettingsOpen),
    .{ .resize = .{ 900, 260 } },
    // Em máquina sem GPU a janela nova só aparece alguns quadros depois.
    .{ .wait = 800 },
    click("voz-mic"),
    expect("sem espaço embaixo, abre para cima", listFlipped),
    shot("dropdown-cima"),
    click("voz-mic-opt:1"),
    expect("escolher guarda o nome e fecha", picked),
    run(restoreDevices),
    .{ .resize = .{ 1280, 800 } },

    s("listas flutuantes: cor do tema"),
    run(openLooks),
    .{ .resize = .{ 1280, 2400 } },
    .{ .wait = 500 },
    run(rememberColors),
    click("theme-color:2"),
    expect("clicar numa cor abre o editor", colorEditorOpen),
    expect("e a grade de cores fica onde estava", colorGridStill),
    shot("dropdown-cor"),
    esc,
    expect("Esc fecha o editor", colorEditorClosed),
    .{ .resize = .{ 1280, 800 } },
    run(closeSettings),

    s("listas flutuantes: dar cargo"),
    run(becomeOwner),
    click("guild:500000"),
    click("member:1002"),
    .{ .expect = .{ .name = "o cartão tem o botão de dar cargo", .check = cardOpen, .timeout_ms = 3000 } },
    .{ .wait = 300 },
    run(rememberRoleButton),
    click("role-add"),
    expect("os cargos abrem por cima, sem mudar o cartão", roleListOpen),
    shot("dropdown-cargo"),
    esc,
    expect("Esc fecha a lista e não o cartão", roleListClosedCardOpen),
    run(stopBeingOwner),

    s("fechar para a bandeja"),
    expect("ligado por padrão", optionOnByDefault),
    run(openAdvanced),
    expect("a opção está em Avançado", optionShown),
    click("toggle:Fechar para a bandeja"),
    expect("o interruptor desliga a opção", optionOff),
    click("toggle:Fechar para a bandeja"),
    expect("e liga de novo", optionOnByDefault),
    run(closeSettings),
    run(trayOk),
    run(pushClose),
    expect("fechar esconde a janela e mostra o ícone", isHidden),
    .{ .wait = 300 },
    expect("escondida, continua de pé e conectada", keepsWorking),
    run(wakeShow),
    expect("Abrir volta a janela e tira o ícone", isShown),
    run(trayFails),
};

// As baterias abaixo terminam com o app saindo: `never` só é alcançado se ele
// não saiu, e aí vira falha.
const never: Op = .{ .expect = .{ .name = "o app devia ter saído antes daqui", .check = neverHere, .timeout_ms = 500 } };

/// Sem bandeja: fechar sai de verdade, com a voz ligada.
pub const ops_no_tray = [_]Op{
    click("channel:500014"),
    .{ .expect = .{ .name = "na call", .check = inVoice, .timeout_ms = 4000 } },
    run(trayFails),
    run(pushClose),
    .{ .wait = 4000 },
    never,
};

/// Sair pelo menu da bandeja, com a janela escondida e a voz ligada.
pub const ops_quit = [_]Op{
    click("channel:500014"),
    .{ .expect = .{ .name = "na call", .check = inVoice, .timeout_ms = 4000 } },
    run(trayOk),
    run(pushClose),
    expect("escondida", isHidden),
    run(wakeQuit),
    .{ .wait = 4000 },
    never,
};

/// Pedido de reinício com a bandeja disponível: para o laço sem esconder.
pub const ops_restart = [_]Op{
    run(trayOk),
    run(demand),
    .{ .wait = 4000 },
    never,
};
