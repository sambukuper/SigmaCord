//! QA do que deixa o app leve: o que era feito ao abrir e agora é sob demanda.
const std = @import("std");
const c = @import("c");
const App = @import("app.zig").App;
const Op = @import("qa_runner.zig").Op;

extern fn sigma_font_index_size(font: *c.ImFont, size: f32) c_int;

/// Logo depois de abrir: nenhuma miniatura interpretada ainda.
fn previewsNotBuilt(app: *App) bool {
    return app.themes.previews_stale and app.themes.previews.items.len == 0;
}

fn openSettings(app: *App) void {
    app.st.settings.open = true;
}

fn closeSettings(app: *App) void {
    app.st.settings.open = false;
}

fn previewsBuilt(app: *App) bool {
    return !app.themes.previews_stale and app.themes.previews.items.len == app.themes.entries.items.len;
}

/// Um emoji não pode custar a tabela inteira até o código dele.
fn emojiIndexSmall(app: *App) bool {
    const font = app.uiFamily("Inter").get(.regular);
    const emoji = "\u{1F600}";
    _ = c.ImFont_CalcTextSizeAEx(font, 17, std.math.floatMax(f32), 0, emoji.ptr, emoji.ptr + emoji.len, null);
    const n = sigma_font_index_size(font, 17);
    return n > 0 and n < 0x8000;
}

pub const startup = [_]Op{
    .{ .section = "leve" },
    .{ .expect = .{ .name = "as miniaturas de tema não são montadas ao abrir", .check = previewsNotBuilt } },
    .{ .run = openSettings },
    .{ .expect = .{ .name = "abrir as Configurações monta as miniaturas de todos os temas", .check = previewsBuilt } },
    .{ .run = closeSettings },
    .{ .expect = .{ .name = "um emoji não reserva a tabela de caracteres até o código dele", .check = emojiIndexSmall } },
};

/// Sem token de verdade: o QA troca de conta entrando na demonstração de novo.
pub fn loginGone(app: *App) bool {
    return app.store.ready and app.login.phase == .hidden;
}
