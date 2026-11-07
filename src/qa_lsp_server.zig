//! Servidor de linguagem de mentira, só para o QA: `sigmacord --qa-lsp-server
//! MODO` (só no build de debug). Fala o protocolo de verdade por stdin/stdout e se comporta mal de
//! propósito, para testar o cliente (net/lsp.zig) sem rodar programa de terceiros.
//! Sem janela e sem SDL: sai antes de o app começar.
//!
//! Modos: normal, crash, crash_late, hang, stubborn, noread, huge, garbage, flood,
//! badinit, ask.
//! `normal` marca as palavras "erro", "aviso" e "dica" do texto recebido. Uma linha
//! com "audit" vira um diagnóstico contando o que o processo enxerga (ambiente,
//! pasta, descritores), para o QA conferir a limpeza. Nenhum valor do ambiente sai
//! daqui, só os nomes.
const std = @import("std");
const c = @import("c");
const L = @import("core/lsp.zig");
const jsonx = @import("net/jsonx.zig");

const gpa = std.heap.c_allocator;

const Mode = enum { normal, crash, crash_late, hang, stubborn, noread, huge, garbage, flood, badinit, ask };

var mode: Mode = .normal;
var opens: u32 = 0;
var changes: u32 = 0;
var closes: u32 = 0;
var root_null = false;
var folders_null = false;
var last_uri: [128]u8 = undefined;
var last_uri_len: usize = 0;
var replies: u32 = 0;

fn writeAll(bytes: []const u8) void {
    var at: usize = 0;
    while (at < bytes.len) {
        const n = c.write(1, bytes.ptr + at, bytes.len - at);
        if (n <= 0) c._exit(0);
        at += @intCast(n);
    }
}

fn send(body: []const u8) void {
    var head: [64]u8 = undefined;
    writeAll(std.fmt.bufPrint(&head, "Content-Length: {d}\r\n\r\n", .{body.len}) catch return);
    writeAll(body);
}

fn sleepForever() noreturn {
    while (true) _ = c.sleep(3600);
}

fn ignoreTerm() void {
    _ = c.signal(c.SIGTERM, c.SIG_IGN);
}

pub fn run(name: []const u8) noreturn {
    mode = std.meta.stringToEnum(Mode, name) orelse c._exit(2);
    switch (mode) {
        .crash => c._exit(3),
        // Não lê nada, não responde nada, não sai com sinal educado.
        .hang => {
            ignoreTerm();
            sleepForever();
        },
        .stubborn, .noread => ignoreTerm(),
        else => {},
    }
    var f: L.Framer = .{};
    var tmp: [64 * 1024]u8 = undefined;
    while (true) {
        const n = c.read(0, &tmp, tmp.len);
        if (n <= 0) {
            // Teimoso: nem o fim do stdin faz sair.
            if (mode == .stubborn or mode == .noread) sleepForever();
            c._exit(0);
        }
        f.feed(gpa, tmp[0..@intCast(n)]) catch c._exit(4);
        while (f.next() catch c._exit(5)) |body| handle(body);
    }
}

fn handle(body: []const u8) void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const root = std.json.parseFromSliceLeaky(std.json.Value, a, body, .{}) catch c._exit(6);
    const id = jsonx.int(jsonx.get(root, "id"));
    const method = jsonx.str(jsonx.get(root, "method")) orelse {
        // Resposta a um pedido nosso (modo `ask`).
        replies += 1;
        return;
    };
    const params = jsonx.get(root, "params");
    if (std.mem.eql(u8, method, "initialize")) {
        if (mode == .badinit) {
            var b: [128]u8 = undefined;
            send(std.fmt.bufPrint(&b, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"error\":{{\"code\":-32603,\"message\":\"nao\"}}}}", .{id orelse 0}) catch return);
            return;
        }
        root_null = jsonx.isNull(if (params) |p| jsonx.get(p, "rootUri") else null);
        folders_null = jsonx.isNull(if (params) |p| jsonx.get(p, "workspaceFolders") else null);
        var b: [160]u8 = undefined;
        send(std.fmt.bufPrint(&b, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"capabilities\":{{\"textDocumentSync\":1}}}}}}", .{id orelse 0}) catch return);
        afterInit();
    } else if (std.mem.eql(u8, method, "textDocument/didOpen")) {
        opens += 1;
        if (mode == .crash_late) c._exit(7);
        const doc = jsonx.get(params.?, "textDocument").?;
        analyze(a, jsonx.str(jsonx.get(doc, "uri")) orelse "", jsonx.int(jsonx.get(doc, "version")) orelse 0, jsonx.str(jsonx.get(doc, "text")) orelse "");
    } else if (std.mem.eql(u8, method, "textDocument/didChange")) {
        changes += 1;
        const doc = jsonx.get(params.?, "textDocument").?;
        const change = jsonx.array(jsonx.get(params.?, "contentChanges"));
        analyze(a, jsonx.str(jsonx.get(doc, "uri")) orelse "", jsonx.int(jsonx.get(doc, "version")) orelse 0, if (change.len > 0) jsonx.str(jsonx.get(change[0], "text")) orelse "" else "");
    } else if (std.mem.eql(u8, method, "textDocument/didClose")) {
        closes += 1;
    } else if (std.mem.eql(u8, method, "shutdown")) {
        if (mode == .stubborn) return;
        var b: [80]u8 = undefined;
        send(std.fmt.bufPrint(&b, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":null}}", .{id orelse 0}) catch return);
    } else if (std.mem.eql(u8, method, "exit")) {
        if (mode == .stubborn) return;
        c._exit(0);
    }
}

