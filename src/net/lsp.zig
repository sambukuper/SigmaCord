//! Cliente LSP: abre os servidores de linguagem como processos filhos e fala
//! com eles por stdin/stdout. Tudo roda numa thread só, com os fluxos do
//! SDL_Process sem bloqueio; a interface só copia dados sob um mutex.
//!
//! Sem uso não custa nada: a thread nasce no primeiro bloco de código de uma
//! linguagem ligada e morre junto com o último servidor (60 s sem digitar).
//!
//! Segurança (o app guarda o token do Discord): o filho recebe um ambiente
//! limpo, roda numa pasta vazia e sem shell, e o único texto enviado é o do
//! bloco que a pessoa está digitando. Nada disso é uma jaula: o servidor é um
//! programa que roda como a pessoa, por isso só sobe depois que ela ligou.
const std = @import("std");
const builtin = @import("builtin");
const sys = @import("../platform/sys.zig");
const c = @import("c");
const L = @import("../core/lsp.zig");

const gpa = std.heap.c_allocator;

/// Tempos e limites. O QA encurta para não esperar um minuto.
pub const Tuning = struct {
    idle_ms: u64 = 60_000,
    debounce_ms: u64 = 300,
    init_timeout_ms: u64 = 30_000,
    backoff_ms: [3]u64 = .{ 1_000, 4_000, 15_000 },
    /// Depois disso rodando bem, as quedas anteriores não contam mais.
    healthy_ms: u64 = 30_000,
    /// O servidor parou de ler e o que temos para mandar não anda.
    write_stall_ms: u64 = 10_000,
    /// Saída no minuto: acima disso o servidor é derrubado.
    flood_bytes: u64 = 32 * 1024 * 1024,
};
pub var tuning: Tuning = .{};

/// Parada normal e ao fechar o app: resposta ao `shutdown`, saída depois do
/// `exit`, SIGTERM e SIGKILL. Ao fechar, a soma cabe folgada no prazo do
/// vigia de main.zig (3 s), mesmo com o servidor travado.
const Stops = struct { shutdown_ms: u64, exit_ms: u64, term_ms: u64, kill_ms: u64 };
const stops_normal: Stops = .{ .shutdown_ms = 1500, .exit_ms = 1000, .term_ms = 500, .kill_ms = 500 };
const stops_quit: Stops = .{ .shutdown_ms = 250, .exit_ms = 200, .term_ms = 100, .kill_ms = 200 };

/// O que pode ficar esperando para ir ao servidor.
const max_outgoing: usize = 1024 * 1024;
/// Servidores ao mesmo tempo (o mais antigo sai para dar lugar).
const max_servers = 4;
/// Linguagens com estado guardado para a interface.
const max_status = 24;

// --- O que a interface vê ------------------------------------------------------

pub const Spec = struct {
    /// A chave da linguagem (zig, python…, ou a de um plugin).
    lang: L.Short = .{},
    language_id: L.Short = .{},
    ext: L.Short = .{},
    cmd: L.Command = .{},
};

pub const State = enum(u8) { off, starting, ready, retrying, stopping, failed };
pub const Failure = enum(u8) { none, spawn, crashed, init_timeout, protocol, write_stall, flood };

pub const Status = struct {
    lang: L.Short = .{},
    state: State = .off,
    failure: Failure = .none,
    exit_code: i32 = 0,
    /// Quedas seguidas; o limite é `tuning.backoff_ms.len`.
    attempts: u8 = 0,
    pid: i64 = 0,
};

pub const Diagnostics = struct {
    lang: L.Short = .{},
    items: [L.max_diags]L.Diag = undefined,
    n: usize = 0,
    /// Quantos o servidor mandou (pode ser mais que `n`).
    total: usize = 0,
};

// --- Compartilhado com a interface (sob `mutex`) ---------------------------------

const Shared = struct {
    // Interface -> thread.
    want_gen: u64 = 0,
    want_active: bool = false,
    want: Spec = .{},
    want_text: [L.max_doc]u8 = undefined,
    want_len: usize = 0,
    stop_gen: u32 = 0,
    // Thread -> interface.
    diag_gen: u32 = 0,
    diags: Diagnostics = .{},
    statuses: [max_status]Status = @splat(.{}),
    n_status: usize = 0,
    status_gen: u32 = 0,
    /// A thread está de pé (e vai olhar os pedidos).
    alive: bool = false,
};

var sh: Shared = .{};
var mutex: ?*c.SDL_Mutex = null;
var thread: ?*c.SDL_Thread = null;
var quit = std.atomic.Value(bool).init(false);
var wake_fn: ?*const fn () void = null;
/// Pasta vazia onde o servidor roda.
var scratch_buf: [512:0]u8 = @splat(0);

