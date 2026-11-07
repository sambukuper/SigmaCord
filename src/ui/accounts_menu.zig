//! Contas no menu do usuário (o do status, ao clicar no próprio nome):
//! as guardadas, com foto e nome vistos no READY; clicar numa troca de
//! conta (desconecta e entra na outra). Mais "Adicionar conta" e
//! "Remover conta".
const std = @import("std");
const c = @import("c");
const d = @import("draw.zig");
const qa = @import("qa.zig");
const w = @import("widgets.zig");
const i18n = @import("i18n.zig");
const store_acc = @import("../net/accounts_store.zig");
const Id = @import("../core/types.zig").Id;

const row_h: f32 = 34;
const item_h: f32 = 32;

/// A conta aberta não está na lista (token da variável SIGMACORD_TOKEN, sem
/// "Lembrar", ou a demonstração): aparece em cima, sem trocar.
fn sessionUnsaved(ctx: *const d.Ctx) bool {
    return store_acc.list.find(store_acc.session) == null and ctx.store.user(ctx.store.me) != null;
}

fn canRemove() bool {
    return store_acc.list.find(store_acc.session) != null;
}

pub fn height(ctx: *const d.Ctx) f32 {
    const n = store_acc.list.len + @intFromBool(sessionUnsaved(ctx));
    return 9 + 24 + @as(f32, @floatFromInt(n)) * row_h + item_h + (if (canRemove()) item_h else 0) + 4;
}

fn avatar(ctx: *d.Ctx, dl: *c.ImDrawList, cx: f32, cy: f32, id: Id, hash: []const u8, name: []const u8) void {
    const s: f32 = 22;
    const r: d.Rect = .{ .x = cx - s / 2, .y = cy - s / 2, .w = s, .h = s };
    var ub: [160]u8 = undefined;
    const url = if (hash.len > 0) w.cdnUrl(&ub, .avatar, id, hash) else "";
    if (w.picture(ctx, dl, url, r, s / 2, 1)) return;
    d.circle(dl, cx, cy, s / 2, ctx.th.role(@intCast(id % 8)).mix(ctx.col(.surface), 0.28));
    var up: [8]u8 = undefined;
    const initial = d.upper(&up, d.firstGlyph(name));
    const font = ctx.ui.get(.semibold);
    const tw = d.width(font, 10, initial);
    d.text(dl, font, 10, cx - tw / 2, cy - 6, d.Rgba.white.alpha(0.92), initial);
}

/// Desenha a parte das contas a partir de `y`, dentro do menu `r`.
/// Retorna true se algo foi escolhido (o menu fecha).
pub fn draw(ctx: *d.Ctx, dl: *c.ImDrawList, r: d.Rect, y0: f32) bool {
    var y = y0;
    const fam = ctx.ui;
    d.line(dl, r.x + 10, y + 4, r.right() - 10, y + 4, ctx.col(.border), 1);
    y += 9;
    d.text(dl, fam.get(.bold), 11, r.x + 16, y + 6, ctx.col(.faint), i18n.tr("CONTAS", "ACCOUNTS"));
    y += 24;
    const radius = @max(ctx.th.radius - 2, 2);

    if (sessionUnsaved(ctx)) {
        const u = ctx.store.user(ctx.store.me).?;
        const ir: d.Rect = .{ .x = r.x + 6, .y = y, .w = r.w - 12, .h = row_h - 2 };
        avatar(ctx, dl, ir.x + 18, ir.y + ir.h / 2, u.id, if (ctx.store.demo) "" else u.avatar orelse "", u.name);
        const tag = if (ctx.store.demo) i18n.tr("demonstração", "demo") else i18n.tr("não guardada", "not saved");
        const nw = d.textClipped(dl, fam.get(.semibold), 14, ir.x + 36, d.centerY(ir, 14), ctx.col(.text), u.name, ir.w - 110);
        _ = d.textClipped(dl, fam.get(.regular), 11.5, ir.x + 36 + nw + 6, d.centerY(ir, 11.5) + 1, ctx.col(.faint), tag, ir.w - nw - 50);
        y += row_h;
    }
    for (store_acc.list.slice()) |*a| {
        const ir: d.Rect = .{ .x = r.x + 6, .y = y, .w = r.w - 12, .h = row_h - 2 };
        const current = a.id == store_acc.session;
        qa.mark(ir, "account:{d}", .{a.id});
        if (current) {
            // A conta aberta: só mostra (com o visto), não troca para ela mesma.
            d.rect(dl, ir, ctx.col(.selected), radius);
        } else {
            const hb = d.hit(ctx, 0xacc0 + @as(usize, @intCast(a.id % 100_000)), ir);
            if (hb.hovered) d.rect(dl, ir, ctx.col(.hover), radius);
            d.tip(ctx, ir, i18n.tr("Trocar para esta conta", "Switch to this account"), hb.hovered);
            if (hb.clicked) {
                ctx.act(.{ .switch_account = a.id });
                return true;
            }
        }
        avatar(ctx, dl, ir.x + 18, ir.y + ir.h / 2, a.id, a.avatar(), a.name());
        _ = d.textClipped(dl, fam.get(if (current) .semibold else .medium), 14, ir.x + 36, d.centerY(ir, 14), ctx.col(.text), a.name(), ir.w - 62);
        if (current) {
            const cx = ir.right() - 16;
            const cy = ir.y + ir.h / 2;
            d.line(dl, cx - 5, cy, cx - 1, cy + 4, ctx.col(.accent), 2);
            d.line(dl, cx - 1, cy + 4, cx + 6, cy - 4, ctx.col(.accent), 2);
        }
        y += row_h;
    }
    const items = [_]struct { label: []const u8, en: []const u8, danger: bool }{
        .{ .label = "Adicionar conta", .en = "Add Account", .danger = false },
        .{ .label = "Remover conta", .en = "Remove Account", .danger = true },
    };
    for (items, 0..) |it, i| {
        if (it.danger and !canRemove()) continue;
        const ir: d.Rect = .{ .x = r.x + 6, .y = y, .w = r.w - 12, .h = item_h - 2 };
        const hb = d.hit(ctx, 0xacb0 + i, ir);
        qa.mark(ir, "menu:{s}", .{it.label});
        const base = if (it.danger) ctx.col(.danger) else ctx.col(.accent);
        if (hb.hovered) d.rect(dl, ir, base, radius);
        const tc = if (hb.hovered) (if (it.danger) d.Rgba.white else ctx.col(.accent_text)) else if (it.danger) ctx.col(.danger) else ctx.col(.text).mix(ctx.col(.muted), 0.15);
        d.text(dl, fam.get(.medium), 14, ir.x + 10, d.centerY(ir, 14), tc, i18n.tr(it.label, it.en));
        if (hb.clicked) {
            ctx.act(if (it.danger) .{ .remove_account = store_acc.session } else .add_account);
            return true;
        }
        y += item_h;
    }
    return false;
}
