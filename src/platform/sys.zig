//! O que muda entre Linux e Windows: sockets, pasta de dados, chaveiro, RAM,
//! mapear arquivos, trava de instância, bandeja e avisos do sistema. O resto do
//! app fala com estas funções.
const std = @import("std");
const builtin = @import("builtin");
const c = @import("c");

pub const windows = builtin.os.tag == .windows;
pub const macos = builtin.os.tag == .macos;

pub const Socket = c.curl_socket_t;
pub const no_socket: Socket = if (windows) std.math.maxInt(Socket) else -1;
pub const PollFd = c.struct_pollfd;
pub const SockAddrIn = c.struct_sockaddr_in;

pub fn valid(s: Socket) bool {
    return s != no_socket;
}

/// Uma vez, antes de qualquer outra coisa.
pub fn init() void {
    if (windows) {
        var data: c.WSADATA = undefined;
        _ = c.WSAStartup(0x0202, &data);
    } else {
        // Um filho (secret-tool) ou pipe fechado vira erro de write, não a morte do app.
        _ = c.signal(c.SIGPIPE, c.SIG_IGN);
    }
}

pub fn poll(fds: [*]PollFd, n: usize, timeout_ms: c_int) void {
    if (windows) _ = c.WSAPoll(fds, @intCast(n), timeout_ms) else _ = c.poll(fds, @intCast(n), timeout_ms);
}

pub fn closeSocket(s: Socket) void {
    if (windows) _ = c.closesocket(s) else _ = c.close(s);
}

/// UDP que nunca bloqueia (`recvNow` volta na hora).
pub fn udpSocket() ?Socket {
    if (windows) {
        const s = c.socket(c.AF_INET, c.SOCK_DGRAM, 0);
        if (s == no_socket) return null;
        var on: c_ulong = 1;
        // FIONBIO (a macro não passa pelo translate-c).
        _ = c.ioctlsocket(s, @bitCast(@as(u32, 0x8004667E)), &on);
        return s;
    }
    const s = c.socket(c.AF_INET, c.SOCK_DGRAM | c.SOCK_CLOEXEC, 0);
    return if (s < 0) null else s;
}

pub fn recvNow(s: Socket, buf: []u8) isize {
    if (windows) return c.recv(s, buf.ptr, @intCast(buf.len), 0);
    return c.recv(s, buf.ptr, buf.len, c.MSG_DONTWAIT);
}

pub fn sendTo(s: Socket, data: []const u8, to: *const SockAddrIn) isize {
    if (windows) return c.sendto(s, data.ptr, @intCast(data.len), 0, @ptrCast(to), @sizeOf(SockAddrIn));
    return c.sendto(s, data.ptr, data.len, 0, @ptrCast(to), @sizeOf(SockAddrIn));
}

pub fn bindAny(s: Socket) bool {
    var local = std.mem.zeroes(SockAddrIn);
    local.sin_family = c.AF_INET;
    return c.bind(s, @ptrCast(&local), @sizeOf(SockAddrIn)) == 0;
}

/// IP e porta -> endereço (porta em ordem de rede).
pub fn ipv4(ip: [*:0]const u8, port: u16) ?SockAddrIn {
    var sa = std.mem.zeroes(SockAddrIn);
    sa.sin_family = c.AF_INET;
    sa.sin_port = std.mem.nativeToBig(u16, port);
    if (c.inet_pton(c.AF_INET, ip, &sa.sin_addr) != 1) return null;
    return sa;
}

