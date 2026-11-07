//! QA dos erros de código (LSP). O servidor é sempre o de mentira, o próprio
//! binário com `--qa-lsp-server MODO` (src/qa_lsp_server.zig): nenhum programa de
//! terceiros roda aqui. O SIGMACORD_TOKEN do teste é um valor falso, só para conferir
//! que ele não chega ao filho.
//! `QA_SUITE=lsp` roda isto; `QA_SUITE=lsp-quit` deixa um servidor de pé (travado,
//! com QA_LSP_MODE) e sai: quem confere se ele morreu é tools/qa_lsp.sh.
const std = @import("std");
const c = @import("c");
const App = @import("app.zig").App;
const R = @import("qa_runner.zig");
const Op = R.Op;
const qa = @import("ui/qa.zig");
const autocomplete = @import("ui/autocomplete.zig");
const lsp_ui = @import("ui/lsp_ui.zig");
const S = @import("ui/settings_state.zig");
const L = @import("core/lsp.zig");
const net = @import("net/lsp.zig");
const engine = @import("plugins/engine.zig");

fn s(name: []const u8) Op {
    return .{ .section = name };
}
fn click(k: []const u8) Op {
    return .{ .click = .{ .mark = k } };
}
fn expect(name: []const u8, f: *const fn (*App) bool) Op {
    return .{ .expect = .{ .name = name, .check = f } };
}
fn expectLong(name: []const u8, f: *const fn (*App) bool) Op {
    return .{ .expect = .{ .name = name, .check = f, .timeout_ms = 7000 } };
}
fn run(f: *const fn (*App) void) Op {
    return .{ .run = f };
}
fn shot(name: []const u8) Op {
    return .{ .shot = name };
}
const shift_enter: Op = .{ .key = .{ .key = c.ImGuiKey_Enter, .shift = true } };
const open_settings: Op = .{ .key = .{ .key = c.ImGuiKey_Comma, .ctrl = true } };

// --- Preparação ---------------------------------------------------------------------

var self_buf: [700:0]u8 = @splat(0);
var cwd_buf: [700:0]u8 = @splat(0);
var path_saved: [4096:0]u8 = @splat(0);
var path_had = false;

fn setEnv(k: [*:0]const u8, v: [*:0]const u8) void {
    _ = c.setenv(k, v, 1);
    _ = c.SDL_SetEnvironmentVariable(c.SDL_GetEnvironment(), k, v, true);
}

fn selfPath() []const u8 {
    return std.mem.sliceTo(&self_buf, 0);
}

fn prepare(_: *App) void {
    const base = c.SDL_GetBasePath() orelse return;
    _ = std.fmt.bufPrintSentinel(&self_buf, "{s}sigmacord", .{std.mem.span(base)}, 0) catch return;
    const cwd = c.SDL_GetCurrentDirectory() orelse return;
    defer c.SDL_free(cwd);
    _ = std.fmt.bufPrintSentinel(&cwd_buf, "{s}", .{std.mem.span(cwd)}, 0) catch return;
    const dir = std.mem.sliceTo(&cwd_buf, 0);
    if (c.SDL_getenv("PATH")) |p| {
        _ = std.fmt.bufPrintSentinel(&path_saved, "{s}", .{std.mem.span(p)}, 0) catch {};
        path_had = true;
    }
    _ = c.SDL_CreateDirectory("qa-out/lsp-bin");
    _ = c.SDL_CreateDirectory("qa-out/lsp-rel");
    _ = c.SDL_CreateDirectory("qa-out/lsp-scratch");
    _ = c.SDL_RemovePath("qa-out/lsp-rodou");
    // O comando pelo nome, encontrado no PATH.
    _ = c.SDL_RemovePath("qa-out/lsp-bin/fake-lsp-qa");
    _ = c.symlink(&self_buf, "qa-out/lsp-bin/fake-lsp-qa");
    // Um "zls" que só existe aqui e denuncia se for executado.
    var script: [2000]u8 = undefined;
    const body = std.fmt.bufPrint(&script, "#!/bin/sh\n: > '{s}/qa-out/lsp-rodou'\nexec '{s}' --qa-lsp-server normal\n", .{ dir, selfPath() }) catch return;
    _ = c.SDL_SaveFile("qa-out/lsp-bin/zls", body.ptr, body.len);
    _ = c.chmod("qa-out/lsp-bin/zls", 0o755);
    // Numa entrada relativa do PATH: não pode ser sugerido.
    _ = c.SDL_SaveFile("qa-out/lsp-rel/clangd", body.ptr, body.len);
    _ = c.chmod("qa-out/lsp-rel/clangd", 0o755);
    var pb: [1000]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&pb, "qa-out/lsp-rel:{s}/qa-out/lsp-bin", .{dir}, 0) catch return;
    setEnv("PATH", path.ptr);
    setEnv("SIGMACORD_TOKEN", "qa-valor-falso-nao-e-token");
    // Sobra de uma execução anterior: a pasta tem que chegar vazia ao servidor.
    _ = c.SDL_SaveFile("qa-out/lsp-scratch/sobra.txt", "x", 1);
    net.tuning = .{};
}