fn lock() void {
    c.SDL_LockMutex(mutex);
}
fn unlock() void {
    c.SDL_UnlockMutex(mutex);
}

// --- Interface -------------------------------------------------------------------

/// Sem criar nada: só guarda como acordar a tela e onde fica a pasta vazia.
pub fn setup(wake: *const fn () void, scratch: []const u8) void {
    wake_fn = wake;
    const n = @min(scratch.len, scratch_buf.len);
    @memcpy(scratch_buf[0..n], scratch[0..n]);
    scratch_buf[n] = 0;
}

/// A thread está rodando (com zero servidores e nada a fazer, ela sai sozinha).
pub fn running() bool {
    if (mutex == null) return false;
    lock();
    defer unlock();
    return sh.alive;
}

/// O bloco sob o cursor. `fresh`: é outro bloco, os erros antigos somem já.
pub fn setDoc(spec: *const Spec, text: []const u8, fresh: bool) void {
    if (quit.load(.acquire) or text.len > L.max_doc) return;
    if (mutex == null) mutex = c.SDL_CreateMutex() orelse return;
    lock();
    sh.want = spec.*;
    sh.want_active = true;
    @memcpy(sh.want_text[0..text.len], text);
    sh.want_len = text.len;
    sh.want_gen +%= 1;
    if (fresh) clearDiagsLocked();
    const start = !sh.alive;
    if (start) sh.alive = true;
    unlock();
    if (start) startThread();
}

fn startThread() void {
    // A thread anterior já terminou (foi ela que desmarcou `alive`).
    if (thread) |t| c.SDL_WaitThread(t, null);
    thread = c.SDL_CreateThread(threadMain, "lsp", null);
    if (thread == null) {
        lock();
        sh.alive = false;
        unlock();
    }
}

/// O cursor saiu do bloco (ou a mensagem foi enviada): nada mais vai para o servidor.
pub fn clearDoc() void {
    if (mutex == null) return;
    lock();
    defer unlock();
    sh.want_active = false;
    sh.want_gen +%= 1;
    clearDiagsLocked();
}

fn clearDiagsLocked() void {
    if (sh.diags.n == 0 and sh.diags.total == 0) return;
    sh.diags.n = 0;
    sh.diags.total = 0;
    sh.diag_gen +%= 1;
}

/// A configuração mudou (comando, interruptor, plugin): para tudo e esquece as
/// falhas. Quem ainda valer sobe de novo no próximo pedido.
pub fn stopAll() void {
    if (mutex == null) return;
    lock();
    defer unlock();
    sh.stop_gen +%= 1;
    sh.want_active = false;
    sh.want_gen +%= 1;
    clearDiagsLocked();
    for (sh.statuses[0..sh.n_status]) |*st| {
        if (st.state == .failed or st.state == .retrying) {
            st.state = .off;
            st.failure = .none;
            st.attempts = 0;
        }
    }
    sh.status_gen +%= 1;
}

/// Botão "Tentar de novo".
pub fn retry(lang: []const u8) void {
    if (mutex == null) return;
    lock();
    defer unlock();
    for (sh.statuses[0..sh.n_status]) |*st| {
        if (!st.lang.eql(lang) or st.state != .failed) continue;
        st.state = .off;
        st.failure = .none;
        st.attempts = 0;
        sh.status_gen +%= 1;
    }
}

pub fn statusOf(lang: []const u8) Status {
    if (mutex == null) return .{ .lang = L.Short.of(lang) };
    lock();
    defer unlock();
    for (sh.statuses[0..sh.n_status]) |*st| {
        if (st.lang.eql(lang)) return st.*;
    }
    return .{ .lang = L.Short.of(lang) };
}

pub fn statusGen() u32 {
    if (mutex == null) return 0;
    lock();
    defer unlock();
    return sh.status_gen;
}

/// Copia os erros se mudaram desde `seen`. false = nada novo.
pub fn copyDiags(seen: *u32, out: *Diagnostics) bool {
    if (mutex == null) return false;
    lock();
    defer unlock();
    if (seen.* == sh.diag_gen) return false;
    seen.* = sh.diag_gen;
    out.lang = sh.diags.lang;
    out.n = sh.diags.n;
    out.total = sh.diags.total;
    @memcpy(out.items[0..out.n], sh.diags.items[0..out.n]);
    return true;
}

