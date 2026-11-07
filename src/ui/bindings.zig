//! Os atalhos do app: uma lista de ações, cada uma com a tecla que a pessoa
//! escolheu em Configurações → Atalhos de teclado. Cada atalho vive num campo
//! Text das configurações (`bind_<id>`): vazio é o padrão de sempre, "none"
//! é nenhum. root.zig chama captureTick (a captura da página consome a tecla)
//! e depois dispatch, antes dos atalhos fixos. Vale com a janela em foco:
//! o SDL não tem atalho global portátil.
const std = @import("std");
const c = @import("c");
const d = @import("draw.zig");
const qa = @import("qa.zig");
const anim = @import("anim.zig");
const i18n = @import("i18n.zig");
const keys = @import("bind_keys.zig");
const palette = @import("palette.zig");
const search = @import("search.zig");
const S = @import("settings_state.zig");

const Combo = keys.Combo;

/// Ids de `d.hit` desta página (longe dos sequenciais de settings.Page e das
/// outras páginas com base própria).
const bind_id: usize = 0x61000;
const reset_id: usize = 0x62000;

pub const Bind = struct {
    /// Nome estável: o campo `bind_<id>` nas configurações e a marca do QA.
    id: []const u8,
    pt: []const u8,
    en: []const u8,
    /// O atalho de sempre, no texto das configurações ("ctrl+shift+m").
    default: []const u8,
    get: *const fn (*const S.Settings) []const u8,
    put: *const fn (*S.Settings, []const u8) void,
    run: *const fn (ctx: *d.Ctx) void,
    /// Tema e abas: Shift apertado junto vira "voltar", então ele não
    /// precisa bater com o Shift gravado (a ação lê o Shift do teclado).
    variant: bool = false,
};

fn makeGet(comptime field: []const u8) *const fn (*const S.Settings) []const u8 {
    return struct {
        fn get(s: *const S.Settings) []const u8 {
            return @field(s, field).slice();
        }
    }.get;
}

fn makePut(comptime field: []const u8) *const fn (*S.Settings, []const u8) void {
    return struct {
        fn put(s: *S.Settings, v: []const u8) void {
            @field(s, field).set(v);
        }
    }.put;
}

// --- As ações ---------------------------------------------------------------

fn runMute(ctx: *d.Ctx) void {
    ctx.act(.toggle_mute);
}

fn runDeafen(ctx: *d.Ctx) void {
    ctx.act(.toggle_deafen);
}

fn runPalette(ctx: *d.Ctx) void {
    palette.commands_first = false;
    if (ctx.st.palette.open) ctx.act(.close_palette) else ctx.act(.open_palette);
}

fn runSearch(ctx: *d.Ctx) void {
    if (!ctx.st.settings.open) search.toggle();
}

fn runSettings(ctx: *d.Ctx) void {
    ctx.act(if (ctx.st.settings.open) .close_settings else .open_settings);
}

fn runFullscreen(ctx: *d.Ctx) void {
    ctx.act(.toggle_fullscreen);
}

fn runTheme(ctx: *d.Ctx) void {
    ctx.act(.{ .next_theme = if (ctx.io.*.KeyShift) -1 else 1 });
}

fn runInbox(ctx: *d.Ctx) void {
    if (!ctx.st.settings.open) ctx.act(.toggle_inbox);
}

fn runSaved(ctx: *d.Ctx) void {
    if (!ctx.st.settings.open) ctx.act(.toggle_saved);
}

fn runNextTab(ctx: *d.Ctx) void {
    ctx.act(.{ .next_tab = if (ctx.io.*.KeyShift) -1 else 1 });
}

fn runCloseTab(ctx: *d.Ctx) void {
    ctx.act(.{ .close_tab = ctx.st.tab });
}

