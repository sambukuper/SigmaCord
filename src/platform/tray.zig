//! O ícone na bandeja do sistema, pelo SDL_CreateTray. Só existe com a janela
//! escondida: com ela aberta nada fica carregado nem acordando o app.
//!
//! No Linux ele mora em outro processo (`--tray-helper`). O protocolo não tem como
//! tirar um ícone do registro: ele só sai quando a conexão D-Bus de quem o criou
//! fecha. No mesmo processo, cada ida à bandeja somaria um ícone; além disso o GTK
//! e as 20 voltas por segundo para atendê-lo ficariam no app para sempre.
const std = @import("std");
const c = @import("c");
const sys = @import("sys.zig");
const platform = @import("window.zig");

var tray: ?*c.SDL_Tray = null;
var helper: ?*c.SDL_Process = null;
var reader: ?*c.SDL_Thread = null;
/// Fomos nós que mandamos o processo do ícone embora.
var closing = std.atomic.Value(bool).init(false);
var wake_type: u32 = 0;
/// O QA roda sem bandeja de verdade: aqui ele escolhe se ela "abriu".
pub var fake: ?bool = null;
var fake_on = false;

// O recado do processo do ícone para o app, um byte de cada vez.
const msg_ready = 'r';
const msg_failed = 'x';
const msg_open = 'o';
const msg_quit = 'q';

pub fn active() bool {
    return tray != null or helper != null or fake_on;
}

fn onOpen(_: ?*anyopaque, _: ?*c.SDL_TrayEntry) callconv(.c) void {
    platform.Window.wake(wake_type, .show);
}

fn onQuit(_: ?*anyopaque, _: ?*c.SDL_TrayEntry) callconv(.c) void {
    platform.Window.wake(wake_type, .quit);
}

/// Tem bandeja para mostrar o ícone? (No QA, o que ele escolheu.)
pub fn hostAvailable() bool {
    return fake orelse sys.trayHostAvailable();
}

/// Cria o ícone com o menu. Um ícone sem menu não teria como voltar.
fn build(open_label: [*:0]const u8, quit_label: [*:0]const u8, on_open: c.SDL_TrayCallback, on_quit: c.SDL_TrayCallback) ?*c.SDL_Tray {
    const icon = platform.decodeIcon(platform.icon_32);
    defer if (icon) |i| c.SDL_DestroySurface(i);
    const t = c.SDL_CreateTray(icon, "SigmaCord") orelse {
        std.log.info("bandeja: SDL_CreateTray falhou: {s}", .{c.SDL_GetError()});
        return null;
    };
    const menu = c.SDL_CreateTrayMenu(t);
    const open_entry = if (menu != null) c.SDL_InsertTrayEntryAt(menu, -1, open_label, c.SDL_TRAYENTRY_BUTTON) else null;
    const quit_entry = if (menu != null) c.SDL_InsertTrayEntryAt(menu, -1, quit_label, c.SDL_TRAYENTRY_BUTTON) else null;
    if (open_entry == null or quit_entry == null) {
        std.log.info("bandeja: não deu para montar o menu: {s}", .{c.SDL_GetError()});
        c.SDL_DestroyTray(t);
        return null;
    }
    c.SDL_SetTrayEntryCallback(open_entry, on_open, null);
    c.SDL_SetTrayEntryCallback(quit_entry, on_quit, null);
    return t;
}

/// Põe o ícone. Falso: não tem como; fechar precisa sair de verdade.
pub fn show(wake: u32, open_label: [*:0]const u8, quit_label: [*:0]const u8) bool {
    if (active()) return true;
    if (fake) |f| {
        fake_on = f;
        return f;
    }
    if (!sys.trayHostAvailable()) {
        std.log.info("bandeja: nenhum painel para mostrar o ícone neste sistema", .{});
        return false;
    }
    wake_type = wake;
    if (!sys.windows) return startHelper(open_label, quit_label);
    tray = build(open_label, quit_label, onOpen, onQuit);
    return tray != null;
}

pub fn hide() void {
    fake_on = false;
    if (tray) |t| c.SDL_DestroyTray(t);
    tray = null;
    stopHelper();
}

// --- O app, falando com o processo do ícone -------------------------------------

fn startHelper(open_label: [*:0]const u8, quit_label: [*:0]const u8) bool {
    sys.closeOnExec();
    // Pelo nome de verdade, para aparecer como sigmacord na lista de processos.
    // Se o arquivo foi trocado com o app aberto (atualização), o caminho do kernel ainda roda.
    var pb: [1024]u8 = undefined;
    const n = c.readlink("/proc/self/exe", &pb, pb.len - 1);
    const named = n > 0 and !std.mem.endsWith(u8, pb[0..@intCast(n)], " (deleted)");
    if (named) pb[@intCast(n)] = 0;
    const self: [*:0]const u8 = if (named) @ptrCast(&pb) else "/proc/self/exe";
    var args = [_:null]?[*:0]const u8{ self, "--tray-helper", open_label, quit_label };
    const props = c.SDL_CreateProperties();
    if (props == 0) return false;
    defer c.SDL_DestroyProperties(props);
    _ = c.SDL_SetPointerProperty(props, c.SDL_PROP_PROCESS_CREATE_ARGS_POINTER, @ptrCast(&args));
    _ = c.SDL_SetNumberProperty(props, c.SDL_PROP_PROCESS_CREATE_STDIN_NUMBER, c.SDL_PROCESS_STDIO_APP);
    _ = c.SDL_SetNumberProperty(props, c.SDL_PROP_PROCESS_CREATE_STDOUT_NUMBER, c.SDL_PROCESS_STDIO_APP);
    _ = c.SDL_SetNumberProperty(props, c.SDL_PROP_PROCESS_CREATE_STDERR_NUMBER, c.SDL_PROCESS_STDIO_NULL);
    const proc = c.SDL_CreateProcessWithProperties(props) orelse {
        std.log.info("bandeja: não abriu o processo do ícone: {s}", .{c.SDL_GetError()});
        return false;
    };
    closing.store(false, .release);
    helper = proc;
    // A janela só some com o ícone de pé, senão não haveria como voltar.
    if (!waitReady(proc)) {
        stopHelper();
        return false;
    }
    reader = c.SDL_CreateThread(readerMain, "bandeja", proc);
    if (reader == null) {
        stopHelper();
        return false;
    }
    return true;
}