/// Fechando o app: encerra os filhos (no fim, à força) e espera a thread.
pub fn shutdown() void {
    quit.store(true, .release);
    if (thread) |t| {
        c.SDL_WaitThread(t, null);
        thread = null;
    }
    scanJoin();
    if (mutex) |m| {
        c.SDL_DestroyMutex(m);
        mutex = null;
    }
}

// --- A procura no PATH ------------------------------------------------------------

/// Um executável conhecido encontrado no PATH. Só existe: não foi executado.
pub const Found = struct { exe: u8 = 0, path_len: u16 = 0, path: [512]u8 = undefined };

var scan_thread: ?*c.SDL_Thread = null;
var scan_done = std.atomic.Value(bool).init(false);
var scan_results: [L.known.len]Found = @splat(.{});

/// Procura em outra thread: uma pasta de rede no PATH não trava a tela.
pub fn scanStart() void {
    if (scan_thread != null and !scan_done.load(.acquire)) return;
    if (quit.load(.acquire)) return;
    scanJoin();
    scan_done.store(false, .release);
    scan_thread = c.SDL_CreateThread(scanMain, "lsp-path", null);
    if (scan_thread == null) scan_done.store(true, .release);
}

fn scanJoin() void {
    if (scan_thread) |t| c.SDL_WaitThread(t, null);
    scan_thread = null;
}

/// O resultado de uma linguagem (`known[i]`), quando a procura terminou.
pub fn scanResult(i: usize) ?*const Found {
    if (!scan_done.load(.acquire)) return null;
    return if (scan_results[i].path_len > 0) &scan_results[i] else null;
}

/// Encerrada a procura, nada mais escreve em `scan_results`.
pub fn scanFinished() bool {
    return scan_done.load(.acquire);
}

fn scanMain(_: ?*anyopaque) callconv(.c) c_int {
    for (L.known, 0..) |k, i| {
        scan_results[i] = .{};
        for (k.exes, 0..) |exe, j| {
            if (findOnPath(exe.name, &scan_results[i])) {
                scan_results[i].exe = @intCast(j);
                break;
            }
        }
    }
    scan_done.store(true, .release);
    if (wake_fn) |w| w();
    return 0;
}

/// Só caminhos absolutos do PATH (um "." ou vazio faria a pasta atual valer).
fn findOnPath(name: []const u8, out: *Found) bool {
    const path = std.mem.span(c.SDL_getenv("PATH") orelse return false);
    var it = std.mem.tokenizeScalar(u8, path, L.path_sep);
    const exts: []const []const u8 = if (builtin.os.tag == .windows) &.{ ".exe", ".cmd", ".bat" } else &.{""};
    while (it.next()) |dir| {
        if (!std.fs.path.isAbsolute(dir)) continue;
        for (exts) |ext| {
            var buf: [512]u8 = undefined;
            const full = std.fmt.bufPrintSentinel(&buf, "{s}{c}{s}{s}", .{ dir, std.fs.path.sep, name, ext }, 0) catch continue;
            if (!isExecutable(full)) continue;
            @memcpy(out.path[0..full.len], full);
            out.path_len = @intCast(full.len);
            return true;
        }
    }
    return false;
}

fn isExecutable(path: [:0]const u8) bool {
    var info: c.SDL_PathInfo = undefined;
    if (!c.SDL_GetPathInfo(path.ptr, &info) or info.type != c.SDL_PATHTYPE_FILE) return false;
    if (builtin.os.tag == .windows) return true;
    return c.access(path.ptr, c.X_OK) == 0;
}

// --- A thread ----------------------------------------------------------------------

const Phase = enum {
    /// Sem processo: esperando a próxima tentativa.
    retry_wait,
    init,
    ready,
    /// Parando: esperando a resposta do `shutdown`, a saída depois do `exit`,
    /// e depois de cada sinal.
    shut_wait,
    exit_wait,
    term_wait,
    kill_wait,
};

const Server = struct {
    spec: Spec,
    proc: ?*c.SDL_Process = null,
    stdin: ?*c.SDL_IOStream = null,
    stdout: ?*c.SDL_IOStream = null,
    phase: Phase = .retry_wait,
    deadline: u64 = 0,
    out: std.ArrayList(u8) = .empty,
    out_at: usize = 0,
    framer: L.Framer = .{},
    next_id: i64 = 1,
    init_id: i64 = 0,
    shutdown_id: i64 = 0,
    doc_open: bool = false,
    version: i64 = 0,
    dirty: bool = false,
    dirty_at: u64 = 0,
    close_doc: bool = false,
    fails: u8 = 0,
    retry_at: u64 = 0,
    ready_at: u64 = 0,
    write_stuck_since: u64 = 0,
    window_start: u64 = 0,
    window_bytes: u64 = 0,
    /// Depois do `exit` enfileirado, fecha o stdin quando o que falta sair.
    close_stdin: bool = false,

    fn deinit(s: *Server) void {
        s.out.deinit(gpa);
        s.framer.deinit(gpa);
    }

    fn uri(s: *const Server, buf: []u8) []const u8 {
        return L.documentUri(buf, std.mem.sliceTo(&scratch_buf, 0), s.spec.ext.slice());
    }
};