fn cleanup(app: *App) void {
    const set = &app.st.settings;
    for (0..L.known.len) |i| {
        S.lspOn(set, i).* = false;
        S.lspCmd(set, i).* = .{};
    }
    set.lsp_plugins_ok = .{};
    net.tuning = .{};
    if (path_had) setEnv("PATH", &path_saved);
    _ = c.unsetenv("SIGMACORD_TOKEN");
    _ = c.SDL_UnsetEnvironmentVariable(c.SDL_GetEnvironment(), "SIGMACORD_TOKEN");
    _ = c.SDL_RemovePath("qa-out/plugins/lsp-qa.lua");
    if (engine.current) |e| e.reload();
    @memset(&app.st.input, 0);
    app.st.input_sync = true;
}

// --- Texto e comandos -----------------------------------------------------------------

fn setText(app: *App, text: []const u8, cursor: usize) void {
    @memset(&app.st.input, 0);
    @memcpy(app.st.input[0..text.len], text);
    app.st.input_sync = true;
    autocomplete.pending_cursor = cursor;
    app.st.focus_input = true;
}

/// Texto com o cursor onde está o `|`.
fn setMarked(app: *App, marked: []const u8) void {
    var buf: [1000]u8 = undefined;
    const at = std.mem.indexOfScalar(u8, marked, '|').?;
    @memcpy(buf[0..at], marked[0..at]);
    const tail = marked[at + 1 ..];
    @memcpy(buf[at..][0..tail.len], tail);
    setText(app, buf[0 .. at + tail.len], at);
}

fn fakeCmd(app: *App, mode: []const u8) void {
    var b: [800]u8 = undefined;
    const t = std.fmt.bufPrint(&b, "\"{s}\" --qa-lsp-server {s}", .{ selfPath(), mode }) catch return;
    const set = &app.st.settings;
    set.lsp_cmd_zig.set(t);
    set.lsp_on_zig = true;
}

fn zig() net.Status {
    return net.statusOf("zig");
}

/// Filhos deste processo (zumbi conta): prova que nada ficou para trás.
fn childCount() u32 {
    const me = c.getpid();
    const dir = c.opendir("/proc") orelse return 999;
    defer _ = c.closedir(dir);
    var n: u32 = 0;
    while (c.readdir(dir)) |entry| {
        const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&entry.*.d_name)), 0);
        const pid = std.fmt.parseInt(c_int, name, 10) catch continue;
        var pb: [64]u8 = undefined;
        const path = std.fmt.bufPrintSentinel(&pb, "/proc/{d}/stat", .{pid}, 0) catch continue;
        // Direto: arquivo de /proc diz que tem tamanho 0 (e o SDL_LoadFile acredita).
        const fd = c.open(path.ptr, c.O_RDONLY);
        if (fd < 0) continue;
        defer _ = c.close(fd);
        var data: [1024]u8 = undefined;
        const got = c.read(fd, &data, data.len);
        if (got <= 0) continue;
        const text = data[0..@intCast(got)];
        // "pid (nome) estado ppid ...": o nome pode ter espaços.
        const close = std.mem.lastIndexOfScalar(u8, text, ')') orelse continue;
        var it = std.mem.tokenizeScalar(u8, text[close + 1 ..], ' ');
        _ = it.next();
        const ppid = std.fmt.parseInt(c_int, it.next() orelse continue, 10) catch continue;
        if (ppid == me) n += 1;
    }
    return n;
}

fn alive(pid: i64) bool {
    return pid > 0 and c.kill(@intCast(pid), 0) == 0;
}

var pid_a: i64 = 0;
var count_a: u32 = 0;

fn auditMsg() ?[]const u8 {
    for (lsp_ui.diags.items[0..lsp_ui.diags.n]) |*g| {
        if (std.mem.startsWith(u8, g.message(), "pid=")) return g.message();
    }
    return null;
}

