//! QA dos plugins (entra na bateria geral do qa_runner.zig): os plugins incluídos,
//! usados como uma pessoa usa, com o painel, os menus e as notas de verdade. O
//! HTTP fala com um servidor de mentira aqui mesmo (127.0.0.1), que também conta
//! o que recebeu: nada sai para a internet e nada fala com o Discord.
const std = @import("std");
const c = @import("c");
const i18n = @import("ui/i18n.zig");
const App = @import("app.zig").App;
const R = @import("qa_runner.zig");
const Op = R.Op;
const qa = @import("ui/qa.zig");
const types = @import("core/types.zig");
const gw = @import("net/fake_gateway.zig");
const sys = @import("platform/sys.zig");
const platform = @import("platform/window.zig");
const engine = @import("plugins/engine.zig");
const host = @import("plugins/host.zig");
const http_curl = @import("plugins/http_curl.zig");
const exemplos = @import("plugin_examples");
const attachments = @import("ui/attachments.zig");
const Id = types.Id;
const Plugin = engine.Plugin;

fn s(name: []const u8) Op {
    return .{ .section = name };
}
fn click(k: []const u8) Op {
    return .{ .click = .{ .mark = k } };
}
fn dyn(f: *const fn (*App, []u8) []const u8) Op {
    return .{ .click = .{ .dyn = f } };
}
fn rdyn(f: *const fn (*App, []u8) []const u8) Op {
    return .{ .rclick = .{ .dyn = f } };
}
// A resposta passa pela outra thread: em máquina ocupada, leva o tempo que levar.
/// Botão direito no texto da mensagem: no meio da linha pode estar a barra de ações.
const rmsg: Op = .{ .rclick = .{ .dyn_at = .{ .f = tMsgText, .fx = 0.25, .fy = 0.5 } } };
fn expect(name: []const u8, f: *const fn (*App) bool) Op {
    return .{ .expect = .{ .name = name, .check = f, .timeout_ms = 8000 } };
}
fn expectLong(name: []const u8, f: *const fn (*App) bool) Op {
    return .{ .expect = .{ .name = name, .check = f, .timeout_ms = 12000 } };
}
fn key(k: c_int) Op {
    return .{ .key = .{ .key = k } };
}
fn ctrl(k: c_int) Op {
    return .{ .key = .{ .key = k, .ctrl = true } };
}
fn run(f: *const fn (*App) void) Op {
    return .{ .run = f };
}

const geral: Id = 500005;
const memes: Id = 500006;

fn plugin(app: *App, name: []const u8) ?*Plugin {
    for (app.plugins.list.items) |p| if (std.mem.eql(u8, p.name, name)) return p;
    return null;
}

fn toastHas(app: *App, needle: []const u8) bool {
    return std.mem.indexOf(u8, app.st.toast.text(), needle) != null;
}

fn inputText(app: *App) []const u8 {
    return std.mem.sliceTo(&app.st.input, 0);
}

fn openIs(app: *App, name: []const u8) bool {
    const p = app.plugins.panel_open orelse return false;
    return std.mem.eql(u8, p.name, name);
}

/// A primeira marcação com o prefixo, pronta para clicar.
fn firstMark(prefix: []const u8, buf: []u8) []const u8 {
    var keys: [16][56]u8 = undefined;
    var lens: [16]u8 = undefined;
    const n = qa.keysWith(&.{prefix}, &keys, &lens);
    if (n == 0) return prefix;
    const k = keys[0][0..lens[0]];
    @memcpy(buf[0..k.len], k);
    return buf[0..k.len];
}

fn anyMark(prefix: []const u8) bool {
    var keys: [2][56]u8 = undefined;
    var lens: [2]u8 = undefined;
    return qa.keysWith(&.{prefix}, &keys, &lens) > 0;
}

// --- Arquivos ---------------------------------------------------------------------

pub fn wipeDataPub(app: *App) void {
    wipeData(app);
}

/// Sem as sobras de outra rodada: nem plugins, nem os dados deles.
fn wipeData(app: *App) void {
    var pb: [96]u8 = undefined;
    const dir = std.fmt.bufPrintSentinel(&pb, "qa-out/plugin-data/{d}", .{app.store.me}, 0) catch return;
    var count: c_int = 0;
    if (c.SDL_GlobDirectory(dir.ptr, "*", 0, &count)) |names| {
        defer c.SDL_free(@ptrCast(names));
        for (0..@intCast(count)) |i| {
            var fb: [160]u8 = undefined;
            const f = std.fmt.bufPrintSentinel(&fb, "{s}/{s}", .{ dir, std.mem.span(names[i] orelse continue) }, 0) catch continue;
            _ = c.SDL_RemovePath(f.ptr);
        }
    }
}

/// Saíram da lista dos incluídos, mas usam partes da API que nenhum outro usa.
const fixtures = [_]exemplos.Exemplo{
    .{ .name = "bookmarks.lua", .source = @embedFile("plugins/testdata/bookmarks.lua") },
    .{ .name = "filter.lua", .source = @embedFile("plugins/testdata/filter.lua") },
    .{ .name = "stats.lua", .source = @embedFile("plugins/testdata/stats.lua") },
    .{ .name = "snippets.lua", .source = @embedFile("plugins/testdata/snippets.lua") },
    .{ .name = "timestamps.lua", .source = @embedFile("plugins/testdata/timestamps.lua") },
};

fn writeFixtures(_: *App) void {
    _ = c.SDL_CreateDirectory("qa-out/plugins");
    for (fixtures) |ex| {
        var b: [96]u8 = undefined;
        const to = std.fmt.bufPrintSentinel(&b, "qa-out/plugins/{s}", .{ex.name}, 0) catch continue;
        _ = c.SDL_SaveFile(to.ptr, ex.source.ptr, ex.source.len);
    }
}

fn fixturesLoaded(app: *App) bool {
    for (fixtures) |ex| {
        const p = plugin(app, ex.name) orelse return false;
        if (p.status() != .running) return false;
    }
    return bundledRunning(app);
}

fn writeBundled(app: *App) void {
    _ = c.SDL_CreateDirectory("qa-out/plugins");
    for (exemplos.list) |ex| {
        var b: [96]u8 = undefined;
        const to = std.fmt.bufPrintSentinel(&b, "qa-out/plugins/{s}", .{ex.name}, 0) catch continue;
        _ = c.SDL_SaveFile(to.ptr, ex.source.ptr, ex.source.len);
    }
    writeFixtures(app);
}

fn removeAllIn(dir: [:0]const u8) void {
    var count: c_int = 0;
    if (c.SDL_GlobDirectory(dir.ptr, "*", 0, &count)) |names| {
        defer c.SDL_free(@ptrCast(names));
        for (0..@intCast(count)) |i| {
            var fb: [160]u8 = undefined;
            const f = std.fmt.bufPrintSentinel(&fb, "{s}/{s}", .{ dir, std.mem.span(names[i] orelse continue) }, 0) catch continue;
            _ = c.SDL_RemovePath(f.ptr);
        }
    }
}

pub fn removeAllPlugins(_: *App) void {
    removeAllIn("qa-out/plugins/antigos");
    removeAllIn("qa-out/plugins");
}

// --- O servidor de mentira ----------------------------------------------------------

var srv_started = false;
var srv_sock: sys.Socket = sys.no_socket;
var srv_lock: ?*c.SDL_Mutex = null;
var srv_count: u32 = 0;
var srv_last: [4096]u8 = undefined;
var srv_last_len: usize = 0;
/// Algum pedido trouxe algo que nunca deveria sair.
var srv_leak = false;

const translated_body = "{\"responseData\":{\"translatedText\":\"texto traduzido pelo servidor\",\"match\":1},\"responseStatus\":200}";

fn startServer(_: *App) void {
    if (!http_curl.qa_builds or srv_started) return;
    var port: u16 = 0;
    srv_sock = sys.tcpListenLocal(&port) orelse return;
    srv_lock = c.SDL_CreateMutex();
    const t = c.SDL_CreateThread(serverMain, "qa-http", null) orelse return;
    c.SDL_DetachThread(t);
    srv_started = true;
    const b = std.fmt.bufPrint(&http_curl.qa_base, "http://127.0.0.1:{d}", .{port}) catch return;
    http_curl.qa_base_len = b.len;
}

fn serverMain(_: ?*anyopaque) callconv(.c) c_int {
    while (true) {
        const client = sys.tcpAccept(srv_sock) orelse return 0;
        defer sys.closeSocket(client);
        var buf: [8192]u8 = undefined;
        var n: usize = 0;
        while (n < buf.len) {
            const got = sys.tcpRecv(client, buf[n..], 1000);
            if (got.len == 0) break;
            n += got.len;
            if (std.mem.indexOf(u8, buf[0..n], "\r\n\r\n")) |head_end| {
                // Com corpo: espera ele chegar também.
                const need = contentLength(buf[0..head_end]);
                if (n >= head_end + 4 + need) break;
            }
        }
        const req = buf[0..n];
        c.SDL_LockMutex(srv_lock);
        srv_count += 1;
        srv_last_len = @min(req.len, srv_last.len);
        @memcpy(srv_last[0..srv_last_len], req[0..srv_last_len]);
        for ([_][]const u8{ "authorization:", "cookie:", "x-super-properties:", "x-discord", "x-fingerprint:" }) |bad| {
            if (std.ascii.findIgnoreCase(req, bad) != null) srv_leak = true;
        }
        c.SDL_UnlockMutex(srv_lock);
        reply(client, req);
    }
}

fn contentLength(head: []const u8) usize {
    const at = std.ascii.findIgnoreCase(head, "content-length:") orelse return 0;
    const rest = head[at + "content-length:".len..];
    const end = std.mem.indexOf(u8, rest, "\r\n") orelse rest.len;
    return std.fmt.parseInt(usize, std.mem.trim(u8, rest[0..end], " "), 10) catch 0;
}

