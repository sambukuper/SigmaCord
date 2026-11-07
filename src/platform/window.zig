//! Janela, renderizador e o mecanismo de "acordar" o laço principal.
//! É a única parte que conhece o SDL e o backend gráfico; um backend por
//! software (wl_shm, sem GPU) entraria aqui sem mexer no resto.
const std = @import("std");
const sys = @import("sys.zig");
const c = @import("c");

pub const Wake = enum(i32) {
    gateway = 1,
    theme = 2,
    tick = 3,
    media = 4,
    token = 5,
    /// Abrir a janela: menu da bandeja ou um segundo SigmaCord.
    show = 6,
    /// Sair de verdade: menu da bandeja.
    quit = 7,
    /// A thread dos plugins tem pedidos para a interface.
    plugins = 8,
};

pub const Window = struct {
    window: *c.SDL_Window,
    renderer: *c.SDL_Renderer,
    wake_type: u32,

    pub fn init(title: [*:0]const u8, w: c_int, h: c_int) !Window {
        preferNvidiaEgl();
        // Fechar a janela é o app quem decide (ficar na bandeja ou sair). Sem
        // isto o SDL ainda manda um QUIT junto, e QUIT aqui é sempre sair.
        _ = c.SDL_SetHint(c.SDL_HINT_QUIT_ON_LAST_WINDOW_CLOSE, "0");
        _ = c.SDL_SetAppMetadata("SigmaCord", (@import("build_options").version ++ "\x00").ptr, "dev.sigmacord");
        if (!c.SDL_Init(c.SDL_INIT_VIDEO)) return error.SdlInit;
        var flags = c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_HIGH_PIXEL_DENSITY | c.SDL_WINDOW_TRANSPARENT;
        // SIGMACORD_HIDDEN=1: janela escondida (medir desempenho com a GPU de verdade).
        if (c.SDL_getenv("SIGMACORD_HIDDEN") != null) flags |= c.SDL_WINDOW_HIDDEN;
        const window = c.SDL_CreateWindow(title, w, h, flags) orelse return error.SdlWindow;
        // On Windows the requested size is in pixels: at 150% the window would open at 2/3 size.
        const s = contentScale(window);
        if (s != 1) openScaled(window, w, h, s);
        if (decodeIcon(icon_64)) |icon| {
            _ = c.SDL_SetWindowIcon(window, icon);
            c.SDL_DestroySurface(icon);
        }
        // SIGMACORD_RENDERER escolhe o backend do SDL (opengl, vulkan, gpu, software).
        const renderer = c.SDL_CreateRenderer(window, c.SDL_getenv("SIGMACORD_RENDERER")) orelse return error.SdlRenderer;
        _ = c.SDL_SetRenderVSync(renderer, 1);
        _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_NONE);
        const wake_type = c.SDL_RegisterEvents(1);
        return .{ .window = window, .renderer = renderer, .wake_type = wake_type };
    }

    pub fn deinit(win: *Window) void {
        c.SDL_DestroyRenderer(win.renderer);
        c.SDL_DestroyWindow(win.window);
        c.SDL_Quit();
    }

    /// Pode ser chamado de qualquer thread.
    pub fn wake(wake_type: u32, what: Wake) void {
        var ev = std.mem.zeroes(c.SDL_Event);
        ev.type = wake_type;
        ev.user.code = @intFromEnum(what);
        _ = c.SDL_PushEvent(&ev);
    }

    pub fn screenshot(win: *Window, path: [*:0]const u8) bool {
        const surface = c.SDL_RenderReadPixels(win.renderer, null) orelse return false;
        defer c.SDL_DestroySurface(surface);
        return c.SDL_SavePNG(surface, path);
    }
};

/// How much the display scale asks for beyond what SDL already applies. On macOS
/// and Wayland the window is already in points (1); on Windows and X11 it is in
/// pixels, and the scale (125%, 150%…) is up to the app.
pub fn contentScale(window: *c.SDL_Window) f32 {
    const display = c.SDL_GetWindowDisplayScale(window);
    const density = c.SDL_GetWindowPixelDensity(window);
    if (display <= 0 or density <= 0) return 1;
    return display / density;
}

/// The opening size at this scale, up to what fits the display: 1280x800 at 150% is 1920x1200,
/// taller than a 1080p laptop, and the text box would stay below the screen. SDL centered the
/// window for the old size, so it is centered again.
fn openScaled(window: *c.SDL_Window, w: c_int, h: c_int, s: f32) void {
    var sw: c_int = @intFromFloat(@as(f32, @floatFromInt(w)) * s);
    var sh: c_int = @intFromFloat(@as(f32, @floatFromInt(h)) * s);
    const display = c.SDL_GetDisplayForWindow(window);
    var area: c.SDL_Rect = undefined;
    if (c.SDL_GetDisplayUsableBounds(display, &area)) {
        var top: c_int = 0;
        var left: c_int = 0;
        var bottom: c_int = 0;
        var right: c_int = 0;
        _ = c.SDL_GetWindowBordersSize(window, &top, &left, &bottom, &right);
        sw = @min(sw, area.w - left - right);
        sh = @min(sh, area.h - top - bottom);
    }
    _ = c.SDL_SetWindowSize(window, sw, sh);
    const centered: c_int = @intCast(@as(u32, c.SDL_WINDOWPOS_CENTERED_MASK) | display);
    _ = c.SDL_SetWindowPosition(window, centered, centered);
}

