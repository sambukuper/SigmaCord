//! Monta o quadro: resolve o layout do tema, desenha os estilos dos nós,
//! chama cada componente pelo nome e cuida das sobreposições (paleta, aviso)
//! e dos atalhos de teclado.
const std = @import("std");
const c = @import("c");
const kdl = @import("../theme/kdl.zig");
const layout = @import("../theme/layout.zig");
const theme_mod = @import("../theme/theme.zig");
const d = @import("draw.zig");
const i18n = @import("i18n.zig");
const anim = @import("anim.zig");
const rail = @import("comp_rail.zig");
const channels = @import("comp_channels.zig");
const chat = @import("comp_chat.zig");
const msgs = @import("comp_messages.zig");
const popup = @import("popup.zig");
const side = @import("comp_side.zig");
const palette = @import("palette.zig");
const settings = @import("settings.zig");
const vim = @import("vim.zig");
const search = @import("search.zig");
const bindings = @import("bindings.zig");
const Preview = @import("../theme/manager.zig").Preview;

const extra = @import("comp_extra.zig");
const fx = @import("fx.zig");
const display = @import("display_text.zig");
const backdrop = @import("backdrop.zig");
const resize = @import("resize.zig");
const plugin_panel = @import("plugin_panel.zig");

const Component = *const fn (*d.Ctx, *const kdl.Node, d.Rect) void;

const registry = std.StaticStringMap(Component).initComptime(.{
    .{ "guild-bar", rail.draw },
    .{ "channel-list", channels.channelList },
    .{ "user-panel", channels.userPanel },
    .{ "header", chat.header },
    .{ "tabs", chat.tabs },
    .{ "messages", msgs.messages },
    .{ "composer", msgs.composer },
    .{ "member-list", side.memberList },
    .{ "status-bar", side.statusBar },
    .{ "label", label },
    .{ "logo", extra.logo },
    .{ "topbar", extra.topbar },
    .{ "crt", extra.crt },
    .{ "shape", extra.shape },
    .{ "rule", extra.rule },
    .{ "window-controls", extra.windowControls },
    .{ "starfield", backdrop.draw },
    .{ "orbit", backdrop.draw },
    .{ "aurora", backdrop.draw },
    .{ "dunes", backdrop.draw },
    .{ "topography", backdrop.draw },
    .{ "radar", backdrop.draw },
    .{ "spacer", spacer },
});

fn spacer(_: *d.Ctx, _: *const kdl.Node, _: d.Rect) void {}

/// --stats: tempo gasto em cada componente (µs somados desde a última leitura).
pub var profile = false;
pub var prof_names: [24][]const u8 = undefined;
pub var prof_us: [24]u64 = @splat(0);
pub var prof_n: usize = 0;

fn profAdd(name: []const u8, us: u64) void {
    for (prof_names[0..prof_n], 0..) |nm, i| if (std.mem.eql(u8, nm, name)) {
        prof_us[i] += us;
        return;
    };
    if (prof_n == prof_names.len) return;
    prof_names[prof_n] = name;
    prof_us[prof_n] = us;
    prof_n += 1;
}

/// `label text="SigmaCord" size=14 weight=bold color=accent align=center`
fn label(ctx: *d.Ctx, n: *const kdl.Node, r: d.Rect) void {
    if (ctx.th.nodeFx(n)) |x| if (x.text) |tx| return display.label(ctx, n, r, tx);
    const t = d.pstr(n, "text", "");
    const fam = ctx.familyFor(n);
    const weight = std.meta.stringToEnum(d.Weight, d.pstr(n, "weight", "semibold")) orelse .semibold;
    const font = fam.get(weight);
    const size = d.pnum(n, "size", 14);
    const color = if (theme_mod.tokenFromName(d.pstr(n, "color", "muted"))) |tok| ctx.col(tok) else ctx.col(.muted);
    const tw = d.width(font, size, t);
    const x = if (d.is(n, "align", "center", "left")) r.x + (r.w - tw) / 2 else if (d.is(n, "align", "right", "left")) r.right() - tw - 10 else r.x + 10;
    d.text(ctx.dl, font, size, x, d.centerY(r, size), color, t);
}

