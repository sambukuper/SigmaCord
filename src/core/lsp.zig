//! LSP: a parte pura do cliente (sem SDL, sem threads, sem processo): quadros
//! Content-Length, mensagens JSON-RPC, os blocos de código da caixa de texto,
//! o mapeamento de linhas e colunas e a tabela de linguagens conhecidas.
//! Quem abre o processo e fala com ele é net/lsp.zig; quem olha a caixa de
//! texto é ui/lsp_ui.zig. Ver docs/lsp.md.
const std = @import("std");
const builtin = @import("builtin");
const jsonx = @import("../net/jsonx.zig");

/// Uma mensagem do servidor maior que isso é tratada como defeito: o documento
/// tem no máximo `max_doc`, nenhuma resposta legítima chega perto.
pub const max_message: usize = 1024 * 1024;
const max_header: usize = 4096;
/// O texto de um bloco que vai para o servidor.
pub const max_doc: usize = 8 * 1024;
/// Diagnósticos guardados por publicação (os mais graves ficam).
pub const max_diags: usize = 32;
pub const max_argv: usize = 32;

/// Texto curto de tamanho fixo (linguagem, extensão).
pub const Short = struct {
    buf: [24]u8 = undefined,
    len: u8 = 0,

    pub fn of(s: []const u8) Short {
        var o: Short = .{};
        o.len = @intCast(@min(s.len, o.buf.len));
        @memcpy(o.buf[0..o.len], s[0..o.len]);
        return o;
    }

    pub fn slice(s: *const Short) []const u8 {
        return s.buf[0..s.len];
    }

    pub fn eql(a: *const Short, b: []const u8) bool {
        return std.mem.eql(u8, a.slice(), b);
    }
};

// --- Comando (argv, sem shell) -----------------------------------------------

/// Um argv guardado em um bloco só: os argumentos separados por NUL. Não tem
/// ponteiros para dentro de si, então pode ser copiado entre threads.
pub const Command = struct {
    buf: [1024]u8 = undefined,
    len: u16 = 0,
    n: u8 = 0,

    /// false = não coube, ou o argumento tem NUL (não dá para passar a um exec).
    pub fn add(cmd: *Command, arg: []const u8) bool {
        if (cmd.n >= max_argv or @as(usize, cmd.len) + arg.len + 1 > cmd.buf.len) return false;
        if (std.mem.indexOfScalar(u8, arg, 0) != null) return false;
        @memcpy(cmd.buf[cmd.len..][0..arg.len], arg);
        cmd.buf[cmd.len + arg.len] = 0;
        cmd.len += @intCast(arg.len + 1);
        cmd.n += 1;
        return true;
    }

    pub fn bytes(cmd: *const Command) []const u8 {
        return cmd.buf[0..cmd.len];
    }

    pub fn eql(a: *const Command, b: *const Command) bool {
        return std.mem.eql(u8, a.bytes(), b.bytes());
    }

    pub fn iterator(cmd: *const Command) Iterator {
        return .{ .rest = cmd.bytes() };
    }

    pub const Iterator = struct {
        rest: []const u8,

        /// Cada argumento termina em NUL dentro de `buf`.
        pub fn next(it: *Iterator) ?[:0]const u8 {
            if (it.rest.len == 0) return null;
            const end = std.mem.indexOfScalar(u8, it.rest, 0).?;
            const arg = it.rest[0..end :0];
            it.rest = it.rest[end + 1..];
            return arg;
        }
    };

    /// Para mostrar na tela: os argumentos separados por espaço.
    pub fn display(cmd: *const Command, out: []u8) []const u8 {
        var n: usize = 0;
        var it = cmd.iterator();
        while (it.next()) |arg| {
            if (n > 0 and n < out.len) {
                out[n] = ' ';
                n += 1;
            }
            const k = @min(arg.len, out.len - n);
            @memcpy(out[n..][0..k], arg[0..k]);
            n += k;
        }
        return out[0..n];
    }

    /// O nome curto do programa ("/usr/bin/zls" -> "zls").
    pub fn program(cmd: *const Command) []const u8 {
        var it = cmd.iterator();
        const arg = it.next() orelse return "";
        const cut = std.mem.lastIndexOfAny(u8, arg, "/\\") orelse return arg;
        return arg[cut + 1..];
    }
};

/// Texto digitado nas configurações -> argv. Nada de shell: só separa por
/// espaços, com aspas simples ou duplas para quem tem espaço no caminho. A
/// barra invertida é um caractere comum (caminhos do Windows).
pub fn splitArgv(text: []const u8, out: *Command) bool {
    out.* = .{};
    var arg: [1024]u8 = undefined;
    var i: usize = 0;
    while (true) {
        while (i < text.len and isSpace(text[i])) i += 1;
        if (i >= text.len) break;
        var n: usize = 0;
        var quote: u8 = 0;
        while (i < text.len) : (i += 1) {
            const ch = text[i];
            if (quote != 0) {
                if (ch == quote) quote = 0 else {
                    if (n >= arg.len) return false;
                    arg[n] = ch;
                    n += 1;
                }
            } else if (ch == '"' or ch == '\'') {
                quote = ch;
            } else if (isSpace(ch)) {
                break;
            } else {
                if (n >= arg.len) return false;
                arg[n] = ch;
                n += 1;
            }
        }
        if (quote != 0) return false;
        if (!out.add(arg[0..n])) return false;
    }
    if (out.n == 0) return false;
    var it = out.iterator();
    return it.next().?.len > 0;
}

fn isSpace(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r';
}

