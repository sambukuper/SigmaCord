//! Atalhos globais: as teclas valem fora da janela também. Cada sistema dá
//! esse poder de um jeito, então há um backend por plataforma:
//!  - Windows: RegisterHotKey com uma thread própria (o WM_HOTKEY chega na
//!    fila dela, sem janela nenhuma);
//!  - Linux/X11: XGrabKey na janela raiz, com uma conexão X aberta aqui
//!    (libX11 via dlopen: quem só tem Wayland segue sem tecla global);
//!  - Wayland: o compositor não entrega tecla global sem o portal, então o
//!    atalho continua valendo só com a janela em foco (ui/bindings.zig).
//! A thread vive o app inteiro: espera a lista de atalhos mudar, (re)registra
//! tudo e põe as teclas apertadas numa fila que o quadro drena.
const std = @import("std");
const builtin = @import("builtin");
const c = @import("c");
const imgui = @import("imgui_c");

pub const max_binds = 16;

/// Um atalho a registrar. `index` volta na fila quando a tecla for apertada.
pub const Spec = struct {
    index: u8,
    key: c_int,
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,
    super: bool = false,
};

// --- Estado compartilhado entre a interface e a thread ----------------------

var disabled = false;
var backend_ok = false;

var mutex: ?*c.SDL_Mutex = null;
var thread: ?*c.SDL_Thread = null;

fn lock() void {
    c.SDL_LockMutex(mutex);
}
fn unlock() void {
    c.SDL_UnlockMutex(mutex);
}

/// Conta de mudanças: a thread compara com a dela para saber que trocou.
var gen: u32 = 0;
var specs_buf: [max_binds]Spec = undefined;
var specs_n: usize = 0;

var fired_buf: [32]u8 = undefined;
var fired_len: usize = 0;
var fired_head: usize = 0;

/// Chamado uma vez, no começo: QA e prints não registram tecla nenhuma.
pub fn disable() void {
    disabled = true;
}

/// A lista de atalhos globais mudou: guarda e acorda a thread.
pub fn update(specs: []const Spec) void {
    if (disabled) return;
    if (mutex == null) mutex = c.SDL_CreateMutex();
    lock();
    defer unlock();
    specs_n = @min(specs.len, max_binds);
    @memcpy(specs_buf[0..specs_n], specs[0..specs_n]);
    gen +%= 1;
    if (thread == null) {
        thread = c.SDL_CreateThread(threadMain, "atalhos", null);
    } else if (builtin.os.tag == .windows) {
        postRegrab();
    }
}

/// Uma tecla global apertada (índice em ui/bindings.zig) ou null.
pub fn pop() ?u8 {
    if (mutex == null) return null;
    lock();
    defer unlock();
    if (fired_len == 0) return null;
    const i = fired_buf[fired_head];
    fired_head = (fired_head + 1) % fired_buf.len;
    fired_len -= 1;
    return i;
}

/// O backend do sistema abriu? (No Wayland e sem libX11, não.)
pub fn active() bool {
    if (mutex == null) return false;
    lock();
    defer unlock();
    return thread != null and backend_ok;
}

fn fire(index: u8) void {
    lock();
    defer unlock();
    if (fired_len == fired_buf.len) return;
    fired_buf[(fired_head + fired_len) % fired_buf.len] = index;
    fired_len += 1;
}

fn threadMain(_: ?*anyopaque) callconv(.c) c_int {
    switch (builtin.os.tag) {
        .windows => winLoop(),
        .linux => x11Loop(),
        else => {},
    }
    return 0;
}

// --- Windows ----------------------------------------------------------------

const WM_HOTKEY: u32 = 0x0312;
const WM_SIGMACORD_REGRAB: u32 = 0x8000; // WM_APP
const MOD_ALT: u32 = 0x1;
const MOD_CONTROL: u32 = 0x2;
const MOD_SHIFT: u32 = 0x4;
const MOD_WIN: u32 = 0x8;

const MSG = extern struct {
    hwnd: ?*opaque {},
    message: u32,
    wParam: usize,
    lParam: isize,
    time: u32,
    pt: extern struct { x: i32, y: i32 },
};

extern "user32" fn RegisterHotKey(hWnd: ?*opaque {}, id: c_int, fsModifiers: c_uint, vk: c_uint) i32;
extern "user32" fn UnregisterHotKey(hWnd: ?*opaque {}, id: c_int) i32;
extern "user32" fn GetMessageW(lpMsg: *MSG, hWnd: ?*opaque {}, min: c_uint, max: c_uint) i32;
extern "user32" fn PostThreadMessageW(idThread: u32, msg: u32, wParam: usize, lParam: isize) i32;
extern "kernel32" fn GetCurrentThreadId() u32;