// Só a thread mexe nestes.
var servers: [max_servers]?*Server = @splat(null);
var seen_want: u64 = 0;
var seen_stop: u32 = 0;
var cur_active = false;
var cur_spec: Spec = .{};
var cur_text: [L.max_doc]u8 = undefined;
var cur_len: usize = 0;
var last_activity: u64 = 0;
var quitting = false;
var diag_scratch: [L.max_diags]L.Diag = undefined;
var wake_pending = false;
var last_wake: u64 = 0;

fn threadMain(_: ?*anyopaque) callconv(.c) c_int {
    quitting = false;
    last_activity = c.SDL_GetTicks();
    while (true) {
        const now = c.SDL_GetTicks();
        takeRequests(now);
        if (quit.load(.acquire) and !quitting) {
            quitting = true;
            cur_active = false;
            for (&servers) |*slot| if (slot.*) |s| beginStop(s, slot, now);
        }
        // Sem digitar há um minuto: o servidor sai (e a thread, sem ninguém).
        if (!quitting and now -| last_activity > tuning.idle_ms) {
            for (&servers) |*slot| if (slot.*) |s| beginStop(s, slot, now);
        }
        var busy = false;
        for (&servers) |*slot| if (slot.*) |s| {
            if (pump(s, slot, now)) busy = true;
        };
        flushWake(now);
        if (isEmpty() and tryFinish()) {
            if (wake_fn) |w| w();
            return 0;
        }
        // Sem nada acontecendo são 40 acordadas por segundo, e só com servidor de pé.
        c.SDL_Delay(if (busy) 2 else 25);
    }
}

fn isEmpty() bool {
    for (servers) |s| if (s != null) return false;
    return true;
}

/// Sem servidores e sem pedidos novos: a thread acaba. O teste é sob o mutex,
/// o mesmo em que `setDoc` decide se precisa de uma thread nova.
fn tryFinish() bool {
    lock();
    defer unlock();
    if (!quit.load(.acquire) and (sh.want_gen != seen_want or sh.stop_gen != seen_stop)) return false;
    sh.alive = false;
    return true;
}

fn takeRequests(now: u64) void {
    lock();
    const changed = sh.want_gen != seen_want;
    const stop = sh.stop_gen != seen_stop;
    seen_want = sh.want_gen;
    seen_stop = sh.stop_gen;
    if (changed) {
        cur_active = sh.want_active;
        cur_spec = sh.want;
        cur_len = sh.want_len;
        @memcpy(cur_text[0..cur_len], sh.want_text[0..cur_len]);
    }
    unlock();
    if (stop) for (&servers) |*slot| if (slot.*) |s| beginStop(s, slot, now);
    if (!changed or quit.load(.acquire)) return;
    last_activity = now;
    if (cur_active) target(now) else closeDocs(null);
}

fn closeDocs(except: ?*Server) void {
    for (servers) |slot| if (slot) |s| {
        if (s == except) continue;
        s.dirty = false;
        if (s.doc_open) s.close_doc = true;
    };
}

fn stopping(s: *const Server) bool {
    return switch (s.phase) {
        .shut_wait, .exit_wait, .term_wait, .kill_wait => true,
        else => false,
    };
}

/// O servidor do bloco atual: sobe se preciso e fica com o texto para enviar.
fn target(now: u64) void {
    var found: ?*Server = null;
    for (&servers) |*slot| if (slot.*) |s| {
        if (stopping(s) or !s.spec.lang.eql(cur_spec.lang.slice())) continue;
        // Mudou o comando: o que está de pé não serve mais.
        if (!s.spec.cmd.eql(&cur_spec.cmd)) {
            beginStop(s, slot, now);
            continue;
        }
        found = s;
    };
    const s = found orelse blk: {
        if (failedLang(cur_spec.lang.slice())) return;
        break :blk addServer(now) orelse return;
    };
    closeDocs(s);
    s.spec.language_id = cur_spec.language_id;
    s.spec.ext = cur_spec.ext;
    s.close_doc = false;
    s.dirty = true;
    s.dirty_at = now;
    lock();
    sh.diags.lang = cur_spec.lang;
    unlock();
}