fn afterInit() void {
    switch (mode) {
        // Para de ler: o pipe enche e quem escreve não pode travar.
        .noread => sleepForever(),
        // Um quadro maior que o permitido.
        .huge => {
            writeAll("Content-Length: 9000000\r\n\r\n");
            const chunk: [64 * 1024]u8 = @splat('x');
            var left: usize = 9_000_000;
            while (left > 0) {
                const k = @min(left, chunk.len);
                writeAll(chunk[0..k]);
                left -= k;
            }
        },
        // Log escrito em stdout, o erro clássico de servidor mal feito.
        .garbage => writeAll("isto nao e LSP\nnem de longe\r\n\r\n"),
        // Sem parar.
        .flood => {
            const msg = "{\"jsonrpc\":\"2.0\",\"method\":\"window/logMessage\",\"params\":{\"type\":4,\"message\":\"blablablablablablablablablablablablablablablablablablablablablablablablabla\"}}";
            while (true) send(msg);
        },
        // Pedidos que precisam de resposta, senão um servidor de verdade espera para sempre.
        .ask => {
            send("{\"jsonrpc\":\"2.0\",\"id\":100,\"method\":\"workspace/configuration\",\"params\":{\"items\":[{\"section\":\"x\"}]}}");
            send("{\"jsonrpc\":\"2.0\",\"id\":\"s1\",\"method\":\"nao/existe\"}");
        },
        else => {},
    }
}

/// Coluna em unidades de UTF-16 (o que o protocolo pede).
fn utf16Len(s: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const k = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        n += if (k == 4) 2 else 1;
        i += k;
    }
    return n;
}

fn analyze(a: std.mem.Allocator, uri: []const u8, version: i64, text: []const u8) void {
    last_uri_len = @min(uri.len, last_uri.len);
    @memcpy(last_uri[0..last_uri_len], uri[0..last_uri_len]);
    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(a, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":") catch return;
    jsonx.writeString(&out, a, uri) catch return;
    out.print(a, ",\"version\":{d},\"diagnostics\":[", .{version}) catch return;
    var first = true;
    var line: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |row| : (line += 1) {
        const words = [_]struct { w: []const u8, sev: u8 }{ .{ .w = "erro", .sev = 1 }, .{ .w = "aviso", .sev = 2 }, .{ .w = "dica", .sev = 4 } };
        for (words) |x| {
            var from: usize = 0;
            while (std.mem.indexOfPos(u8, row, from, x.w)) |at| {
                from = at + x.w.len;
                const col = utf16Len(row[0..at]);
                if (!first) out.append(a, ',') catch return;
                first = false;
                out.print(a, "{{\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}},\"severity\":{d},\"source\":\"falso\",\"message\":\"achei {s} na linha {d} do bloco\"}}", .{ line, col, line, col + x.w.len, x.sev, x.w, line }) catch return;
            }
        }
        if (std.mem.indexOf(u8, row, "audit") != null) {
            if (!first) out.append(a, ',') catch return;
            first = false;
            out.print(a, "{{\"range\":{{\"start\":{{\"line\":{d},\"character\":0}},\"end\":{{\"line\":{d},\"character\":5}}}},\"severity\":3,\"message\":", .{ line, line }) catch return;
            jsonx.writeString(&out, a, audit(a)) catch return;
            out.append(a, '}') catch return;
        }
    }
    out.appendSlice(a, "]}}") catch return;
    send(out.items);
}

fn audit(a: std.mem.Allocator) []const u8 {
    var o: std.ArrayList(u8) = .empty;
    o.print(a, "pid={d} opens={d} changes={d} closes={d} root_null={} folders_null={} cwd_files={d} fds={d} replies={d} uri={s} env=", .{
        c.getpid(), opens, changes, closes, root_null, folders_null, countDir("."), countFds(), replies, last_uri[0..last_uri_len],
    }) catch return "";
    var i: usize = 0;
    while (std.c.environ[i]) |entry| : (i += 1) {
        const e = std.mem.span(entry);
        const eq = std.mem.indexOfScalar(u8, e, '=') orelse e.len;
        o.print(a, "{s}{s}", .{ if (i > 0) "," else "", e[0..eq] }) catch return o.items;
    }
    return o.items;
}

fn countDir(path: [*:0]const u8) i32 {
    const dir = c.opendir(path) orelse return -1;
    defer _ = c.closedir(dir);
    var n: i32 = 0;
    while (c.readdir(dir)) |entry| {
        const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&entry.*.d_name)), 0);
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        n += 1;
    }
    return n;
}

/// Descritores abertos, sem contar o da própria listagem.
fn countFds() i32 {
    return countDir("/proc/self/fd") - 1;
}