fn auditField(name: []const u8) ?[]const u8 {
    const m = auditMsg() orelse return null;
    var it = std.mem.tokenizeScalar(u8, m, ' ');
    while (it.next()) |w| {
        if (w.len > name.len and w[name.len] == '=' and std.mem.startsWith(u8, w, name)) return w[name.len + 1 ..];
    }
    return null;
}

fn auditInt(name: []const u8) ?u32 {
    return std.fmt.parseInt(u32, auditField(name) orelse return null, 10) catch null;
}

// --- Passos ---------------------------------------------------------------------------

fn textOff(app: *App) void {
    setMarked(app, "```zig\nerro\n|");
}
fn clearText(app: *App) void {
    setText(app, "", 0);
}
fn nothingRunning(_: *App) bool {
    return !net.running() and !lsp_ui.have_doc and childCount() == 0;
}
fn scanFound(_: *App) bool {
    return net.scanFinished() and qa.find("lsp-sugestao:zig") != null;
}
fn relativeIgnored(_: *App) bool {
    return qa.find("lsp-sugestao:cpp") == null;
}
fn notRun(_: *App) bool {
    var info: c.SDL_PathInfo = undefined;
    return !c.SDL_GetPathInfo("qa-out/lsp-rodou", &info) and childCount() == 0;
}
fn staysOff(app: *App) bool {
    return !app.st.settings.lsp_on_zig;
}
fn cmdTyped(app: *App) bool {
    return std.mem.eql(u8, app.st.settings.lsp_cmd_zig.slice(), "fake-lsp-qa --qa-lsp-server normal");
}
fn isOn(app: *App) bool {
    return app.st.settings.lsp_on_zig;
}
fn badCmdShown(_: *App) bool {
    return qa.find("lsp-cmd-ruim:zig") != null;
}
fn typedDiag(_: *App) bool {
    return qa.find("lsp-diag:0:L3:err") != null and zig().state == .ready;
}

// Linhas: o bloco começa na linha 4 da caixa; o servidor conta a partir do corpo.
const mapped = "oi\n\nmais uma\n```zig\nçç erro aqui\n😀 aviso\nok\ndica|\n```\n";
fn textMapped(app: *App) void {
    setMarked(app, mapped);
}
fn mapErr(_: *App) bool {
    return qa.find("lsp-diag:0:L5:err") != null and qa.find("lsp-diag:1:L6:warning") != null and qa.find("lsp-diag:2:L8:hint") != null;
}
fn mapCols(_: *App) bool {
    const items = lsp_ui.diags.items;
    // "çç " = 3 unidades; "😀 " = 3 unidades (o emoji conta 2).
    return items[0].line == 0 and items[0].col == 3 and items[1].line == 1 and items[1].col == 3;
}
fn squigglesOn(_: *App) bool {
    return qa.find("lsp-squiggles") != null;
}
fn textTall(app: *App) void {
    var b: [600]u8 = undefined;
    var n: usize = 0;
    const head = "```zig\n";
    @memcpy(b[0..head.len], head);
    n = head.len;
    for (0..14) |_| {
        @memcpy(b[n..][0..5], "erro\n");
        n += 5;
    }
    setText(app, b[0..n], n);
}
fn tallListOnly(_: *App) bool {
    return qa.find("lsp-diag:0:L2:err") != null and qa.find("lsp-squiggles") == null;
}

fn textAudit(app: *App) void {
    setMarked(app, "```zig\naudit|\n");
}
fn auditEnv(_: *App) bool {
    const env = auditField("env") orelse return false;
    return std.mem.indexOf(u8, env, "SIGMACORD_TOKEN") == null and (std.mem.eql(u8, env, "PATH,HOME") or std.mem.eql(u8, env, "HOME,PATH"));
}
fn auditRoot(_: *App) bool {
    const r = auditField("root_null") orelse return false;
    const f = auditField("folders_null") orelse return false;
    return std.mem.eql(u8, r, "true") and std.mem.eql(u8, f, "true");
}
fn auditCwd(_: *App) bool {
    return auditInt("cwd_files") == 0;
}
fn auditFds(_: *App) bool {
    return auditInt("fds") == 3;
}
fn auditUri(_: *App) bool {
    const u = auditField("uri") orelse return false;
    return std.mem.startsWith(u8, u, "file:///") and std.mem.endsWith(u8, u, "/sigmacord-composer.zig");
}
fn tokenStillHere(_: *App) bool {
    const t = c.SDL_getenv("SIGMACORD_TOKEN") orelse return false;
    return std.mem.eql(u8, std.mem.span(t), "qa-valor-falso-nao-e-token");
}

