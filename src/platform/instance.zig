//! Um SigmaCord por pasta de configurações: um segundo chamado acorda o primeiro
//! (que pode estar escondido na bandeja) em vez de abrir outra conexão.
//!
//! A exclusão é uma trava de arquivo (`instance.lock`, sys.lockFile): atômica, e
//! o sistema solta se o processo morrer. O aviso vai por TCP em 127.0.0.1, numa
//! porta livre escrita em `instance.port` com um segredo: o mesmo código nos dois
//! sistemas, e nenhum outro programa consegue chamar a janela.
const std = @import("std");
const c = @import("c");
const sys = @import("sys.zig");
const fsutil = @import("fsutil.zig");
const platform = @import("window.zig");
const Instance = @import("../core/janela.zig").Instance;

pub const Outcome = enum {
    /// Somos o primeiro.
    primary,
    /// Não deu para travar (pasta sem escrita…): abre sem a proteção, em vez de
    /// não abrir.
    alone,
    /// Havia outro, e ele atendeu: é só sair.
    signaled,
    /// Tem um com a trava que não atende nem termina.
    stuck,
};

/// Quanto esperar por um primeiro que ainda está abrindo ou fechando. Passa do
/// vigia de 3 s de main.zig, depois do qual quem está saindo já morreu.
const wait_ms: u64 = 4000;
/// Depois de um reinício, o antigo pode demorar um pouco a soltar.
const restart_wait_ms: u64 = 5000;

var lock: ?sys.FileLock = null;
var listener: sys.Socket = sys.no_socket;
var stop_pipe: sys.Wake = .{};
var thread: ?*c.SDL_Thread = null;
var wake_type: u32 = 0;
var nonce: [Instance.nonce_len]u8 = undefined;

/// Antes de abrir a janela. `restarted`: o processo antigo está fechando para
/// este tomar o lugar, então não adianta chamar por ele: só espera a trava.
pub fn begin(restarted: bool) Outcome {
    var lb: [512]u8 = undefined;
    const dir = fsutil.configPath(&lb, "") orelse return .alone;
    if (!fsutil.ensureDir(dir)) return .alone;
    var pb: [512]u8 = undefined;
    const path = fsutil.configPath(&pb, "instance.lock") orelse return .alone;
    const deadline = c.SDL_GetTicks() + (if (restarted) restart_wait_ms else wait_ms);
    while (true) {
        switch (sys.lockFile(path.ptr)) {
            .got => |l| {
                lock = l;
                publish();
                return .primary;
            },
            .failed => return .alone,
            .held => {},
        }
        if (!restarted and signal()) return .signaled;
        if (c.SDL_GetTicks() >= deadline) break;
        c.SDL_Delay(100);
    }
    // O reinício desistiu e o antigo continua de pé: que ele apareça.
    return if (signal()) .signaled else .stuck;
}

/// Abre a porta e escreve onde ela está. Quem chamar antes de `listen` fica na
/// fila do sistema.
fn publish() void {
    var port: u16 = 0;
    listener = sys.tcpListenLocal(&port) orelse return;
    var state: u64 = c.SDL_GetTicksNS() ^ @intFromPtr(&port);
    const hex = "0123456789abcdef";
    for (&nonce) |*ch| ch.* = hex[@intCast(c.SDL_rand_r(&state, hex.len))];
    var tb: [64]u8 = undefined;
    const text = std.fmt.bufPrint(&tb, "{d} {s}\n", .{ port, nonce }) catch return;
    var pb: [512]u8 = undefined;
    const path = fsutil.configPath(&pb, "instance.port") orelse return;
    _ = fsutil.writePrivate(path, text);
}

/// Avisa o primeiro. Verdadeiro só com a resposta dele.
fn signal() bool {
    var pb: [512]u8 = undefined;
    const path = fsutil.configPath(&pb, "instance.port") orelse return false;
    var size: usize = 0;
    const data = c.SDL_LoadFile(path.ptr, &size) orelse return false;
    defer c.SDL_free(data);
    const info = Instance.parse(@as([*]const u8, @ptrCast(data))[0..size]) orelse return false;
    const s = sys.tcpConnectLocal(info.port) orelse return false;
    defer sys.closeSocket(s);
    sys.allowForeground();
    sys.tcpSend(s, info.nonce);
    var buf: [8]u8 = undefined;
    return std.mem.eql(u8, sys.tcpRecv(s, &buf, 1000), "ok");
}

/// Com o app de pé: atende os próximos chamados (`.show` no laço principal).
pub fn listen(wake: u32) void {
    if (!sys.valid(listener)) return;
    wake_type = wake;
    stop_pipe = sys.Wake.open();
    thread = c.SDL_CreateThread(listenMain, "instance", null);
}

fn listenMain(_: ?*anyopaque) callconv(.c) c_int {
    while (true) {
        var fds = [2]sys.PollFd{
            .{ .fd = listener, .events = c.POLLIN, .revents = 0 },
            .{ .fd = stop_pipe.read, .events = c.POLLIN, .revents = 0 },
        };
        sys.poll(&fds, 2, -1);
        if (fds[1].revents != 0) return 0;
        if (fds[0].revents == 0) continue;
        const client = sys.tcpAccept(listener) orelse continue;
        defer sys.closeSocket(client);
        var buf: [Instance.nonce_len + 1]u8 = undefined;
        if (!std.mem.eql(u8, sys.tcpRecv(client, &buf, 500), &nonce)) continue;
        sys.tcpSend(client, "ok");
        platform.Window.wake(wake_type, .show);
    }
}

/// Começo do encerramento: quem chamar agora espera a trava em vez de receber
/// um "ok" de quem já não vai abrir janela nenhuma.
pub fn stopListening() void {
    if (thread) |t| {
        sys.wakeSignal(stop_pipe.write);
        c.SDL_WaitThread(t, null);
        thread = null;
        stop_pipe.close();
    }
    if (sys.valid(listener)) sys.closeSocket(listener);
    listener = sys.no_socket;
}

/// Fim do encerramento: daqui em diante outro SigmaCord já pode assumir.
pub fn release() void {
    stopListening();
    if (lock) |l| sys.unlockFile(l);
    lock = null;
}