fn hidden(ctx: *d.Ctx, name: []const u8) bool {
    const s = &ctx.st.settings;
    if (!s.show_member_list and std.mem.eql(u8, name, "member-list")) return true;
    if (!s.show_status_bar and std.mem.eql(u8, name, "status-bar")) return true;
    return false;
}

pub fn frame(ctx: *d.Ctx, placed: *std.ArrayList(layout.Placed), previews: []const Preview) void {
    const vp = c.ImGui_GetMainViewport();
    c.ImGui_SetNextWindowPos(vp.*.Pos, 0);
    c.ImGui_SetNextWindowSize(vp.*.Size, 0);
    _ = c.ImGui_Begin("##root", null, c.ImGuiWindowFlags_NoDecoration | c.ImGuiWindowFlags_NoMove |
        c.ImGuiWindowFlags_NoSavedSettings | c.ImGuiWindowFlags_NoBringToFrontOnFocus |
        c.ImGuiWindowFlags_NoBackground | c.ImGuiWindowFlags_NoScrollWithMouse | c.ImGuiWindowFlags_NoNav);
    ctx.dl = c.ImGui_GetWindowDrawList();
    ctx.fg = c.ImGui_GetForegroundDrawList();
    const rich = @import("rich.zig");
    rich.frame_ctx = ctx;
    rich.emoji_images = @import("emoji_img.zig").enabled(ctx);
    vim.beforeFrame(ctx.st);
    ctx.win = .{ .x = vp.*.Pos.x, .y = vp.*.Pos.y, .w = vp.*.Size.x, .h = vp.*.Size.y };

    d.opt_theme = ctx.th;
    fx.beginFrame();
    if (ctx.th.layout) |root| {
        const Look = struct {
            fn get(p: *const anyopaque, name: []const u8) ?bool {
                const th: *const theme_mod.Theme = @ptrCast(@alignCast(p));
                return th.option(name);
            }
        };
        // O que o usuário desligou sai do layout (a conversa ocupa o espaço).
        var hides: [2][]const u8 = undefined;
        var n_hides: usize = 0;
        if (!ctx.st.settings.show_member_list) {
            hides[n_hides] = "member-list";
            n_hides += 1;
        }
        if (!ctx.st.settings.show_status_bar) {
            hides[n_hides] = "status-bar";
            n_hides += 1;
        }
        // Painel de plugin aberto: o tema inteiro cabe no que sobra da janela.
        const bounds = search.reserve(plugin_panel.reserve(ctx.win));
        // Largura dos painéis: a da pessoa, com a conversa sempre usável.
        var sizes = resize.sizes(&ctx.st.settings);
        layout.solveSized(ctx.st.gpa, root, bounds, bounds.w, .{ .ctx = ctx.th, .get = Look.get, .hides = hides[0..n_hides] }, &sizes, "messages", resize.min_chat, placed) catch {};
        resize.addPanels(ctx, placed.items, &sizes);
        const base_theme = ctx.th;
        defer ctx.th = base_theme;
        var local: theme_mod.Theme = undefined;
        for (placed.items, 0..) |p, i| {
            // Cores sobrescritas neste pedaço do layout.
            ctx.th = base_theme;
            if (base_theme.node_colors.get(p.node)) |ovs| {
                local = base_theme.*;
                for (ovs) |o| local.colors.set(o.tok, o.color);
                ctx.th = &local;
            }
            // Fundo rápido pelo próprio nó: bg=sidebar radius=12
            if (p.node.str("bg")) |bg| if (theme_mod.tokenFromName(bg)) |tok|
                d.rect(ctx.dl, p.rect, ctx.col(tok), d.pnum(p.node, "radius", 0));
            if (ctx.th.style(p.node.str("style"))) |st| d.drawStyle(ctx, ctx.dl, st, p.rect, i);
            // Primitivas novas no próprio nó (gradiente, grão, borda por lado…).
            if (base_theme.nodeFx(p.node)) |x| fx.node(ctx, x, p.node, p.rect, i);
            if (p.kind != .component or hidden(ctx, p.node.name)) continue;
            c.ImGui_PushIDPtr(p.node);
            defer c.ImGui_PopID();
            const inner = p.rect.inset(d.pnum(p.node, "inset-x", 0), d.pnum(p.node, "inset-y", 0));
            if (registry.get(p.node.name)) |draw| {
                const t0 = if (profile) c.SDL_GetTicksNS() else 0;
                // (Uma régua pode ter 1 pixel de altura.)
                if ((inner.w > 4 and inner.h > 4) or (draw == &extra.rule and inner.w > 0 and inner.h > 0)) draw(ctx, p.node, inner);
                if (profile) profAdd(p.node.name, (c.SDL_GetTicksNS() - t0) / 1000);
            } else unknown(ctx, p);
            if (d.pflag(p.node, "autohide", false)) autohide(ctx, p, i);
        }
    }
    // Por cima dos painéis, por baixo do que flutua (a lista do autocompletar).
    resize.submit(ctx);
    plugin_panel.draw(ctx);
    @import("lsp_ui.zig").panel(ctx);
    @import("autocomplete.zig").draw(ctx);
    c.ImGui_End();

    const t1 = if (profile) c.SDL_GetTicksNS() else 0;
    popup.draw(ctx);
    settings.draw(ctx, previews);
    if (profile) profAdd("overlays", (c.SDL_GetTicksNS() - t1) / 1000);
    @import("attachments.zig").viewer(ctx);
    palette.draw(ctx);
    search.draw(ctx);
    toast(ctx);
    shortcuts(ctx);
}