/// Monta o texto do comando sugerido, com aspas se o caminho tem espaço.
pub fn commandText(out: []u8, path: []const u8, args: []const u8) []const u8 {
    const q: []const u8 = if (std.mem.indexOfScalar(u8, path, ' ') != null) "\"" else "";
    const sep: []const u8 = if (args.len > 0) " " else "";
    return std.fmt.bufPrint(out, "{s}{s}{s}{s}{s}", .{ q, path, q, sep, args }) catch "";
}

// --- Linguagens conhecidas ---------------------------------------------------

/// Uma etiqueta de bloco (```py) e o que ela diz ao servidor.
pub const Tag = struct { tag: []const u8, id: []const u8, ext: []const u8 };
/// Um executável conhecido: só é procurado no PATH, nunca executado para isso.
pub const Exe = struct { name: []const u8, args: []const u8 = "" };

pub const Known = struct {
    /// Nome em settings_state (lsp_on_<key>, lsp_cmd_<key>) e o que os plugins usam.
    key: []const u8,
    label: []const u8,
    tags: []const Tag,
    exes: []const Exe,
};

pub const known = [_]Known{
    .{ .key = "zig", .label = "Zig", .tags = &.{.{ .tag = "zig", .id = "zig", .ext = "zig" }}, .exes = &.{.{ .name = "zls" }} },
    .{ .key = "python", .label = "Python", .tags = &.{
        .{ .tag = "python", .id = "python", .ext = "py" },
        .{ .tag = "py", .id = "python", .ext = "py" },
        .{ .tag = "py3", .id = "python", .ext = "py" },
    }, .exes = &.{
        .{ .name = "ruff", .args = "server" },
        .{ .name = "pyright-langserver", .args = "--stdio" },
        .{ .name = "pylsp" },
    } },
    .{ .key = "rust", .label = "Rust", .tags = &.{
        .{ .tag = "rust", .id = "rust", .ext = "rs" },
        .{ .tag = "rs", .id = "rust", .ext = "rs" },
    }, .exes = &.{.{ .name = "rust-analyzer" }} },
    .{ .key = "cpp", .label = "C / C++", .tags = &.{
        .{ .tag = "c", .id = "c", .ext = "c" },
        .{ .tag = "h", .id = "c", .ext = "h" },
        .{ .tag = "cpp", .id = "cpp", .ext = "cpp" },
        .{ .tag = "c++", .id = "cpp", .ext = "cpp" },
        .{ .tag = "cc", .id = "cpp", .ext = "cpp" },
        .{ .tag = "cxx", .id = "cpp", .ext = "cpp" },
        .{ .tag = "hpp", .id = "cpp", .ext = "hpp" },
    }, .exes = &.{.{ .name = "clangd" }} },
    .{ .key = "go", .label = "Go", .tags = &.{
        .{ .tag = "go", .id = "go", .ext = "go" },
        .{ .tag = "golang", .id = "go", .ext = "go" },
    }, .exes = &.{.{ .name = "gopls" }} },
    .{ .key = "typescript", .label = "TypeScript / JavaScript", .tags = &.{
        .{ .tag = "typescript", .id = "typescript", .ext = "ts" },
        .{ .tag = "ts", .id = "typescript", .ext = "ts" },
        .{ .tag = "tsx", .id = "typescriptreact", .ext = "tsx" },
        .{ .tag = "javascript", .id = "javascript", .ext = "js" },
        .{ .tag = "js", .id = "javascript", .ext = "js" },
        .{ .tag = "jsx", .id = "javascriptreact", .ext = "jsx" },
    }, .exes = &.{.{ .name = "typescript-language-server", .args = "--stdio" }} },
    .{ .key = "lua", .label = "Lua", .tags = &.{.{ .tag = "lua", .id = "lua", .ext = "lua" }}, .exes = &.{.{ .name = "lua-language-server" }} },
};

/// O que uma etiqueta de bloco significa: a linguagem conhecida (índice em
/// `known`) e os nomes que vão para o servidor.
pub const Found = struct { index: usize, tag: Tag };

pub fn findTag(tag: []const u8) ?Found {
    var buf: [16]u8 = undefined;
    if (tag.len == 0 or tag.len > buf.len) return null;
    const low = std.ascii.lowerString(&buf, tag);
    for (known, 0..) |k, i| {
        for (k.tags) |tg| if (std.mem.eql(u8, tg.tag, low)) return .{ .index = i, .tag = tg };
    }
    return null;
}

/// A chave de uma linguagem que um plugin pediu: "py" é a mesma linguagem de
/// "python"; o que o app não conhece vale como está.
pub fn canonicalLang(lang: []const u8) []const u8 {
    return if (findTag(lang)) |f| known[f.index].key else lang;
}

/// Linguagem de um plugin: vira etiqueta de bloco e extensão do documento,
/// então só o que é seguro em uma URI (sem '#', '/', '%', espaço…).
pub fn validLang(lang: []const u8) bool {
    if (lang.len == 0 or lang.len > 16) return false;
    for (lang) |ch| {
        const ok = (ch >= 'a' and ch <= 'z') or (ch >= '0' and ch <= '9') or ch == '_' or ch == '-' or ch == '+';
        if (!ok) return false;
    }
    return true;
}

/// `file://<pasta vazia>/sigmacord-composer.zig`: documento virtual, nada em
/// disco (o texto vai no didOpen). Tem de ser `file:` porque o clangd, entre
/// outros, recusa qualquer outro esquema. A pasta é a do próprio servidor.
pub fn documentUri(out: []u8, dir: []const u8, ext: []const u8) []const u8 {
    var w = std.Io.Writer.fixed(out);
    write: {
        w.writeAll("file://") catch break :write;
        // Windows: `C:\\pasta` vira `/C:/pasta`.
        if (dir.len == 0 or (dir[0] != '/' and dir[0] != '\\')) w.writeByte('/') catch break :write;
        for (dir) |ch| switch (ch) {
            '\\' => w.writeByte('/') catch break :write,
            'A'...'Z', 'a'...'z', '0'...'9', '/', '.', '_', '-', '~', ':' => w.writeByte(ch) catch break :write,
            else => w.print("%{X:0>2}", .{ch}) catch break :write,
        };
        w.print("/sigmacord-composer.{s}", .{ext}) catch break :write;
        return w.buffered();
    }
    return "file:///sigmacord-composer";
}