/// Acorda quem está em `poll`. Linux: um pipe. Windows: o poll só aceita
/// sockets, então é um par UDP em 127.0.0.1.
pub const Wake = struct {
    read: Socket = no_socket,
    write: Socket = no_socket,

    pub fn open() Wake {
        if (windows) {
            const r = udpSocket() orelse return .{};
            const w = udpSocket() orelse {
                closeSocket(r);
                return .{};
            };
            var addr = ipv4("127.0.0.1", 0) orelse return .{ .read = r, .write = w };
            var len: c_int = @sizeOf(SockAddrIn);
            if (c.bind(r, @ptrCast(&addr), len) != 0 or c.getsockname(r, @ptrCast(&addr), &len) != 0 or c.connect(w, @ptrCast(&addr), len) != 0) {
                closeSocket(r);
                closeSocket(w);
                return .{};
            }
            return .{ .read = r, .write = w };
        }
        var fds: [2]c_int = undefined;
        if (c.pipe(&fds) != 0) return .{};
        for (fds) |fd| {
            _ = c.fcntl(fd, c.F_SETFL, c.O_NONBLOCK);
            _ = c.fcntl(fd, c.F_SETFD, c.FD_CLOEXEC);
        }
        return .{ .read = fds[0], .write = fds[1] };
    }

    pub fn close(w: *Wake) void {
        for ([_]Socket{ w.read, w.write }) |s| if (valid(s)) closeSocket(s);
        w.* = .{};
    }

    pub fn drain(w: *const Wake) void {
        var junk: [64]u8 = undefined;
        if (windows) _ = c.recv(w.read, &junk, junk.len, 0) else _ = c.read(w.read, &junk, junk.len);
    }
};

pub fn wakeSignal(write_end: Socket) void {
    if (windows) _ = c.send(write_end, "x", 1, 0) else _ = c.write(write_end, "x", 1);
}

// --- TCP local (um SigmaCord fala com o outro) -----------------------------------

/// Escuta em 127.0.0.1, numa porta livre. No Windows, sem isso o socket é
/// herdado por quem o app abrir (e a porta fica presa depois de sair).
pub fn tcpListenLocal(port: *u16) ?Socket {
    const s = if (windows) c.socket(c.AF_INET, c.SOCK_STREAM, 0) else c.socket(c.AF_INET, c.SOCK_STREAM | c.SOCK_CLOEXEC, 0);
    if (!valid(s)) return null;
    if (windows) _ = c.SetHandleInformation(@ptrFromInt(s), c.HANDLE_FLAG_INHERIT, 0);
    var addr = ipv4("127.0.0.1", 0) orelse {
        closeSocket(s);
        return null;
    };
    var len: if (windows) c_int else c.socklen_t = @sizeOf(SockAddrIn);
    if (c.bind(s, @ptrCast(&addr), len) != 0 or c.listen(s, 4) != 0 or c.getsockname(s, @ptrCast(&addr), &len) != 0) {
        closeSocket(s);
        return null;
    }
    port.* = std.mem.bigToNative(u16, addr.sin_port);
    return s;
}

pub fn tcpConnectLocal(port: u16) ?Socket {
    const s = if (windows) c.socket(c.AF_INET, c.SOCK_STREAM, 0) else c.socket(c.AF_INET, c.SOCK_STREAM | c.SOCK_CLOEXEC, 0);
    if (!valid(s)) return null;
    const addr = ipv4("127.0.0.1", port) orelse {
        closeSocket(s);
        return null;
    };
    if (c.connect(s, @ptrCast(&addr), @sizeOf(SockAddrIn)) != 0) {
        closeSocket(s);
        return null;
    }
    return s;
}

pub fn tcpAccept(s: Socket) ?Socket {
    const client = c.accept(s, null, null);
    return if (valid(client)) client else null;
}

pub fn tcpSend(s: Socket, data: []const u8) void {
    if (windows) _ = c.send(s, data.ptr, @intCast(data.len), 0) else _ = c.send(s, data.ptr, data.len, 0);
}

/// Espera chegar algo por até `timeout_ms` e lê uma vez.
pub fn tcpRecv(s: Socket, buf: []u8, timeout_ms: c_int) []u8 {
    var fds = [1]PollFd{.{ .fd = s, .events = c.POLLIN, .revents = 0 }};
    poll(&fds, 1, timeout_ms);
    if (fds[0].revents == 0) return buf[0..0];
    const n = if (windows) c.recv(s, buf.ptr, @intCast(buf.len), 0) else c.recv(s, buf.ptr, buf.len, 0);
    return if (n > 0) buf[0..@intCast(n)] else buf[0..0];
}