var win_tid: u32 = 0;

fn postRegrab() void {
    if (win_tid != 0) _ = PostThreadMessageW(win_tid, WM_SIGMACORD_REGRAB, 0, 0);
}

fn winLoop() void {
    win_tid = GetCurrentThreadId();
    // A primeira lista pode já estar guardada quando a thread nasce.
    regrabWin();
    var msg: MSG = undefined;
    while (true) {
        const r = GetMessageW(&msg, null, 0, 0);
        if (r <= 0) {
            c.SDL_Delay(50);
            continue;
        }
        if (msg.message == WM_HOTKEY) {
            if (msg.wParam < max_binds) fire(@intCast(msg.wParam));
        } else if (msg.message == WM_SIGMACORD_REGRAB) {
            regrabWin();
        }
    }
}

fn regrabWin() void {
    lock();
    const specs = specs_buf[0..specs_n];
    // Sem janela: o WM_HOTKEY cai na fila da thread que registrou.
    for (0..max_binds) |id| _ = UnregisterHotKey(null, @intCast(id));
    for (specs) |s| {
        const vk = toVk(s.key) orelse continue;
        var mods: c_uint = 0;
        if (s.alt) mods |= MOD_ALT;
        if (s.ctrl) mods |= MOD_CONTROL;
        if (s.shift) mods |= MOD_SHIFT;
        if (s.super) mods |= MOD_WIN;
        // Outro programa já tem essa tecla: fica sem global e o atalho
        // continua funcionando com a janela em foco.
        _ = RegisterHotKey(null, @intCast(s.index), mods, vk);
    }
    unlock();
    backend_ok = true;
}

fn toVk(key: c_int) ?c_uint {
    if (key >= imgui.ImGuiKey_A and key <= imgui.ImGuiKey_Z) return @intCast('A' + key - imgui.ImGuiKey_A);
    if (key >= imgui.ImGuiKey_0 and key <= imgui.ImGuiKey_9) return @intCast('0' + key - imgui.ImGuiKey_0);
    if (key >= imgui.ImGuiKey_F1 and key <= imgui.ImGuiKey_F24) return @intCast(0x70 + key - imgui.ImGuiKey_F1); // VK_F1…
    return switch (key) {
        imgui.ImGuiKey_Enter => 0x0D, // VK_RETURN
        imgui.ImGuiKey_Space => 0x20, // VK_SPACE
        imgui.ImGuiKey_Tab => 0x09, // VK_TAB
        imgui.ImGuiKey_Backspace => 0x08, // VK_BACK
        imgui.ImGuiKey_Delete => 0x2E, // VK_DELETE
        imgui.ImGuiKey_Insert => 0x2D, // VK_INSERT
        imgui.ImGuiKey_Home => 0x24, // VK_HOME
        imgui.ImGuiKey_End => 0x23, // VK_END
        imgui.ImGuiKey_PageUp => 0x21, // VK_PRIOR
        imgui.ImGuiKey_PageDown => 0x22, // VK_NEXT
        imgui.ImGuiKey_UpArrow => 0x26, // VK_UP
        imgui.ImGuiKey_DownArrow => 0x28, // VK_DOWN
        imgui.ImGuiKey_LeftArrow => 0x25, // VK_LEFT
        imgui.ImGuiKey_RightArrow => 0x27, // VK_RIGHT
        imgui.ImGuiKey_Comma => 0xBC, // VK_OEM_COMMA
        imgui.ImGuiKey_Period => 0xBE, // VK_OEM_PERIOD
        imgui.ImGuiKey_Slash => 0xBF, // VK_OEM_2
        imgui.ImGuiKey_Semicolon => 0xBA, // VK_OEM_1
        imgui.ImGuiKey_Minus => 0xBD, // VK_OEM_MINUS
        imgui.ImGuiKey_Equal => 0xBB, // VK_OEM_PLUS
        else => null,
    };
}

// --- Linux / X11 ------------------------------------------------------------

const XKeyPress: c_int = 2;
const ShiftMask: u32 = 1 << 0;
const LockMask: u32 = 1 << 1;
const ControlMask: u32 = 1 << 2;
const Mod1Mask: u32 = 1 << 3; // Alt
const Mod2Mask: u32 = 1 << 4; // Num Lock
const Mod4Mask: u32 = 1 << 6; // Super