/// `PATH` é separado por `:` e por `;` no Windows.
pub const path_sep: u8 = if (builtin.os.tag == .windows) ';' else ':';

// --- Liberação de servidores de plugins --------------------------------------

/// O plugin propõe; quem decide é a pessoa, e a decisão vale só para aquele
/// plugin, linguagem e argv exatos. Trocar o argv anula a decisão, senão um
/// plugin liberado uma vez poderia rodar qualquer programa depois.
pub const approval_len = 16;

pub fn approvalKey(plugin: []const u8, lang: []const u8, cmd: *const Command) [approval_len]u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(plugin);
    h.update(&.{0});
    h.update(lang);
    h.update(&.{0});
    h.update(cmd.bytes());
    var digest: [32]u8 = undefined;
    h.final(&digest);
    return std.fmt.bytesToHex(digest[0 .. approval_len / 2].*, .lower);
}

pub fn isApproved(list: []const u8, key: *const [approval_len]u8) bool {
    var it = std.mem.tokenizeScalar(u8, list, ' ');
    while (it.next()) |k| if (std.mem.eql(u8, k, key)) return true;
    return false;
}

/// A lista sem a chave.
pub fn withoutApproval(out: []u8, list: []const u8, key: *const [approval_len]u8) []const u8 {
    var n: usize = 0;
    var it = std.mem.tokenizeScalar(u8, list, ' ');
    while (it.next()) |k| {
        if (std.mem.eql(u8, k, key)) continue;
        if (n + k.len + 1 > out.len) break;
        if (n > 0) {
            out[n] = ' ';
            n += 1;
        }
        @memcpy(out[n..][0..k.len], k);
        n += k.len;
    }
    return out[0..n];
}

/// A lista com a chave; null = não cabe em `limit` bytes.
pub fn withApproval(out: []u8, list: []const u8, key: *const [approval_len]u8, limit: usize) ?[]const u8 {
    if (isApproved(list, key)) return list;
    const n = list.len + @as(usize, if (list.len > 0) 1 else 0) + key.len;
    if (n > limit or n > out.len) return null;
    return std.fmt.bufPrint(out, "{s}{s}{s}", .{ list, if (list.len > 0) " " else "", key }) catch null;
}

// --- Blocos de código na caixa de texto ---------------------------------------

pub const Block = struct {
    tag: []const u8,
    /// Onde o ``` de abertura começa.
    open: usize,
    body_start: usize,
    body_end: usize,
    /// Primeiro byte depois do bloco (o fim do texto, se ainda não fechou).
    end: usize,
    /// Linha da caixa (a partir de 0) onde o corpo começa.
    first_line: u32,
};

/// O bloco de código com etiqueta sob o cursor. Segue a mesma regra de
/// core/markdown.zig (a etiqueta vai até a quebra de linha, até 16 bytes, sem
/// espaço), mas o bloco ainda sem ``` de fechamento conta: está sendo digitado.
pub fn blockAt(text: []const u8, cursor: usize) ?Block {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, text, i, "```")) |open| {
        if (cursor < open) return null;
        const close = std.mem.indexOfPos(u8, text, open + 3, "```");
        const end = if (close) |x| x + 3 else text.len;
        if (cursor > end) {
            i = end;
            continue;
        }
        const nl = std.mem.indexOfScalarPos(u8, text, open + 3, '\n') orelse return null;
        if (close) |x| if (nl >= x) return null;
        const tag = text[open + 3 .. nl];
        if (tag.len == 0 or tag.len > 16 or std.mem.indexOfAny(u8, tag, " \t\r") != null) return null;
        return .{
            .tag = tag,
            .open = open,
            .body_start = nl + 1,
            .body_end = close orelse text.len,
            .end = end,
            .first_line = @intCast(std.mem.count(u8, text[0 .. nl + 1], "\n")),
        };
    }
    return null;
}

/// Os bytes da linha `line` (sem a quebra), ou null se o texto é mais curto.
pub fn lineAt(text: []const u8, line: usize) ?[]const u8 {
    var start: usize = 0;
    var i: usize = 0;
    while (i < line) : (i += 1) {
        const nl = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse return null;
        start = nl + 1;
    }
    const end = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
    return text[start..end];
}

/// O LSP conta colunas em unidades de UTF-16. Devolve o byte correspondente
/// dentro da linha, parando no fim dela se a coluna passa dali.
pub fn utf16ToByte(line: []const u8, col: u32) usize {
    var units: u32 = 0;
    var i: usize = 0;
    while (i < line.len and units < col) {
        const n = std.unicode.utf8ByteSequenceLength(line[i]) catch 1;
        if (i + n > line.len) break;
        units += if (n == 4) 2 else 1;
        i += n;
    }
    return i;
}

// --- Quadros (Content-Length) -------------------------------------------------