// --- Trava de instância -----------------------------------------------------------

pub const FileLock = if (windows) c.HANDLE else c_int;
pub const LockResult = union(enum) {
    got: FileLock,
    /// Outro processo está com ela.
    held,
    /// Não deu para saber (pasta sem escrita, sistema de arquivos sem trava).
    failed,
};

/// Só um processo por vez. Se ele morrer, o sistema solta sozinho: nunca sobra
/// trava velha para impedir o app de abrir.
pub fn lockFile(path: [*:0]const u8) LockResult {
    if (windows) {
        const h = c.CreateFileA(path, c.GENERIC_READ | c.GENERIC_WRITE, 0, null, c.OPEN_ALWAYS, c.FILE_ATTRIBUTE_NORMAL, null);
        if (h != c.INVALID_HANDLE_VALUE) return .{ .got = h };
        return if (c.GetLastError() == c.ERROR_SHARING_VIOLATION) .held else .failed;
    }
    const fd = c.open(path, c.O_RDWR | c.O_CREAT | c.O_CLOEXEC, @as(c_uint, 0o600));
    if (fd < 0) return .failed;
    if (c.flock(fd, c.LOCK_EX | c.LOCK_NB) == 0) return .{ .got = fd };
    const held = std.c._errno().* == @intFromEnum(std.c.E.AGAIN);
    _ = c.close(fd);
    return if (held) .held else .failed;
}

pub fn unlockFile(lock: FileLock) void {
    if (windows) _ = c.CloseHandle(lock) else _ = c.close(lock);
}

// --- Bandeja e avisos -------------------------------------------------------------

/// Um segundo processo deixa o primeiro vir para a frente (no Windows, só quem
/// está em primeiro plano pode passar a vez).
pub fn allowForeground() void {
    if (windows) _ = c.AllowSetForegroundWindow(0xFFFFFFFF);
}

/// Filho nenhum herda os sockets e a trava do app.
pub fn closeOnExec() void {
    if (windows) return;
    var fd: c_int = 3;
    while (fd < 1024) : (fd += 1) _ = c.fcntl(fd, c.F_SETFD, @as(c_int, c.FD_CLOEXEC));
}