fn markChanges(_: *App) void {
    count_a = auditInt("changes") orelse 9999;
}
fn burst(comptime i: usize) fn (*App) void {
    return struct {
        fn f(app: *App) void {
            const texts = [_][]const u8{ "a", "ab", "abc", "abcd", "abcde", "abcdef" };
            var b: [100]u8 = undefined;
            const t = std.fmt.bufPrint(&b, "```zig\naudit {s}\n", .{texts[i]}) catch return;
            setText(app, t, t.len);
        }
    }.f;
}
fn debounced(_: *App) bool {
    const now_changes = auditInt("changes") orelse return false;
    // Seis mudanças em 240 ms: uma resposta, com no máximo uma de sobra.
    return now_changes > count_a and now_changes <= count_a + 2;
}

fn textOutside(app: *App) void {
    setMarked(app, "fo|ra\n```zig\nerro\n```\nfora");
}
fn leftBlock(_: *App) bool {
    return !lsp_ui.have_doc and lsp_ui.diags.n == 0 and qa.find("lsp-panel") == null;
}
fn textReturn(app: *App) void {
    setMarked(app, "fora\n```zig\naudit|\n```\nfora");
}
fn sawClose(_: *App) bool {
    return (auditInt("closes") orelse 0) >= 1 and (auditInt("opens") orelse 0) >= 2;
}
fn textTwo(app: *App) void {
    setMarked(app, "```zig\nerro\n```\ntexto\n```zig\naviso|\n```\n");
}
fn secondBlock(_: *App) bool {
    return lsp_ui.first_line == 5 and lsp_ui.diags.n == 1 and lsp_ui.diags.items[0].severity == .warning and qa.find("lsp-diag:0:L6:warning") != null;
}
fn textPython(app: *App) void {
    setMarked(app, "```python\nerro|\n");
}
fn otherLangNothing(_: *App) bool {
    return !lsp_ui.have_doc and net.statusOf("python").state == .off;
}

fn markPid(_: *App) void {
    pid_a = zig().pid;
}
fn useAbsoluteCmd(app: *App) void {
    fakeCmd(app, "normal");
}
fn textErro(app: *App) void {
    setMarked(app, "```zig\nerro|\n");
}
fn restarted(_: *App) bool {
    const st = zig();
    return st.state == .ready and st.pid != pid_a and !alive(pid_a) and qa.find("lsp-diag:0:L2:err") != null;
}
fn childGone(_: *App) bool {
    return !alive(pid_a) and childCount() == 0;
}
fn threadGone(_: *App) bool {
    return !net.running() and childCount() == 0;
}
fn ready(_: *App) bool {
    return zig().state == .ready and alive(zig().pid);
}
fn readyDiag(_: *App) bool {
    return ready(undefined) and lsp_ui.diags.n > 0;
}
fn shortIdle(_: *App) void {
    net.tuning.idle_ms = 600;
}
fn normalIdle(_: *App) void {
    net.tuning.idle_ms = 60_000;
}
fn cleanOff(_: *App) bool {
    return zig().state == .off and !net.running() and childCount() == 0;
}

// Falhas.
fn quick(_: *App) void {
    net.tuning.backoff_ms = .{ 60, 120, 180 };
}
fn modeFn(comptime mode: []const u8) fn (*App) void {
    return struct {
        fn f(app: *App) void {
            fakeCmd(app, mode);
        }
    }.f;
}
fn failedWith(comptime why: net.Failure) fn (*App) bool {
    return struct {
        fn f(_: *App) bool {
            const st = zig();
            return st.state == .failed and st.failure == why and childCount() == 0;
        }
    }.f;
}
fn sawFailure(comptime why: net.Failure) fn (*App) bool {
    return struct {
        fn f(_: *App) bool {
            return zig().failure == why;
        }
    }.f;
}
fn crashedThreeTimes(_: *App) bool {
    const st = zig();
    return st.state == .failed and st.failure == .crashed and st.exit_code == 3 and st.attempts == 3 and childCount() == 0;
}
fn failShown(_: *App) bool {
    return qa.find("lsp-status") != null;
}
fn retryShown(_: *App) bool {
    return qa.find("button:Tentar de novo: Zig") != null;
}
fn retriedOff(_: *App) bool {
    return zig().state != .failed;
}
fn failedAgain(_: *App) bool {
    return zig().state == .failed and zig().attempts == 3;
}
fn missingCmd(app: *App) void {
    app.st.settings.lsp_cmd_zig.set("/nao/existe/servidor-falso");
    app.st.settings.lsp_on_zig = true;
}
fn stopNow(app: *App) void {
    app.st.settings.lsp_on_zig = false;
}
fn smallFlood(_: *App) void {
    net.tuning.flood_bytes = 256 * 1024;
}
fn shortInit(_: *App) void {
    net.tuning.init_timeout_ms = 200;
}
fn shortStall(_: *App) void {
    net.tuning.write_stall_ms = 250;
    net.tuning.debounce_ms = 1;
    // Espera longa: o motivo da queda fica visível até o QA olhar.
    net.tuning.backoff_ms = .{ 30_000, 30_000, 30_000 };
}
fn pushBig(_: *App) void {
    const G = struct {
        var buf: [L.max_doc]u8 = @splat('x');
        var n: u8 = 0;
    };
    G.n +%= 1;
    G.buf[0] = G.n;
    net.setDoc(&lsp_ui.spec, &G.buf, false);
}
fn defaults(_: *App) void {
    net.tuning = .{};
}