fn failedLang(lang: []const u8) bool {
    lock();
    defer unlock();
    for (sh.statuses[0..sh.n_status]) |*st| {
        if (st.lang.eql(lang)) return st.state == .failed;
    }
    return false;
}

fn addServer(now: u64) ?*Server {
    var free: ?*?*Server = null;
    for (&servers) |*slot| {
        if (slot.* == null) {
            free = slot;
            break;
        }
    }
    if (free == null) {
        // Todos ocupados: o mais antigo que não está parando sai. A vaga
        // abre em alguns instantes; o pedido atual espera a próxima tecla.
        for (&servers) |*slot| if (slot.*) |s| if (!stopping(s)) {
            beginStop(s, slot, now);
            break;
        };
        return null;
    }
    const s = gpa.create(Server) catch return null;
    s.* = .{ .spec = cur_spec };
    free.?.* = s;
    spawn(s, free.?, now);
    return free.?.*;
}

// --- O processo ----------------------------------------------------------------------

/// O ambiente do filho é este e mais nada: nem SIGMACORD_TOKEN, nem o que mais
/// estiver no ambiente de quem abriu o app.
const env_keep = [_][*:0]const u8{ "PATH", "HOME" } ++ (if (builtin.os.tag == .windows)
    [_][*:0]const u8{ "SystemRoot", "SystemDrive", "USERPROFILE", "APPDATA", "LOCALAPPDATA", "TEMP", "TMP", "PATHEXT" }
else
    [_][*:0]const u8{});

/// Esvazia a pasta. Sem descer em subpastas de propósito: um link deixado ali
/// por um servidor nunca faz o app apagar o que está do outro lado.
fn prepareScratch() ?[*:0]const u8 {
    const dir: [*:0]const u8 = &scratch_buf;
    if (scratch_buf[0] == 0 or !c.SDL_CreateDirectory(dir)) return null;
    var count: c_int = 0;
    if (c.SDL_GlobDirectory(dir, null, 0, &count)) |names| {
        defer c.SDL_free(@ptrCast(names));
        for (0..@intCast(count)) |i| {
            const name = names[i] orelse continue;
            var buf: [800]u8 = undefined;
            const p = std.fmt.bufPrintSentinel(&buf, "{s}/{s}", .{ std.mem.span(dir), std.mem.span(name) }, 0) catch continue;
            _ = c.SDL_RemovePath(p.ptr);
        }
    }
    return dir;
}

/// Soquete do Discord, arquivos abertos: nada disso atravessa o exec.
fn spawn(s: *Server, slot: *?*Server, now: u64) void {
    const cwd = prepareScratch() orelse return giveUp(s, slot, .spawn, 0);
    sys.closeOnExec();
    var args: [L.max_argv + 1:null]?[*:0]const u8 = @splat(null);
    var it = s.spec.cmd.iterator();
    var n: usize = 0;
    while (it.next()) |arg| : (n += 1) args[n] = arg.ptr;
    const env = c.SDL_CreateEnvironment(false) orelse return giveUp(s, slot, .spawn, 0);
    defer c.SDL_DestroyEnvironment(env);
    for (env_keep) |name| {
        if (c.SDL_getenv(name)) |v| _ = c.SDL_SetEnvironmentVariable(env, name, v, true);
    }
    const props = c.SDL_CreateProperties();
    if (props == 0) return giveUp(s, slot, .spawn, 0);
    defer c.SDL_DestroyProperties(props);
    _ = c.SDL_SetPointerProperty(props, c.SDL_PROP_PROCESS_CREATE_ARGS_POINTER, @ptrCast(&args));
    _ = c.SDL_SetPointerProperty(props, c.SDL_PROP_PROCESS_CREATE_ENVIRONMENT_POINTER, env);
    _ = c.SDL_SetStringProperty(props, c.SDL_PROP_PROCESS_CREATE_WORKING_DIRECTORY_STRING, cwd);
    _ = c.SDL_SetNumberProperty(props, c.SDL_PROP_PROCESS_CREATE_STDIN_NUMBER, c.SDL_PROCESS_STDIO_APP);
    _ = c.SDL_SetNumberProperty(props, c.SDL_PROP_PROCESS_CREATE_STDOUT_NUMBER, c.SDL_PROCESS_STDIO_APP);
    _ = c.SDL_SetNumberProperty(props, c.SDL_PROP_PROCESS_CREATE_STDERR_NUMBER, c.SDL_PROCESS_STDIO_NULL);
    const proc = c.SDL_CreateProcessWithProperties(props) orelse {
        // Programa que não existe não melhora tentando de novo.
        std.log.warn("lsp: não abriu {s}: {s}", .{ s.spec.cmd.program(), std.mem.span(c.SDL_GetError()) });
        return giveUp(s, slot, .spawn, 0);
    };
    s.proc = proc;
    s.stdin = c.SDL_GetProcessInput(proc);
    s.stdout = c.SDL_GetProcessOutput(proc);
    s.phase = .init;
    s.deadline = now + tuning.init_timeout_ms;
    s.out.clearRetainingCapacity();
    s.out_at = 0;
    s.framer.deinit(gpa);
    s.doc_open = false;
    s.close_doc = false;
    s.close_stdin = false;
    s.write_stuck_since = 0;
    s.window_start = now;
    s.window_bytes = 0;
    s.init_id = s.next_id;
    s.next_id += 1;
    L.writeInitialize(&s.out, gpa, s.init_id) catch {};
    const pid = c.SDL_GetNumberProperty(c.SDL_GetProcessProperties(proc), c.SDL_PROP_PROCESS_PID_NUMBER, 0);
    setStatus(s.spec.lang.slice(), .starting, .none, 0, s.fails, pid);
}