/// Junta o que vem do processo em mensagens inteiras. O tamanho é limitado:
/// um servidor doido não faz o buffer crescer sem fim.
pub const Framer = struct {
    buf: std.ArrayList(u8) = .empty,
    start: usize = 0,

    pub const Error = error{ OutOfMemory, BadHeader, TooLarge };

    pub fn deinit(f: *Framer, gpa: std.mem.Allocator) void {
        f.buf.deinit(gpa);
        f.* = .{};
    }

    /// Invalida o que `next` devolveu antes.
    pub fn feed(f: *Framer, gpa: std.mem.Allocator, bytes: []const u8) Error!void {
        if (f.start > 0) {
            const rest = f.buf.items[f.start..];
            std.mem.copyForwards(u8, f.buf.items[0..rest.len], rest);
            f.buf.items.len = rest.len;
            f.start = 0;
        }
        if (f.buf.items.len + bytes.len > max_message + max_header + 64 * 1024) return error.TooLarge;
        try f.buf.appendSlice(gpa, bytes);
    }

    /// O corpo da próxima mensagem completa, ou null se ainda falta chegar.
    pub fn next(f: *Framer) Error!?[]const u8 {
        const rest = f.buf.items[f.start..];
        const head_end = std.mem.indexOf(u8, rest, "\r\n\r\n") orelse {
            if (rest.len > max_header) return error.BadHeader;
            return null;
        };
        if (head_end > max_header) return error.BadHeader;
        var length: ?usize = null;
        var it = std.mem.splitSequence(u8, rest[0..head_end], "\r\n");
        while (it.next()) |line| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.BadHeader;
            if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " \t"), "content-length")) continue;
            length = std.fmt.parseInt(usize, std.mem.trim(u8, line[colon + 1 ..], " \t"), 10) catch return error.BadHeader;
        }
        const len = length orelse return error.BadHeader;
        if (len > max_message) return error.TooLarge;
        const body_at = head_end + 4;
        if (rest.len < body_at + len) return null;
        f.start += body_at + len;
        return rest[body_at..][0..len];
    }
};

// --- Mensagens que saem --------------------------------------------------------

fn frame(out: *std.ArrayList(u8), gpa: std.mem.Allocator, body: []const u8) !void {
    try out.print(gpa, "Content-Length: {d}\r\n\r\n", .{body.len});
    try out.appendSlice(gpa, body);
}

/// `rootUri` nulo e sem pastas: o servidor não tem por que olhar projeto nenhum.
pub fn writeInitialize(out: *std.ArrayList(u8), gpa: std.mem.Allocator, id: i64) !void {
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(gpa);
    try b.print(gpa,
        \\{{"jsonrpc":"2.0","id":{d},"method":"initialize","params":{{"processId":null,"clientInfo":{{"name":"SigmaCord"}},"rootUri":null,"rootPath":null,"workspaceFolders":null,"capabilities":{{"general":{{"positionEncodings":["utf-16"]}},"textDocument":{{"synchronization":{{"didSave":false,"willSave":false}},"publishDiagnostics":{{"versionSupport":true}}}},"workspace":{{"configuration":false,"workspaceFolders":false}}}}}}}}
    , .{id});
    try frame(out, gpa, b.items);
}

pub fn writeNotification(out: *std.ArrayList(u8), gpa: std.mem.Allocator, method: []const u8) !void {
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(gpa);
    const params: []const u8 = if (std.mem.eql(u8, method, "initialized")) ",\"params\":{}" else "";
    try b.print(gpa, "{{\"jsonrpc\":\"2.0\",\"method\":\"{s}\"{s}}}", .{ method, params });
    try frame(out, gpa, b.items);
}

pub fn writeShutdown(out: *std.ArrayList(u8), gpa: std.mem.Allocator, id: i64) !void {
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(gpa);
    try b.print(gpa, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"shutdown\"}}", .{id});
    try frame(out, gpa, b.items);
}

pub fn writeDidOpen(out: *std.ArrayList(u8), gpa: std.mem.Allocator, uri: []const u8, language_id: []const u8, version: i64, text: []const u8) !void {
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(gpa);
    try b.appendSlice(gpa, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":");
    try jsonx.writeString(&b, gpa, uri);
    try b.appendSlice(gpa, ",\"languageId\":");
    try jsonx.writeString(&b, gpa, language_id);
    try b.print(gpa, ",\"version\":{d},\"text\":", .{version});
    try jsonx.writeString(&b, gpa, text);
    try b.appendSlice(gpa, "}}}");
    try frame(out, gpa, b.items);
}