const big_pushes = blk: {
    var out: [60]Op = undefined;
    for (0..30) |i| {
        out[i * 2] = run(pushBig);
        out[i * 2 + 1] = .{ .wait = 30 };
    }
    break :blk out;
};

// Respostas aos pedidos do servidor.
fn answered(_: *App) bool {
    return auditInt("replies") == 2;
}

// Plugins.
fn writePlugin(comptime lang: []const u8, comptime extra: []const u8) fn (*App) void {
    return struct {
        fn f(_: *App) void {
            _ = c.SDL_CreateDirectory("qa-out/plugins");
            var b: [1500]u8 = undefined;
            const t = std.fmt.bufPrint(&b, "sigma.lsp(\"{s}\", {{\"{s}\", \"--qa-lsp-server\", \"normal\"{s}}})\n", .{ lang, selfPath(), extra }) catch return;
            _ = c.SDL_SaveFile("qa-out/plugins/lsp-qa.lua", t.ptr, t.len);
            engine.current.?.reload();
        }
    }.f;
}
fn pluginRow(_: *App) bool {
    return qa.find("toggle:zig · lsp-qa.lua") != null;
}
fn pluginStaysOff(_: *App) bool {
    return !net.running() and !lsp_ui.have_doc and childCount() == 0;
}
fn pluginRunning(_: *App) bool {
    return zig().state == .ready and lsp_ui.diags.n > 0 and childCount() == 1;
}
fn zigOff(app: *App) void {
    app.st.settings.lsp_on_zig = false;
    app.st.settings.lsp_cmd_zig = .{};
}
fn disablePlugin(_: *App) void {
    const e = engine.current.?;
    for (e.list.items) |p| if (std.mem.eql(u8, p.name, "lsp-qa.lua")) e.setEnabled(p, false);
}
fn enablePlugin(_: *App) void {
    const e = engine.current.?;
    for (e.list.items) |p| if (std.mem.eql(u8, p.name, "lsp-qa.lua")) e.setEnabled(p, true);
}
fn textHaskell(app: *App) void {
    setMarked(app, "```haskell\nerro|\n");
}
fn haskellRuns(_: *App) bool {
    const st = net.statusOf("haskell");
    return st.state == .ready and qa.find("lsp-diag:0:L2:err") != null;
}

// Sugestão.
fn suggestedRan(_: *App) bool {
    var info: c.SDL_PathInfo = undefined;
    return c.SDL_GetPathInfo("qa-out/lsp-rodou", &info) and qa.find("lsp-diag:0:L2:err") != null;
}
fn pinnedPath(app: *App) bool {
    const t = app.st.settings.lsp_cmd_zig.slice();
    return app.st.settings.lsp_on_zig and std.mem.endsWith(u8, t, "/qa-out/lsp-bin/zls");
}
fn settingsPage(app: *App) bool {
    return app.st.settings.open and app.st.settings.page == .lsp;
}

// --- Roteiro ---------------------------------------------------------------------------