/// Na ordem da página: voz primeiro, depois o resto.
pub const list = [_]Bind{
    .{ .id = "mute", .pt = "Mutar / desmutar o microfone", .en = "Mute / unmute the microphone", .default = "ctrl+shift+m", .get = makeGet("bind_mute"), .put = makePut("bind_mute"), .run = &runMute },
    .{ .id = "deafen", .pt = "Ensurdecer / voltar a ouvir", .en = "Deafen / undeafen", .default = "ctrl+shift+d", .get = makeGet("bind_deafen"), .put = makePut("bind_deafen"), .run = &runDeafen },
    .{ .id = "palette", .pt = "Paleta de comandos", .en = "Command palette", .default = "ctrl+k", .get = makeGet("bind_palette"), .put = makePut("bind_palette"), .run = &runPalette },
    .{ .id = "search", .pt = "Buscar mensagens", .en = "Search messages", .default = "ctrl+f", .get = makeGet("bind_search"), .put = makePut("bind_search"), .run = &runSearch },
    .{ .id = "settings", .pt = "Configurações", .en = "Settings", .default = "ctrl+,", .get = makeGet("bind_settings"), .put = makePut("bind_settings"), .run = &runSettings },
    .{ .id = "fullscreen", .pt = "Tela cheia", .en = "Fullscreen", .default = "f11", .get = makeGet("bind_fullscreen"), .put = makePut("bind_fullscreen"), .run = &runFullscreen },
    .{ .id = "theme", .pt = "Próximo tema (Shift volta)", .en = "Next theme (Shift goes back)", .default = "f2", .get = makeGet("bind_theme"), .put = makePut("bind_theme"), .run = &runTheme, .variant = true },
    .{ .id = "inbox", .pt = "Caixa de entrada", .en = "Inbox", .default = "ctrl+i", .get = makeGet("bind_inbox"), .put = makePut("bind_inbox"), .run = &runInbox },
    .{ .id = "saved", .pt = "Mensagens salvas", .en = "Saved messages", .default = "ctrl+shift+s", .get = makeGet("bind_saved"), .put = makePut("bind_saved"), .run = &runSaved },
    .{ .id = "next_tab", .pt = "Próxima aba (Shift volta)", .en = "Next tab (Shift goes back)", .default = "ctrl+tab", .get = makeGet("bind_next_tab"), .put = makePut("bind_next_tab"), .run = &runNextTab, .variant = true },
    .{ .id = "close_tab", .pt = "Fechar a aba", .en = "Close the tab", .default = "ctrl+w", .get = makeGet("bind_close_tab"), .put = makePut("bind_close_tab"), .run = &runCloseTab },
};

/// A combinação atual de um atalho: o campo das configurações, ou o padrão
/// dele. null = desligado ("none", texto que não se entende ou padrão vazio).
pub fn resolve(b: *const Bind, s: *const S.Settings) ?Combo {
    const spec = b.get(s);
    const chosen = if (spec.len == 0) b.default else spec;
    if (std.mem.eql(u8, chosen, "none")) return null;
    const k = keys.parse(chosen) orelse return null;
    if (!keys.valid(k)) return null;
    return k;
}

/// A tecla vale com a janela em foco. Tudo que a captura aceita tem Ctrl, Alt
/// ou Super, ou é F1–F24: nada aqui digita uma letra por cima da caixa de texto.
pub fn dispatch(ctx: *d.Ctx) void {
    if (capturing != null) return;
    const io = ctx.io;
    const s = &ctx.st.settings;
    for (&list) |*b| {
        const k = resolve(b, s) orelse continue;
        if (io.*.KeyCtrl != k.ctrl or io.*.KeyAlt != k.alt or io.*.KeySuper != k.super) continue;
        if (!b.variant and io.*.KeyShift != k.shift) continue;
        if (!c.ImGui_IsKeyPressedEx(k.key, false)) continue;
        b.run(ctx);
    }
}

// --- Captura ----------------------------------------------------------------

/// O atalho que está esperando uma tecla (índice em `list`).
var capturing: ?usize = null;

pub fn capturingNow() bool {
    return capturing != null;
}

/// Chamado por root.zig a cada quadro, antes de qualquer atalho: a tecla
/// apertada vira o atalho novo e não vaza para o resto. Esc cancela.
pub fn captureTick(ctx: *d.Ctx) void {
    const i = capturing orelse return;
    // Saiu da página de atalhos (ou fechou as configurações): a captura para.
    if (!ctx.st.settings.open or ctx.st.settings.page != .atalhos) {
        capturing = null;
        return;
    }
    const io = ctx.io;
    if (c.ImGui_IsKeyPressed(c.ImGuiKey_Escape)) {
        capturing = null;
        return;
    }
    for (keys.captureCandidates()) |code| {
        if (!c.ImGui_IsKeyPressedEx(code, false)) continue;
        const k = Combo{ .key = code, .ctrl = io.*.KeyCtrl, .shift = io.*.KeyShift, .alt = io.*.KeyAlt, .super = io.*.KeySuper };
        if (!keys.valid(k)) continue;
        setBind(ctx, i, k);
        capturing = null;
        return;
    }
}