/// Sempre o texto inteiro: é pouco (uma mensagem do Discord) e vale para
/// qualquer servidor, incremental ou não.
pub fn writeDidChange(out: *std.ArrayList(u8), gpa: std.mem.Allocator, uri: []const u8, version: i64, text: []const u8) !void {
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(gpa);
    try b.appendSlice(gpa, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{\"uri\":");
    try jsonx.writeString(&b, gpa, uri);
    try b.print(gpa, ",\"version\":{d}}},\"contentChanges\":[{{\"text\":", .{version});
    try jsonx.writeString(&b, gpa, text);
    try b.appendSlice(gpa, "}]}}");
    try frame(out, gpa, b.items);
}

pub fn writeDidClose(out: *std.ArrayList(u8), gpa: std.mem.Allocator, uri: []const u8) !void {
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(gpa);
    try b.appendSlice(gpa, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didClose\",\"params\":{\"textDocument\":{\"uri\":");
    try jsonx.writeString(&b, gpa, uri);
    try b.appendSlice(gpa, "}}}");
    try frame(out, gpa, b.items);
}

// --- Mensagens que chegam -------------------------------------------------------

pub const Severity = enum(u8) { err = 1, warning = 2, info = 3, hint = 4 };

pub const Diag = struct {
    /// Relativos ao bloco, como o servidor mandou (coluna em UTF-16).
    line: u32 = 0,
    col: u32 = 0,
    end_line: u32 = 0,
    end_col: u32 = 0,
    severity: Severity = .err,
    msg_len: u8 = 0,
    msg: [200]u8 = undefined,

    pub fn message(g: *const Diag) []const u8 {
        return g.msg[0..g.msg_len];
    }
};

pub const Event = union(enum) {
    ignored,
    response: struct { id: i64, ok: bool },
    /// `n` diagnósticos em `out` (os mais graves), de `total`.
    diagnostics: struct { version: ?i64, n: usize, total: usize },
};

const Value = std.json.Value;

/// Interpreta uma mensagem do servidor. Pedidos dele (workspace/configuration e
/// companhia) ganham resposta em `reply`: um servidor que espera e nunca recebe
/// fica parado. Diagnósticos de outro documento são ignorados.
pub fn handleMessage(gpa: std.mem.Allocator, body: []const u8, uri: []const u8, out: []Diag, reply: *std.ArrayList(u8)) !Event {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const root = std.json.parseFromSliceLeaky(Value, arena.allocator(), body, .{}) catch return error.BadJson;
    if (root != .object) return error.BadJson;
    const method = jsonx.str(jsonx.get(root, "method"));
    const id = jsonx.get(root, "id");
    if (method) |m| {
        if (id) |req_id| {
            try writeReply(gpa, reply, req_id, m, jsonx.get(root, "params"));
            return .ignored;
        }
        if (!std.mem.eql(u8, m, "textDocument/publishDiagnostics")) return .ignored;
        const params = jsonx.get(root, "params") orelse return .ignored;
        const got = jsonx.str(jsonx.get(params, "uri")) orelse return .ignored;
        // Só o nome: o servidor pode devolver o caminho normalizado.
        if (!std.mem.eql(u8, std.fs.path.basenamePosix(got), std.fs.path.basenamePosix(uri))) return .ignored;
        const version = if (jsonx.get(params, "version")) |v| (if (v == .integer) v.integer else null) else null;
        const items = jsonx.array(jsonx.get(params, "diagnostics"));
        return .{ .diagnostics = .{ .version = version, .n = collectDiags(items, out), .total = items.len } };
    }
    if (id) |v| if (v == .integer) {
        return .{ .response = .{ .id = v.integer, .ok = jsonx.get(root, "error") == null } };
    };
    return .ignored;
}

fn writeReply(gpa: std.mem.Allocator, reply: *std.ArrayList(u8), id: Value, method: []const u8, params: ?Value) !void {
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(gpa);
    try b.appendSlice(gpa, "{\"jsonrpc\":\"2.0\",\"id\":");
    switch (id) {
        .integer => |i| try b.print(gpa, "{d}", .{i}),
        .string, .number_string => |s| try jsonx.writeString(&b, gpa, s),
        else => try b.appendSlice(gpa, "null"),
    }
    if (std.mem.eql(u8, method, "workspace/configuration")) {
        // Sem configuração: um null para cada item pedido.
        const n = @min(jsonx.array(if (params) |p| jsonx.get(p, "items") else null).len, 256);
        try b.appendSlice(gpa, ",\"result\":[");
        for (0..n) |i| try b.appendSlice(gpa, if (i == 0) "null" else ",null");
        try b.append(gpa, ']');
    } else if (std.mem.eql(u8, method, "client/registerCapability") or
        std.mem.eql(u8, method, "client/unregisterCapability") or
        std.mem.eql(u8, method, "window/workDoneProgress/create") or
        std.mem.eql(u8, method, "window/showMessageRequest") or
        std.mem.eql(u8, method, "workspace/workspaceFolders"))
    {
        try b.appendSlice(gpa, ",\"result\":null");
    } else {
        try b.appendSlice(gpa, ",\"error\":{\"code\":-32601,\"message\":\"method not found\"}");
    }
    try b.append(gpa, '}');
    try frame(reply, gpa, b.items);
}

fn clampU32(v: ?i64) u32 {
    return @intCast(std.math.clamp(v orelse 0, 0, std.math.maxInt(u32)));
}

fn collectDiags(items: []const Value, out: []Diag) usize {
    var n: usize = 0;
    for (items) |it| {
        const text = jsonx.str(jsonx.get(it, "message")) orelse continue;
        var g: Diag = .{};
        const sev = jsonx.int(jsonx.get(it, "severity")) orelse 1;
        g.severity = if (sev >= 1 and sev <= 4) @enumFromInt(@as(u8, @intCast(sev))) else .err;
        const range = jsonx.get(it, "range");
        const st = if (range) |r| jsonx.get(r, "start") else null;
        const en = if (range) |r| jsonx.get(r, "end") else null;
        g.line = clampU32(if (st) |p| jsonx.int(jsonx.get(p, "line")) else null);
        g.col = clampU32(if (st) |p| jsonx.int(jsonx.get(p, "character")) else null);
        g.end_line = clampU32(if (en) |p| jsonx.int(jsonx.get(p, "line")) else null);
        g.end_col = clampU32(if (en) |p| jsonx.int(jsonx.get(p, "character")) else null);
        g.msg_len = @intCast(cleanMessage(&g.msg, text).len);
        // Lotado: fica com os mais graves (e as primeiras linhas).
        if (n < out.len) {
            out[n] = g;
            n += 1;
        } else {
            var worst: usize = 0;
            for (out, 0..) |o, i| {
                if (before(&out[worst], &o)) worst = i;
            }
            if (before(&g, &out[worst])) out[worst] = g;
        }
    }
    // Inserção: são no máximo `max_diags`, e o block sort pesa 40 KB no executável.
    std.sort.insertion(Diag, out[0..n], {}, struct {
        fn lt(_: void, a: Diag, b: Diag) bool {
            return before(&a, &b);
        }
    }.lt);
    return n;
}

fn before(a: *const Diag, b: *const Diag) bool {
    if (a.severity != b.severity) return @intFromEnum(a.severity) < @intFromEnum(b.severity);
    if (a.line != b.line) return a.line < b.line;
    return a.col < b.col;
}

/// O texto vem de outro programa: uma linha só, sem caracteres de controle,
/// UTF-8 válido e cortado sem partir um caractere.
fn cleanMessage(out: []u8, text: []const u8) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch {
            i += 1;
            continue;
        };
        if (i + len > text.len or !std.unicode.utf8ValidateSlice(text[i..][0..len])) {
            i += 1;
            continue;
        }
        if (n + len > out.len) break;
        if (len == 1 and text[i] < 0x20) {
            // Várias quebras seguidas viram um espaço só.
            if (n > 0 and out[n - 1] != ' ') {
                out[n] = ' ';
                n += 1;
            }
        } else {
            @memcpy(out[n..][0..len], text[i..][0..len]);
            n += len;
        }
        i += len;
    }
    return std.mem.trimEnd(u8, out[0..n], " ");
}

