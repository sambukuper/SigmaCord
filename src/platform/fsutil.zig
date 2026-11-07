//! Arquivos só do dono: configurações (o proxy pode ter usuário:senha),
//! rascunhos, mensagens salvas, cache de mensagens e tokens. Todos gravam
//! do mesmo jeito: num .tmp com permissão 600, inteiro (write parcial
//! continua de onde parou), `fsync` e depois troca de nome; uma queda no meio
//! nunca deixa o arquivo pela metade nem com a permissão padrão.
const std = @import("std");
const sys = @import("sys.zig");
const c = @import("c");

/// $XDG_CONFIG_HOME/sigmacord/<nome> (ou ~/.config/sigmacord/<nome>);
/// `nome` vazio dá a própria pasta.
pub fn configPath(buf: []u8, name: []const u8) ?[:0]const u8 {
    const sep: []const u8 = if (name.len > 0) "/" else "";
    var hb: [512]u8 = undefined;
    const base = sys.configHome(&hb) orelse return null;
    return std.fmt.bufPrintSentinel(buf, "{s}/sigmacord{s}{s}", .{ base, sep, name }, 0) catch null;
}

/// Cria a pasta (e as de cima que faltarem) só para o dono. As nossas
/// (…/sigmacord e o que fica dentro dela) voltam para 700 mesmo se já
/// existiam; as de fora (o ~/.config, o ~/.cache) não mudam de permissão.
pub fn ensureDir(dir: []const u8) bool {
    var buf: [512]u8 = undefined;
    if (dir.len == 0 or dir.len >= buf.len) return false;
    @memcpy(buf[0..dir.len], dir);
    buf[dir.len] = 0;
    var ours = false;
    var start: usize = 0;
    var i: usize = 1;
    while (i <= dir.len) : (i += 1) {
        if (i < dir.len and dir[i] != '/') continue;
        const part = dir[start..i];
        start = i + 1;
        if (std.mem.eql(u8, std.mem.trimStart(u8, part, "/"), "sigmacord")) ours = true;
        const keep = buf[i];
        buf[i] = 0;
        const p: [*:0]const u8 = @ptrCast(&buf);
        sys.mkdirPrivate(p);
        if (ours and !sys.windows) _ = c.chmod(p, 0o700);
        buf[i] = keep;
    }
    return sys.exists(@ptrCast(&buf));
}

/// Grava `bytes` em `path` (só o dono lê), criando a pasta se faltar.
pub fn writePrivate(path: [:0]const u8, bytes: []const u8) bool {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| if (slash > 0) {
        if (!ensureDir(path[0..slash])) return false;
    };
    return replace(path, bytes, true);
}

/// Como `writePrivate`, quando quem chama já sabe que a pasta existe e o
/// conteúdo pode ser refeito (cache): sem esperar o disco confirmar.
pub fn replacePrivate(path: [:0]const u8, bytes: []const u8) bool {
    return replace(path, bytes, false);
}

/// Um arquivo nosso que não deu para ler fica guardado como `<nome>.bad`:
/// o próximo salvamento regravaria por cima o que a pessoa tinha ali.
pub fn keepBroken(path: [:0]const u8) void {
    var buf: [528]u8 = undefined;
    const bad = std.fmt.bufPrintSentinel(&buf, "{s}.bad", .{path}, 0) catch return;
    if (sys.replaceFile(path.ptr, bad.ptr)) std.log.warn("{s} estava ilegível; guardei uma cópia em {s}", .{ path, bad });
}

fn replace(path: [:0]const u8, bytes: []const u8, durable: bool) bool {
    var tbuf: [528]u8 = undefined;
    // Com o PID: duas instâncias abertas não escrevem no mesmo temporário.
    const tmp = std.fmt.bufPrintSentinel(&tbuf, "{s}.{d}.tmp", .{ path, c.getpid() }, 0) catch return false;
    // Sem `durable`, uma queda de energia logo depois pode deixar o arquivo vazio.
    if (!sys.writeNew(tmp.ptr, bytes, durable) or !sys.replaceFile(tmp.ptr, path.ptr)) {
        _ = c.unlink(tmp.ptr);
        return false;
    }
    return true;
}