const XKeyEvent = extern struct {
    type: c_int,
    serial: usize,
    send_event: c_int,
    display: *opaque {},
    window: u64,
    root: u64,
    subwindow: u64,
    time: u64,
    x: c_int,
    y: c_int,
    x_root: c_int,
    y_root: c_int,
    state: u32,
    keycode: u32,
    same_screen: c_int,
};

/// O XEvent de verdade tem 192 bytes (24 longs): o XNextEvent escreve ele
/// inteiro, então a união precisa do tamanho cheio, não só do XKeyEvent.
const XEvent = extern union {
    type: c_int,
    xkey: XKeyEvent,
    pad: [24]u64,
};

fn x11Loop() void {
    x11Real() catch return;
}

/// Erro de X não derruba o app (o padrão do X encerra o processo).
fn x11IgnoreError(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
    return 0;
}

fn x11Real() !void {
    const names = [_][]const u8{ "libX11.so.6", "libX11.so" };
    var lib: std.DynLib = undefined;
    for (names) |n| {
        lib = std.DynLib.open(n) catch continue;
        break;
    } else return error.NoX11;

    const Handler = *const fn (?*anyopaque, ?*anyopaque) callconv(.c) c_int;
    const Fn = fn (Handler) callconv(.c) Handler;
    const setErr: *const Fn = lib.lookup(*const Fn, "XSetErrorHandler") orelse return error.NoX11;
    // Erro de X (tecla já presa por outro programa) não pode matar o app:
    // o tratador padrão do X encerra o processo inteiro.
    _ = setErr(&x11IgnoreError);

    // Um apelido só para o Display: cada `opaque {}` literal é um tipo novo,
    // e os dois lados da declaração têm que ser o MESMO tipo.
    const Display = *anyopaque;
    const Dpy = ?Display;
    const open: *const fn (?[:0]const u8) callconv(.c) Dpy = lib.lookup(*const fn (?[:0]const u8) callconv(.c) Dpy, "XOpenDisplay") orelse return error.NoX11;
    const close: *const fn (Display) callconv(.c) c_int = lib.lookup(*const fn (Display) callconv(.c) c_int, "XCloseDisplay") orelse return error.NoX11;
    const rootOf: *const fn (Display) callconv(.c) u64 = lib.lookup(*const fn (Display) callconv(.c) u64, "XDefaultRootWindow") orelse return error.NoX11;
    const keycodeOf: *const fn (Display, u64) callconv(.c) u8 = lib.lookup(*const fn (Display, u64) callconv(.c) u8, "XKeysymToKeycode") orelse return error.NoX11;
    const Grab = *const fn (Display, c_int, u32, u64, c_int, c_int, c_int) callconv(.c) c_int;
    const grab: Grab = lib.lookup(Grab, "XGrabKey") orelse return error.NoX11;
    const ungrab: *const fn (Display, c_int, u32, u64) callconv(.c) c_int = lib.lookup(*const fn (Display, c_int, u32, u64) callconv(.c) c_int, "XUngrabKey") orelse return error.NoX11;
    const fdOf: *const fn (Display) callconv(.c) c_int = lib.lookup(*const fn (Display) callconv(.c) c_int, "XConnectionNumber") orelse return error.NoX11;
    const pending: *const fn (Display) callconv(.c) c_int = lib.lookup(*const fn (Display) callconv(.c) c_int, "XPending") orelse return error.NoX11;
    const next: *const fn (Display, *XEvent) callconv(.c) c_int = lib.lookup(*const fn (Display, *XEvent) callconv(.c) c_int, "XNextEvent") orelse return error.NoX11;
    const sync: *const fn (Display, c_int) callconv(.c) c_int = lib.lookup(*const fn (Display, c_int) callconv(.c) c_int, "XSync") orelse return error.NoX11;

    const dpy: Display = open(null) orelse return error.NoDisplay;
    defer _ = close(dpy);
    const root = rootOf(dpy);
    lock();
    backend_ok = true;
    var seen: u32 = gen +% 1;
    unlock();

    var keys: [max_binds]struct { index: u8, keycode: u32, mods: u32 } = undefined;
    var keys_n: usize = 0;

    while (true) {
        lock();
        const g = gen;
        const specs = specs_buf[0..specs_n];
        unlock();

        if (g != seen) {
            seen = g;
            // Solta as teclas de antes, registra as de agora.
            for (keys[0..keys_n]) |k| {
                for ([_]u32{ 0, LockMask, Mod2Mask, LockMask | Mod2Mask }) |lk| {
                    _ = ungrab(dpy, @intCast(k.keycode), k.mods | lk, root);
                }
            }
            keys_n = 0;
            for (specs) |s| {
                if (keys_n >= max_binds) break;
                const ks = toKeysym(s.key) orelse continue;
                const kc: u32 = keycodeOf(dpy, ks);
                // Tecla que este teclado não tem (layout sem o desenho): pula.
                if (kc == 0) continue;
                var mods: u32 = 0;
                if (s.shift) mods |= ShiftMask;
                if (s.ctrl) mods |= ControlMask;
                if (s.alt) mods |= Mod1Mask;
                if (s.super) mods |= Mod4Mask;
                // Presa também com Caps Lock e Num Lock apertados: quatro
                // combinações por tecla.
                for ([_]u32{ 0, LockMask, Mod2Mask, LockMask | Mod2Mask }) |lk| {
                    _ = grab(dpy, @intCast(kc), mods | lk, root, 0, 0, 0);
                }
                keys[keys_n] = .{ .index = s.index, .keycode = kc, .mods = mods };
                keys_n += 1;
            }
            _ = sync(dpy, 0);
        }

        while (pending(dpy) > 0) {
            var ev: XEvent = undefined;
            _ = next(dpy, &ev);
            if (ev.type != XKeyPress) continue;
            for (keys[0..keys_n]) |k| {
                if (k.keycode != ev.xkey.keycode) continue;
                const state = ev.xkey.state;
                var want: u32 = 0;
                if (state & ShiftMask != 0) want |= ShiftMask;
                if (state & ControlMask != 0) want |= ControlMask;
                if (state & Mod1Mask != 0) want |= Mod1Mask;
                if (state & Mod4Mask != 0) want |= Mod4Mask;
                if (want == k.mods) fire(k.index);
            }
        }

        // A lista muda sem evento: espera pouco e olha de novo.
        var fds = [_]std.posix.pollfd{.{ .fd = fdOf(dpy), .events = std.posix.POLL.IN, .revents = 0 }};
        _ = std.posix.poll(&fds, 100) catch 0;
    }
}