/// Tem quem mostre um ícone de bandeja? No Windows, a barra de tarefas. No Linux
/// o SDL_CreateTray funciona mesmo sem painel nenhum (o ícone só não aparece),
/// então a pergunta vai direto para o StatusNotifierWatcher, pelo D-Bus. Sem
/// libdbus, sem sessão ou sem resposta conta como "não": fechar sai de verdade,
/// que é o erro seguro.
pub fn trayHostAvailable() bool {
    if (windows) return true;
    // Fica carregada: o próprio SDL já a usa, e a pergunta se repete com a janela escondida.
    const Lib = struct {
        var handle: ?*c.SDL_SharedObject = null;
    };
    const lib = Lib.handle orelse (c.SDL_LoadObject("libdbus-1.so.3") orelse return false);
    Lib.handle = lib;
    const Conn = opaque {};
    const Msg = opaque {};
    const Fns = struct {
        threads_init: *const fn () callconv(.c) u32,
        error_init: *const fn (*[64]u8) callconv(.c) void,
        error_free: *const fn (*[64]u8) callconv(.c) void,
        bus_get_private: *const fn (c_int, *[64]u8) callconv(.c) ?*Conn,
        set_exit_on_disconnect: *const fn (*Conn, u32) callconv(.c) void,
        conn_close: *const fn (*Conn) callconv(.c) void,
        conn_unref: *const fn (*Conn) callconv(.c) void,
        new_call: *const fn ([*:0]const u8, [*:0]const u8, [*:0]const u8, [*:0]const u8) callconv(.c) ?*Msg,
        msg_unref: *const fn (*Msg) callconv(.c) void,
        iter_init_append: *const fn (*Msg, *[128]u8) callconv(.c) void,
        iter_append_basic: *const fn (*[128]u8, c_int, *const anyopaque) callconv(.c) u32,
        send_block: *const fn (*Conn, *Msg, c_int, *[64]u8) callconv(.c) ?*Msg,
        iter_init: *const fn (*Msg, *[128]u8) callconv(.c) u32,
        iter_type: *const fn (*[128]u8) callconv(.c) c_int,
        iter_recurse: *const fn (*[128]u8, *[128]u8) callconv(.c) void,
        iter_get_basic: *const fn (*[128]u8, *anyopaque) callconv(.c) void,
    };
    const names = [_][*:0]const u8{
        "dbus_threads_init_default",     "dbus_error_init",               "dbus_error_free",
        "dbus_bus_get_private",          "dbus_connection_set_exit_on_disconnect", "dbus_connection_close",
        "dbus_connection_unref",         "dbus_message_new_method_call",  "dbus_message_unref",
        "dbus_message_iter_init_append", "dbus_message_iter_append_basic", "dbus_connection_send_with_reply_and_block",
        "dbus_message_iter_init",        "dbus_message_iter_get_arg_type", "dbus_message_iter_recurse",
        "dbus_message_iter_get_basic",
    };
    var f: Fns = undefined;
    inline for (@typeInfo(Fns).@"struct".field_names, 0..) |fname, i| {
        const sym = c.SDL_LoadFunction(lib, names[i]) orelse return false;
        @field(f, fname) = @ptrCast(sym);
    }
    _ = f.threads_init();
    // DBusError tem 32 bytes e DBusMessageIter, 72: os dois com folga.
    var err: [64]u8 align(8) = undefined;
    f.error_init(&err);
    defer f.error_free(&err);
    const conn = f.bus_get_private(0, &err) orelse return false;
    // Por padrão a libdbus derruba o processo quando a conexão cai.
    f.set_exit_on_disconnect(conn, 0);
    defer {
        f.conn_close(conn);
        f.conn_unref(conn);
    }
    const msg = f.new_call("org.kde.StatusNotifierWatcher", "/StatusNotifierWatcher", "org.freedesktop.DBus.Properties", "Get") orelse return false;
    defer f.msg_unref(msg);
    var args: [128]u8 align(8) = undefined;
    f.iter_init_append(msg, &args);
    var iface: [*:0]const u8 = "org.kde.StatusNotifierWatcher";
    var prop: [*:0]const u8 = "IsStatusNotifierHostRegistered";
    if (f.iter_append_basic(&args, 's', @ptrCast(&iface)) == 0 or f.iter_append_basic(&args, 's', @ptrCast(&prop)) == 0) return false;
    const reply = f.send_block(conn, msg, 250, &err) orelse return false;
    defer f.msg_unref(reply);
    var it: [128]u8 align(8) = undefined;
    var sub: [128]u8 align(8) = undefined;
    if (f.iter_init(reply, &it) == 0 or f.iter_type(&it) != 'v') return false;
    f.iter_recurse(&it, &sub);
    if (f.iter_type(&sub) != 'b') return false;
    var on: u32 = 0;
    f.iter_get_basic(&sub, @ptrCast(&on));
    return on != 0;
}

/// O ícone temporário do aviso do Windows (o do SDL não dá para usar: ele não
/// expõe o identificador). Fica até o próximo `toastExpire` depois de 30 s.
var toast_hwnd: ?*anyopaque = null;
var toast_ms: i64 = 0;
const toast_uid: u32 = 0x1A5C;