// --- Testes ---------------------------------------------------------------------

const t = std.testing;

test "quadros inteiros, partidos e em sequência" {
    var f: Framer = .{};
    defer f.deinit(t.allocator);
    try f.feed(t.allocator, "Content-Length: 5\r\nContent-Type: x\r\n\r\nhel");
    try t.expect((try f.next()) == null);
    try f.feed(t.allocator, "loconTent-LENGTH:2\r\n\r\nok");
    try t.expectEqualStrings("hello", (try f.next()).?);
    try t.expectEqualStrings("ok", (try f.next()).?);
    try t.expect((try f.next()) == null);
}

test "quadros: cabeçalho ruim e mensagem grande demais" {
    {
        var f: Framer = .{};
        defer f.deinit(t.allocator);
        try f.feed(t.allocator, "lixo sem dois pontos\r\n\r\n");
        try t.expectError(error.BadHeader, f.next());
    }
    {
        var f: Framer = .{};
        defer f.deinit(t.allocator);
        try f.feed(t.allocator, "Content-Type: x\r\n\r\n");
        try t.expectError(error.BadHeader, f.next());
    }
    {
        var f: Framer = .{};
        defer f.deinit(t.allocator);
        try f.feed(t.allocator, "Content-Length: 99999999999\r\n\r\n");
        try t.expectError(error.TooLarge, f.next());
    }
    {
        // Lixo sem fim de cabeçalho não fica acumulando.
        var f: Framer = .{};
        defer f.deinit(t.allocator);
        const junk: [8000]u8 = @splat('x');
        try f.feed(t.allocator, &junk);
        try t.expectError(error.BadHeader, f.next());
    }
    {
        // O buffer tem teto mesmo com um Content-Length válido enorme.
        var f: Framer = .{};
        defer f.deinit(t.allocator);
        const chunk = try t.allocator.alloc(u8, max_message + 128 * 1024);
        defer t.allocator.free(chunk);
        try t.expectError(error.TooLarge, f.feed(t.allocator, chunk));
    }
}

test "initialize não aponta para projeto nenhum" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(t.allocator);
    try writeInitialize(&out, t.allocator, 1);
    var f: Framer = .{};
    defer f.deinit(t.allocator);
    try f.feed(t.allocator, out.items);
    const body = (try f.next()).?;
    const parsed = try std.json.parseFromSlice(Value, t.allocator, body, .{});
    defer parsed.deinit();
    const p = jsonx.get(parsed.value, "params").?;
    try t.expect(jsonx.get(p, "rootUri").? == .null);
    try t.expect(jsonx.get(p, "workspaceFolders").? == .null);
    try t.expectEqualStrings("initialize", jsonx.str(jsonx.get(parsed.value, "method")).?);
}

test "didChange é JSON válido com aspas, barras e quebras no texto" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(t.allocator);
    try writeDidChange(&out, t.allocator, "untitled:x.zig", 7, "a = \"b\\c\"\n\tç\x01");
    var f: Framer = .{};
    defer f.deinit(t.allocator);
    try f.feed(t.allocator, out.items);
    const parsed = try std.json.parseFromSlice(Value, t.allocator, (try f.next()).?, .{});
    defer parsed.deinit();
    const p = jsonx.get(parsed.value, "params").?;
    try t.expectEqual(@as(i64, 7), jsonx.int(jsonx.get(jsonx.get(p, "textDocument").?, "version")).?);
    const changes = jsonx.array(jsonx.get(p, "contentChanges"));
    try t.expectEqualStrings("a = \"b\\c\"\n\tç\x01", jsonx.str(jsonx.get(changes[0], "text")).?);
}

test "diagnósticos: lê, limpa o texto, ordena e ignora outro documento" {
    const body =
        \\{"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"untitled:a.zig","version":3,"diagnostics":[
        \\ {"range":{"start":{"line":4,"character":2},"end":{"line":4,"character":6}},"severity":2,"message":"aviso"},
        \\ {"range":{"start":{"line":1,"character":0},"end":{"line":1,"character":9}},"severity":1,"message":"linha um\nlinha dois\u0007"},
        \\ {"range":{"start":{"line":-5,"character":99999999999},"end":{"line":0,"character":0}},"severity":77,"message":"esquisito"},
        \\ {"range":{},"message":123}
        \\]}}
    ;
    var reply: std.ArrayList(u8) = .empty;
    defer reply.deinit(t.allocator);
    var out: [8]Diag = undefined;
    const e = try handleMessage(t.allocator, body, "untitled:a.zig", &out, &reply);
    try t.expectEqual(@as(usize, 3), e.diagnostics.n);
    try t.expectEqual(@as(usize, 4), e.diagnostics.total);
    try t.expectEqual(@as(?i64, 3), e.diagnostics.version);
    // Severidade desconhecida conta como erro; primeiro os erros, por linha.
    try t.expectEqualStrings("esquisito", out[0].message());
    try t.expectEqual(@as(u32, 0), out[0].line);
    try t.expectEqual(@as(u32, std.math.maxInt(u32)), out[0].col);
    try t.expectEqualStrings("linha um linha dois", out[1].message());
    try t.expectEqual(Severity.warning, out[2].severity);
    try t.expectEqual(@as(u32, 6), out[2].end_col);
    try t.expectEqual(Event.ignored, try handleMessage(t.allocator, body, "untitled:outro.zig", &out, &reply));
    try t.expectEqual(@as(usize, 0), reply.items.len);
}