fn waitReady(proc: *c.SDL_Process) bool {
    const out = c.SDL_GetProcessOutput(proc);
    // A primeira vez carrega o GTK do disco.
    var tries: u32 = 0;
    while (tries < 500) : (tries += 1) {
        var b: u8 = 0;
        if (c.SDL_ReadIO(out, &b, 1) == 1) return b == msg_ready;
        if (c.SDL_GetIOStatus(out) != c.SDL_IO_STATUS_NOT_READY) return false;
        c.SDL_Delay(10);
    }
    std.log.info("bandeja: o processo do ícone não respondeu", .{});
    return false;
}

fn readerMain(data: ?*anyopaque) callconv(.c) c_int {
    const proc: *c.SDL_Process = @ptrCast(data.?);
    const out = c.SDL_GetProcessOutput(proc);
    const fd = c.SDL_GetNumberProperty(c.SDL_GetIOProperties(out), c.SDL_PROP_IOSTREAM_FILE_DESCRIPTOR_NUMBER, -1);
    while (true) {
        var b: u8 = 0;
        if (c.SDL_ReadIO(out, &b, 1) == 1) {
            if (b == msg_open) platform.Window.wake(wake_type, .show);
            if (b == msg_quit) platform.Window.wake(wake_type, .quit);
            continue;
        }
        if (c.SDL_GetIOStatus(out) != c.SDL_IO_STATUS_NOT_READY) break;
        if (fd < 0) {
            c.SDL_Delay(50);
            continue;
        }
        var fds = [1]sys.PollFd{.{ .fd = @intCast(fd), .events = c.POLLIN, .revents = 0 }};
        sys.poll(&fds, 1, -1);
    }
    // O ícone sumiu sem ninguém pedir: a janela volta, nunca fica um processo invisível.
    if (!closing.load(.acquire)) platform.Window.wake(wake_type, .show);
    return 0;
}

fn stopHelper() void {
    const proc = helper orelse return;
    closing.store(true, .release);
    // Fechar a entrada é o recado para sair, e o ícone sai do painel junto.
    if (c.SDL_GetProcessInput(proc)) |stream| _ = c.SDL_CloseIO(stream);
    var code: c_int = 0;
    var tries: u32 = 0;
    while (!c.SDL_WaitProcess(proc, false, &code)) : (tries += 1) {
        if (tries == 100) {
            _ = c.SDL_KillProcess(proc, true);
            _ = c.SDL_WaitProcess(proc, true, &code);
            break;
        }
        c.SDL_Delay(2);
    }
    if (reader) |t| c.SDL_WaitThread(t, null);
    reader = null;
    c.SDL_DestroyProcess(proc);
    helper = null;
}

// --- O processo do ícone --------------------------------------------------------

fn say(b: u8) void {
    var one = [1]u8{b};
    _ = c.write(1, &one, 1);
}

fn helperOpen(_: ?*anyopaque, _: ?*c.SDL_TrayEntry) callconv(.c) void {
    say(msg_open);
}

fn helperQuit(_: ?*anyopaque, _: ?*c.SDL_TrayEntry) callconv(.c) void {
    say(msg_quit);
}

/// Mostra o ícone até a entrada fechar: o app mandou sair ou morreu, até com SIGKILL.
pub fn helperMain(open_label: [*:0]const u8, quit_label: [*:0]const u8) noreturn {
    const t = if (c.SDL_Init(c.SDL_INIT_EVENTS)) build(open_label, quit_label, helperOpen, helperQuit) else null;
    if (t == null) {
        say(msg_failed);
        std.process.exit(1);
    }
    say(msg_ready);
    var fds = [1]sys.PollFd{.{ .fd = 0, .events = c.POLLIN, .revents = 0 }};
    while (true) {
        fds[0].revents = 0;
        sys.poll(&fds, 1, 50);
        if (fds[0].revents != 0) break;
        c.SDL_UpdateTrays();
    }
    // Apaga a cópia do ícone em /tmp; o resto o sistema limpa.
    c.SDL_DestroyTray(t);
    std.process.exit(0);
}

/// Para a página de configurações: a resposta de há pouco (no máximo uma
/// pergunta a cada 5 s, já que a página redesenha o tempo todo).
var host_ms: i64 = -10_000;
var host_ok = true;

pub fn hostSeen(now_ms: i64) bool {
    if (now_ms - host_ms >= 5_000) {
        host_ms = now_ms;
        host_ok = hostAvailable();
    }
    return host_ok;
}
