//! Testes das partes que não dependem de janela nem de GPU.
const std = @import("std");
const builtin_themes = @import("builtin_themes");
const theme = @import("theme/theme.zig");
const layout = @import("theme/layout.zig");

test {
    _ = @import("net/retry.zig");
    _ = @import("core/resample.zig");
    _ = @import("core/plain_letters.zig");
    _ = @import("core/gif_favorites.zig");
    _ = @import("platform/debug_log.zig");
    _ = @import("core/types.zig");
    _ = @import("core/ritmo.zig");
    _ = @import("core/mem_use.zig");
    _ = @import("core/image_uri.zig");
    _ = @import("core/version.zig");
    _ = @import("core/sort.zig");
    _ = @import("core/markdown.zig");
    _ = @import("core/changelog.zig");
    _ = @import("core/store.zig");
    _ = @import("core/filtros.zig");
    _ = @import("core/leitura.zig");
    _ = @import("core/links.zig");
    _ = @import("core/voz.zig");
    _ = @import("core/janela.zig");
    _ = @import("core/ruido.zig");
    _ = @import("core/lsp.zig");
    _ = @import("ui/rascunhos.zig");
    _ = @import("core/inbox.zig");
    _ = @import("core/saved.zig");
    _ = @import("core/mentions.zig");
    _ = @import("ui/emoji_data.zig");
    _ = @import("core/cache_format.zig");
    _ = @import("core/search_query.zig");
    _ = @import("core/accounts.zig");
    _ = @import("theme/kdl.zig");
    _ = @import("theme/color.zig");
    _ = @import("theme/theme.zig");
    _ = @import("theme/fx.zig");
    _ = @import("ui/procgen.zig");
    _ = @import("theme/custom.zig");
    _ = @import("theme/layout.zig");
    _ = @import("ui/anim.zig");
    _ = @import("ui/bind_keys.zig");
    _ = @import("ui/fuzzy.zig");
    _ = @import("ui/i18n.zig");
    _ = @import("ui/syntax.zig");
    _ = @import("ui/settings_state.zig");
    _ = @import("ui/guild_color.zig");
    _ = @import("net/jsonx.zig");
    _ = @import("net/read_state_json.zig");
    _ = @import("net/media_url.zig");
    _ = @import("net/proxy.zig");
    _ = @import("net/settings_proto.zig");
    _ = @import("net/thread_json.zig");
    _ = @import("net/user_json.zig");
    _ = @import("ui/apng.zig");
    _ = @import("plugins/engine.zig");
    _ = @import("plugins/manifest.zig");
    _ = @import("plugins/deco.zig");
    _ = @import("plugins/panel.zig");
    _ = @import("plugins/rewrite.zig");
    _ = @import("plugins/json.zig");
}

/// Componentes que a interface sabe desenhar (manter igual a ui/root.zig).
const known = [_][]const u8{ "row", "column", "stack", "guild-bar", "channel-list", "user-panel", "header", "tabs", "messages", "composer", "member-list", "status-bar", "label", "spacer", "logo", "topbar", "crt", "shape", "rule", "span", "starfield", "orbit", "aurora", "dunes", "topography", "radar", "window-controls" };

fn checkNames(n: anytype) !void {
    for (n.children) |*ch| {
        var ok = false;
        for (known) |k| if (std.mem.eql(u8, k, ch.name)) {
            ok = true;
        };
        if (!ok) {
            std.debug.print("componente desconhecido '{s}' na linha {d}\n", .{ ch.name, ch.line });
            return error.UnknownComponent;
        }
        try checkNames(ch);
    }
}

test "todos os temas embutidos carregam e montam o layout" {
    for (builtin_themes.list) |b| {
        var d: theme.Diagnostic = .{};
        var t = theme.load(std.testing.allocator, b.source, null, &d) catch |err| {
            std.debug.print("tema {s}: linha {d}: {s}\n", .{ b.name, d.line, d.message });
            return err;
        };
        defer t.deinit();
        try checkNames(t.layout.?);
        var out: std.ArrayList(layout.Placed) = .empty;
        defer out.deinit(std.testing.allocator);
        try layout.solve(std.testing.allocator, t.layout.?, .{ .x = 0, .y = 0, .w = 1280, .h = 800 }, 1280, &out);
        try std.testing.expect(out.items.len > 3);
        for (out.items) |p| try std.testing.expect(p.rect.w >= 0 and p.rect.h >= 0);
    }
}

test "os dois CHANGELOGs têm as mesmas versões, com o mesmo tanto em cada seção" {
    const log = @import("core/changelog.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const en = try log.parse(arena.allocator(), @embedFile("changelog_en"));
    const pt = try log.parse(arena.allocator(), @embedFile("changelog_pt"));
    try std.testing.expect(en.len > 0);
    try std.testing.expectEqual(en.len, pt.len);
    for (en, pt) |a, b| {
        try std.testing.expectEqualStrings(a.name, b.name);
        try std.testing.expectEqual(a.sections.len, b.sections.len);
        for (a.sections, b.sections) |sa, sb| try std.testing.expectEqual(sa.items.len, sb.items.len);
    }
}