/// `autohide`: o componente some (fica quase invisível) até o mouse chegar
/// perto. Um véu da cor do fundo por cima faz o papel de "transparência".
fn autohide(ctx: *d.Ctx, p: layout.Placed, i: usize) void {
    const near = p.rect.inset(-48, -48).contains(ctx.mouse.x, ctx.mouse.y) or ctx.st.popup != .none;
    const k = anim.to(anim.id("autohide", i), if (near) 1 else 0, 10);
    if (k > 0.98) return;
    d.rect(ctx.fg, p.rect, ctx.col(.bg).alpha(0.9 * (1 - k)), 0);
}

fn unknown(ctx: *d.Ctx, p: layout.Placed) void {
    // Ajuda quem está escrevendo um tema: mostra o nome que não existe.
    d.border(ctx.dl, p.rect, ctx.col(.danger), 4, 2);
    var buf: [96]u8 = undefined;
    const t = i18n.fmt(&buf, "componente desconhecido: {s} (linha {d})", "unknown component: {s} (line {d})", .{ p.node.name, p.node.line });
    d.text(ctx.dl, ctx.ui.get(.semibold), 13, p.rect.x + 8, p.rect.y + 6, ctx.col(.danger), t);
}

fn toast(ctx: *d.Ctx) void {
    const t = &ctx.st.toast;
    const k = anim.to(anim.id("toast", 0), if (ctx.now_ms < t.until_ms) 1 else 0, 14);
    // Parado na tela não precisa de quadros; só acorda para sumir.
    if (ctx.now_ms < t.until_ms) anim.at(t.until_ms);
    if (k < 0.01) return;
    const font = ctx.ui.get(.semibold);
    const fs: f32 = 14;
    const tw = d.width(font, fs, t.text());
    const r: d.Rect = .{ .x = ctx.win.x + (ctx.win.w - tw - 36) / 2, .y = ctx.win.y + 14 - (1 - k) * 10, .w = tw + 36, .h = 34 };
    d.shadow(ctx.fg, r, 17, 12, ctx.col(.shadow).alpha(k));
    d.rect(ctx.fg, r, (if (t.is_error) ctx.col(.danger) else ctx.col(.overlay)).alpha(k), 17);
    if (!t.is_error) d.border(ctx.fg, r, ctx.col(.accent).alpha(0.6 * k), 17, 1);
    d.text(ctx.fg, font, fs, r.x + 18, d.centerY(r, fs), (if (t.is_error) d.Rgba.white else ctx.col(.text)).alpha(k), t.text());
}

