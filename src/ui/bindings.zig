//! Os atalhos do app: uma lista de ações, cada uma com a tecla que a pessoa
//! escolheu em Configurações → Atalhos de teclado. Cada atalho vive num campo
//! Text das configurações (`bind_<id>`): vazio é o padrão de sempre, "none"
//! é nenhum; cada um liga e desliga no próprio campo `bind_on_<id>`, e todos
//! juntos podem valer fora da janela (`bind_global`, platform/hotkeys.zig).
//! root.zig chama captureTick (a captura da página consome a tecla), drain
//! (as teclas globais) e dispatch, antes dos atalhos fixos.
const std = @import("std");
const c = @import("c");
const d = @import("draw.zig");
const qa = @import("qa.zig");
const anim = @import("anim.zig");
const i18n = @import("i18n.zig");
const keys = @import("bind_keys.zig");
const hotkeys = @import("../platform/hotkeys.zig");
const palette = @import("palette.zig");
const search = @import("search.zig");
const S = @import("settings_state.zig");

const Combo = keys.Combo;

/// Ids de `d.hit` desta página (longe dos sequenciais de settings.Page e das
/// outras páginas com base própria).
const bind_id: usize = 0x61000;
const reset_id: usize = 0x62000;
const enable_id: usize = 0x63000;