test "diagnósticos demais: ficam os mais graves" {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(t.allocator);
    try list.appendSlice(t.allocator, "{\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":\"u\",\"diagnostics\":[");
    for (0..100) |i| try list.print(t.allocator, "{{\"range\":{{\"start\":{{\"line\":{d},\"character\":0}}}},\"severity\":{d},\"message\":\"m\"}},", .{ i, @as(u32, if (i == 90) 1 else 3) });
    try list.appendSlice(t.allocator, "{\"message\":\"fim\",\"severity\":4}]}}");
    var reply: std.ArrayList(u8) = .empty;
    defer reply.deinit(t.allocator);
    var out: [4]Diag = undefined;
    const e = try handleMessage(t.allocator, list.items, "u", &out, &reply);
    try t.expectEqual(@as(usize, 4), e.diagnostics.n);
    try t.expectEqual(@as(usize, 101), e.diagnostics.total);
    try t.expectEqual(@as(u32, 90), out[0].line);
    try t.expectEqual(Severity.err, out[0].severity);
    try t.expectEqual(@as(u32, 0), out[1].line);
}

test "mensagem de diagnóstico: corte sem partir caractere e UTF-8 ruim" {
    var out: [8]u8 = undefined;
    try t.expectEqualStrings("çççç", cleanMessage(&out, "ççççç"));
    try t.expectEqualStrings("ab", cleanMessage(&out, "a\xffb"));
    try t.expectEqualStrings("a b", cleanMessage(&out, "a\r\nb\n"));
}

test "pedidos do servidor sempre têm resposta" {
    var reply: std.ArrayList(u8) = .empty;
    defer reply.deinit(t.allocator);
    var out: [1]Diag = undefined;
    _ = try handleMessage(t.allocator, "{\"id\":\"abc\",\"method\":\"workspace/configuration\",\"params\":{\"items\":[{},{},{}]}}", "u", &out, &reply);
    _ = try handleMessage(t.allocator, "{\"id\":9,\"method\":\"window/workDoneProgress/create\"}", "u", &out, &reply);
    _ = try handleMessage(t.allocator, "{\"id\":10,\"method\":\"nao/existe\"}", "u", &out, &reply);
    var f: Framer = .{};
    defer f.deinit(t.allocator);
    try f.feed(t.allocator, reply.items);
    try t.expect(std.mem.indexOf(u8, (try f.next()).?, "\"id\":\"abc\",\"result\":[null,null,null]") != null);
    try t.expect(std.mem.indexOf(u8, (try f.next()).?, "\"id\":9,\"result\":null") != null);
    try t.expect(std.mem.indexOf(u8, (try f.next()).?, "-32601") != null);
}

test "respostas e JSON quebrado" {
    var reply: std.ArrayList(u8) = .empty;
    defer reply.deinit(t.allocator);
    var out: [1]Diag = undefined;
    const ok = try handleMessage(t.allocator, "{\"id\":4,\"result\":null}", "u", &out, &reply);
    try t.expectEqual(@as(i64, 4), ok.response.id);
    try t.expect(ok.response.ok);
    const bad = try handleMessage(t.allocator, "{\"id\":5,\"error\":{\"code\":1}}", "u", &out, &reply);
    try t.expect(!bad.response.ok);
    try t.expectError(error.BadJson, handleMessage(t.allocator, "{nao", "u", &out, &reply));
    try t.expectError(error.BadJson, handleMessage(t.allocator, "[1,2]", "u", &out, &reply));
}

test "bloco sob o cursor" {
    const s = "oi\n\n```zig\nconst a = 1;\nb\n```\nfim\n```py\nx\n";
    // Antes do bloco e depois dele: nada.
    try t.expect(blockAt(s, 1) == null);
    try t.expect(blockAt(s, std.mem.indexOf(u8, s, "fim").? + 1) == null);
    const b = blockAt(s, std.mem.indexOf(u8, s, "const").?).?;
    try t.expectEqualStrings("zig", b.tag);
    try t.expectEqual(@as(u32, 3), b.first_line);
    try t.expectEqualStrings("const a = 1;\nb\n", s[b.body_start..b.body_end]);
    // Ainda sem fechar: vai até o fim do texto.
    const p = blockAt(s, s.len).?;
    try t.expectEqualStrings("py", p.tag);
    try t.expectEqual(s.len, p.end);
    try t.expectEqual(@as(u32, 8), p.first_line);
    try t.expectEqualStrings("x\n", s[p.body_start..p.body_end]);
}

test "bloco: as mesmas regras do markdown" {
    // Sem etiqueta, com espaço, longa demais, ou tudo numa linha só: não conta.
    try t.expect(blockAt("```\ncodigo\n```", 5) == null);
    try t.expect(blockAt("```nao vale\ncodigo\n```", 15) == null);
    try t.expect(blockAt("```umaetiquetamuitolonga\nx\n```", 27) == null);
    try t.expect(blockAt("```zig x = 1```", 6) == null);
    try t.expect(blockAt("```zig", 6) == null);
    // Fechar na mesma linha do código.
    const b = blockAt("```zig\nx```", 8).?;
    try t.expectEqualStrings("x", "```zig\nx```"[b.body_start..b.body_end]);
    // Corpo vazio.
    const v = blockAt("```zig\n", 7).?;
    try t.expectEqual(v.body_start, v.body_end);
    // CRLF não deixa a etiqueta com \r: não bate.
    try t.expect(blockAt("```zig\r\nx", 9) == null);
}

