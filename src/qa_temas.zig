//! QA das primitivas novas dos temas (entra na bateria por tema do qa_runner.zig):
//! textura gerada uma vez, tema parado que não pede quadros, movimento lento que
//! obedece a "reduzir movimento" e as marcas de cada tema que usa alguma coisa.
const std = @import("std");
const c = @import("c");
const App = @import("app.zig").App;
const R = @import("qa_runner.zig");
const Op = R.Op;
const qa = @import("ui/qa.zig");
const fx = @import("ui/fx.zig");
const anim = @import("ui/anim.zig");
const extra = @import("ui/comp_extra.zig");

fn expect(name: []const u8, f: *const fn (*App) bool) Op {
    return .{ .expect = .{ .name = name, .check = f } };
}

var generated0: u32 = 0;
var wakes0: u32 = 0;

fn remember(_: *App) void {
    generated0 = fx.generated;
    wakes0 = fx.motion_wakes;
}

fn noNewTexture(_: *App) bool {
    return fx.generated == generated0;
}

fn noMotionWake(_: *App) bool {
    return fx.motion_wakes == wakes0;
}

/// Ao redimensionar, refaz só o que depende do tamanho: uma vez, não por quadro.
fn fewNewTextures(_: *App) bool {
    return fx.generated -% generated0 <= 4;
}

fn themeIs(app: *App, name: []const u8) bool {
    return std.mem.eql(u8, app.themes.name(), name);
}

/// Os prints deste tema usam mesmo as primitivas (se ele for um dos que usam).
fn themeMarks(app: *App) bool {
    if (themeIs(app, "orbital")) {
        const word = qa.find("display:ORBITAL") orelse return false;
        // Tracking de verdade: 7 letras mono de 15 px mais 6 × 8 de espaço.
        if (word.w < 95) return false;
        const run = qa.find("display:01") orelse return false;
        if (run.w < 60) return false; // "01" grande + "CANAIS" espaçado na mesma linha
        return qa.find("backdrop:starfield") != null and qa.find("backdrop:orbit") != null and
            qa.find("shape:arc") != null and qa.find("rule:dashed") != null and fx.live_entries > 0;
    }
    if (themeIs(app, "editorial")) {
        return qa.find("display:SigmaCord") != null and qa.find("rule:oxford") != null and
            qa.find("rule:double") != null and fx.live_entries > 0;
    }
    if (themeIs(app, "cupertino")) {
        return qa.find("backdrop:dunes") != null and qa.find("winctl:close") != null and
            qa.find("winctl:minimize") != null and qa.find("winctl:zoom") != null;
    }
    if (themeIs(app, "vidro")) return qa.find("backdrop:aurora") != null and fx.live_entries > 0;
    return true;
}

fn setMotion(app: *App, on: bool) void {
    if (!themeIs(app, "orbital")) return;
    if (app.themes.setOption("movimento", on)) {}
}

fn motionOn(app: *App) void {
    setMotion(app, true);
    wakes0 = fx.motion_wakes;
}

fn motionOff(app: *App) void {
    setMotion(app, false);
    wakes0 = fx.motion_wakes;
}

/// Pediu quadro, e não mais que 15 por segundo.
fn motionWakes(app: *App) bool {
    if (!themeIs(app, "orbital")) return true;
    if (fx.motion_wakes == wakes0) return false;
    return anim.next_wake_ms - anim.now_ms <= 100 and fx.last_period_ms >= 66;
}

fn reduceOn(app: *App) void {
    app.st.settings.reduce_motion = true;
}

fn reduceOff(app: *App) void {
    app.st.settings.reduce_motion = false;
}

fn reducedStill(app: *App) bool {
    _ = app;
    return fx.motion_wakes == wakes0;
}

fn rememberWakes(_: *App) void {
    wakes0 = fx.motion_wakes;
}

/// `hover-bg` do painel do orbital acende com o mouse em cima.
fn hoverLit(app: *App) bool {
    return !themeIs(app, "orbital") or fx.hover_seen > 0.9;
}

// Os botões da janela: fechar conta (no QA não sai de verdade), maximizar pede
// ao sistema e não pode quebrar a tela. Outros temas não têm a marca: o robô pula.
var closes0: u32 = 0;

fn rememberCloses(_: *App) void {
    closes0 = extra.qa_close_requests;
}

fn tWinClose(app: *App, b: []u8) []const u8 {
    if (!themeIs(app, "cupertino")) return "";
    return std.fmt.bufPrint(b, "winctl:close", .{}) catch "";
}

fn tWinZoom(app: *App, b: []u8) []const u8 {
    if (!themeIs(app, "cupertino")) return "";
    return std.fmt.bufPrint(b, "winctl:zoom", .{}) catch "";
}

fn closeRequested(app: *App) bool {
    return !themeIs(app, "cupertino") or extra.qa_close_requests == closes0 + 1;
}

fn stillUsable(app: *App) bool {
    return app.store.ready and qa.find("composer") != null;
}

pub const ops_window = [_]Op{
    .{ .run = rememberCloses },
    .{ .click = .{ .dyn = tWinClose } },
    expect("o botão de fechar pede para sair", closeRequested),
    .{ .click = .{ .dyn = tWinZoom } },
    .{ .wait = 150 },
    expect("maximizar não quebra a tela", stillUsable),
    .{ .click = .{ .dyn = tWinZoom } },
    .{ .wait = 150 },
    expect("restaurar não quebra a tela", stillUsable),
};

fn settingsInReach(_: *App) bool {
    return qa.find("user-btn:2") != null or qa.find("header-settings") != null;
}

pub const ops_static = [_]Op{
    expect("primitivas do tema estão na tela", themeMarks),
    expect("o botão de configurações está à vista", settingsInReach),
    .{ .hover = .{ .mark = "composer" } },
    .{ .wait = 400 },
    expect("fundo no hover acende", hoverLit),
    .{ .run = remember },
    .{ .wait = 250 },
    expect("textura gerada uma vez, não por quadro", noNewTexture),
    expect("tema parado não pede quadros", noMotionWake),
};

pub const ops_motion = [_]Op{
    .{ .run = motionOn },
    .{ .wait = 120 },
    expect("fundo em movimento pede no máximo 15 quadros/s", motionWakes),
    .{ .run = reduceOn },
    .{ .wait = 50 },
    .{ .run = rememberWakes },
    .{ .wait = 150 },
    expect("\"reduzir movimento\" para o fundo", reducedStill),
    .{ .run = reduceOff },
    .{ .run = motionOff },
    .{ .wait = 50 },
    .{ .run = remember },
    .{ .wait = 120 },
    expect("desligou o movimento: parado de novo", noMotionWake),
};

pub const ops_resize_before = [_]Op{.{ .run = remember }};
pub const ops_resize_after = [_]Op{expect("redimensionar refaz só o que depende do tamanho", fewNewTextures)};