fn shortcuts(ctx: *d.Ctx) void {
    const io = ctx.io;
    const ctrl = io.*.KeyCtrl;
    const shift = io.*.KeyShift;
    // Captura da página Atalhos: enquanto ela espera (e no quadro em que
    // termina), a tecla dela não vaza para os outros atalhos.
    const was_capturing = bindings.capturingNow();
    bindings.captureTick(ctx);
    if (was_capturing) return;
    if (c.ImGui_IsKeyPressed(c.ImGuiKey_Escape) and ctx.st.popup == .none and !ctx.st.selection.empty()) ctx.st.selection = .{};
    if (ctrl) zoomKeys(ctx);
    // Os atalhos configuráveis (Configurações → Atalhos de teclado): mic,
    // surdez, paleta, busca, tela cheia e companhia.
    bindings.dispatch(ctx);
    const alt_enter = io.*.KeyAlt and (c.ImGui_IsKeyPressedEx(c.ImGuiKey_Enter, false) or c.ImGui_IsKeyPressedEx(c.ImGuiKey_KeypadEnter, false));
    if (alt_enter) ctx.act(.toggle_fullscreen);
    // Ctrl+Shift+P: a mesma paleta, com as ações primeiro.
    if (ctrl and shift and c.ImGui_IsKeyPressed(c.ImGuiKey_P)) {
        palette.commands_first = true;
        ctx.act(if (ctx.st.palette.open) .close_palette else .open_palette);
    }
    vim.keys(ctx);
    if (io.*.KeyAlt) {
        const keys = [_]c_int{ c.ImGuiKey_1, c.ImGuiKey_2, c.ImGuiKey_3, c.ImGuiKey_4, c.ImGuiKey_5, c.ImGuiKey_6, c.ImGuiKey_7, c.ImGuiKey_8, c.ImGuiKey_9 };
        for (keys, 0..) |k, i| if (c.ImGui_IsKeyPressed(k)) ctx.act(.{ .focus_tab = i });
    }
}

/// Ctrl + , Ctrl - e Ctrl 0: a interface inteira, como no navegador e no Discord.
fn zoomKeys(ctx: *d.Ctx) void {
    const set = &ctx.st.settings;
    const before = set.ui_scale;
    if (c.ImGui_IsKeyPressedEx(c.ImGuiKey_Equal, false) or c.ImGui_IsKeyPressedEx(c.ImGuiKey_KeypadAdd, false)) set.ui_scale += 0.1;
    if (c.ImGui_IsKeyPressedEx(c.ImGuiKey_Minus, false) or c.ImGui_IsKeyPressedEx(c.ImGuiKey_KeypadSubtract, false)) set.ui_scale -= 0.1;
    if (c.ImGui_IsKeyPressedEx(c.ImGuiKey_0, false) or c.ImGui_IsKeyPressedEx(c.ImGuiKey_Keypad0, false)) set.ui_scale = 1;
    if (set.ui_scale == before) return;
    set.ui_scale = std.math.clamp(@round(set.ui_scale * 20) / 20, 0.75, 2);
    ctx.st.showToast(ctx.now_ms, false, "interface em {d:.0}%", "interface at {d:.0}%", .{set.ui_scale * 100});
    ctx.act(.save_settings);
}