pub const ops = [_]Op{
    s("lsp: desligado por padrão"),
    click("guild:500000"),
    click("channel:500005"),
    run(prepare),
    click("composer"),
    run(textOff),
    .{ .wait = 500 },
    expect("bloco ```zig sem nada ligado: nenhuma thread, nenhum filho", nothingRunning),

    s("lsp: configurações"),
    open_settings,
    click("settings:Erros no código"),
    expect("a página abre", settingsPage),
    .{ .expect = .{ .name = "acha o zls no PATH", .check = scanFound, .timeout_ms = 3000 } },
    expect("entrada relativa do PATH não vale", relativeIgnored),
    expect("achar não é executar", notRun),
    shot("lsp-config"),
    click("toggle:Zig"),
    expect("sem comando, o interruptor não liga", staysOff),
    click("lsp-cmd:zig"),
    .{ .text = "fake-lsp-qa --qa-lsp-server normal" },
    .{ .key = .{ .key = c.ImGuiKey_Enter } },
    expect("o comando digitado fica salvo", cmdTyped),
    expect("salvar o comando não liga", staysOff),
    click("toggle:Zig"),
    expect("agora liga", isOn),
    click("settings-close"),
    .{ .wait = 350 },

    s("lsp: digitando"),
    run(clearText),
    .{ .wait = 30 },
    click("composer"),
    .{ .text = "```zig" },
    shift_enter,
    .{ .text = "const a = 1;" },
    shift_enter,
    .{ .text = "erro aqui" },
    .{ .expect = .{ .name = "digitando: o erro aparece com a linha da caixa", .check = typedDiag, .timeout_ms = 4000 } },
    .{ .wait = 150 },
    shot("lsp-digitando"),

    s("lsp: linhas e colunas"),
    run(textMapped),
    .{ .expect = .{ .name = "linhas do bloco viram linhas da caixa", .check = mapErr, .timeout_ms = 3000 } },
    expect("colunas em UTF-16", mapCols),
    .{ .wait = 100 },
    expect("sublinhado sobre o texto", squigglesOn),
    shot("lsp-sublinhado"),
    run(textTall),
    .{ .expect = .{ .name = "texto que rola: só a lista, sem chutar posição", .check = tallListOnly, .timeout_ms = 3000 } },

    s("lsp: o que o servidor recebe e enxerga"),
    run(textAudit),
    .{ .expect = .{ .name = "ambiente do filho: só PATH e HOME, sem o token", .check = auditEnv, .timeout_ms = 3000 } },
    expect("o token continua no ambiente do app", tokenStillHere),
    expect("rootUri e workspaceFolders nulos", auditRoot),
    expect("pasta de trabalho vazia", auditCwd),
    expect("só stdin, stdout e stderr abertos (nada do app vaza)", auditFds),
    expect("documento virtual (file: na pasta vazia)", auditUri),

    s("lsp: espera entre as teclas"),
    run(markChanges),
    run(burst(0)),
    .{ .wait = 40 },
    run(burst(1)),
    .{ .wait = 40 },
    run(burst(2)),
    .{ .wait = 40 },
    run(burst(3)),
    .{ .wait = 40 },
    run(burst(4)),
    .{ .wait = 40 },
    run(burst(5)),
    .{ .expect = .{ .name = "seis mudanças seguidas viram uma", .check = debounced, .timeout_ms = 2000 } },

    s("lsp: só o bloco sob o cursor"),
    run(textOutside),
    expect("cursor fora do bloco: a lista some e o texto para de ir", leftBlock),
    run(textReturn),
    .{ .expect = .{ .name = "fora fecha o documento e voltar abre de novo", .check = sawClose, .timeout_ms = 3000 } },
    run(textTwo),
    .{ .expect = .{ .name = "dois blocos: vale o do cursor", .check = secondBlock, .timeout_ms = 3000 } },
    run(textPython),
    expect("linguagem sem servidor ligado: nada", otherLangNothing),

    s("lsp: mudar a configuração"),
    run(textErro),
    .{ .expect = .{ .name = "de pé", .check = readyDiag, .timeout_ms = 3000 } },
    run(markPid),
    run(useAbsoluteCmd),
    .{ .wait = 30 },
    run(textErro),
    expectLong("trocar o comando reinicia o servidor", restarted),
    run(markPid),
    open_settings,
    click("settings:Erros no código"),
    click("toggle:Zig"),
    expectLong("desligar mata o filho e a thread", threadGone),
    expect("o filho que estava rodando sumiu", childGone),
    click("settings-close"),

    s("lsp: um minuto sem digitar (encurtado)"),
    run(shortIdle),
    run(useAbsoluteCmd),
    click("composer"),
    run(textErro),
    .{ .expect = .{ .name = "sobe", .check = ready, .timeout_ms = 3000 } },
    run(markPid),
    expectLong("parado de digitar: filho e thread saem", cleanOff),
    expect("o filho sumiu", childGone),
    run(textAudit),
    expectLong("voltar a digitar sobe de novo", ready),
    run(normalIdle),
    run(markPid),
    run(stopNow),
    expectLong("desliga", threadGone),

    s("lsp: servidor que cai"),
    run(quick),
    run(modeFn("crash")),
    .{ .wait = 30 },
    run(textErro),
    expectLong("cai logo ao abrir: três novas tentativas e para", crashedThreeTimes),
    .{ .wait = 100 },
    expect("o erro aparece na caixa", failShown),
    shot("lsp-falhou"),
    open_settings,
    click("settings:Erros no código"),
    .{ .wait = 50 },
    expect("a página oferece tentar de novo", retryShown),
    click("button:Tentar de novo: Zig"),
    expect("tentar de novo limpa o erro", retriedOff),
    click("settings-close"),
    click("composer"),
    expectLong("e tenta mesmo (cai de novo)", failedAgain),
    run(stopNow),
    .{ .wait = 30 },
    run(modeFn("crash_late")),
    .{ .wait = 30 },
    run(textErro),
    expectLong("cai depois de abrir o documento", failedWith(.crashed)),
    run(stopNow),
    .{ .wait = 30 },
    run(missingCmd),
    .{ .wait = 30 },
    run(textErro),
    expectLong("programa que não existe: erro claro, sem insistir", failedWith(.spawn)),
    run(stopNow),
    .{ .wait = 30 },
    run(modeFn("badinit")),
    .{ .wait = 30 },
    run(textErro),
    expectLong("recusa o initialize", failedWith(.protocol)),
    run(stopNow),
    .{ .wait = 30 },

    s("lsp: servidor que se comporta mal"),
    run(modeFn("garbage")),
    .{ .wait = 30 },
    run(textErro),
    expectLong("lixo no stdout", failedWith(.protocol)),
    run(stopNow),
    .{ .wait = 30 },
    run(modeFn("huge")),
    .{ .wait = 30 },
    run(textErro),
    expectLong("mensagem gigante é recusada sem acumular", failedWith(.protocol)),
    run(stopNow),
    .{ .wait = 30 },
    run(smallFlood),
    run(modeFn("flood")),
    .{ .wait = 30 },
    run(textErro),
    expectLong("saída sem parar é cortada", failedWith(.flood)),
    run(stopNow),
    .{ .wait = 30 },
    run(defaults),
    run(quick),
    run(shortInit),
    run(modeFn("hang")),
    .{ .wait = 30 },
    run(textErro),
    expectLong("travado desde o início: prazo, SIGKILL e nada para trás", failedWith(.init_timeout)),
    run(stopNow),
    expectLong("sem nenhum filho", threadGone),
    run(defaults),
    run(quick),
    run(shortStall),
    run(modeFn("noread")),
    .{ .wait = 30 },
    run(textErro),
    expectLong("noread sobe", ready),
    run(markPid),
} ++ big_pushes ++ [_]Op{
    expectLong("parou de ler: o pipe enche e o cliente não trava", sawFailure(.write_stall)),
    expect("o filho foi morto", childGone),
    run(stopNow),
    expectLong("sem nenhum filho", threadGone),
    run(defaults),

    s("lsp: parar um servidor travado"),
    run(modeFn("stubborn")),
    .{ .wait = 30 },
    run(textErro),
    expectLong("stubborn sobe", readyDiag),
    run(markPid),
    run(stopNow),
    expectLong("ignora shutdown, exit e SIGTERM: leva SIGKILL", childGone),
    expectLong("thread sai", threadGone),

    s("lsp: pedidos do servidor"),
    run(modeFn("ask")),
    .{ .wait = 30 },
    run(textAudit),
    expectLong("os pedidos dele têm resposta", answered),
    run(stopNow),
    expectLong("sem nenhum filho", threadGone),

    s("lsp: sugestão do PATH"),
    run(zigOff),
    open_settings,
    click("settings:Erros no código"),
    .{ .wait = 60 },
    click("button:Usar zls e ligar"),
    expect("o clique liga, com o caminho inteiro", pinnedPath),
    click("settings-close"),
    click("composer"),
    run(textErro),
    expectLong("só agora o programa roda", suggestedRan),
    run(stopNow),
    expectLong("sem nenhum filho", threadGone),

    s("lsp: plugin propõe, a pessoa decide"),
    run(zigOff),
    run(writePlugin("zig", "")),
    open_settings,
    click("settings:Erros no código"),
    .{ .wait = 60 },
    expect("a proposta aparece na página", pluginRow),
    .{ .resize = .{ 1280, 1500 } },
    .{ .wait = 150 },
    shot("lsp-plugin"),
    .{ .resize = .{ 1280, 800 } },
    .{ .wait = 150 },
    click("settings-close"),
    click("composer"),
    run(textErro),
    .{ .wait = 450 },
    expect("proposta sem aceite não roda nada", pluginStaysOff),
    open_settings,
    click("settings:Erros no código"),
    .{ .wait = 60 },
    click("toggle:zig · lsp-qa.lua"),
    click("settings-close"),
    click("composer"),
    run(textAudit),
    expectLong("aceita: roda", pluginRunning),
    run(markPid),
    run(writePlugin("zig", ", \"--outro\"")),
    expectLong("o plugin troca o comando: o filho morre", childGone),
    run(textAudit),
    .{ .wait = 450 },
    expect("e o novo comando precisa de outro aceite", pluginStaysOff),
    open_settings,
    click("settings:Erros no código"),
    .{ .wait = 60 },
    click("toggle:zig · lsp-qa.lua"),
    click("settings-close"),
    click("composer"),
    run(textAudit),
    expectLong("aceitou de novo: roda", pluginRunning),
    run(markPid),
    run(disablePlugin),
    expectLong("desligar o plugin mata o filho", childGone),
    run(enablePlugin),
    run(writePlugin("haskell", "")),
    open_settings,
    click("settings:Erros no código"),
    .{ .wait = 60 },
    click("toggle:haskell · lsp-qa.lua"),
    click("settings-close"),
    click("composer"),
    run(textHaskell),
    expectLong("linguagem que o app não conhece, via plugin", haskellRuns),

    s("lsp: limpeza"),
    run(cleanup),
    expectLong("nada ficou rodando", threadGone),
    run(clearText),
    .{ .wait = 30 },
};