fn reply(client: sys.Socket, req: []const u8) void {
    var head: [256]u8 = undefined;
    if (std.mem.startsWith(u8, req, "GET /get")) {
        sys.tcpSend(client, std.fmt.bufPrint(&head, "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{translated_body.len}) catch return);
        sys.tcpSend(client, translated_body);
    } else if (std.mem.startsWith(u8, req, "GET /api/cve/")) {
        replyCve(client, req);
    } else if (std.mem.startsWith(u8, req, "GET /repos/")) {
        replyGithub(client, req);
    } else if (std.mem.startsWith(u8, req, "GET /big")) {
        // Mais que o limite, sem avisar o tamanho.
        sys.tcpSend(client, "HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n");
        var chunk: [65536]u8 = undefined;
        @memset(&chunk, 'x');
        for (0..32) |_| sys.tcpSend(client, &chunk);
    } else if (std.mem.startsWith(u8, req, "GET /redir")) {
        sys.tcpSend(client, "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:1/segredo\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
    } else if (std.mem.startsWith(u8, req, "POST /echo")) {
        const at = std.mem.indexOf(u8, req, "\r\n\r\n") orelse return;
        const body = req[at + 4..];
        sys.tcpSend(client, std.fmt.bufPrint(&head, "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{body.len}) catch return);
        sys.tcpSend(client, body);
    } else {
        sys.tcpSend(client, "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
    }
}

/// Respostas guardadas do serviço de verdade, e o 404 dele para o que não existe.
fn replyCve(client: sys.Socket, req: []const u8) void {
    const rest = req["GET /api/cve/".len..];
    const id = rest[0 .. std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len];
    const records = [_]struct { id: []const u8, body: []const u8 }{
        .{ .id = "CVE-2021-44228", .body = @embedFile("plugins/testdata/cve/CVE-2021-44228.json") },
        .{ .id = "CVE-2024-3094", .body = @embedFile("plugins/testdata/cve/CVE-2024-3094.json") },
        .{ .id = "CVE-1999-0001", .body = @embedFile("plugins/testdata/cve/CVE-1999-0001.json") },
        .{ .id = "CVE-2016-0001", .body = @embedFile("plugins/testdata/cve/CVE-2016-0001.json") },
    };
    var head: [256]u8 = undefined;
    for (records) |r| if (std.mem.eql(u8, r.id, id)) {
        sys.tcpSend(client, std.fmt.bufPrint(&head, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{r.body.len}) catch return);
        return sys.tcpSend(client, r.body);
    };
    const missing = "{\"error\":\"CVE_RECORD_DNE\",\"message\":\"The cve record for the cve id does not exist.\"}";
    sys.tcpSend(client, std.fmt.bufPrint(&head, "HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{missing.len}) catch return);
    sys.tcpSend(client, missing);
}

/// Respostas guardadas da API de verdade.
fn replyGithub(client: sys.Socket, req: []const u8) void {
    const rest = req["GET ".len..];
    const path = rest[0 .. std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len];
    const body: []const u8 = if (std.mem.eql(u8, path, "/repos/curl/curl"))
        @embedFile("plugins/testdata/github/repo-curl.json")
    else if (std.mem.eql(u8, path, "/repos/curl/curl/issues/1"))
        @embedFile("plugins/testdata/github/issue-curl.json")
    else
        @embedFile("plugins/testdata/github/missing.json");
    const found = !std.mem.startsWith(u8, body, "{\"message\":\"Not Found");
    var head: [256]u8 = undefined;
    const line = if (found) "200 OK" else "404 Not Found";
    sys.tcpSend(client, std.fmt.bufPrint(&head, "HTTP/1.1 {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ line, body.len }) catch return);
    sys.tcpSend(client, body);
}

fn serverCount() u32 {
    c.SDL_LockMutex(srv_lock);
    defer c.SDL_UnlockMutex(srv_lock);
    return srv_count;
}

fn serverLastHas(needle: []const u8) bool {
    c.SDL_LockMutex(srv_lock);
    defer c.SDL_UnlockMutex(srv_lock);
    return std.mem.indexOf(u8, srv_last[0..srv_last_len], needle) != null;
}

// --- Mensagens "de outras pessoas" -----------------------------------------------------

var seq: u64 = 0;

fn inject(app: *App, channel: Id, author: Id, text: []const u8) Id {
    const ca = std.heap.c_allocator;
    seq += 1;
    const id = types.makeSnowflake(gw.nowMs(), 0x7a000 + seq);
    const content = ca.dupe(u8, text) catch return 0;
    app.events.push(.{ .message_create = .{ .id = id, .channel = channel, .author = author, .timestamp = @divTrunc(gw.nowMs(), 1000), .content = content } });
    platform.Window.wake(app.win.wake_type, .gateway);
    return id;
}

fn editMsg(app: *App, channel: Id, id: Id, text: []const u8) void {
    const content = std.heap.c_allocator.dupe(u8, text) catch return;
    app.events.push(.{ .message_update = .{ .channel = channel, .id = id, .content = content } });
    platform.Window.wake(app.win.wake_type, .gateway);
}

fn deleteMsg(app: *App, channel: Id, id: Id) void {
    app.events.push(.{ .message_delete = .{ .channel = channel, .id = id } });
    platform.Window.wake(app.win.wake_type, .gateway);
}

/// Mensagem usada nos menus: uma recente de outra pessoa, no canal aberto.
var msg_id: Id = 0;
var msg_author: Id = 0;

fn pickOther(app: *App) void {
    const ch = app.st.activeChannel() orelse return;
    const cs = app.store.channel(ch) orelse return;
    var i = cs.messages.items.len;
    while (i > 0) {
        i -= 1;
        const m = &cs.messages.items[i];
        // Só texto: em cima de um link, o botão direito é do link.
        if (m.msg.author == app.store.me or m.msg.id == 0 or m.msg.system != .none or m.msg.content.len == 0 or std.mem.indexOf(u8, m.msg.content, "://") != null) continue;
        // E à vista, longe do cabeçalho e da caixa de texto.
        const r = qa.find(mark(&mbuf, "msgtext:{d}", m.msg.id)) orelse continue;
        if (r.y < 120 or r.bottom() > app.io.*.DisplaySize.y - 120) continue;
        msg_id = m.msg.id;
        msg_author = m.msg.author;
        return;
    }
}

var mbuf: [64]u8 = undefined;

fn mark(buf: []u8, comptime fmt: []const u8, id: Id) []const u8 {
    return std.fmt.bufPrint(buf, fmt, .{id}) catch "";
}

fn tMsgText(_: *App, buf: []u8) []const u8 {
    return mark(buf, "msgtext:{d}", msg_id);
}

fn tUser(_: *App, buf: []u8) []const u8 {
    return mark(buf, "user:{d}", msg_author);
}

// --- Thread e página ----------------------------------------------------------------

fn threadUp(app: *App) bool {
    return app.plugins.threadRunning() and plugin(app, "bookmarks.lua") != null;
}

fn bundledRunning(app: *App) bool {
    for (exemplos.list) |ex| {
        const p = plugin(app, ex.name) orelse return false;
        if (p.status() != .running) return false;
    }
    return true;
}

fn cardsShow(_: *App) bool {
    return qa.find("plugin-card:bookmarks.lua") != null and qa.find("plugin-chip:bookmarks.lua:menu") != null and
        qa.find("plugin-open:bookmarks.lua") != null and qa.find("plugin-chip:shrug.lua:legado") != null;
}

fn hostCardShows(_: *App) bool {
    return qa.find("plugin-chip:translate.lua:http") != null and qa.find("host:translate.lua:api.mymemory.translated.net") != null;
}

fn alertsShow(_: *App) bool {
    // Lê mensagens e abre endereços: avisa. A tradução só vê o que você escolhe no menu.
    return qa.find("plugin-alert:links.lua") != null and qa.find("plugin-alert:translate.lua") == null and qa.find("plugin-alert:reminders.lua") == null;
}

fn newChips(_: *App) bool {
    return qa.find("plugin-chip:cleanlinks.lua:rewrite") != null and qa.find("plugin-chip:links.lua:links") != null and
        qa.find("plugin-chip:snippets.lua:completions") != null and qa.find("plugin-chip:translate.lua:settings") != null;
}

// --- Favoritos ------------------------------------------------------------------------

fn toGeral(app: *App) void {
    app.handle(.{ .open_message = .{ .channel = geral, .id = 0 } });
}

fn toMemes(app: *App) void {
    app.handle(.{ .open_message = .{ .channel = memes, .id = 0 } });
}

fn bookmarkBadge(_: *App) bool {
    return qa.find(mark(&mbuf, "deco-badge:{d}", msg_id)) != null;
}

fn noBadge(_: *App) bool {
    return qa.find(mark(&mbuf, "deco-badge:{d}", msg_id)) == null;
}

fn panelFavoritos(app: *App) bool {
    return openIs(app, "bookmarks.lua") and qa.find("pp-panel") != null;
}
fn panelFavoritosSemConfig(app: *App) bool {
    return panelFavoritos(app) and !app.st.settings.open;
}

fn tItem(_: *App, buf: []u8) []const u8 {
    return mark(buf, "pp-item:{d}", msg_id);
}

fn itemThere(_: *App) bool {
    return qa.find(mark(&mbuf, "pp-item:{d}", msg_id)) != null;
}

fn itemGone(_: *App) bool {
    return qa.find(mark(&mbuf, "pp-item:{d}", msg_id)) == null and qa.find("pp-panel") != null;
}

fn onMemes(app: *App) bool {
    return app.st.activeChannel() == memes;
}

fn jumpedBack(app: *App) bool {
    return app.st.activeChannel() == geral and qa.find(mark(&mbuf, "msg:{d}", msg_id)) != null;
}

fn tRemove(_: *App, buf: []u8) []const u8 {
    return mark(buf, "pp-btn:rm{d}", msg_id);
}

fn layoutMoved(_: *App) bool {
    const pn = qa.find("pp-panel") orelse return false;
    const comp = qa.find("composer") orelse return false;
    // Encaixado: a caixa de mensagem não fica embaixo do painel.
    return comp.right() <= pn.x + 1 or comp.x >= pn.right() - 1;
}

fn dockedLeft(app: *App) bool {
    const pn = qa.find("pp-panel") orelse return false;
    const comp = qa.find("composer") orelse return false;
    return app.plugins.panel_left and pn.x < 1 and comp.x >= pn.right() - 1;
}

fn dockedRight(app: *App) bool {
    const pn = qa.find("pp-panel") orelse return false;
    const comp = qa.find("composer") orelse return false;
    return !app.plugins.panel_left and comp.right() <= pn.x + 1;
}

var width0: f32 = 0;
fn rememberWidth(app: *App) void {
    width0 = app.plugins.panel_w;
}
fn widthChanged(app: *App) bool {
    return @abs(app.plugins.panel_w - width0) > 40;
}

fn openFavoritos(app: *App) void {
    app.plugins.openPanel(plugin(app, "bookmarks.lua"));
}

fn panelClosed(app: *App) bool {
    return app.plugins.panel_open == null and qa.find("pp-panel") == null;
}

// --- Lembretes -------------------------------------------------------------------------

var desktop0: u32 = 0;
fn rememberDesktop(_: *App) void {
    desktop0 = host.qa_desktop;
}
fn reminderSet(app: *App) bool {
    return toastHas(app, "Vou lembrar");
}
fn reminderFired(_: *App) bool {
    return host.qa_desktop > desktop0 and std.mem.indexOf(u8, host.qa_desktop_text[0..host.qa_desktop_len], "teste do lembrete") != null;
}
fn panelLembretes(app: *App) bool {
    return openIs(app, "reminders.lua") and qa.find("pp-btn:in1h") != null;
}
fn tReminderItem(_: *App, buf: []u8) []const u8 {
    return firstMark("pp-item:r", buf);
}
fn hasReminder(_: *App) bool {
    return anyMark("pp-item:r");
}
fn noReminder(_: *App) bool {
    return !anyMark("pp-item:r") and qa.find("pp-panel") != null;
}
fn tReminderCancel(_: *App, buf: []u8) []const u8 {
    return firstMark("pp-btn:cancel", buf);
}
fn restartAll(app: *App) void {
    const me = app.plugins.account;
    app.plugins.setAccount(0);
    app.plugins.setAccount(me);
}
fn firedOldShown(_: *App) bool {
    return anyMark("pp-item:old");
}
fn reminderJumped(app: *App) bool {
    return app.st.activeChannel() == geral and qa.find(mark(&mbuf, "msg:{d}", msg_id)) != null;
}
fn timeRefused(app: *App) bool {
    return toastHas(app, "Não entendi esse tempo");
}
fn pendingGone(_: *App) bool {
    return qa.find("pp-btn:in1h") == null and !anyMark("pp-item:r");
}
fn tSnooze(_: *App, buf: []u8) []const u8 {
    return firstMark("pp-btn:snooze", buf);
}
fn twoReminders(_: *App) bool {
    var keys: [4][56]u8 = undefined;
    var lens: [4]u8 = undefined;
    return qa.keysWith(&.{"pp-item:r"}, &keys, &lens) >= 2;
}
fn hasDatedReminder(app: *App) bool {
    const p = plugin(app, "reminders.lua") orelse return false;
    const t = p.tree orelse return false;
    for (t.nodes.items) |*n| if (n.kind == .item and std.mem.indexOf(u8, n.text, "conferir amanhã") != null) return true;
    return false;
}
fn hasDailyReminder(app: *App) bool {
    const p = plugin(app, "reminders.lua") orelse return false;
    const t = p.tree orelse return false;
    for (t.nodes.items) |*n| if (n.kind == .item and std.mem.indexOf(u8, n.text, "🔁 reunião") != null) return true;
    return false;
}
fn panelLembretesAberto(app: *App) bool {
    return openIs(app, "reminders.lua") and qa.find("pp-panel") != null;
}

// --- Destaques ---------------------------------------------------------------------------

var hit_id: Id = 0;
fn sendUrgent(app: *App) void {
    hit_id = inject(app, geral, 1001, "isso é URGENTE, pessoal");
}
fn highlightToast(app: *App) bool {
    return toastHas(app, "★ urgente");
}
fn hitInPanel(_: *App) bool {
    return qa.find(mark(&mbuf, "pp-item:{d}", hit_id)) != null;
}
fn hitBadge(app: *App) bool {
    // Pelo índice: depois de um pulo, a mensagem nova pode estar fora da tela.
    const f = app.store.findAny(hit_id) orelse return false;
    const v = app.plugins.deco.view(f.m, app.store.me);
    return v.n > 0 and std.mem.indexOf(u8, v.slice()[0].badge, "urgente") != null;
}
fn tHit(_: *App, buf: []u8) []const u8 {
    return mark(buf, "pp-item:{d}", hit_id);
}
fn hitJumped(app: *App) bool {
    return app.st.activeChannel() == geral and qa.find(mark(&mbuf, "msg:{d}", hit_id)) != null;
}
fn deleteHit(app: *App) void {
    deleteMsg(app, geral, hit_id);
}
fn hitGone(_: *App) bool {
    return qa.find(mark(&mbuf, "pp-item:{d}", hit_id)) == null;
}
fn hitDiskClean(app: *App) bool {
    // No disco nunca fica o texto de ninguém.
    var pb: [96]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&pb, "qa-out/plugin-data/{d}/highlights.lua.json", .{app.store.me}, 0) catch return false;
    var size: usize = 0;
    const data = c.SDL_LoadFile(path.ptr, &size) orelse return false;
    defer c.SDL_free(data);
    const text = @as([*]const u8, @ptrCast(data))[0..size];
    return std.mem.indexOf(u8, text, "pessoal") == null and std.mem.indexOf(u8, text, "urgente") != null;
}
fn tabBadge(_: *App) bool {
    return qa.find("pp-badge:highlights.lua") != null;
}
fn headerBadge(_: *App) bool {
    return qa.find("header-plugins-badge") != null;
}
fn noBadges(app: *App) bool {
    return app.plugins.n_badges == 0 and qa.find("header-plugins-badge") == null;
}
fn editHit(app: *App) void {
    editMsg(app, geral, hit_id, "agora URGENTE de verdade");
}
fn hitEdited(app: *App) bool {
    const p = plugin(app, "highlights.lua") orelse return false;
    const t = p.tree orelse return false;
    var kb: [32]u8 = undefined;
    const k = std.fmt.bufPrint(&kb, "{d}", .{hit_id}) catch return false;
    for (t.nodes.items) |*n| if (std.mem.eql(u8, n.key, k)) return std.mem.indexOf(u8, n.sub, "de verdade") != null;
    return false;
}
fn editHitNoWord(app: *App) void {
    editMsg(app, geral, hit_id, "mudei de ideia");
}
fn mutedRow(_: *App) bool {
    return anyMark("pp-btn:unmute");
}
fn notMuted(_: *App) bool {
    return !anyMark("pp-btn:unmute");
}
fn tUnmute(_: *App, buf: []u8) []const u8 {
    return firstMark("pp-btn:unmute", buf);
}
fn sendUrgentMuted(app: *App) void {
    _ = inject(app, geral, 1001, "URGENTE no canal silenciado");
}
fn noHighlightToast(app: *App) bool {
    return !toastHas(app, "★ urgente");
}
fn desktopFired(_: *App) bool {
    return host.qa_desktop > desktop0 and std.mem.indexOf(u8, host.qa_desktop_text[0..host.qa_desktop_len], "urgente") != null;
}
fn paletteOpen(app: *App) bool {
    return app.st.palette.open;
}
fn panelDestaques(app: *App) bool {
    return openIs(app, "highlights.lua");
}
fn wordThere(_: *App) bool {
    return qa.find("pp-item:w1") != null;
}
fn noWord(_: *App) bool {
    return qa.find("pp-item:w1") == null;
}

// --- Filtro ----------------------------------------------------------------------------

var filtered_id: Id = 0;
var other_id: Id = 0;
fn sendSpoiler(app: *App) void {
    filtered_id = inject(app, geral, 1001, "olha um spoiler aqui");
    other_id = inject(app, geral, 1001, "mensagem que passa");
}
fn isCollapsed(app: *App, id: Id) bool {
    const f = app.store.findAny(id) orelse return false;
    return app.plugins.deco.collapses(f.m, app.store.me) and !app.st.filtros.revealed.contains(id);
}
fn stickBottom(app: *App) void {
    app.st.scrollOf(geral).stick_bottom = true;
}
fn collapsed(_: *App) bool {
    return qa.find(mark(&mbuf, "hidden:{d}", filtered_id)) != null and qa.find(mark(&mbuf, "msgtext:{d}", other_id)) != null;
}
fn tShow(_: *App, buf: []u8) []const u8 {
    return mark(buf, "hidden-show:{d}", filtered_id);
}
fn shown(_: *App) bool {
    return qa.find(mark(&mbuf, "hidden:{d}", filtered_id)) == null and qa.find(mark(&mbuf, "msgtext:{d}", filtered_id)) != null;
}
fn panelFiltro(app: *App) bool {
    return openIs(app, "filter.lua");
}
fn userCollapsed(app: *App) bool {
    return isCollapsed(app, other_id);
}
fn userBack(app: *App) bool {
    return !isCollapsed(app, other_id);
}
fn pausedLabel(_: *App) bool {
    return qa.find("pp-btn:pause") != null;
}
fn pickUserMessage(app: *App) void {
    msg_id = other_id;
    msg_author = if (app.store.findAny(other_id)) |f| f.m.msg.author else 0;
}
fn hasUserRow(_: *App) bool {
    return qa.find("pp-item:u1") != null;
}

// --- Trechos ----------------------------------------------------------------------------

fn panelTrechos(app: *App) bool {
    return openIs(app, "snippets.lua");
}
fn snippetSaved(_: *App) bool {
    return qa.find("pp-item:ola") != null;
}
fn snippetGone(_: *App) bool {
    return qa.find("pp-item:ola") == null;
}
fn snippetEnterSaved(_: *App) bool {
    return qa.find("pp-item:enter") != null;
}
fn snippetDraftFromMessage(app: *App) bool {
    return panelTrechos(app) and qa.find("pp-input:text") != null;
}
fn snippetFromMessageSaved(_: *App) bool {
    return qa.find("pp-item:da-mensagem") != null;
}
fn inserted(app: *App) bool {
    return std.mem.indexOf(u8, inputText(app), "olá, tudo bem?") != null;
}
fn notSent(app: *App) bool {
    const ch = app.st.activeChannel() orelse return false;
    const cs = app.store.channel(ch) orelse return false;
    const items = cs.messages.items;
    if (items.len == 0) return true;
    return !std.mem.eql(u8, items[items.len - 1].msg.content, "olá, tudo bem?");
}
fn insertedAndNotSent(app: *App) bool {
    return inserted(app) and notSent(app);
}
fn inputEmpty(app: *App) bool {
    return inputText(app).len == 0;
}
fn suggestionShown(_: *App) bool {
    return qa.find("autocomplete") != null and qa.find("ac:0") != null;
}

// --- Tradução ---------------------------------------------------------------------------

const translate_host = "host:translate.lua:api.mymemory.translated.net";
var count0: u32 = 0;
fn rememberCount(_: *App) void {
    count0 = serverCount();
}
fn asksApproval(app: *App) bool {
    return toastHas(app, "Aprove");
}
fn nothingSent(_: *App) bool {
    return serverCount() == count0;
}
fn approved(app: *App) bool {
    return app.plugins.isApproved("translate.lua", "api.mymemory.translated.net");
}
fn notApproved(app: *App) bool {
    return !approved(app);
}
fn noteShows(app: *App) bool {
    const v = viewOf(app) orelse return false;
    for (v.slice()) |*part| {
        if (std.mem.indexOf(u8, part.note, "texto traduzido pelo servidor") != null) return qa.find(mark(&mbuf, "deco-note:{d}", msg_id)) != null;
    }
    return false;
}
fn viewOf(app: *App) ?engine.deco.View {
    const f = app.store.findAny(msg_id) orelse return null;
    return app.plugins.deco.view(f.m, app.store.me);
}
fn requestClean() bool {
    return !srv_leak;
}
fn requestOk(_: *App) bool {
    return requestClean() and serverLastHas("GET /get?q=") and serverLastHas("langpair=Autodetect%7Cpt") and !serverLastHas("Cookie") and !serverLastHas("Authorization");
}
fn tClose(_: *App, buf: []u8) []const u8 {
    return mark(buf, "deco-close:{d}", msg_id);
}
fn noteGone(_: *App) bool {
    return qa.find(mark(&mbuf, "deco-note:{d}", msg_id)) == null;
}
fn optionsShow(_: *App) bool {
    return qa.find("pp-select:target") != null and qa.find("pp-select:source") != null;
}
fn languageList(_: *App) bool {
    return qa.find("pp-opt:target:es") != null and qa.find("pp-opt:target:zh-CN") != null;
}
fn optionIs(app: *App, name: []const u8, key_name: []const u8, want: []const u8) bool {
    const p = plugin(app, name) orelse return false;
    const t = p.settings orelse return false;
    for (t.nodes.items) |*n| if (std.mem.eql(u8, n.key, key_name)) return std.mem.eql(u8, n.meta, want);
    return false;
}
fn targetEs(app: *App) bool {
    return optionIs(app, "translate.lua", "target", "es");
}
fn optionsKept(app: *App) bool {
    return targetEs(app) and optionIs(app, "translate.lua", "source", "en");
}
fn requestEs(_: *App) bool {
    return serverLastHas("langpair=Autodetect%7Ces");
}
fn requestFr(_: *App) bool {
    return serverLastHas("langpair=Autodetect%7Cfr");
}
fn requestSource(_: *App) bool {
    return serverLastHas("langpair=en%7Ces");
}
fn requestDe(_: *App) bool {
    return serverLastHas("%7Cde");
}
fn noteHasText(app: *App, text: []const u8) bool {
    const v = viewOf(app) orelse return false;
    for (v.slice()) |*part| if (std.mem.indexOf(u8, part.note, text) != null) return true;
    return false;
}
fn noteEs(app: *App) bool {
    return noteHasText(app, "🌐 ES · texto traduzido");
}
fn noteFr(app: *App) bool {
    return noteHasText(app, "🌐 FR · texto traduzido");
}
fn secondList(_: *App) bool {
    return qa.find("menu:Francês") != null and qa.find("menu:Chinês") != null;
}
fn toolbarGlyph(_: *App) bool {
    return qa.find("tb-plugin:Translate") != null;
}
fn translationInBox(app: *App) bool {
    return std.mem.eql(u8, inputText(app), "texto traduzido pelo servidor");
}
fn translationNotSent(app: *App) bool {
    const ch = app.st.activeChannel() orelse return false;
    const cs = app.store.channel(ch) orelse return false;
    const items = cs.messages.items;
    return items.len == 0 or !std.mem.eql(u8, items[items.len - 1].msg.content, "texto traduzido pelo servidor");
}
fn trWorked(app: *App) bool {
    return translationInBox(app) and translationNotSent(app) and requestDe(app);
}

// --- Atualizar e arquivar ---------------------------------------------------------------

const old_translate =
    \\-- @name Translate
    \\-- @version 1.0.0
    \\-- @capabilities menu
    \\-- arquivo-antigo
    \\sigma.menu("message", "Velho", function() end)
;

fn writeOldTranslate(_: *App) void {
    _ = c.SDL_SaveFile("qa-out/plugins/translate.lua", old_translate.ptr, old_translate.len);
}
fn oldLoaded(app: *App) bool {
    const p = plugin(app, "translate.lua") orelse return false;
    return std.mem.eql(u8, p.man.version, "1.0.0") and p.isRunning();
}
fn updateOffered(_: *App) bool {
    return qa.find("plugin-update:translate.lua") != null;
}
fn updateGone(app: *App) bool {
    const p = plugin(app, "translate.lua") orelse return false;
    return !std.mem.eql(u8, p.man.version, "1.0.0") and p.isRunning() and qa.find("plugin-card:translate.lua") != null and qa.find("plugin-update:translate.lua") == null;
}
fn fileHas(path: [*:0]const u8, needle: []const u8) bool {
    var size: usize = 0;
    const data = c.SDL_LoadFile(path, &size) orelse return false;
    defer c.SDL_free(data);
    return std.mem.indexOf(u8, @as([*]const u8, @ptrCast(data))[0..size], needle) != null;
}
fn bakKept(_: *App) bool {
    return fileHas("qa-out/plugins/translate.lua.bak", "arquivo-antigo") and !fileHas("qa-out/plugins/translate.lua", "arquivo-antigo");
}
fn writeBakMarker(_: *App) void {
    const text = "copia-de-antes";
    _ = c.SDL_SaveFile("qa-out/plugins/translate.lua.bak", text.ptr, text.len);
}
fn bakNotOverwritten(_: *App) bool {
    return fileHas("qa-out/plugins/translate.lua.bak", "copia-de-antes") and fileHas("qa-out/plugins/translate.lua.bak2", "arquivo-antigo");
}
fn writeCollision(_: *App) void {
    _ = c.SDL_CreateDirectory("qa-out/plugins/antigos");
    const text = "ja-estava-aqui";
    _ = c.SDL_SaveFile("qa-out/plugins/antigos/bookmarks.lua", text.ptr, text.len);
}
fn archiveOffered(_: *App) bool {
    return qa.find("plugin-archive") != null;
}
fn archived(app: *App) bool {
    if (plugin(app, "bookmarks.lua") != null or plugin(app, "stats.lua") != null or plugin(app, "shrug.lua") != null) return false;
    // Nada é apagado, nem o que já estava na pasta.
    return bundledRunning(app) and qa.find("plugin-archive") == null and
        fileHas("qa-out/plugins/antigos/bookmarks.lua", "ja-estava-aqui") and
        fileHas("qa-out/plugins/antigos/bookmarks-2.lua", "@name") and
        fileHas("qa-out/plugins/antigos/stats.lua", "@name");
}

// --- Links limpos, horários, links e arquivos ----------------------------------------------

fn lastContentIs(app: *App, want: []const u8) bool {
    const ch = app.st.activeChannel() orelse return false;
    const cs = app.store.channel(ch) orelse return false;
    const items = cs.messages.items;
    if (items.len == 0) return false;
    return std.mem.eql(u8, items[items.len - 1].msg.content, want);
}
fn linkCleaned(app: *App) bool {
    return lastContentIs(app, "olha https://youtu.be/abc?t=30");
}
fn linkInCodeKept(app: *App) bool {
    return lastContentIs(app, "`https://youtu.be/abc?si=xyz`");
}
fn stampInBox(app: *App) bool {
    const t = inputText(app);
    return std.mem.startsWith(u8, t, "<t:") and std.mem.endsWith(u8, t, ":f>");
}
fn stampRelative(app: *App) bool {
    const t = inputText(app);
    return std.mem.startsWith(u8, t, "<t:") and std.mem.endsWith(u8, t, ":R>");
}
fn stampShown(_: *App) bool {
    return anyMark("stamp:");
}
/// Em todos os formatos, na mesma hora: número sem sinal, e o ano onde deveria estar.
fn stampReadable(_: *App) bool {
    const rich = @import("ui/rich.zig");
    const when: u64 = 1_800_000_000;
    for ("tTdDfFR") |style| {
        var b: [96]u8 = undefined;
        const t = rich.stampText(&b, when << 8 | style);
        if (t.len < 2 or std.mem.indexOfScalar(u8, t, '+') != null or std.mem.eql(u8, t, "?")) return false;
        if (std.mem.indexOfScalar(u8, "dDfF", style) != null and std.mem.indexOf(u8, t, "2027") == null) return false;
    }
    return true;
}
fn sendLink(app: *App) void {
    _ = inject(app, geral, 1001, "olha https://exemplo.com/pagina.");
}
fn panelLinks(app: *App) bool {
    return openIs(app, "links.lua");
}
fn linkItemUrl(app: *App) ?[]const u8 {
    const p = plugin(app, "links.lua") orelse return null;
    const t = p.tree orelse return null;
    for (t.nodes.items) |*n| if (std.mem.eql(u8, n.key, "i1")) return n.sub;
    return null;
}
fn linkListed(app: *App) bool {
    return panelLinks(app) and std.mem.eql(u8, linkItemUrl(app) orelse "", "https://exemplo.com/pagina") and qa.find("pp-item:i1") != null;
}
fn linkFiltered(app: *App) bool {
    return linkItemUrl(app) == null;
}
fn urlOpened(_: *App) bool {
    return std.mem.eql(u8, attachments.last_opened[0..attachments.last_opened_len], "https://exemplo.com/pagina");
}
fn urlCopied(app: *App) bool {
    return toastHas(app, "copiado");
}
fn kindMenu(_: *App) bool {
    return qa.find("pp-opt:kind:file") != null;
}
fn linkJumped(app: *App) bool {
    return app.st.activeChannel() == geral;
}
fn linksForgotten(app: *App) bool {
    return panelClosed(app) and linkItemUrl(app) == null;
}

// --- Anti-golpe -----------------------------------------------------------------------------

var scam_id: Id = 0;
var official_id: Id = 0;
var talk_id: Id = 0;
var scam2_id: Id = 0;

fn partOf(app: *App, id: Id) ?engine.deco.Part {
    const f = app.store.findAny(id) orelse return null;
    const v = app.plugins.deco.view(f.m, app.store.me);
    return if (v.n > 0) v.slice()[0] else null;
}
fn sendScams(app: *App) void {
    official_id = inject(app, geral, 1001, "entra no nosso servidor https://discord.gg/abc");
    talk_id = inject(app, geral, 1001, "alguém sabe se nitro grátis existe mesmo?");
    scam_id = inject(app, geral, 1001, "pessoal, ganhe nitro grátis por 3 meses nesse link https://dlscord-nitro.ru/gift/abc");
}
fn scamMarked(app: *App) bool {
    const part = partOf(app, scam_id) orelse return false;
    return part.danger and std.mem.indexOf(u8, part.note, "Possível golpe") != null and std.mem.indexOf(u8, part.note, "dlscord-nitro.ru") != null;
}
fn scamDrawnRed(_: *App) bool {
    return qa.find(mark(&mbuf, "deco-danger:{d}", scam_id)) != null;
}
fn othersClean(app: *App) bool {
    return app.store.findAny(talk_id) != null and app.store.findAny(official_id) != null and partOf(app, talk_id) == null and partOf(app, official_id) == null;
}
fn scamBadge(app: *App) bool {
    const p = plugin(app, "scamguard.lua") orelse return false;
    const t = p.tree orelse return false;
    return std.mem.eql(u8, t.badge, "1") and qa.find("header-plugins-badge") != null;
}
fn scamListed(app: *App) bool {
    return openIs(app, "scamguard.lua") and qa.find(mark(&mbuf, "pp-item:{d}", scam_id)) != null;
}
fn onlyThisScam(app: *App) bool {
    // Nada do que a demonstração já tem no canal é marcado.
    const p = plugin(app, "scamguard.lua") orelse return false;
    const t = p.tree orelse return false;
    var items: usize = 0;
    for (t.nodes.items) |*n| {
        if (n.kind == .item) items += 1;
    }
    return items == 1;
}
fn tScamItem(_: *App, buf: []u8) []const u8 {
    return mark(buf, "pp-item:{d}", scam_id);
}
fn scamJumped(app: *App) bool {
    return app.st.activeChannel() == geral and qa.find(mark(&mbuf, "msg:{d}", scam_id)) != null;
}
fn pickScam(_: *App) void {
    msg_id = scam_id;
}
fn scamCleared(app: *App) bool {
    return partOf(app, scam_id) == null and qa.find(mark(&mbuf, "pp-item:{d}", scam_id)) == null;
}
fn trustedRow(_: *App) bool {
    return qa.find("pp-btn:untrust1") != null;
}
fn sendSameDomain(app: *App) void {
    scam2_id = inject(app, geral, 1001, "de novo https://dlscord-nitro.ru/outro");
}
fn sameDomainClean(app: *App) bool {
    return app.store.findAny(scam2_id) != null and partOf(app, scam2_id) == null;
}
fn sameDomainMarked(app: *App) bool {
    const part = partOf(app, scam2_id) orelse return false;
    return part.danger;
}
fn deleteScam2(app: *App) void {
    deleteMsg(app, geral, scam2_id);
}
fn scam2Gone(_: *App) bool {
    return qa.find(mark(&mbuf, "pp-item:{d}", scam2_id)) == null;
}
fn sendIpLink(app: *App) void {
    scam2_id = inject(app, geral, 1001, "baixa aqui http://45.33.32.156/ferramenta");
}

// --- Radar de CVE ---------------------------------------------------------------------------

const cve_host = "host:cve.lua:cveawg.mitre.org";
var cve_id: Id = 0;
var cve2_id: Id = 0;
var cve_old_id: Id = 0;
var cve_rejected_id: Id = 0;
var cve_missing_id: Id = 0;

fn noteOf(app: *App, id: Id) []const u8 {
    const part = partOf(app, id) orelse return "";
    return part.note;
}
fn sendCve(app: *App) void {
    cve_id = inject(app, geral, 1001, "cuidado com o cve-2021-44228, atualizem tudo");
}
fn cveCardShows(_: *App) bool {
    return qa.find("plugin-chip:cve.lua:http") != null and qa.find(cve_host) != null and qa.find("plugin-alert:cve.lua") != null;
}
fn cveNote(app: *App) bool {
    return std.mem.startsWith(u8, noteOf(app, cve_id), "🛡 CVE-2021-44228 · CRÍTICA · CVSS 10.0 · Apache Log4j2");
}
fn cveOnlyNumber(_: *App) bool {
    return serverLastHas("GET /api/cve/CVE-2021-44228 ") and !serverLastHas("atualizem") and !srv_leak;
}
fn cveRed(app: *App) bool {
    const part = partOf(app, cve_id) orelse return false;
    return part.danger;
}
fn sendCveAgain(app: *App) void {
    cve2_id = inject(app, geral, 1002, "CVE-2021-44228 de novo");
}
fn cveAgainNote(app: *App) bool {
    return std.mem.indexOf(u8, noteOf(app, cve2_id), "CVSS 10.0") != null;
}
fn sendCveKinds(app: *App) void {
    cve_old_id = inject(app, geral, 1001, "o velho CVE-1999-0001");
    cve_rejected_id = inject(app, geral, 1001, "esse CVE-2016-0001 foi rejeitado");
    cve_missing_id = inject(app, geral, 1001, "e o CVE-2099-99999 nem existe");
}
fn cveOldNote(app: *App) bool {
    const n = noteOf(app, cve_old_id);
    return std.mem.indexOf(u8, n, "sem nota CVSS") != null and std.mem.indexOf(u8, n, "ip_input.c") != null;
}
fn cveRejectedNote(app: *App) bool {
    return std.mem.indexOf(u8, noteOf(app, cve_rejected_id), "rejeitado") != null;
}
fn cveMissingNote(app: *App) bool {
    return std.mem.indexOf(u8, noteOf(app, cve_missing_id), "não existe") != null;
}
fn panelCve(app: *App) bool {
    return openIs(app, "cve.lua") and qa.find("pp-item:CVE-2024-3094") != null;
}
fn cveFilled(app: *App) bool {
    const p = plugin(app, "cve.lua") orelse return false;
    const t = p.tree orelse return false;
    for (t.nodes.items) |*n| if (std.mem.eql(u8, n.key, "CVE-2024-3094")) return std.mem.indexOf(u8, n.sub, "Xz") != null;
    return false;
}
fn cveOpened(_: *App) bool {
    return std.mem.eql(u8, attachments.last_opened[0..attachments.last_opened_len], "https://www.cve.org/CVERecord?id=CVE-2024-3094");
}
fn cveApproved(app: *App) bool {
    return app.plugins.isApproved("cve.lua", "cveawg.mitre.org");
}
fn cveNotApproved(app: *App) bool {
    return !cveApproved(app);
}

// --- Cartões do GitHub ------------------------------------------------------------------------

const github_host = "host:github.lua:api.github.com";
var gh_issue_id: Id = 0;
var gh_repo_id: Id = 0;
var gh_missing_id: Id = 0;

fn sendGithub(app: *App) void {
    gh_issue_id = inject(app, geral, 1001, "lembra do curl/curl#1 lá de trás?");
    gh_repo_id = inject(app, geral, 1001, "o código está em https://github.com/curl/curl");
    gh_missing_id = inject(app, geral, 1001, "esse aqui não existe: https://github.com/curl/curl/issues/99999999");
}
fn githubCardShows(_: *App) bool {
    return qa.find("plugin-chip:github.lua:http") != null and qa.find(github_host) != null;
}
fn githubApproved(app: *App) bool {
    return app.plugins.isApproved("github.lua", "api.github.com");
}
fn githubNotApproved(app: *App) bool {
    return !githubApproved(app);
}
fn ghIssueNote(app: *App) bool {
    return std.mem.eql(u8, noteOf(app, gh_issue_id), "🔀 curl/curl#1 · fechado · docs/libcurl/libcurl.m4 bug");
}
fn ghRepoNote(app: *App) bool {
    return std.mem.startsWith(u8, noteOf(app, gh_repo_id), "📦 curl/curl · ★ ");
}
fn ghMissingClean(app: *App) bool {
    return app.store.findAny(gh_missing_id) != null and partOf(app, gh_missing_id) == null and serverLastHas("/issues/99999999");
}
fn ghOnlyName(_: *App) bool {
    return !serverLastHas("não existe") and !serverLastHas("lembra") and !srv_leak;
}

// --- O que perdi ----------------------------------------------------------------------------

var missed_mention: Id = 0;
fn sendMissed(app: *App) void {
    var b: [64]u8 = undefined;
    const text = std.fmt.bufPrint(&b, "oi <@{d}>, viu o deploy?", .{app.store.me}) catch return;
    missed_mention = inject(app, geral, 1001, text);
    _ = inject(app, geral, 1002, "alguém sabe onde fica o manual novo?");
    _ = inject(app, geral, 1002, "achei uma pista em https://exemplo.com/manual");
}
fn missedShown(app: *App) bool {
    return openIs(app, "catchup.lua") and qa.find("pp-bar:person1") != null and qa.find("pp-item:mention1") != null and
        qa.find("pp-item:question1") != null and qa.find("pp-item:link1") != null;
}
fn missedOnlyUnread(app: *App) bool {
    const p = plugin(app, "catchup.lua") orelse return false;
    const t = p.tree orelse return false;
    var total: f32 = 0;
    for (t.nodes.items) |*n| {
        if (std.mem.eql(u8, n.key, "nothing-new")) return false;
        if (std.mem.startsWith(u8, n.key, "person")) total += n.value;
    }
    return total == 3;
}
fn missedJumped(app: *App) bool {
    return app.st.activeChannel() == geral and qa.find(mark(&mbuf, "msg:{d}", missed_mention)) != null;
}
fn modeMenu(_: *App) bool {
    return qa.find("pp-opt:mode:50") != null;
}
fn missedMore(app: *App) bool {
    const p = plugin(app, "catchup.lua") orelse return false;
    const t = p.tree orelse return false;
    var total: f32 = 0;
    for (t.nodes.items) |*n| {
        if (std.mem.startsWith(u8, n.key, "person")) total += n.value;
    }
    return total > 3;
}
fn missedForgotten(app: *App) bool {
    const p = plugin(app, "catchup.lua") orelse return false;
    const t = p.tree orelse return false;
    if (!panelClosed(app)) return false;
    for (t.nodes.items) |*n| {
        if (std.mem.eql(u8, n.key, "person1")) return false;
    }
    return true;
}

// --- Estatísticas ------------------------------------------------------------------------

fn panelStats(app: *App) bool {
    return openIs(app, "stats.lua") and qa.find("pp-bar:top1") != null and qa.find("pp-text:total") != null;
}

// --- Limites do HTTP, com o curl de verdade ---------------------------------------------

const qa_http_plugin =
    \\-- @name QA HTTP
    \\-- @capabilities http, notify
    \\-- @hosts qa.exemplo.com
    \\local function mostra(nome)
    \\  return function(r)
    \\    sigma.notify(nome .. "|" .. tostring(r.ok) .. "|" .. tostring(r.status) .. "|" .. tostring(r.error) .. "|" .. #r.body)
    \\  end
    \\end
    \\sigma.command("/qa-big", function() sigma.http.get("https://qa.exemplo.com/big", mostra("big")) end)
    \\sigma.command("/qa-redir", function() sigma.http.get("https://qa.exemplo.com/redir", mostra("redir")) end)
    \\sigma.command("/qa-post", function()
    \\  sigma.http.post("https://qa.exemplo.com/echo", { body = "corpo-do-post", headers = { ["Content-Type"] = "text/plain", Cookie = "a=b", Authorization = "c" } }, mostra("post"))
    \\end)
    \\sigma.command("/qa-plain", function()
    \\  sigma.notify("plain|" .. tostring(pcall(sigma.http.get, "http://qa.exemplo.com/x", mostra("x"))))
    \\end)
;

const qa_slow_plugin =
    \\-- @name QA lento
    \\-- @capabilities notify
    \\sigma.command("/qa-lento", function()
    \\  -- Mais de um segundo na thread dos plugins, com poucas instruções: o tempo
    \\  -- passa em C. Um laço de Lua contra o relógio estoura o limite de instruções
    \\  -- onde ler o relógio é barato (no Windows).
    \\  local s = string.rep("a", 100000)
    \\  local t = os.time()
    \\  local n = 0
    \\  while os.time() - t < 2 and n < 200 do
    \\    pcall(string.find, s, ".-.-.-b")
    \\    n = n + 1
    \\  end
    \\  sigma.notify("lento acabou")
    \\end)
;

const qa_noisy_plugin =
    \\-- @name QA barulhento
    \\-- @capabilities notify
    \\sigma.command("/qa-barulho", function()
    \\  for i = 1, 12 do sigma.notify("barulho " .. i, { desktop = true }) end
    \\end)
;

fn writeExtra(_: *App) void {
    _ = c.SDL_SaveFile("qa-out/plugins/qahttp.lua", qa_http_plugin.ptr, qa_http_plugin.len);
    _ = c.SDL_SaveFile("qa-out/plugins/qalento.lua", qa_slow_plugin.ptr, qa_slow_plugin.len);
    _ = c.SDL_SaveFile("qa-out/plugins/qabarulho.lua", qa_noisy_plugin.ptr, qa_noisy_plugin.len);
}
fn removeExtra(_: *App) void {
    _ = c.SDL_RemovePath("qa-out/plugins/qahttp.lua");
    _ = c.SDL_RemovePath("qa-out/plugins/qalento.lua");
    _ = c.SDL_RemovePath("qa-out/plugins/qabarulho.lua");
}
fn noisyLimited(_: *App) bool {
    return host.qa_desktop - desktop0 == 6 and std.mem.indexOf(u8, host.qa_desktop_text[0..host.qa_desktop_len], "barulho 6") != null;
}
fn reminderAfterNoise(_: *App) bool {
    return host.qa_desktop - desktop0 == 7 and std.mem.indexOf(u8, host.qa_desktop_text[0..host.qa_desktop_len], "depois do barulho") != null;
}
fn extraLoaded(app: *App) bool {
    const a = plugin(app, "qahttp.lua") orelse return false;
    const b = plugin(app, "qalento.lua") orelse return false;
    return a.status() == .running and b.status() == .running and app.plugins.n_commands > 0;
}
fn bigRefused(app: *App) bool {
    return toastHas(app, "big|false|0|too_big|0");
}
fn redirectNotFollowed(app: *App) bool {
    return toastHas(app, "redir|false|302|");
}
fn postEchoed(app: *App) bool {
    return toastHas(app, "post|true|200|nil|13") and serverLastHas("corpo-do-post") and !serverLastHas("Cookie") and !serverLastHas("Authorization") and !srv_leak;
}
fn plainRefused(app: *App) bool {
    return toastHas(app, "plain|false");
}

var loops0: u32 = 0;
fn loopsNow(app: *App) u32 {
    const w = app.plugins.worker orelse return 0;
    return w.loops.load(.monotonic);
}
fn rememberLoops(app: *App) void {
    loops0 = loopsNow(app);
}
fn loopsSame(app: *App) bool {
    return loopsNow(app) == loops0;
}

var frames_seen: u32 = 0;
var frames_until_done: ?u32 = null;
fn clearFrames(_: *App) void {
    frames_seen = 0;
    frames_until_done = null;
}
/// Cada conferência é um quadro; valem os de antes do Lua acabar. Com o plugin na
/// thread da interface, o aviso já estaria lá na primeira.
fn framesWhileBusy(app: *App) bool {
    frames_seen += 1;
    if (frames_until_done == null and toastHas(app, "lento acabou")) frames_until_done = frames_seen;
    return (frames_until_done orelse 0) >= 2;
}

// --- Roteiros -----------------------------------------------------------------------------

// --- Outras escritas nas mensagens: o print mostra se cada uma aparece --------------------

fn sendScripts(app: *App) void {
    // A frase de "your code displays Japanese wrong": muda de desenho entre japonês e chinês.
    _ = inject(app, geral, 1002, "刃直海角骨入");
    _ = inject(app, geral, 1001, "日本語: こんにちは、カタカナも漢字も表示されますか");
    _ = inject(app, geral, 1002, "한국어: 안녕하세요, 한글이 잘 보이나요");
    _ = inject(app, geral, 1001, "中文: 你好,世界。这是简体中文");
    _ = inject(app, geral, 1002, "Русский: привет, мир. Ελληνικά: γειά σου κόσμε");
    _ = inject(app, geral, 1001, "Türkçe: ğüşıöç İ. Tiếng Việt: xin chào thế giới");
    _ = inject(app, geral, 1002, "Polski: zażółć gęślą jaźń. Čeština: příliš žluťoučký kůň");
}

fn preferJapanese(app: *App) void {
    app.fonts_lang_changed = false;
    app.fonts.preferLanguage("ja");
    app.st.theme_gen +%= 1;
}

pub const ops_scripts = [_]Op{
    s("outras escritas"),
    run(toGeral),
    .{ .wait = 300 },
    expect("antes de um texto pedir, nenhuma fonte reserva", @import("qa_paineis.zig").scriptsNotLoaded),
    run(sendScripts),
    run(stickBottom),
    expect("o texto pede e as fontes reserva entram em todas as fontes", @import("qa_paineis.zig").scriptsLoaded),
    .{ .wait = 700 },
    .{ .shot = "escritas" },
    // Trocar para japonês com o app aberto: o desenho japonês passa para a frente.
    run(preferJapanese),
    .{ .wait = 700 },
    .{ .shot = "escritas-ja" },
};

// --- Encaminhar: o menu, a escolha do destino e o cartão que chega ------------------------

fn forwardPicking(app: *App) bool {
    const p = &app.st.palette;
    if (!p.open or p.forward != msg_id or p.items.items.len == 0) return false;
    for (p.items.items) |it| if (it.kind != .channel) return false;
    return true;
}
fn forwardTargetIsMemes(app: *App) bool {
    const p = &app.st.palette;
    return p.items.items.len > 0 and p.items.items[0].id == memes;
}
fn forwardedToMemes(app: *App) bool {
    if (app.st.palette.open or app.st.palette.forward != 0) return false;
    const src = app.store.findAny(msg_id) orelse return false;
    const cs = app.store.channel(memes) orelse return false;
    const items = cs.messages.items;
    if (items.len == 0) return false;
    const m = &items[items.len - 1].msg;
    return m.author == app.store.me and m.embeds.len == 1 and std.mem.eql(u8, m.embeds[0].provider, "Encaminhada") and
        std.mem.eql(u8, m.embeds[0].description, src.m.msg.content);
}
fn paletteIsNormalAgain(app: *App) bool {
    const p = &app.st.palette;
    if (!p.open or p.forward != 0) return false;
    for (p.items.items) |it| if (it.kind != .channel) return true;
    return false;
}

pub const ops_forward = [_]Op{
    s("encaminhar mensagem"),
    run(toGeral),
    .{ .wait = 300 },
    run(pickOther),
    rmsg,
    click("menu:Encaminhar"),
    expect("o menu abre a escolha do destino, só com canais", forwardPicking),
    .{ .wait = 150 },
    .{ .shot = "encaminhar-destino" },
    .{ .text = "memes" },
    expect("a busca acha o canal", forwardTargetIsMemes),
    key(c.ImGuiKey_Enter),
    expectLong("a mensagem chega no destino, como cartão, com o texto original", forwardedToMemes),
    ctrl(c.ImGuiKey_K),
    expect("a paleta volta a ser a normal", paletteIsNormalAgain),
    key(c.ImGuiKey_Escape),
};

/// Entra depois de "Instalar os incluídos" na bateria geral (configurações abertas).
pub const ops = [_]Op{
    s("plugins: a página"),
    run(writeFixtures),
    run(reloadNow),
    expectLong("os plugins de teste ligam junto com os incluídos", fixturesLoaded),
    expect("os incluídos estão ligados, numa thread própria", threadUp),
    expect("todos os plugins incluídos rodam sem erro", bundledRunning),
    expect("cartão com o cabeçalho, as permissões e o botão do painel", cardsShow),
    expect("plugin antigo aparece como API antiga", cardsShow),
    expect("as capacidades novas aparecem como etiquetas", newChips),
    expect("quem lê mensagens e manda para fora ganha um aviso, os outros não", alertsShow),
    .{ .shot = "plugins-pagina" },
    .{ .key = .{ .key = c.ImGuiKey_Escape } },

    s("plugins: favoritos"),
    run(toGeral),
    .{ .wait = 200 },
    run(pickOther),
    rmsg,
    click("menu:Salvar nos favoritos"),
    expect("salvar nos favoritos marca a mensagem", bookmarkBadge),
    .{ .shot = "plugin-selo" },
    click("header-plugins"),
    expect("o botão do cabeçalho abre o painel", panelFavoritos),
    expect("a mensagem salva está no painel", itemThere),
    expect("com o painel aberto a caixa de texto cabe ao lado", layoutMoved),
    .{ .shot = "plugin-favoritos" },
    click("pp-input:search"),
    .{ .text = "nada-disso-existe" },
    expect("a busca filtra o painel", itemGone),
    ctrl(c.ImGuiKey_A),
    key(c.ImGuiKey_Backspace),
    expect("sem busca, a mensagem volta", itemThere),
    run(toMemes),
    expect("muda de canal", onMemes),
    dyn(tItem),
    expect("clicar no favorito volta para a mensagem", jumpedBack),
    dyn(tRemove),
    expect("remover tira do painel", itemGone),
    expect("e da mensagem", noBadge),
    rmsg,
    click("menu:Salvar nos favoritos"),
    expect("salvar de novo", itemThere),
    rmsg,
    click("menu:Salvar nos favoritos"),
    expect("o mesmo menu tira quem já está salvo", itemGone),

    s("plugins: painel encaixável"),
    run(rememberWidth),
    .{ .drag = .{ .from = .{ .mark = "pp-resize" }, .to = .{ .at = .{ .key = "pp-panel", .fx = 0.5, .fy = 0.5 } } } },
    expect("arrastar a borda muda a largura", widthChanged),
    click("pp-side"),
    expect("encaixar à esquerda leva o layout junto", dockedLeft),
    .{ .shot = "plugin-esquerda" },
    click("pp-side"),
    expect("e voltar à direita", dockedRight),
    click("pp-close"),
    expect("fechar devolve o espaço", panelClosed),
    .{ .resize = .{ 760, 620 } },
    .{ .wait = 150 },
    run(openFavoritos),
    expect("com a janela estreita, o painel abre por cima", panelFavoritos),
    .{ .shot = "plugin-estreito" },
    click("pp-close"),
    expect("e o botão de fechar responde", panelClosed),
    .{ .resize = .{ 1280, 800 } },
    .{ .wait = 150 },

    s("plugins: lembretes"),
    run(rememberDesktop),
    click("composer"),
    .{ .text = "/remind 1s teste do lembrete" },
    key(c.ImGuiKey_Enter),
    expect("/remind confirma", reminderSet),
    expectLong("na hora, sai a notificação do sistema", reminderFired),
    run(pickOther),
    rmsg,
    click("menu:Lembrar desta mensagem"),
    click("menu:Outro tempo…"),
    expect("\"Outro tempo…\" abre o painel com os tempos", panelLembretes),
    .{ .shot = "plugin-lembrete" },
    click("pp-btn:in1h"),
    expect("escolher o tempo cria o lembrete", hasReminder),
    expect("o que já avisou fica na lista", firedOldShown),
    dyn(tSnooze),
    expect("\"mais 10 min\" põe o que já avisou de volta na lista", twoReminders),
    dyn(tReminderCancel),
    expect("e dá para cancelar", hasReminder),
    run(restartAll),
    expect("o painel volta sozinho depois de reiniciar", panelLembretesAberto),
    expect("o lembrete sobrevive a reiniciar", hasReminder),
    dyn(tReminderCancel),
    expect("cancelar tira da lista", noReminder),
    run(pickOther),
    rmsg,
    click("menu:Lembrar desta mensagem"),
    .{ .shot = "plugin-lembrete-lista" },
    click("menu:Em 10 minutos"),
    expect("a segunda lista cria o lembrete direto", hasReminder),
    dyn(tReminderCancel),
    expect("cancelar", noReminder),
    rmsg,
    click("menu:Lembrar desta mensagem"),
    click("menu:Em 1 hora"),
    expect("em 1 hora", hasReminder),
    dyn(tReminderCancel),
    expect("cancelar", noReminder),
    rmsg,
    click("menu:Lembrar desta mensagem"),
    click("menu:Em 3 horas"),
    expect("em 3 horas", hasReminder),
    dyn(tReminderCancel),
    expect("cancelar", noReminder),
    rmsg,
    click("menu:Lembrar desta mensagem"),
    click("menu:Amanhã"),
    expect("amanhã", hasReminder),
    dyn(tReminderCancel),
    expect("cancelar", noReminder),
    click("composer"),
    .{ .text = "/remind amanhã 9h conferir amanhã" },
    key(c.ImGuiKey_Enter),
    expect("/remind entende dia e hora", hasDatedReminder),
    dyn(tReminderCancel),
    expect("cancelar", noReminder),
    click("composer"),
    .{ .text = "/remind todo dia 8:30 reunião" },
    key(c.ImGuiKey_Enter),
    expect("/remind todo dia marca a repetição", hasDailyReminder),
    dyn(tReminderCancel),
    expect("cancelar", noReminder),
    rmsg,
    click("menu:Lembrar desta mensagem"),
    click("menu:Outro tempo…"),
    expect("o painel pergunta o tempo de novo", panelLembretes),
    click("pp-btn:in10m"),
    expect("10 min cria o lembrete", hasReminder),
    dyn(tReminderCancel),
    expect("cancelar", noReminder),
    rmsg,
    click("menu:Lembrar desta mensagem"),
    click("menu:Outro tempo…"),
    expect("o painel pergunta o tempo de novo", panelLembretes),
    click("pp-btn:in3h"),
    expect("3 h cria o lembrete", hasReminder),
    dyn(tReminderCancel),
    expect("cancelar", noReminder),
    rmsg,
    click("menu:Lembrar desta mensagem"),
    click("menu:Outro tempo…"),
    expect("o painel pergunta o tempo de novo", panelLembretes),
    click("pp-btn:in1d"),
    expect("amanhã cria o lembrete", hasReminder),
    dyn(tReminderItem),
    expect("clicar no lembrete vai até a mensagem", reminderJumped),
    dyn(tReminderCancel),
    expect("cancelar", noReminder),
    rmsg,
    click("menu:Lembrar desta mensagem"),
    click("menu:Outro tempo…"),
    expect("o painel pergunta o tempo de novo", panelLembretes),
    click("pp-input:custom"),
    .{ .text = "banana" },
    key(c.ImGuiKey_Enter),
    expect("um tempo que não existe é recusado", timeRefused),
    .{ .text = "20m" },
    key(c.ImGuiKey_Enter),
    expect("um tempo escrito cria o lembrete", hasReminder),
    dyn(tReminderCancel),
    expect("cancelar", noReminder),
    rmsg,
    click("menu:Lembrar desta mensagem"),
    click("menu:Outro tempo…"),
    expect("o painel pergunta o tempo de novo", panelLembretes),
    click("pp-btn:pending-off"),
    expect("deixar para lá não cria nada", pendingGone),

    s("plugins: destaques"),
    ctrl(c.ImGuiKey_K),
    expect("abre a paleta", paletteOpen),
    .{ .text = "Painel: Destaques" },
    .{ .wait = 80 },
    key(c.ImGuiKey_Enter),
    expect("a paleta abre o painel do plugin", panelDestaques),
    click("pp-input:new"),
    .{ .text = "urgente" },
    key(c.ImGuiKey_Enter),
    expect("acrescentar uma palavra", wordThere),
    run(sendUrgent),
    expect("alguém escreve a palavra: aviso", highlightToast),
    expect("entra no histórico", hitInPanel),
    expect("e a mensagem ganha um selo", hitBadge),
    .{ .shot = "plugin-destaques" },
    .{ .wait = 1800 },
    expect("no disco fica a palavra, nunca o texto de quem escreveu", hitDiskClean),
    click("pp-tab:bookmarks.lua"),
    run(sendUrgent),
    expect("com outro painel na frente, o número aparece na etiqueta", tabBadge),
    .{ .shot = "plugin-numero" },
    click("pp-close"),
    expect("fecha o painel", panelClosed),
    expect("e o botão do cabeçalho avisa", headerBadge),
    // O aviso passa por cima do botão: espera ele sair, para o print mostrar o ponto.
    .{ .wait = 4000 },
    .{ .shot = "plugin-numero-cabecalho" },
    click("header-plugins"),
    expect("o botão abre quem tem novidade", panelDestaques),
    expect("abriu, viu: o número some", noBadges),
    run(editHit),
    expect("editaram: o histórico mostra o texto novo", hitEdited),
    run(editHitNoWord),
    expect("sem a palavra, sai do histórico", hitGone),
    run(sendUrgent),
    expect("outra com a palavra", hitInPanel),
    click("pp-btn:mute"),
    expect("silenciar o canal põe na lista", mutedRow),
    run(clearToast),
    run(sendUrgentMuted),
    .{ .wait = 300 },
    expect("no canal silenciado, nenhum aviso", noHighlightToast),
    dyn(tUnmute),
    expect("reativar tira da lista", notMuted),
    ctrl(c.ImGuiKey_Comma),
    click("settings:Plugins"),
    click("pp-toggle:desktop"),
    .{ .wait = 100 },
    key(c.ImGuiKey_Escape),
    run(rememberDesktop),
    run(sendUrgent),
    expect("com a opção ligada, sai a notificação do sistema", desktopFired),
    run(toMemes),
    expect("muda de canal", onMemes),
    dyn(tHit),
    expect("clicar no histórico volta para a mensagem", hitJumped),
    run(deleteHit),
    expect("apagaram a mensagem: sai do histórico", hitGone),
    run(sendUrgent),
    expect("outra mensagem com a palavra", hitInPanel),
    click("pp-btn:clear"),
    expect("limpar o histórico", hitGone),
    click("pp-btn:rmw1"),
    expect("tirar a palavra", noWord),

    s("plugins: filtro local"),
    click("pp-tab:filter.lua"),
    expect("trocar de painel pela etiqueta", panelFiltro),
    click("pp-input:new"),
    .{ .text = "spoiler" },
    key(c.ImGuiKey_Enter),
    .{ .wait = 100 },
    run(sendSpoiler),
    run(stickBottom),
    expect("a mensagem com a palavra fica recolhida, a outra não", collapsed),
    .{ .shot = "plugin-filtro" },
    dyn(tShow),
    expect("mostrar abre só aquela", shown),
    run(pickUserMessage),
    rmsg,
    click("menu:Recolher desta pessoa"),
    expect("recolher pelo menu da mensagem pega todas da pessoa", userCollapsed),
    expect("a pessoa entra na lista", hasUserRow),
    click("pp-btn:pause"),
    expect("pausar devolve as mensagens", userBack),
    click("pp-btn:pause"),
    expect("retomar recolhe de novo", userCollapsed),
    click("pp-btn:rmu1"),
    expect("tirar a pessoa devolve as mensagens", userBack),
    rdyn(tUser),
    click("menu:Recolher mensagens"),
    expect("o menu da pessoa também recolhe", userCollapsed),
    click("pp-btn:rmu1"),
    expect("e tirar devolve", userBack),
    click("pp-btn:rmw1"),
    .{ .wait = 100 },

    s("plugins: trechos"),
    click("pp-tab:snippets.lua"),
    expect("abre o painel de trechos", panelTrechos),
    click("pp-input:name"),
    .{ .text = "ola" },
    .{ .wait = 60 },
    click("pp-input:text"),
    .{ .text = "olá, tudo bem?" },
    .{ .wait = 60 },
    click("pp-btn:add"),
    expect("guardar um trecho", snippetSaved),
    click("composer"),
    ctrl(c.ImGuiKey_A),
    key(c.ImGuiKey_Backspace),
    .{ .text = ";ol" },
    expect("digitar ;ol mostra o trecho na lista", suggestionShown),
    .{ .shot = "plugin-sugestao" },
    key(c.ImGuiKey_Tab),
    expect("Tab põe o texto na caixa, sem enviar", insertedAndNotSent),
    ctrl(c.ImGuiKey_A),
    key(c.ImGuiKey_Backspace),
    click("pp-item:ola"),
    expect("clicar põe na caixa, sem enviar", insertedAndNotSent),
    .{ .shot = "plugin-trechos" },
    click("composer"),
    ctrl(c.ImGuiKey_A),
    key(c.ImGuiKey_Backspace),
    expect("caixa vazia", inputEmpty),
    .{ .text = "/snip ola" },
    key(c.ImGuiKey_Enter),
    expect("/snip põe na caixa, sem enviar", insertedAndNotSent),
    ctrl(c.ImGuiKey_A),
    key(c.ImGuiKey_Backspace),
    click("pp-btn:rmola"),
    expect("tirar o trecho", snippetGone),
    click("pp-input:name"),
    .{ .text = "enter" },
    .{ .wait = 60 },
    click("pp-input:text"),
    .{ .text = "pelo enter" },
    .{ .wait = 60 },
    key(c.ImGuiKey_Enter),
    expect("Enter no texto também guarda", snippetEnterSaved),
    click("pp-btn:rmenter"),
    .{ .wait = 100 },
    run(pickOther),
    rmsg,
    click("menu:Guardar como trecho"),
    expect("guardar uma mensagem traz o texto para o campo", snippetDraftFromMessage),
    click("pp-input:name"),
    .{ .text = "da-mensagem" },
    .{ .wait = 60 },
    click("pp-btn:add"),
    expect("e dá para guardar com um nome", snippetFromMessageSaved),
    click("pp-btn:rmda-mensagem"),
    .{ .wait = 100 },

    s("plugins: tradução"),
    run(startServer),
    run(rememberCount),
    run(pickOther),
    rmsg,
    click("menu:Traduzir"),
    expect("sem aprovar o host, pede aprovação", asksApproval),
    expect("e nada sai para a rede", nothingSent),
    ctrl(c.ImGuiKey_Comma),
    click("settings:Plugins"),
    expect("o cartão mostra o host a aprovar", hostCardShows),
    .{ .shot = "plugin-aprovar" },
    click(translate_host),
    expect("aprovar o host", approved),
    key(c.ImGuiKey_Escape),
    rmsg,
    click("menu:Traduzir"),
    expectLong("a tradução aparece embaixo da mensagem", noteShows),
    .{ .shot = "plugin-traducao" },
    expect("o pedido não leva nada da conta", requestOk),
    dyn(tClose),
    expect("o × dispensa a nota", noteGone),
    rmsg,
    click("menu:Traduzir"),
    expectLong("depois do ×, traduzir de novo traduz (e não só tira a nota)", noteShows),
    rmsg,
    click("menu:Traduzir"),
    expect("clicar outra vez tira", noteGone),

    s("plugins: opções da tradução"),
    ctrl(c.ImGuiKey_Comma),
    click("settings:Plugins"),
    expect("o cartão mostra as opções", optionsShow),
    click("pp-select:target"),
    expect("a lista de idiomas abre", languageList),
    .{ .shot = "plugin-opcoes" },
    click("pp-opt:target:es"),
    expect("escolher um idioma fica marcado", targetEs),
    key(c.ImGuiKey_Escape),
    rmsg,
    click("menu:Traduzir"),
    expectLong("o pedido vai para o idioma da página", requestEs),
    expectLong("a nota mostra o idioma", noteEs),
    .{ .shot = "plugin-traducao-idioma" },
    dyn(tClose),
    expect("o × dispensa a nota", noteGone),
    rmsg,
    click("menu:Traduzir para…"),
    expect("\"Traduzir para…\" abre a segunda lista", secondList),
    .{ .shot = "plugin-menu-idiomas" },
    click("menu:Francês"),
    expectLong("o pedido vai para o idioma da lista", requestFr),
    expectLong("a nota mostra esse idioma", noteFr),
    rmsg,
    click("menu:Traduzir"),
    expect("\"Traduzir\" tira a nota", noteGone),
    rmsg,
    click("menu:Traduzir"),
    expectLong("a lista não mudou a página: volta ao idioma escolhido", requestEs),
    expectLong("a nota volta", noteEs),
    dyn(tClose),
    expect("o × dispensa a nota", noteGone),
    .{ .hover = .{ .dyn = tMsgText } },
    .{ .wait = 150 },
    expect("o botão aparece na barra da mensagem", toolbarGlyph),
    .{ .shot = "plugin-barra" },
    click("tb-plugin:Translate"),
    expectLong("o botão da barra traduz", noteEs),
    dyn(tClose),
    expect("o × dispensa a nota", noteGone),
    ctrl(c.ImGuiKey_Comma),
    click("settings:Plugins"),
    click("pp-select:source"),
    click("pp-opt:source:en"),
    .{ .wait = 100 },
    key(c.ImGuiKey_Escape),
    rmsg,
    click("menu:Traduzir"),
    expectLong("a origem muda a primeira metade do par", requestSource),
    dyn(tClose),
    run(restartAll),
    expectLong("reiniciar o plugin mantém as duas opções", optionsKept),
    run(clearToast),
    click("composer"),
    ctrl(c.ImGuiKey_A),
    key(c.ImGuiKey_Backspace),
    .{ .text = "/tr de bom dia" },
    key(c.ImGuiKey_Enter),
    expectLong("/tr põe a tradução na caixa, sem enviar", trWorked),
    ctrl(c.ImGuiKey_A),
    key(c.ImGuiKey_Backspace),

    s("plugins: atualizar um incluído"),
    run(writeOldTranslate),
    run(reloadNow),
    expectLong("com o arquivo velho na pasta, ele continua rodando", oldLoaded),
    ctrl(c.ImGuiKey_Comma),
    click("settings:Plugins"),
    expect("o cartão oferece a versão nova", updateOffered),
    .{ .shot = "plugin-atualizar" },
    click("plugin-update:translate.lua"),
    expectLong("atualizar troca o arquivo, e o botão some", updateGone),
    expect("o arquivo de antes fica guardado como .bak", bakKept),
    run(writeBakMarker),
    run(writeOldTranslate),
    run(reloadNow),
    expectLong("de novo com o arquivo velho", oldLoaded),
    expect("o cartão oferece de novo", updateOffered),
    click("plugin-update:translate.lua"),
    expectLong("atualizar outra vez", updateGone),
    expect("um .bak que já existe não é sobrescrito", bakNotOverwritten),
    click(translate_host),
    expect("tirar a aprovação", notApproved),
    key(c.ImGuiKey_Escape),

    s("plugins: links limpos"),
    click("composer"),
    .{ .text = "olha https://youtu.be/abc?si=xyz&t=30" },
    key(c.ImGuiKey_Enter),
    expect("o rastreio sai do link enviado", linkCleaned),
    click("composer"),
    .{ .text = "`https://youtu.be/abc?si=xyz`" },
    key(c.ImGuiKey_Enter),
    expect("em bloco de código, fica como está", linkInCodeKept),

    s("plugins: horários"),
    click("composer"),
    .{ .text = "/ts em 2h" },
    key(c.ImGuiKey_Enter),
    expect("/ts põe o horário na caixa, sem enviar", stampInBox),
    key(c.ImGuiKey_Enter),
    expect("enviado, aparece como horário", stampShown),
    expect("e é legível em todos os formatos", stampReadable),
    .{ .shot = "plugin-horario" },
    ctrl(c.ImGuiKey_Comma),
    click("settings:Plugins"),
    click("pp-select:style"),
    click("pp-opt:style:R"),
    .{ .wait = 100 },
    key(c.ImGuiKey_Escape),
    click("composer"),
    .{ .text = "/ts em 2h" },
    key(c.ImGuiKey_Enter),
    expect("o formato vem das opções", stampRelative),
    key(c.ImGuiKey_Enter),
    expect("\"em 2 horas\" também aparece como horário", stampShown),

    s("plugins: links e arquivos"),
    run(toGeral),
    .{ .wait = 150 },
    run(sendLink),
    .{ .wait = 150 },
    click("composer"),
    .{ .text = "/links" },
    key(c.ImGuiKey_Enter),
    key(c.ImGuiKey_Enter),
    expectLong("/links abre o painel, com o link da mensagem", linkListed),
    .{ .shot = "plugin-links" },
    click("pp-input:search"),
    .{ .text = "nada-disso-existe" },
    expect("a busca filtra", linkFiltered),
    ctrl(c.ImGuiKey_A),
    key(c.ImGuiKey_Backspace),
    expect("sem busca, volta", linkListed),
    click("pp-select:kind"),
    expect("a lista de tipos abre", kindMenu),
    click("pp-opt:kind:file"),
    expect("só arquivos: o link sai", linkFiltered),
    click("pp-select:kind"),
    click("pp-opt:kind:all"),
    expect("tudo: o link volta", linkListed),
    click("pp-btn:open1"),
    expect("abrir vai para o navegador", urlOpened),
    click("pp-btn:copy1"),
    expect("copiar avisa", urlCopied),
    click("pp-item:i1"),
    expect("clicar no item vai até a mensagem", linkJumped),
    .{ .wait = 600 },
    click("pp-btn:refresh"),
    .{ .wait = 150 },
    expect("atualizar mantém a lista", linkListed),
    click("pp-close"),
    expectLong("fechou: a lista some da memória", linksForgotten),

    s("plugins: anti-golpe"),
    run(toGeral),
    .{ .wait = 200 },
    run(sendScams),
    run(stickBottom),
    expect("o golpe ganha a nota, em vermelho e com o motivo", scamMarked),
    expect("desenhada em vermelho", scamDrawnRed),
    .{ .wait = 200 },
    expect("o convite oficial e a conversa sobre nitro sem link, não", othersClean),
    expect("com o painel fechado, o número avisa", scamBadge),
    .{ .shot = "plugin-golpe" },
    click("composer"),
    .{ .text = "/scam" },
    key(c.ImGuiKey_Enter),
    key(c.ImGuiKey_Enter),
    expect("/scam abre o painel com a detecção", scamListed),
    expect("e nada do que já estava no canal foi marcado", onlyThisScam),
    .{ .shot = "plugin-golpe-painel" },
    run(toMemes),
    expect("muda de canal", onMemes),
    dyn(tScamItem),
    expect("clicar na detecção volta para a mensagem", scamJumped),
    run(pickScam),
    .{ .wait = 300 },
    rmsg,
    click("menu:Não é golpe"),
    expect("\"Não é golpe\" tira a nota e a linha do painel", scamCleared),
    expect("o endereço vai para a lista dos confiáveis", trustedRow),
    run(sendSameDomain),
    .{ .wait = 300 },
    expect("o mesmo endereço não marca mais", sameDomainClean),
    click("pp-btn:untrust1"),
    .{ .wait = 100 },
    run(sendSameDomain),
    expect("tirar da lista volta a marcar", sameDomainMarked),
    run(deleteScam2),
    expect("apagaram a mensagem: sai do painel", scam2Gone),
    run(sendIpLink),
    expect("link para IP marca", sameDomainMarked),
    ctrl(c.ImGuiKey_Comma),
    click("settings:Plugins"),
    click("pp-toggle:mark_ip"),
    .{ .wait = 100 },
    key(c.ImGuiKey_Escape),
    run(sendIpLink),
    .{ .wait = 300 },
    expect("com a opção desligada, não", sameDomainClean),
    click("pp-close"),
    expect("fecha o painel", panelClosed),

    s("plugins: radar de CVE"),
    run(startServer),
    run(toGeral),
    .{ .wait = 150 },
    run(rememberCount),
    run(sendCve),
    .{ .wait = 400 },
    expect("sem aprovar o host, nada sai", nothingSent),
    ctrl(c.ImGuiKey_Comma),
    click("settings:Plugins"),
    expect("o cartão mostra o host, a internet e o aviso", cveCardShows),
    click(cve_host),
    expect("aprovar o host", cveApproved),
    key(c.ImGuiKey_Escape),
    run(stickBottom),
    expectLong("aprovar busca o que estava esperando, e a nota aparece", cveNote),
    expect("só o número do CVE sai daqui", cveOnlyNumber),
    expect("crítico vem em vermelho", cveRed),
    .{ .shot = "plugin-cve" },
    .{ .wait = 3400 },
    run(rememberCount),
    run(sendCveAgain),
    expect("citado de novo: a nota vem sem pedir nada", cveAgainNote),
    expect("nenhum pedido a mais", nothingSent),
    run(restartAll),
    .{ .wait = 300 },
    run(rememberCount),
    run(sendCveAgain),
    expect("depois de reiniciar também", cveAgainNote),
    expect("nenhum pedido a mais", nothingSent),
    run(sendCveKinds),
    expectLong("formato antigo: resumo, sem nota CVSS", cveOldNote),
    expectLong("rejeitado pelo registro", cveRejectedNote),
    expectLong("inexistente", cveMissingNote),
    .{ .shot = "plugin-cve-tipos" },
    click("composer"),
    .{ .text = "/cve CVE-2024-3094" },
    key(c.ImGuiKey_Enter),
    expect("/cve abre o painel", panelCve),
    expectLong("e o resumo chega", cveFilled),
    .{ .shot = "plugin-cve-painel" },
    click("pp-btn:openCVE-2024-3094"),
    expect("abrir o registro vai para o navegador", cveOpened),
    click("pp-close"),
    expect("fecha o painel", panelClosed),
    ctrl(c.ImGuiKey_Comma),
    click("settings:Plugins"),
    click(cve_host),
    expect("tirar a aprovação", cveNotApproved),
    key(c.ImGuiKey_Escape),

    s("plugins: cartões do GitHub"),
    run(toGeral),
    .{ .wait = 150 },
    run(rememberCount),
    run(sendGithub),
    .{ .wait = 400 },
    expect("sem aprovar o host, nada sai", nothingSent),
    ctrl(c.ImGuiKey_Comma),
    click("settings:Plugins"),
    expect("o cartão mostra o host a aprovar", githubCardShows),
    click(github_host),
    expect("aprovar o host", githubApproved),
    key(c.ImGuiKey_Escape),
    run(stickBottom),
    expectLong("dono/repo#123 vira uma nota com o título e o estado", ghIssueNote),
    expectLong("o link do repositório, com as estrelas", ghRepoNote),
    expectLong("o que não existe fica sem nota", ghMissingClean),
    expect("só o nome e o número saem daqui", ghOnlyName),
    .{ .shot = "plugin-github" },
    ctrl(c.ImGuiKey_Comma),
    click("settings:Plugins"),
    click(github_host),
    expect("tirar a aprovação", githubNotApproved),
    key(c.ImGuiKey_Escape),

    s("plugins: o que perdi"),
    run(toMemes),
    .{ .wait = 200 },
    run(sendMissed),
    .{ .wait = 300 },
    run(toGeral),
    .{ .wait = 400 },
    click("composer"),
    .{ .text = "/perdi" },
    key(c.ImGuiKey_Enter),
    key(c.ImGuiKey_Enter),
    expectLong("/perdi abre o resumo: pessoas, menção, pergunta e link", missedShown),
    expect("só das não lidas", missedOnlyUnread),
    .{ .shot = "plugin-perdi" },
    click("pp-item:mention1"),
    expect("clicar na menção vai até a mensagem", missedJumped),
    click("pp-select:mode"),
    expect("a lista de quantas abre", modeMenu),
    click("pp-opt:mode:50"),
    expectLong("as últimas 50 contam mais", missedMore),
    .{ .wait = 600 },
    click("pp-btn:refresh"),
    .{ .wait = 150 },
    expect("atualizar mantém o resumo", missedMore),
    click("pp-close"),
    expectLong("fechou: o resumo some da memória", missedForgotten),

    s("plugins: estatísticas"),
    click("composer"),
    .{ .text = "/stats" },
    key(c.ImGuiKey_Enter),
    key(c.ImGuiKey_Enter),
    expectLong("/stats abre o painel com quem mais fala", panelStats),
    .{ .shot = "plugin-estatisticas" },
    .{ .wait = 600 },
    click("pp-btn:refresh"),
    .{ .wait = 150 },
    expect("atualizar mantém os números", panelStats),
    click("pp-close"),
    expect("fecha o painel", panelClosed),

    s("plugins: parado não custa nada"),
    .{ .wait = 2000 },
    run(rememberLoops),
    .{ .wait = 1200 },
    expect("sem nada acontecendo, a thread dos plugins dorme", loopsSame),

    s("plugins: limites do HTTP"),
    run(writeExtra),
    run(reloadNow),
    expectLong("carrega os plugins de teste", extraLoaded),
    run(approveQa),
    .{ .wait = 80 },
    run(clearToast),
    click("composer"),
    .{ .text = "/qa-big" },
    key(c.ImGuiKey_Enter),
    key(c.ImGuiKey_Enter),
    expectLong("resposta maior que o limite é recusada", bigRefused),
    click("composer"),
    .{ .text = "/qa-redir" },
    key(c.ImGuiKey_Enter),
    key(c.ImGuiKey_Enter),
    expectLong("redirecionamento não é seguido", redirectNotFollowed),
    click("composer"),
    .{ .text = "/qa-post" },
    key(c.ImGuiKey_Enter),
    key(c.ImGuiKey_Enter),
    expectLong("POST funciona, sem os cabeçalhos proibidos", postEchoed),
    click("composer"),
    .{ .text = "/qa-plain" },
    key(c.ImGuiKey_Enter),
    key(c.ImGuiKey_Enter),
    expect("http:// sem TLS é recusado", plainRefused),

    s("plugins: um barulhento não come o aviso dos outros"),
    run(rememberDesktop),
    click("composer"),
    .{ .text = "/qa-barulho" },
    key(c.ImGuiKey_Enter),
    key(c.ImGuiKey_Enter),
    expectLong("só 6 notificações do sistema por minuto, por plugin", noisyLimited),
    click("composer"),
    .{ .text = "/remind 1s depois do barulho" },
    key(c.ImGuiKey_Enter),
    expectLong("e o lembrete avisa mesmo assim", reminderAfterNoise),

    s("plugins: o Lua não segura a interface"),
    run(clearFrames),
    click("composer"),
    .{ .text = "/qa-lento" },
    key(c.ImGuiKey_Enter),
    key(c.ImGuiKey_Enter),
    expectLong("a interface segue desenhando enquanto um plugin trabalha", framesWhileBusy),
    run(removeExtra),
    run(reloadNow),
    .{ .wait = 200 },

    s("plugins: o cartão abre o painel"),
    ctrl(c.ImGuiKey_Comma),
    click("settings:Plugins"),
    click("plugin-open:bookmarks.lua"),
    expect("Abrir painel fecha as configurações e mostra o painel", panelFavoritosSemConfig),
    ctrl(c.ImGuiKey_Comma),
    click("settings:Plugins"),
    click("plugin-open:bookmarks.lua"),
    expect("com ele aberto, o mesmo botão fecha", panelClosed),

    s("plugins: arquivar os que saíram do app"),
    run(writeCollision),
    expect("a página mostra o botão de arquivar", archiveOffered),
    .{ .shot = "plugin-arquivar" },
    click("plugin-archive"),
    expectLong("arquivar tira da pasta, sem apagar nada", archived),

    s("plugins: varredura da página"),
};

fn reloadNow(app: *App) void {
    app.plugins.reload();
}

fn approveQa(app: *App) void {
    const p = plugin(app, "qahttp.lua") orelse return;
    app.plugins.setApproved(p, "qa.exemplo.com", true);
}

fn clearToast(app: *App) void {
    app.st.toast.len = 0;
}

// --- TLS de verdade (tools/qa_http_tls.sh) -------------------------------------------

fn useTlsServer(app: *App) void {
    if (!http_curl.qa_builds) return;
    const base = std.mem.span(c.SDL_getenv("QA_HTTP_BASE") orelse return);
    @memcpy(http_curl.qa_base[0..base.len], base);
    http_curl.qa_base_len = base.len;
    if (c.SDL_getenv("QA_HTTP_CAINFO")) |ca| {
        const path = std.mem.span(ca);
        @memcpy(http_curl.qa_cainfo[0..path.len], path);
        http_curl.qa_cainfo[path.len] = 0;
        http_curl.qa_cainfo_len = path.len;
    }
    if (plugin(app, "translate.lua")) |p| app.plugins.setApproved(p, "api.mymemory.translated.net", true);
}

fn tlsResult(app: *App) bool {
    const v = viewOf(app) orelse return false;
    const want: []const u8 = if (c.SDL_getenv("QA_HTTP_BAD_CA") != null) "Não consegui traduzir (network)" else "traduzido por HTTPS";
    for (v.slice()) |*part| if (std.mem.indexOf(u8, part.note, want) != null) return true;
    return false;
}

fn tlsLoaded(app: *App) bool {
    const p = plugin(app, "translate.lua") orelse return false;
    return p.isRunning() and p.menus.items.len > 0;
}

fn approveCve(app: *App) void {
    if (plugin(app, "cve.lua")) |p| app.plugins.setApproved(p, "cveawg.mitre.org", true);
}

fn realLoaded(app: *App) bool {
    const p = plugin(app, "cve.lua") orelse return false;
    const g = plugin(app, "github.lua") orelse return false;
    return p.isRunning() and g.isRunning() and app.store.ready;
}

fn approveGithub(app: *App) void {
    if (plugin(app, "github.lua")) |p| app.plugins.setApproved(p, "api.github.com", true);
}
// O exemplo da página inicial do site: precisa funcionar como está lá.
const site_sample = @embedFile("plugins/testdata/site_cve.lua");
var sample_id: Id = 0;
fn writeSiteSample(app: *App) void {
    _ = c.SDL_SaveFile("qa-out/plugins/site_cve.lua", site_sample.ptr, site_sample.len);
    app.plugins.reload();
}
fn sampleOn(app: *App) bool {
    const p = plugin(app, "site_cve.lua") orelse return false;
    return p.isRunning();
}
fn sendSample(app: *App) void {
    if (plugin(app, "site_cve.lua")) |p| app.plugins.setApproved(p, "cveawg.mitre.org", true);
    sample_id = inject(app, geral, 1001, "o exemplo do site olha o cve-2021-44228");
}
fn hasNote(app: *App, id: Id, want: []const u8) bool {
    const f = app.store.findAny(id) orelse return false;
    const v = app.plugins.deco.view(f.m, app.store.me);
    for (v.slice()) |*part| if (std.mem.indexOf(u8, part.note, want) != null) return true;
    return false;
}
fn sampleNote(app: *App) bool {
    return hasNote(app, sample_id, "CVE-2021-44228: Apache Log4j2");
}
fn approveTranslate(app: *App) void {
    if (plugin(app, "translate.lua")) |p| app.plugins.setApproved(p, "api.mymemory.translated.net", true);
}
fn sendEnglish(app: *App) void {
    msg_id = inject(app, geral, 1001, "The weather is nice today and I will go to the beach with my friends");
}
fn translatedForReal(app: *App) bool {
    const v = viewOf(app) orelse return false;
    for (v.slice()) |*part| {
        // Enquanto espera a nota é "Traduzindo…"; depois, o erro ou "já está no seu idioma".
        const not_yet = [_][]const u8{ "Traduzindo", "Não consegui", "já está" };
        var skip = part.note.len == 0;
        for (not_yet) |n| skip = skip or std.mem.indexOf(u8, part.note, n) != null;
        if (skip) continue;
        std.debug.print("tradução de verdade: {s}\n", .{part.note});
        return true;
    }
    return false;
}
fn sendMovedRepo(app: *App) void {
    gh_issue_id = inject(app, geral, 1001, "lembra do curl/curl#1 lá de trás?");
    gh_repo_id = inject(app, geral, 1001, "o código está em https://github.com/docker/docker");
    gh_missing_id = inject(app, geral, 1001, "esse aqui não existe: https://github.com/curl/curl/issues/99999999");
}
fn ghMovedNote(app: *App) bool {
    return std.mem.startsWith(u8, noteOf(app, gh_repo_id), "📦 moby/moby · ★ ");
}
fn ghMissingStaysClean(app: *App) bool {
    return app.store.findAny(gh_missing_id) != null and partOf(app, gh_missing_id) == null;
}

/// Contra o serviço de verdade: só números de CVE públicos saem daqui. Não entra em
/// tools/qa.sh, porque depende da internet (QA_SUITE=plugins-real).
pub const ops_real = [_]Op{
    s("plugins: os serviços de verdade"),
    run(wipeAll),
    expectLong("os plugins incluídos ligam", realLoaded),
    run(toGeral),
    .{ .wait = 200 },
    run(writeSiteSample),
    expectLong("o exemplo do site liga", sampleOn),
    run(sendSample),
    expectLong("e põe a nota, com o registro de verdade", sampleNote),
    expectLong("os plugins incluídos religam", realLoaded),
    run(approveTranslate),
    .{ .wait = 100 },
    run(sendEnglish),
    run(stickBottom),
    .{ .wait = 400 },
    rmsg,
    click("menu:Traduzir"),
    expectLong("uma mensagem em inglês volta traduzida do serviço", translatedForReal),
    run(approveCve),
    .{ .wait = 100 },
    run(sendCve),
    run(sendCveKinds),
    run(stickBottom),
    expectLong("registro real: severidade, CVSS e título", cveNote),
    expectLong("registro real antigo: sem nota, com o resumo", cveOldNote),
    expectLong("registro real rejeitado", cveRejectedNote),
    expectLong("o 404 de verdade para o que não existe", cveMissingNote),
    .{ .shot = "plugin-cve-real" },
    run(approveGithub),
    .{ .wait = 100 },
    run(sendMovedRepo),
    run(stickBottom),
    expectLong("GitHub de verdade: um pull request antigo", ghIssueNote),
    expectLong("e um repositório que mudou de nome", ghMovedNote),
    .{ .wait = 800 },
    expect("o que não existe fica sem nota", ghMissingStaysClean),
    .{ .shot = "plugin-github-real" },
};

// --- A imagem dos plugins no site (tools/site_shots.sh) -------------------------------
// Fala com os serviços de verdade, como ops_real, e serve para os dois idiomas: --lang.

var shown_cve: Id = 0;
var shown_repo: Id = 0;
var shown_scam: Id = 0;

// Só o que vem com o app: os plugins de teste apareceriam nas abas do painel.
fn onlyShipped(app: *App) void {
    wipeData(app);
    removeAllPlugins(app);
    _ = c.SDL_CreateDirectory("qa-out/plugins");
    for (exemplos.list) |ex| {
        var b: [96]u8 = undefined;
        const to = std.fmt.bufPrintSentinel(&b, "qa-out/plugins/{s}", .{ex.name}, 0) catch continue;
        _ = c.SDL_SaveFile(to.ptr, ex.source.ptr, ex.source.len);
    }
    app.plugins.reload();
}
fn vitrineLoaded(app: *App) bool {
    for ([_][]const u8{ "scamguard.lua", "cve.lua", "github.lua", "catchup.lua" }) |name| {
        const p = plugin(app, name) orelse return false;
        if (!p.isRunning()) return false;
    }
    return app.store.ready;
}
fn sendVitrine(app: *App) void {
    const tr = i18n.tr;
    var b: [96]u8 = undefined;
    const call = std.fmt.bufPrint(&b, "<@{d}> {s}", .{ app.store.me, tr("viu o deploy?", "did you see the deploy?") }) catch return;
    _ = inject(app, geral, 1001, call);
    shown_cve = inject(app, geral, 1002, tr("atualizem hoje: CVE-2021-44228 está sendo explorado", "patch today: CVE-2021-44228 is being exploited"));
    shown_repo = inject(app, geral, 1001, tr("o código está em https://github.com/curl/curl", "the code is at https://github.com/curl/curl"));
    shown_scam = inject(app, geral, 1002, tr("pessoal, ganhe nitro grátis por 3 meses https://dlscord-nitro.ru/gift/abc", "hey, get free nitro for 3 months https://dlscord-nitro.ru/gift/abc"));
    _ = inject(app, geral, 1001, tr("alguém sabe onde fica o manual novo?", "does anyone know where the new manual is?"));
}
fn vitrineNotes(app: *App) bool {
    return hasNote(app, shown_cve, "CVSS 10") and hasNote(app, shown_repo, "curl/curl") and hasNote(app, shown_scam, "dlscord-nitro.ru");
}
fn vitrinePanel(app: *App) bool {
    return openIs(app, "catchup.lua") and qa.find("pp-item:mention1") != null and qa.find("pp-item:question1") != null;
}

pub const ops_vitrine = [_]Op{
    s("a imagem dos plugins no site"),
    run(onlyShipped),
    expectLong("os plugins ligam", vitrineLoaded),
    run(approveCve),
    run(approveGithub),
    .{ .wait = 200 },
    run(toMemes),
    .{ .wait = 300 },
    run(sendVitrine),
    expectLong("as notas chegam, com as respostas de verdade", vitrineNotes),
    run(toGeral),
    .{ .wait = 600 },
    click("composer"),
    .{ .text = "/missed" },
    key(c.ImGuiKey_Enter),
    key(c.ImGuiKey_Enter),
    expectLong("o resumo abre", vitrinePanel),
    .{ .wait = 800 },
    .{ .shot = "vitrine" },
};

pub const ops_tls = [_]Op{
    s("plugins: HTTPS de verdade"),
    run(wipeAll),
    expectLong("os plugins incluídos ligam", tlsLoaded),
    run(useTlsServer),
    .{ .wait = 100 },
    run(toGeral),
    .{ .wait = 200 },
    run(pickOther),
    rmsg,
    click("menu:Traduzir"),
    expectLong("o pedido passa pelo TLS e a resposta aparece (ou é recusado sem o certificado)", tlsResult),
};

pub fn endSection(app: *App) void {
    removeAllPlugins(app);
    app.plugins.reload();
    app.plugins.panel_left = false;
    app.plugins.panel_w = 340;
}

pub fn threadGone(app: *App) bool {
    return app.plugins.panel_open == null and !app.plugins.threadRunning();
}

// --- Por tema ---------------------------------------------------------------------------

fn themeCards(_: *App) bool {
    return qa.find("plugin-card:bookmarks.lua") != null and qa.find("plugin-chip:bookmarks.lua:panel") != null and qa.find("toggle:bookmarks.lua") != null;
}

fn themeMenu(_: *App) bool {
    return qa.find("menu:Salvar nos favoritos") != null;
}

fn themeLoaded(app: *App) bool {
    return bundledRunning(app) and app.plugins.panelCount() >= 6;
}

const qa_deco_plugin =
    \\-- @name QA nota
    \\-- @capabilities menu, decorate
    \\sigma.menu("message", "QA nota", function(m)
    \\  sigma.decorate(m, { badge = "selo", note = "uma nota de plugin comprida o bastante para quebrar a linha e mostrar como ela fica embaixo da mensagem em qualquer tema" })
    \\end)
    \\sigma.menu("message", "QA recolhe", function(m)
    \\  sigma.decorate(m, { collapse = true, label = "Recolhida pelo plugin de teste" })
    \\end)
;

fn writeDeco(_: *App) void {
    _ = c.SDL_SaveFile("qa-out/plugins/qadeco.lua", qa_deco_plugin.ptr, qa_deco_plugin.len);
}
fn decoNote(_: *App) bool {
    return qa.find(mark(&mbuf, "deco-note:{d}", msg_id)) != null;
}
fn hiddenNow(_: *App) bool {
    return qa.find(mark(&mbuf, "hidden:{d}", msg_id)) != null;
}
fn tHiddenShow(_: *App, buf: []u8) []const u8 {
    return mark(buf, "hidden-show:{d}", msg_id);
}
fn revealedNow(_: *App) bool {
    return qa.find(mark(&mbuf, "hidden:{d}", msg_id)) == null;
}
fn decoLoaded(app: *App) bool {
    const p = plugin(app, "qadeco.lua") orelse return false;
    return p.isRunning() and p.menus.items.len == 2;
}

fn themeOff(app: *App) bool {
    return app.plugins.list.items.len == 0 and !app.plugins.threadRunning();
}

/// Na bateria de cada tema: os cartões, o painel, o selo e a nota têm que caber e
/// funcionar com qualquer layout.
pub const ops_theme = [_]Op{
    s("plugins neste tema"),
    run(wipeData),
    run(removeAllPlugins),
    run(writeBundled),
    run(reloadNow),
    expectLong("os plugins incluídos ligam", themeLoaded),
    ctrl(c.ImGuiKey_Comma),
    click("settings:Plugins"),
    expect("os cartões aparecem", themeCards),
    .{ .shot = "tema-plugins" },
    expect("as opções aparecem no cartão", optionsShow),
    click("pp-select:target"),
    expect("a lista de idiomas abre", languageList),
    .{ .shot = "tema-plugin-opcoes" },
    key(c.ImGuiKey_Escape),
    key(c.ImGuiKey_Escape),
    click("header-plugins"),
    expect("o botão do cabeçalho abre o painel", panelFavoritos),
    expect("o layout do tema dá lugar ao painel", layoutMoved),
    // A conversa ficou mais estreita: espera a rolagem assentar antes de escolher a mensagem.
    .{ .wait = 400 },
    run(pickOther),
    rmsg,
    expect("as entradas dos plugins aparecem no menu", themeMenu),
    click("menu:Salvar nos favoritos"),
    expect("o favorito aparece no painel", itemThere),
    expect("a mensagem ganha o selo", bookmarkBadge),
    .{ .shot = "tema-plugin-painel" },
    rmsg,
    click("menu:Traduzir para…"),
    expect("a segunda lista abre", secondList),
    .{ .shot = "tema-plugin-segunda-lista" },
    key(c.ImGuiKey_Escape),
    .{ .hover = .{ .dyn = tMsgText } },
    .{ .wait = 150 },
    expect("o botão aparece na barra da mensagem", toolbarGlyph),
    .{ .shot = "tema-plugin-barra" },
    run(sendScams),
    run(stickBottom),
    expect("o golpe ganha a nota em vermelho", scamMarked),
    .{ .wait = 200 },
    .{ .shot = "tema-plugin-golpe" },
    click("pp-side"),
    expect("encaixado à esquerda", dockedLeft),
    .{ .shot = "tema-plugin-esquerda" },
    click("pp-side"),
    click("pp-close"),
    expect("fechar devolve o espaço", panelClosed),
    run(writeDeco),
    run(reloadNow),
    expectLong("o plugin de teste liga", decoLoaded),
    run(pickOther),
    rmsg,
    click("menu:QA nota"),
    expect("a nota aparece embaixo da mensagem", decoNote),
    .{ .shot = "tema-plugin-nota" },
    dyn(tClose),
    expect("o × dispensa a nota", noteGone),
    run(pickOther),
    rmsg,
    click("menu:QA recolhe"),
    expect("recolher vira uma linha", hiddenNow),
    .{ .shot = "tema-plugin-recolhida" },
    dyn(tHiddenShow),
    expect("mostrar abre de novo", revealedNow),
    run(removeAllPlugins),
    run(reloadNow),
    expect("sem plugins, a thread sai", themeOff),
};

// --- Reabrir o app ------------------------------------------------------------------------

fn wipeAll(app: *App) void {
    wipeData(app);
    removeAllPlugins(app);
    writeBundled(app);
    app.plugins.reload();
}

fn persistSaved(_: *App) bool {
    return anyMark("pp-item:r");
}

/// Primeira metade: deixa dados e sai (o app grava ao fechar).
pub const ops_persist_a = [_]Op{
    s("plugins: antes de fechar"),
    run(wipeAll),
    expectLong("os plugins incluídos ligam", themeLoaded),
    run(toGeral),
    .{ .wait = 200 },
    run(pickOther),
    rmsg,
    click("menu:Salvar nos favoritos"),
    expect("salva um favorito", bookmarkBadge),
    click("composer"),
    .{ .text = "/remind 3h fica para depois" },
    key(c.ImGuiKey_Enter),
    expect("cria um lembrete longe", reminderSet),
    click("composer"),
    .{ .text = "/remind 2s vence com o app fechado" },
    key(c.ImGuiKey_Enter),
    // O tempo de o comando chegar à thread dos plugins, antes de fechar.
    .{ .wait = 300 },
};

fn reloadSecond(app: *App) void {
    app.plugins.reload();
}

fn bookmarkBack(app: *App) bool {
    const p = plugin(app, "bookmarks.lua") orelse return false;
    const t = p.tree orelse return false;
    for (t.nodes.items) |*n| if (n.kind == .item) return true;
    return false;
}

fn lateFired(_: *App) bool {
    return std.mem.indexOf(u8, host.qa_desktop_text[0..host.qa_desktop_len], "vence com o app fechado") != null and
        std.mem.indexOf(u8, host.qa_desktop_text[0..host.qa_desktop_len], "atrasado") != null;
}

fn reminderBack(app: *App) bool {
    const p = plugin(app, "reminders.lua") orelse return false;
    const t = p.tree orelse return false;
    for (t.nodes.items) |*n| if (n.kind == .item and std.mem.indexOf(u8, n.text, "fica para depois") != null) return true;
    return false;
}

/// Segunda metade, noutro processo: o que ficou continua lá.
pub const ops_persist_b = [_]Op{
    s("plugins: depois de reabrir"),
    run(reloadSecond),
    expectLong("os plugins incluídos ligam", themeLoaded),
    expectLong("o favorito continua lá", bookmarkBack),
    expectLong("o lembrete continua lá", reminderBack),
    expectLong("o que venceu com o app fechado avisa ao abrir", lateFired),
};