fn toKeysym(key: c_int) ?u64 {
    if (key >= imgui.ImGuiKey_A and key <= imgui.ImGuiKey_Z) return @intCast('a' + key - imgui.ImGuiKey_A);
    if (key >= imgui.ImGuiKey_0 and key <= imgui.ImGuiKey_9) return @intCast('0' + key - imgui.ImGuiKey_0);
    if (key >= imgui.ImGuiKey_F1 and key <= imgui.ImGuiKey_F24) return 0xffbe + @as(u64, @intCast(key - imgui.ImGuiKey_F1)); // XK_F1…
    return switch (key) {
        imgui.ImGuiKey_Enter => 0xff0d, // XK_Return
        imgui.ImGuiKey_Space => 0x20, // XK_space
        imgui.ImGuiKey_Tab => 0xff09, // XK_Tab
        imgui.ImGuiKey_Backspace => 0xff08, // XK_BackSpace
        imgui.ImGuiKey_Delete => 0xffff, // XK_Delete
        imgui.ImGuiKey_Insert => 0xff63, // XK_Insert
        imgui.ImGuiKey_Home => 0xff50, // XK_Home
        imgui.ImGuiKey_End => 0xff57, // XK_End
        imgui.ImGuiKey_PageUp => 0xff55, // XK_Prior
        imgui.ImGuiKey_PageDown => 0xff56, // XK_Next
        imgui.ImGuiKey_UpArrow => 0xff52, // XK_Up
        imgui.ImGuiKey_DownArrow => 0xff54, // XK_Down
        imgui.ImGuiKey_LeftArrow => 0xff51, // XK_Left
        imgui.ImGuiKey_RightArrow => 0xff53, // XK_Right
        imgui.ImGuiKey_Comma => 0x2c, // XK_comma
        imgui.ImGuiKey_Period => 0x2e, // XK_period
        imgui.ImGuiKey_Slash => 0x2f, // XK_slash
        imgui.ImGuiKey_Semicolon => 0x3b, // XK_semicolon
        imgui.ImGuiKey_Minus => 0x2d, // XK_minus
        imgui.ImGuiKey_Equal => 0x3d, // XK_equal
        else => null,
    };
}