pub const Bind = struct {
    /// Nome estável: o campo `bind_<id>` nas configurações e a marca do QA.
    id: []const u8,
    pt: []const u8,
    en: []const u8,
    /// O atalho de sempre, no texto das configurações ("ctrl+shift+m").
    default: []const u8,
    get: *const fn (*const S.Settings) []const u8,
    put: *const fn (*S.Settings, []const u8) void,
    /// Ligado ou desligado: desligado, a tecla não faz nada.
    on_get: *const fn (*const S.Settings) bool,
    on_put: *const fn (*S.Settings, bool) void,
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

fn makeGetOn(comptime field: []const u8) *const fn (*const S.Settings) bool {
    return struct {
        fn get(s: *const S.Settings) bool {
            return @field(s, field);
        }
    }.get;
}

fn makePutOn(comptime field: []const u8) *const fn (*S.Settings, bool) void {
    return struct {
        fn put(s: *S.Settings, v: bool) void {
            @field(s, field) = v;
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
    .{ .id = "mute", .pt = "Mutar / desmutar o microfone", .en = "Mute / unmute the microphone", .default = "ctrl+shift+m", .get = makeGet("bind_mute"), .put = makePut("bind_mute"), .on_get = makeGetOn("bind_on_mute"), .on_put = makePutOn("bind_on_mute"), .run = &runMute },
    .{ .id = "deafen", .pt = "Ensurdecer / voltar a ouvir", .en = "Deafen / undeafen", .default = "ctrl+shift+d", .get = makeGet("bind_deafen"), .put = makePut("bind_deafen"), .on_get = makeGetOn("bind_on_deafen"), .on_put = makePutOn("bind_on_deafen"), .run = &runDeafen },
    .{ .id = "palette", .pt = "Paleta de comandos", .en = "Command palette", .default = "ctrl+k", .get = makeGet("bind_palette"), .put = makePut("bind_palette"), .on_get = makeGetOn("bind_on_palette"), .on_put = makePutOn("bind_on_palette"), .run = &runPalette },
    .{ .id = "search", .pt = "Buscar mensagens", .en = "Search messages", .default = "ctrl+f", .get = makeGet("bind_search"), .put = makePut("bind_search"), .on_get = makeGetOn("bind_on_search"), .on_put = makePutOn("bind_on_search"), .run = &runSearch },
    .{ .id = "settings", .pt = "Configurações", .en = "Settings", .default = "ctrl+,", .get = makeGet("bind_settings"), .put = makePut("bind_settings"), .on_get = makeGetOn("bind_on_settings"), .on_put = makePutOn("bind_on_settings"), .run = &runSettings },
    .{ .id = "fullscreen", .pt = "Tela cheia", .en = "Fullscreen", .default = "f11", .get = makeGet("bind_fullscreen"), .put = makePut("bind_fullscreen"), .on_get = makeGetOn("bind_on_fullscreen"), .on_put = makePutOn("bind_on_fullscreen"), .run = &runFullscreen },
    .{ .id = "theme", .pt = "Próximo tema (Shift volta)", .en = "Next theme (Shift goes back)", .default = "f2", .get = makeGet("bind_theme"), .put = makePut("bind_theme"), .on_get = makeGetOn("bind_on_theme"), .on_put = makePutOn("bind_on_theme"), .run = &runTheme, .variant = true },
    .{ .id = "inbox", .pt = "Caixa de entrada", .en = "Inbox", .default = "ctrl+i", .get = makeGet("bind_inbox"), .put = makePut("bind_inbox"), .on_get = makeGetOn("bind_on_inbox"), .on_put = makePutOn("bind_on_inbox"), .run = &runInbox },
    .{ .id = "saved", .pt = "Mensagens salvas", .en = "Saved messages", .default = "ctrl+shift+s", .get = makeGet("bind_saved"), .put = makePut("bind_saved"), .on_get = makeGetOn("bind_on_saved"), .on_put = makePutOn("bind_on_saved"), .run = &runSaved },
    .{ .id = "next_tab", .pt = "Próxima aba (Shift volta)", .en = "Next tab (Shift goes back)", .default = "ctrl+tab", .get = makeGet("bind_next_tab"), .put = makePut("bind_next_tab"), .on_get = makeGetOn("bind_on_next_tab"), .on_put = makePutOn("bind_on_next_tab"), .run = &runNextTab, .variant = true },
    .{ .id = "close_tab", .pt = "Fechar a aba", .en = "Close the tab", .default = "ctrl+w", .get = makeGet("bind_close_tab"), .put = makePut("bind_close_tab"), .on_get = makeGetOn("bind_on_close_tab"), .on_put = makePutOn("bind_on_close_tab"), .run = &runCloseTab },
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
        if (!b.on_get(s)) continue;
        const k = resolve(b, s) orelse continue;
        if (io.*.KeyCtrl != k.ctrl or io.*.KeyAlt != k.alt or io.*.KeySuper != k.super) continue;
        if (!b.variant and io.*.KeyShift != k.shift) continue;
        if (!c.ImGui_IsKeyPressedEx(k.key, false)) continue;
        b.run(ctx);
    }
}

// --- Teclas globais ---------------------------------------------------------

/// As teclas ligadas valem fora da janela também (platform/hotkeys.zig:
/// RegisterHotKey no Windows, XGrabKey no X11). Chamado quando a lista muda.
pub fn syncGlobal(s: *const S.Settings) void {
    if (capturing != null or !s.bind_global) {
        hotkeys.update(&.{});
        return;
    }
    var specs: [hotkeys.max_binds]hotkeys.Spec = undefined;
    var n: usize = 0;
    for (&list, 0..) |*b, i| {
        if (n >= specs.len) break;
        if (!b.on_get(s)) continue;
        const k = resolve(b, s) orelse continue;
        specs[n] = .{ .index = @intCast(i), .key = k.key, .ctrl = k.ctrl, .shift = k.shift, .alt = k.alt, .super = k.super };
        n += 1;
    }
    hotkeys.update(specs[0..n]);
}

/// As teclas globais apertadas fora da janela, uma por quadro.
pub fn drain(ctx: *d.Ctx) void {
    const s = &ctx.st.settings;
    while (hotkeys.pop()) |i| {
        if (i >= list.len) continue;
        if (!list[i].on_get(s)) continue;
        list[i].run(ctx);
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
    // Saiu da página de atalhos (ou fechou as configurações): a captura para
    // e as teclas globais voltam.
    if (!ctx.st.settings.open or ctx.st.settings.page != .atalhos) {
        capturing = null;
        syncGlobal(&ctx.st.settings);
        return;
    }
    const io = ctx.io;
    if (c.ImGui_IsKeyPressed(c.ImGuiKey_Escape)) {
        capturing = null;
        syncGlobal(&ctx.st.settings);
        return;
    }
    for (keys.captureCandidates()) |code| {
        if (!c.ImGui_IsKeyPressedEx(code, false)) continue;
        const k = Combo{ .key = code, .ctrl = io.*.KeyCtrl, .shift = io.*.KeyShift, .alt = io.*.KeyAlt, .super = io.*.KeySuper };
        if (!keys.valid(k)) continue;
        setBind(ctx, i, k);
        capturing = null;
        syncGlobal(&ctx.st.settings);
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
    syncGlobal(s);
    ctx.st.showToast(ctx.now_ms, false, "atalhos de volta aos padrões ✓", "binds back to defaults ✓", .{});
}

// --- Página de configurações ------------------------------------------------

/// As linhas de Configurações → Atalhos: a ação à esquerda, o liga/desliga e
/// a tecla numa caixa clicável à direita; clicar na caixa começa a captura,
/// o × volta ao padrão, o quadradinho desliga o atalho.
pub fn pageRows(p: anytype) void {
    const ctx = p.ctx;
    const s = &ctx.st.settings;
    // Teclas globais: vale fora da janela também. A pessoa liga por conta e
    // risco: a tecla deixa de chegar aos outros programas.
    const global_before = s.bind_global;
    p.toggle(i18n.tr("Vale fora da janela também (global)", "Works outside the window too (global)"), i18n.tr(
        "As teclas valem em qualquer programa: no Windows e no Linux com X11 (no Wayland, só com a janela em foco). Com isso ligado, as teclas dos atalhos não chegam mais aos outros programas.",
        "Bind keys work in any program: on Windows and Linux with X11 (on Wayland, only while the window is focused). With this on, bind keys no longer reach other programs.",
    ), &s.bind_global);
    if (s.bind_global != global_before) {
        ctx.act(.save_settings);
        syncGlobal(s);
    }
    p.y += 2;
    for (&list, 0..) |*b, i| {
        const row: d.Rect = .{ .x = p.x, .y = p.y, .w = p.w, .h = 38 };
        p.y += 46;
        const cap_w: f32 = 200;
        const cap: d.Rect = .{ .x = row.right() - cap_w, .y = row.y + 2, .w = cap_w, .h = 34 };
        const waiting = capturing != null and capturing.? == i;
        // O quadradinho liga e desliga o atalho sozinho.
        const er: d.Rect = .{ .x = cap.x - 38, .y = row.y + 5, .w = 28, .h = 28 };
        const eh = d.hit(ctx, enable_id + i, er);
        qa.mark(er, "bind-on:{s}", .{b.id});
        const on_before = b.on_get(s);
        if (eh.clicked) {
            b.on_put(s, !on_before);
            ctx.act(.save_settings);
            syncGlobal(s);
        }
        const on = b.on_get(s);
        drawCheckbox(p, er, eh.hovered, on);
        const spec = b.get(s);
        if (spec.len > 0) {
            const xr: d.Rect = .{ .x = er.x - 34, .y = row.y + 5, .w = 28, .h = 28 };
            const xh = d.hit(ctx, reset_id + i, xr);
            qa.mark(xr, "bind-reset:{s}", .{b.id});
            if (xh.clicked) {
                b.put(s, "");
                ctx.act(.save_settings);
                syncGlobal(s);
            }
            d.text(p.dl, p.font(.regular), 16, xr.x + 9, d.centerY(xr, 16), if (xh.hovered) ctx.col(.danger) else ctx.col(.faint), "×");
        }
        const hb = d.hit(ctx, bind_id + i, cap);
        qa.mark(cap, "bind:{s}", .{b.id});
        if (hb.clicked) {
            capturing = if (waiting) null else i;
            // Enquanto aperta a tecla nova, as globais saem do caminho.
            syncGlobal(s);
        }
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
        const lbl_col = if (on) ctx.col(.text) else ctx.col(.faint);
        _ = d.textClipped(p.dl, p.font(.medium), 15, row.x, row.y + 9, lbl_col, i18n.tr(b.pt, b.en), row.w - cap_w - 130);
        // Parado esperando tecla acorda os quadros (a captura é por quadro).
        if (waiting) anim.every(50);
    }
    p.y += 4;
    p.note(i18n.tr(
        "A regra é a dos plugins: letras e números precisam de Ctrl, Alt ou Super; F1–F24 podem ir sozinhas. Com \"fora da janela\" desligado, valem com a janela do SigmaCord em foco.",
        "Same rule as plugins: letters and digits need Ctrl, Alt or Super; F1–F24 can go alone. With \"outside the window\" off, binds work while the SigmaCord window is focused.",
    ));
}

/// O quadradinho de liga/desliga de uma linha.
fn drawCheckbox(p: anytype, r: d.Rect, hovered: bool, on: bool) void {
    const ctx = p.ctx;
    d.rect(p.dl, r, if (on) ctx.col(.accent) else if (hovered) ctx.col(.hover) else ctx.col(.rail), 6);
    d.border(p.dl, r, if (on) ctx.col(.accent) else ctx.col(.border), 6, 1);
    if (on) d.text(p.dl, p.font(.bold), 16, r.x + 7, d.centerY(r, 16), ctx.col(.accent_text), "✓");
}