/// Termina o processo sem conversa, para os casos de defeito.
fn killNow(s: *Server) void {
    const proc = s.proc orelse return;
    _ = c.SDL_KillProcess(proc, true);
    var code: c_int = 0;
    // SIGKILL é imediato, exceto num processo preso em E/S do kernel: aí o
    // zumbi fica para o sistema, a thread não trava por ele.
    var tries: u32 = 0;
    while (!c.SDL_WaitProcess(proc, false, &code) and tries < 100) : (tries += 1) c.SDL_Delay(2);
    closeProcess(s);
}

fn closeProcess(s: *Server) void {
    if (s.proc) |proc| c.SDL_DestroyProcess(proc);
    s.proc = null;
    s.stdin = null;
    s.stdout = null;
}

fn remove(s: *Server, slot: *?*Server) void {
    closeProcess(s);
    s.deinit();
    gpa.destroy(s);
    slot.* = null;
}

/// Um defeito: tenta de novo com um intervalo cada vez maior e, esgotadas as
/// tentativas, mostra o erro e fica parado até a configuração mudar.
fn fail(s: *Server, slot: *?*Server, why: Failure, code: i32, now: u64) void {
    killNow(s);
    if (isCurrent(s)) clearDiagsShared();
    if (quitting) return remove(s, slot);
    if (s.fails >= tuning.backoff_ms.len) return giveUp(s, slot, why, code);
    s.retry_at = now + tuning.backoff_ms[s.fails];
    s.fails += 1;
    s.phase = .retry_wait;
    s.doc_open = false;
    s.close_doc = false;
    setStatus(s.spec.lang.slice(), .retrying, why, code, s.fails, 0);
    // O texto volta a ser enviado quando ele subir.
    if (isCurrent(s)) s.dirty = true;
}

fn giveUp(s: *Server, slot: *?*Server, why: Failure, code: i32) void {
    setStatus(s.spec.lang.slice(), .failed, why, code, s.fails, 0);
    remove(s, slot);
}

fn isCurrent(s: *const Server) bool {
    return cur_active and s.spec.lang.eql(cur_spec.lang.slice());
}

fn clearDiagsShared() void {
    lock();
    clearDiagsLocked();
    unlock();
    wake_pending = true;
}

/// Encerra com educação; quem não responde leva os sinais (ver `pump`).
fn beginStop(s: *Server, slot: *?*Server, now: u64) void {
    const st = if (quitting) stops_quit else stops_normal;
    switch (s.phase) {
        .retry_wait => {
            setStatus(s.spec.lang.slice(), .off, .none, 0, 0, 0);
            remove(s, slot);
        },
        .init => {
            // Ainda sem resposta do initialize: `shutdown` antes dele é erro.
            setStatus(s.spec.lang.slice(), .stopping, .none, 0, s.fails, 0);
            s.close_stdin = true;
            s.phase = .exit_wait;
            s.deadline = now + st.exit_ms;
        },
        .ready => {
            setStatus(s.spec.lang.slice(), .stopping, .none, 0, s.fails, 0);
            s.shutdown_id = s.next_id;
            s.next_id += 1;
            L.writeShutdown(&s.out, gpa, s.shutdown_id) catch {};
            s.phase = .shut_wait;
            s.deadline = now + st.shutdown_ms;
        },
        // Fechando o app no meio de uma parada normal: os prazos encurtam.
        .shut_wait, .exit_wait, .term_wait, .kill_wait => if (quitting) {
            s.deadline = @min(s.deadline, now + st.term_ms);
        },
    }
}