/// Grava a combinação e tira ela de outro atalho que já a usava.
fn setBind(ctx: *d.Ctx, i: usize, k: Combo) void {
    const s = &ctx.st.settings;
    var sb: [48]u8 = undefined;
    const spec = keys.serialize(k, &sb);
    for (&list, 0..) |*other, j| {
        if (j == i) continue;
        const used = resolve(other, s) orelse continue;
        if (Combo.same(used, k)) other.put(s, "none");
    }
    list[i].put(s, spec);
    ctx.act(.save_settings);
}

/// Tudo volta ao padrão (botão da página de atalhos).
pub fn resetDefaults(ctx: *d.Ctx) void {
    const s = &ctx.st.settings;
    for (&list) |*b| b.put(s, "");
    ctx.act(.save_settings);
    ctx.st.showToast(ctx.now_ms, false, "atalhos de volta aos padrões ✓", "binds back to defaults ✓", .{});
}

// --- Página de configurações ------------------------------------------------

/// As linhas de Configurações → Atalhos: a ação à esquerda, a tecla numa
/// caixa clicável à direita; clicar começa a captura, o × volta ao padrão.
pub fn pageRows(p: anytype) void {
    const ctx = p.ctx;
    const s = &ctx.st.settings;
    p.y += 2;
    for (&list, 0..) |*b, i| {
        const row: d.Rect = .{ .x = p.x, .y = p.y, .w = p.w, .h = 38 };
        p.y += 46;
        const cap_w: f32 = 200;
        const cap: d.Rect = .{ .x = row.right() - cap_w, .y = row.y + 2, .w = cap_w, .h = 34 };
        const waiting = capturing != null and capturing.? == i;
        const spec = b.get(s);
        if (spec.len > 0) {
            const xr: d.Rect = .{ .x = cap.x - 34, .y = row.y + 4, .w = 30, .h = 30 };
            const xh = d.hit(ctx, reset_id + i, xr);
            qa.mark(xr, "bind-reset:{s}", .{b.id});
            if (xh.clicked) {
                b.put(s, "");
                ctx.act(.save_settings);
            }
            d.text(p.dl, p.font(.regular), 16, xr.x + 11, d.centerY(xr, 16), if (xh.hovered) ctx.col(.danger) else ctx.col(.faint), "×");
        }
        const hb = d.hit(ctx, bind_id + i, cap);
        qa.mark(cap, "bind:{s}", .{b.id});
        if (hb.clicked) capturing = if (waiting) null else i;
        d.rect(p.dl, cap, ctx.col(.rail).mix(ctx.col(.elevated), if (hb.hovered) 0.4 else 0.2), ctx.th.radius);
        d.border(p.dl, cap, if (waiting) ctx.col(.accent) else if (hb.hovered) ctx.col(.accent).alpha(0.6) else ctx.col(.border), ctx.th.radius, if (waiting) 2 else 1);
        var fb: [48]u8 = undefined;
        var nb: [96]u8 = undefined;
        const off = i18n.tr("nenhum — clique para escolher", "none — click to set");
        const shown = blk: {
            if (waiting) break :blk i18n.tr("Aperte uma tecla… (Esc cancela)", "Press a key… (Esc cancels)");
            const k = resolve(b, s) orelse break :blk off;
            break :blk i18n.fmt(&nb, "{s} · clique para trocar", "{s} · click to change", .{keys.format(k, &fb)});
        };
        const bound = resolve(b, s) != null;
        d.text(p.dl, p.font(if (waiting or !bound) .regular else .semibold), 14, cap.x + 12, d.centerY(cap, 14), if (waiting) ctx.col(.accent) else if (bound) ctx.col(.text) else ctx.col(.muted), shown);
        _ = d.textClipped(p.dl, p.font(.medium), 15, row.x, row.y + 9, ctx.col(.text), i18n.tr(b.pt, b.en), row.w - cap_w - 70);
        // Parado esperando tecla acorda os quadros (a captura é por quadro).
        if (waiting) anim.every(50);
    }
    p.y += 4;
    p.note(i18n.tr(
        "Vale com a janela do SigmaCord em foco. A regra é a dos plugins: letras e números precisam de Ctrl, Alt ou Super; F1–F24 podem ir sozinhas.",
        "Binds work while the SigmaCord window is focused. Same rule as plugins: letters and digits need Ctrl, Alt or Super; F1–F24 can go alone.",
    ));
}