/// Aviso do sistema no Windows. No Linux quem avisa é o notify-send (app.zig).
pub fn toast(hwnd: ?*anyopaque, now_ms: i64, title: []const u8, body: []const u8) void {
    if (!windows) return;
    const h = hwnd orelse return;
    var nid = std.mem.zeroes(c.NOTIFYICONDATAW);
    nid.cbSize = @sizeOf(c.NOTIFYICONDATAW);
    nid.hWnd = @ptrCast(@alignCast(h));
    nid.uID = toast_uid;
    if (toast_hwnd == null) {
        nid.uFlags = c.NIF_ICON | c.NIF_TIP;
        // O ícone 1 de assets/sigmacord.rc.
        nid.hIcon = c.LoadIconA(c.GetModuleHandleA(null), @ptrFromInt(1));
        wide(&nid.szTip, "SigmaCord");
        if (c.Shell_NotifyIconW(c.NIM_ADD, &nid) == 0) return;
        toast_hwnd = h;
    }
    nid.uFlags = c.NIF_INFO;
    nid.dwInfoFlags = c.NIIF_NONE;
    wide(&nid.szInfoTitle, title);
    wide(&nid.szInfo, body);
    _ = c.Shell_NotifyIconW(c.NIM_MODIFY, &nid);
    toast_ms = now_ms;
}

/// `force`: tira o ícone já (o app está fechando).
pub fn toastExpire(now_ms: i64, force: bool) void {
    if (!windows) return;
    const h = toast_hwnd orelse return;
    if (!force and now_ms - toast_ms < 30_000) return;
    var nid = std.mem.zeroes(c.NOTIFYICONDATAW);
    nid.cbSize = @sizeOf(c.NOTIFYICONDATAW);
    nid.hWnd = @ptrCast(@alignCast(h));
    nid.uID = toast_uid;
    _ = c.Shell_NotifyIconW(c.NIM_DELETE, &nid);
    toast_hwnd = null;
}

/// UTF-8 para o campo de tamanho fixo do Windows, cortando o que não couber.
fn wide(out: []u16, s: []const u8) void {
    var tmp: [1024]u16 = undefined;
    const n: usize = @intCast(c.MultiByteToWideChar(c.CP_UTF8, 0, s.ptr, @intCast(@min(s.len, 1024)), &tmp, tmp.len));
    const m = @min(n, out.len - 1);
    @memcpy(out[0..m], tmp[0..m]);
    out[m] = 0;
}

// --- Pastas ---------------------------------------------------------------------

fn env(name: [*:0]const u8) ?[]const u8 {
    const v = c.SDL_getenv(name) orelse return null;
    const s = std.mem.span(v);
    return if (s.len > 0) s else null;
}

/// Onde ficam as configurações (sem o "sigmacord"): $XDG_CONFIG_HOME,
/// %APPDATA% ou ~/.config.
pub fn configHome(buf: []u8) ?[]const u8 {
    if (env("XDG_CONFIG_HOME")) |x| return x;
    if (windows) return env("APPDATA");
    const home = env("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.config", .{home}) catch null;
}

/// Onde fica o cache: $XDG_CACHE_HOME, %LOCALAPPDATA% ou ~/.cache.
pub fn cacheHome(buf: []u8) ?[]const u8 {
    if (env("XDG_CACHE_HOME")) |x| return x;
    if (windows) return env("LOCALAPPDATA");
    const home = env("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.cache", .{home}) catch null;
}

pub fn tempDir() []const u8 {
    if (env("XDG_RUNTIME_DIR")) |x| return x;
    if (windows) return env("TEMP") orelse ".";
    return "/tmp";
}

// --- Arquivos -------------------------------------------------------------------

pub fn mkdirPrivate(path: [*:0]const u8) void {
    if (windows) {
        _ = c.CreateDirectoryA(path, null);
    } else _ = c.mkdir(path, 0o700);
}

/// Tamanho do arquivo, ou null se ele não existe.
pub fn fileSize(path: [*:0]const u8) ?u64 {
    var info: c.SDL_PathInfo = undefined;
    if (!c.SDL_GetPathInfo(path, &info)) return null;
    return info.size;
}

pub fn exists(path: [*:0]const u8) bool {
    return fileSize(path) != null;
}

/// O arquivo só é legível pelo dono? (No Windows, a pasta do perfil já é.)
pub fn ownerOnly(path: [*:0]const u8) bool {
    if (windows) return exists(path);
    var st: c.struct_stat = undefined;
    return c.stat(path, &st) == 0 and st.st_mode & 0o077 == 0;
}