/// Como uma imagem copiada pode estar na área de transferência. O print do Windows costuma vir
/// como bitmap, que o Discord não mostra como imagem: esse vai como PNG (ver `App.pasteImage`).
pub const ClipImage = struct { mime: [*:0]const u8, ext: []const u8, bitmap: bool = false };
const clip_images = [_]ClipImage{
    .{ .mime = "image/png", .ext = "png" },
    .{ .mime = "image/bmp", .ext = "png", .bitmap = true },
    .{ .mime = "image/jpeg", .ext = "jpg" },
    .{ .mime = "image/gif", .ext = "gif" },
    .{ .mime = "image/webp", .ext = "webp" },
};

pub fn clipboardImage() ?ClipImage {
    for (clip_images) |k| if (c.SDL_HasClipboardData(k.mime)) return k;
    return null;
}

/// Ícones embutidos (tools/gen_icons.py).
pub const icon_64 = @embedFile("icon_64");
pub const icon_32 = @embedFile("icon_32");

/// PNG embutido para uma superfície do SDL (quem chama destrói).
pub fn decodeIcon(png: []const u8) ?*c.SDL_Surface {
    var iw: c_int = 0;
    var ih: c_int = 0;
    var comp: c_int = 0;
    const px = c.stbi_load_from_memory(png.ptr, @intCast(png.len), &iw, &ih, &comp, 4) orelse return null;
    defer c.stbi_image_free(px);
    const borrowed = c.SDL_CreateSurfaceFrom(iw, ih, c.SDL_PIXELFORMAT_RGBA32, px, iw * 4) orelse return null;
    defer c.SDL_DestroySurface(borrowed);
    return c.SDL_DuplicateSurface(borrowed);
}

/// Em máquinas só com GPU NVIDIA, o glvnd carrega também o EGL do Mesa (e o
/// LLVM junto, ~23 MB) sem necessidade. Restringe ao EGL da NVIDIA nesse caso.
fn preferNvidiaEgl() void {
    const vendor_file = "/usr/share/glvnd/egl_vendor.d/10_nvidia.json";
    if (c.SDL_getenv("__EGL_VENDOR_LIBRARY_FILENAMES") != null) return;
    if (c.SDL_getenv("SIGMACORD_EGL_ALL") != null) return;
    if (!c.SDL_GetPathInfo(vendor_file, null)) return;

    var found = false;
    var i: u8 = 0;
    while (i < 8) : (i += 1) {
        var buf: [64]u8 = undefined;
        const path = std.fmt.bufPrintSentinel(&buf, "/sys/class/drm/card{d}/device/vendor", .{i}, 0) catch return;
        var size: usize = 0;
        const data = c.SDL_LoadFile(path.ptr, &size) orelse continue;
        defer c.SDL_free(data);
        const s = std.mem.trim(u8, @as([*]const u8, @ptrCast(data))[0..size], " \n");
        if (!std.mem.eql(u8, s, "0x10de")) return; // tem outra GPU: deixa o glvnd escolher
        found = true;
    }
    if (found) _ = c.SDL_setenv_unsafe("__EGL_VENDOR_LIBRARY_FILENAMES", vendor_file, 0);
}

/// Memória proporcional (PSS) do próprio processo, em KB. `file` é a parte que vem
/// de arquivos e dispositivos (bibliotecas, fontes, driver), 0 onde não se sabe.
pub const SelfMem = struct { pss: u32 = 0, file: u32 = 0 };

pub fn selfMemKb() SelfMem {
    if (sys.windows) return .{ .pss = sys.privateKb() };
    // Arquivos do /proc não informam o tamanho, então lê direto.
    const fd = c.open("/proc/self/smaps_rollup", c.O_RDONLY);
    if (fd < 0) return .{};
    defer _ = c.close(fd);
    var buf: [1024]u8 = undefined;
    const n = c.read(fd, &buf, buf.len);
    if (n <= 0) return .{};
    const s = buf[0..@intCast(n)];
    return .{ .pss = rollupKb(s, "\nPss:"), .file = rollupKb(s, "\nPss_File:") };
}

fn rollupKb(s: []const u8, name: []const u8) u32 {
    const at = std.mem.indexOf(u8, s, name) orelse return 0;
    var it = std.mem.tokenizeAny(u8, s[at + name.len ..], " \t");
    const num = it.next() orelse return 0;
    return std.fmt.parseInt(u32, num, 10) catch 0;
}