// --- Um servidor de verdade (QA_LSP_REAL=/caminho/clangd), só à mão ------------------

fn realPrepare(app: *App) void {
    prepare(app);
    const cmd = std.mem.span(c.SDL_getenv("QA_LSP_REAL") orelse return);
    const set = &app.st.settings;
    set.lsp_cmd_cpp.set(cmd);
    set.lsp_on_cpp = true;
}
fn realText(app: *App) void {
    setMarked(app, "```cpp\nint main() { return naoexiste;| }\n```");
}
var real_seen: u32 = 0;
var real_diags: net.Diagnostics = .{};
fn realDiag(_: *App) bool {
    _ = net.copyDiags(&real_seen, &real_diags);
    if (real_diags.n == 0) return false;
    for (real_diags.items[0..real_diags.n]) |*di| std.debug.print("[lsp real] linha {d} col {d}: {s}\n", .{ di.line, di.col, di.message() });
    return true;
}
fn realDead(_: *App) bool {
    return childCount() == 0;
}
fn realStop(_: *App) void {
    net.stopAll();
}

pub const ops_real = [_]Op{
    s("lsp: servidor de verdade"),
    click("guild:500000"),
    click("channel:500005"),
    run(realPrepare),
    click("composer"),
    run(realText),
    .{ .expect = .{ .name = "o servidor de verdade aponta o erro", .check = realDiag, .timeout_ms = 20000 } },
    .{ .wait = 200 },
    shot("lsp-real"),
    run(realStop),
    .{ .expect = .{ .name = "parar mata o servidor", .check = realDead, .timeout_ms = 5000 } },
};