/// Grava `bytes` num arquivo novo só do dono. O chamador renomeia depois.
pub fn writeNew(path: [*:0]const u8, bytes: []const u8, durable: bool) bool {
    const flags = if (windows) c.O_WRONLY | c.O_CREAT | c.O_TRUNC | c.O_BINARY else c.O_WRONLY | c.O_CREAT | c.O_TRUNC | c.O_CLOEXEC;
    const fd = c.open(path, flags, @as(c_uint, 0o600));
    if (fd < 0) return false;
    if (!windows) _ = c.fchmod(fd, 0o600);
    var off: usize = 0;
    var ok = true;
    while (off < bytes.len) {
        const left = bytes.len - off;
        const n = if (windows) c.write(fd, bytes[off..].ptr, @intCast(@min(left, 1 << 30))) else c.write(fd, bytes[off..].ptr, left);
        if (n <= 0) {
            ok = false;
            break;
        }
        off += @intCast(n);
    }
    if (ok and durable) ok = (if (windows) c._commit(fd) else c.fsync(fd)) == 0;
    if (c.close(fd) != 0) ok = false;
    return ok;
}

/// Troca um arquivo por outro de uma vez só, mesmo se o destino existe.
pub fn replaceFile(from: [*:0]const u8, to: [*:0]const u8) bool {
    if (windows) return c.MoveFileExA(from, to, c.MOVEFILE_REPLACE_EXISTING | c.MOVEFILE_WRITE_THROUGH) != 0;
    return c.rename(from, to) == 0;
}

/// Mapeia o arquivo (somente leitura); só as páginas lidas ficam na RAM.
pub fn mapFile(path: [*:0]const u8) ?[]u8 {
    if (windows) {
        const f = c.CreateFileA(path, c.GENERIC_READ, c.FILE_SHARE_READ, null, c.OPEN_EXISTING, c.FILE_ATTRIBUTE_NORMAL, null);
        if (f == c.INVALID_HANDLE_VALUE) return null;
        defer _ = c.CloseHandle(f);
        var size: c.LARGE_INTEGER = undefined;
        if (c.GetFileSizeEx(f, &size) == 0 or size.QuadPart <= 0) return null;
        const m = c.CreateFileMappingA(f, null, c.PAGE_READONLY, 0, 0, null) orelse return null;
        defer _ = c.CloseHandle(m);
        const view = c.MapViewOfFile(m, c.FILE_MAP_READ, 0, 0, 0) orelse return null;
        return @as([*]u8, @ptrCast(view))[0..@intCast(size.QuadPart)];
    }
    const fd = c.open(path, c.O_RDONLY);
    if (fd < 0) return null;
    defer _ = c.close(fd);
    const size = c.lseek(fd, 0, c.SEEK_END);
    if (size <= 0) return null;
    const p = c.mmap(null, @intCast(size), c.PROT_READ, c.MAP_PRIVATE, fd, 0);
    if (p == null or @intFromPtr(p) == std.math.maxInt(usize)) return null;
    return @as([*]u8, @ptrCast(p))[0..@intCast(size)];
}

// --- Chaveiro do Windows (Gerenciador de Credenciais) ---------------------------

pub fn credRead(target: [*:0]const u8, buf: []u8) ?[]u8 {
    if (!windows) return null;
    var cred: c.PCREDENTIALA = null;
    if (c.CredReadA(target, c.CRED_TYPE_GENERIC, 0, &cred) == 0) return null;
    defer c.CredFree(cred);
    const n: usize = cred.*.CredentialBlobSize;
    if (n > buf.len) return null;
    @memcpy(buf[0..n], cred.*.CredentialBlob[0..n]);
    return buf[0..n];
}