fn sendExit(s: *Server, now: u64) void {
    L.writeNotification(&s.out, gpa, "exit") catch {};
    s.close_stdin = true;
    s.phase = .exit_wait;
    s.deadline = now + (if (quitting) stops_quit else stops_normal).exit_ms;
}

/// Uma rodada de um servidor. true = fez alguma coisa (volta logo).
fn pump(s: *Server, slot: *?*Server, now: u64) bool {
    if (s.phase == .retry_wait) {
        if (now >= s.retry_at) spawn(s, slot, now);
        return false;
    }
    var busy = false;
    var eof = false;
    // Lê.
    var rounds: u8 = 0;
    while (rounds < 4) : (rounds += 1) {
        var tmp: [16 * 1024]u8 = undefined;
        const n = c.SDL_ReadIO(s.stdout, &tmp, tmp.len);
        if (n == 0) {
            eof = c.SDL_GetIOStatus(s.stdout) != c.SDL_IO_STATUS_NOT_READY;
            break;
        }
        busy = true;
        if (now - s.window_start > 60_000) {
            s.window_start = now;
            s.window_bytes = 0;
        }
        s.window_bytes += n;
        if (s.window_bytes > tuning.flood_bytes) {
            fail(s, slot, .flood, 0, now);
            return true;
        }
        s.framer.feed(gpa, tmp[0..n]) catch {
            fail(s, slot, .protocol, 0, now);
            return true;
        };
        while (true) {
            const body = s.framer.next() catch {
                fail(s, slot, .protocol, 0, now);
                return true;
            } orelse break;
            onMessage(s, slot, body, now);
            if (slot.* != s or s.proc == null) return true;
        }
    }
    // Saiu?
    var code: c_int = 0;
    if (c.SDL_WaitProcess(s.proc, false, &code)) {
        if (stopping(s)) finished(s, slot) else fail(s, slot, .crashed, code, now);
        return true;
    }
    // Fechou o stdout e continua vivo: não tem mais o que dizer.
    if (eof and !stopping(s)) {
        fail(s, slot, .crashed, 0, now);
        return true;
    }
    switch (s.phase) {
        .init => if (now >= s.deadline) {
            fail(s, slot, .init_timeout, 0, now);
            return true;
        },
        .ready => {
            if (s.fails > 0 and now - s.ready_at > tuning.healthy_ms) {
                s.fails = 0;
                setStatus(s.spec.lang.slice(), .ready, .none, 0, 0, statusPid(s));
            }
            if (sendDoc(s, now)) busy = true;
        },
        .shut_wait => if (now >= s.deadline) sendExit(s, now),
        .exit_wait => if (now >= s.deadline) {
            _ = c.SDL_KillProcess(s.proc, false);
            s.phase = .term_wait;
            s.deadline = now + (if (quitting) stops_quit else stops_normal).term_ms;
        },
        .term_wait => if (now >= s.deadline) {
            _ = c.SDL_KillProcess(s.proc, true);
            s.phase = .kill_wait;
            s.deadline = now + (if (quitting) stops_quit else stops_normal).kill_ms;
        },
        .kill_wait => if (now >= s.deadline) {
            // Nem SIGKILL (preso no kernel): larga, o sistema recolhe.
            finished(s, slot);
            return true;
        },
        .retry_wait => {},
    }
    if (flush(s, slot, now)) busy = true;
    return busy or s.proc == null;
}

/// Parou como pedido. Se outro servidor já assumiu a linguagem (o comando mudou),
/// o estado é o dele.
fn finished(s: *Server, slot: *?*Server) void {
    const replaced = for (servers) |other| {
        if (other) |o| if (o != s and !stopping(o) and o.spec.lang.eql(s.spec.lang.slice())) break true;
    } else false;
    if (!replaced) setStatus(s.spec.lang.slice(), .off, .none, 0, 0, 0);
    remove(s, slot);
}

fn statusPid(s: *const Server) i64 {
    return c.SDL_GetNumberProperty(c.SDL_GetProcessProperties(s.proc), c.SDL_PROP_PROCESS_PID_NUMBER, 0);
}