test "linhas e colunas" {
    try t.expectEqualStrings("b", lineAt("a\nb\nc", 1).?);
    try t.expectEqualStrings("", lineAt("a\n", 1).?);
    try t.expect(lineAt("a", 1) == null);
    // ç = 1 unidade e 2 bytes; 😀 = 2 unidades e 4 bytes.
    try t.expectEqual(@as(usize, 0), utf16ToByte("açb", 0));
    try t.expectEqual(@as(usize, 3), utf16ToByte("açb", 2));
    try t.expectEqual(@as(usize, 4), utf16ToByte("😀b", 2));
    try t.expectEqual(@as(usize, 5), utf16ToByte("😀ab", 3));
    // Passou do fim da linha ou bytes ruins: para onde dá.
    try t.expectEqual(@as(usize, 2), utf16ToByte("ab", 50));
    try t.expectEqual(@as(usize, 1), utf16ToByte("\xf0", 50) + 1);
}

test "comando sem shell" {
    var cmd: Command = .{};
    try t.expect(splitArgv("  zls  --flag ", &cmd));
    var it = cmd.iterator();
    try t.expectEqualStrings("zls", it.next().?);
    try t.expectEqualStrings("--flag", it.next().?);
    try t.expect(it.next() == null);
    try t.expectEqualStrings("zls", cmd.program());

    try t.expect(splitArgv("\"/opt/meu servidor/bin\" 'a b' c\"d e\"f", &cmd));
    it = cmd.iterator();
    try t.expectEqualStrings("/opt/meu servidor/bin", it.next().?);
    try t.expectEqualStrings("a b", it.next().?);
    try t.expectEqualStrings("cd ef", it.next().?);
    try t.expectEqualStrings("bin", cmd.program());

    // O que seria shell é só texto.
    try t.expect(splitArgv("zls; rm -rf $HOME | x", &cmd));
    it = cmd.iterator();
    try t.expectEqualStrings("zls;", it.next().?);
    try t.expectEqualStrings("rm", it.next().?);
    try t.expectEqualStrings("-rf", it.next().?);
    try t.expectEqualStrings("$HOME", it.next().?);
    // Caminho do Windows.
    try t.expect(splitArgv("C:\\tools\\zls.exe", &cmd));
    try t.expectEqualStrings("zls.exe", cmd.program());

    try t.expect(!splitArgv("", &cmd));
    try t.expect(!splitArgv("   ", &cmd));
    try t.expect(!splitArgv("\"sem fechar", &cmd));
    try t.expect(!splitArgv("\"\" x", &cmd));

    var big: Command = .{};
    for (0..max_argv) |_| try t.expect(big.add("x"));
    try t.expect(!big.add("x"));
    var nul: Command = .{};
    try t.expect(!nul.add("a\x00b"));
    var buf: [32]u8 = undefined;
    try t.expect(splitArgv("a b", &cmd));
    try t.expectEqualStrings("a b", cmd.display(&buf));
    try t.expectEqualStrings("\"/a b/c\" --x", commandText(&buf, "/a b/c", "--x"));
    try t.expectEqualStrings("/a/c", commandText(&buf, "/a/c", ""));
}

test "etiquetas" {
    try t.expectEqualStrings("python", known[findTag("PY").?.index].key);
    try t.expectEqualStrings("javascript", findTag("js").?.tag.id);
    try t.expectEqualStrings("typescript", known[findTag("js").?.index].key);
    try t.expectEqualStrings("c", findTag("c").?.tag.id);
    try t.expect(findTag("cobol") == null);
    try t.expect(findTag("") == null);
    try t.expectEqualStrings("python", canonicalLang("py"));
    try t.expectEqualStrings("haskell", canonicalLang("haskell"));
    try t.expect(validLang("haskell"));
    try t.expect(validLang("c++"));
    try t.expect(!validLang("c#"));
    try t.expect(!validLang("a/b"));
    try t.expect(!validLang("Zig"));
    try t.expect(!validLang(""));
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("file:///tmp/a%20b/sigmacord-composer.zig", documentUri(&buf, "/tmp/a b", "zig"));
    try t.expectEqualStrings("file:///C:/x/sigmacord-composer.c", documentUri(&buf, "C:\\x", "c"));
}

test "liberação de plugin vale só para aquele argv" {
    var a: Command = .{};
    var b: Command = .{};
    try t.expect(a.add("zls"));
    try t.expect(b.add("zls"));
    try t.expect(b.add("--outra"));
    const ka = approvalKey("p.lua", "zig", &a);
    const kb = approvalKey("p.lua", "zig", &b);
    try t.expect(!std.mem.eql(u8, &ka, &kb));
    try t.expect(!std.mem.eql(u8, &ka, &approvalKey("q.lua", "zig", &a)));
    try t.expect(!std.mem.eql(u8, &ka, &approvalKey("p.lua", "py", &a)));

    var buf: [255]u8 = undefined;
    const one = withApproval(&buf, "", &ka, 255).?;
    try t.expect(isApproved(one, &ka));
    try t.expect(!isApproved(one, &kb));
    var buf2: [255]u8 = undefined;
    const two = withApproval(&buf2, one, &kb, 255).?;
    try t.expect(isApproved(two, &ka) and isApproved(two, &kb));
    var buf3: [255]u8 = undefined;
    const back = withoutApproval(&buf3, two, &ka);
    try t.expect(!isApproved(back, &ka) and isApproved(back, &kb));
    // Sem espaço: nega em vez de cortar a lista.
    try t.expect(withApproval(&buf3, two, &approvalKey("r.lua", "go", &a), two.len) == null);
}