pub fn credWrite(target: [*:0]const u8, label: [*:0]const u8, secret: []const u8) bool {
    if (!windows) return false;
    var cred = std.mem.zeroes(c.CREDENTIALA);
    cred.Type = c.CRED_TYPE_GENERIC;
    cred.TargetName = @constCast(target);
    cred.Comment = @constCast(label);
    cred.CredentialBlobSize = @intCast(secret.len);
    cred.CredentialBlob = @constCast(secret.ptr);
    cred.Persist = c.CRED_PERSIST_LOCAL_MACHINE;
    return c.CredWriteA(&cred, 0) != 0;
}

pub fn credDelete(target: [*:0]const u8) void {
    if (windows) _ = c.CredDeleteA(target, c.CRED_TYPE_GENERIC, 0);
}

/// No Windows confia nos certificados do sistema (não há pacote de CAs junto). No
/// Linux, cada família de distros guarda o pacote num lugar, e o caminho embutido no
/// OpenSSL do binário portátil só valeria na distro onde ele foi compilado.
pub fn curlTls(h: *c.CURL) void {
    if (windows) {
        _ = c.curl_easy_setopt(h, c.CURLOPT_SSL_OPTIONS, @as(c_long, c.CURLSSLOPT_NATIVE_CA));
    } else {
        const bundles = [_][*:0]const u8{
            "/etc/ssl/certs/ca-certificates.crt", // Debian, Ubuntu, Arch
            "/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem", // Fedora, RHEL
            "/etc/pki/tls/certs/ca-bundle.crt", // Fedora e RHEL mais antigos
            "/etc/ssl/ca-bundle.pem", // openSUSE
            "/etc/ssl/cert.pem", // Alpine e outros
        };
        for (bundles) |path| if (c.access(path, c.R_OK) == 0) {
            _ = c.curl_easy_setopt(h, c.CURLOPT_CAINFO, path);
            return;
        };
    }
}

/// Troca um arquivo possivelmente em uso. O Windows não deixa sobrescrever o
/// executável aberto, mas deixa renomeá-lo: o velho vira `.old` até o próximo início.
pub fn replaceRunning(from: [*:0]const u8, to: [*:0]const u8) bool {
    if (windows) {
        var pb: [1200]u8 = undefined;
        const old = std.fmt.bufPrintSentinel(&pb, "{s}.old", .{std.mem.span(to)}, 0) catch return false;
        _ = c.DeleteFileA(old.ptr);
        if (exists(to) and c.MoveFileExA(to, old.ptr, c.MOVEFILE_REPLACE_EXISTING) == 0) return false;
        if (c.MoveFileExA(from, to, c.MOVEFILE_REPLACE_EXISTING | c.MOVEFILE_WRITE_THROUGH) != 0) return true;
        _ = c.MoveFileExA(old.ptr, to, c.MOVEFILE_REPLACE_EXISTING);
        return false;
    }
    _ = c.chmod(from, 0o755);
    // Guarda o velho para poder voltar se outro arquivo falhar.
    var pb: [1200]u8 = undefined;
    const old = std.fmt.bufPrintSentinel(&pb, "{s}.old", .{std.mem.span(to)}, 0) catch return false;
    _ = c.unlink(old.ptr);
    _ = c.link(to, old.ptr);
    return c.rename(from, to) == 0;
}

/// Desfaz `replaceRunning`.
pub fn restoreOld(to: [*:0]const u8) void {
    var pb: [1200]u8 = undefined;
    const old = std.fmt.bufPrintSentinel(&pb, "{s}.old", .{std.mem.span(to)}, 0) catch return;
    _ = replaceFile(old.ptr, to);
}

/// Memória própria do processo, em KB.
pub fn privateKb() u32 {
    if (!windows) return 0;
    var pm = std.mem.zeroes(c.PROCESS_MEMORY_COUNTERS_EX);
    pm.cb = @sizeOf(c.PROCESS_MEMORY_COUNTERS_EX);
    if (c.K32GetProcessMemoryInfo(c.GetCurrentProcess(), @ptrCast(&pm), pm.cb) == 0) return 0;
    return @intCast(pm.PrivateUsage / 1024);
}