/// Manda o texto, passado o tempo de espera e sem nada na fila: se o servidor
/// está lento, só a versão mais nova vai.
fn sendDoc(s: *Server, now: u64) bool {
    if (s.out_at < s.out.items.len) return false;
    var ubuf: [1800]u8 = undefined;
    const uri = s.uri(&ubuf);
    if (s.close_doc) {
        s.close_doc = false;
        s.doc_open = false;
        L.writeDidClose(&s.out, gpa, uri) catch {};
        return true;
    }
    if (!s.dirty or now - s.dirty_at < tuning.debounce_ms or !isCurrent(s)) return false;
    s.dirty = false;
    s.version += 1;
    const text = cur_text[0..cur_len];
    if (s.doc_open) {
        L.writeDidChange(&s.out, gpa, uri, s.version, text) catch {};
    } else {
        s.doc_open = true;
        L.writeDidOpen(&s.out, gpa, uri, s.spec.language_id.slice(), s.version, text) catch {};
    }
    return true;
}

fn flush(s: *Server, slot: *?*Server, now: u64) bool {
    var moved = false;
    while (s.out_at < s.out.items.len) {
        const rest = s.out.items[s.out_at..];
        const stream = s.stdin orelse {
            s.out_at = s.out.items.len;
            break;
        };
        const n = c.SDL_WriteIO(stream, rest.ptr, rest.len);
        if (n == 0) break;
        s.out_at += n;
        moved = true;
        s.write_stuck_since = 0;
    }
    if (s.out_at < s.out.items.len) {
        // O servidor parou de ler. Parando, os prazos já cuidam dele. O teto
        // é para quem faz pedidos sem parar e não lê as respostas.
        if (s.write_stuck_since == 0) s.write_stuck_since = now;
        if (!stopping(s) and (now - s.write_stuck_since > tuning.write_stall_ms or s.out.items.len > max_outgoing)) {
            fail(s, slot, .write_stall, 0, now);
            return true;
        }
        return moved;
    }
    s.out.clearRetainingCapacity();
    s.out_at = 0;
    // O EOF no stdin é o último recado (servidores saem com ele).
    if (s.close_stdin) {
        s.close_stdin = false;
        if (s.stdin) |stream| {
            _ = c.SDL_CloseIO(stream);
            s.stdin = null;
        }
    }
    return moved;
}

fn onMessage(s: *Server, slot: *?*Server, body: []const u8, now: u64) void {
    var ubuf: [1800]u8 = undefined;
    const ev = L.handleMessage(gpa, body, s.uri(&ubuf), &diag_scratch, &s.out) catch {
        // JSON quebrado num quadro bom: ignora, mas o resto da conversa segue.
        return;
    };
    switch (ev) {
        .ignored => {},
        .response => |r| {
            if (r.id == s.init_id and s.phase == .init) {
                if (!r.ok) return fail(s, slot, .protocol, 0, now);
                L.writeNotification(&s.out, gpa, "initialized") catch {};
                s.phase = .ready;
                s.ready_at = now;
                setStatus(s.spec.lang.slice(), .ready, .none, 0, s.fails, statusPid(s));
            } else if (r.id == s.shutdown_id and s.phase == .shut_wait) {
                sendExit(s, now);
            }
        },
        .diagnostics => |d| {
            if (!isCurrent(s) or stopping(s)) return;
            // Resposta a um texto que já mudou de novo: a próxima vem logo.
            if (d.version) |v| if (v < s.version) return;
            lock();
            sh.diags.lang = s.spec.lang;
            sh.diags.n = d.n;
            sh.diags.total = d.total;
            @memcpy(sh.diags.items[0..d.n], diag_scratch[0..d.n]);
            sh.diag_gen +%= 1;
            unlock();
            wake_pending = true;
        },
    }
}

fn setStatus(lang: []const u8, state: State, why: Failure, code: i32, attempts: u8, pid: i64) void {
    lock();
    defer unlock();
    sh.status_gen +%= 1;
    wake_pending = true;
    var entry: ?*Status = null;
    for (sh.statuses[0..sh.n_status]) |*st| {
        if (st.lang.eql(lang)) entry = st;
    }
    if (entry == null) {
        // Tabela cheia só com plugins demais: reaproveita a última.
        if (sh.n_status < max_status) sh.n_status += 1;
        entry = &sh.statuses[sh.n_status - 1];
    }
    // Só um novo pedido limpa uma falha definitiva (`retry`, `stopAll`).
    entry.?.* = .{ .lang = L.Short.of(lang), .state = state, .failure = why, .exit_code = code, .attempts = attempts, .pid = pid };
}

/// Muitas publicações por segundo não viram muitos quadros.
fn flushWake(now: u64) void {
    if (!wake_pending or now - last_wake < 50) return;
    wake_pending = false;
    last_wake = now;
    if (wake_fn) |w| w();
}