// --- Fechar o app com um servidor de pé (conferido por tools/qa_lsp.sh) ------------------

fn quitPrepare(app: *App) void {
    prepare(app);
    const mode = if (c.SDL_getenv("QA_LSP_MODE")) |m| std.mem.span(m) else "stubborn";
    fakeCmd(app, mode);
}
fn quitStarted(_: *App) bool {
    return zig().pid != 0;
}
fn quitSettled(_: *App) bool {
    const mode = if (c.SDL_getenv("QA_LSP_MODE")) |m| std.mem.span(m) else "stubborn";
    if (std.mem.eql(u8, mode, "hang")) return quitStarted(undefined);
    return zig().state == .ready;
}
fn quitWritePid(_: *App) void {
    var b: [32]u8 = undefined;
    const t = std.fmt.bufPrint(&b, "{d}\n", .{zig().pid}) catch return;
    _ = c.SDL_SaveFile("qa-out/lsp-quit.pid", t.ptr, t.len);
}

pub const ops_quit = [_]Op{
    s("lsp: fechar o app com o servidor de pé"),
    click("guild:500000"),
    click("channel:500005"),
    run(quitPrepare),
    click("composer"),
    run(textErro),
    .{ .expect = .{ .name = "servidor de pé", .check = quitSettled, .timeout_ms = 4000 } },
    run(quitWritePid),
};
