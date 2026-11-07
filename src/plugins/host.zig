//! O lado do app dos plugins (ver engine.zig): lê a pasta, guarda quem está
//! desligado e os hosts aprovados, traduz teclas e entrega eventos, avisos e
//! mensagens. A pasta é ~/.config/sigmacord/plugins (ou
//! $XDG_CONFIG_HOME/sigmacord/plugins); as escolhas ficam em
//! ~/.config/sigmacord/plugins.kdl e os dados de cada plugin, por conta, em
//! ~/.config/sigmacord/plugin-data. No QA é tudo em qa-out e nada de escolha é salvo.
const std = @import("std");
const c = @import("c");
const App = @import("../app.zig").App;
const engine = @import("engine.zig");
const runtime = @import("runtime.zig");
const http_curl = @import("http_curl.zig");
const types = @import("../core/types.zig");
const Store = @import("../core/store.zig").Store;
const kdl = @import("../theme/kdl.zig");
const i18n = @import("../ui/i18n.zig");
const nowMs = @import("../net/fake_gateway.zig").nowMs;
const fsutil = @import("../platform/fsutil.zig");
const sys = @import("../platform/sys.zig");
const platform = @import("../platform/window.zig");

pub const Engine = engine.Engine;

/// QA: notificações do sistema que teriam saído, e o texto da última.
pub var qa_desktop: u32 = 0;
pub var qa_desktop_text: [256]u8 = undefined;
pub var qa_desktop_len: usize = 0;

var app_global: ?*App = null;

pub fn appOf() *App {
    return app_global.?;
}

pub fn init(app: *App) void {
    app_global = app;
    app.plugins = Engine.init(app.gpa, .{
        .ctx = app,
        .notify = &notify,
        .send = &send,
        .where = &where,
        .key = &keyCode,
        .rescan = &rescan,
        .save = &save,
        .failed = &failed,
        .insert = &insert,
        .jump = &jump,
        .copy = &copy,
        .open_url = &openUrl,
        .messages = &messages,
        .wake = &wake,
        .read_data = &readData,
        .write_data = &writeData,
        .keep_broken_data = &keepBroken,
        .http_start = &http_curl.start,
        .http_stop = &http_curl.stop,
    });
    engine.current = &app.plugins;
    runtime.lang_en = &i18n.en;
    runtime.lang_code = &struct {
        fn f() [*:0]const u8 {
            return switch (i18n.current()) {
                .pt => "pt",
                .en => "en",
                .ja => "ja",
            };
        }
    }.f;
    // Prints da documentação: sempre iguais, sem os plugins de quem roda.
    if (app.opts.shot != null) return;
    var buf: [512]u8 = undefined;
    if (dirPath(app, &buf)) |d| app.plugins.setDir(d);
    // No QA a pasta começa vazia e o roteiro usa o botão Recarregar.
    if (app.opts.qa) return;
    loadPrefs(app);
    rescan(app);
}

fn dirPath(app: *const App, buf: []u8) ?[:0]const u8 {
    if (app.opts.qa) return std.fmt.bufPrintSentinel(buf, "qa-out/plugins", .{}, 0) catch null;
    return fsutil.configPath(buf, "plugins");
}

/// Lê os *.lua da pasta (em ordem alfabética) e recarrega todos.
fn rescan(ctx: *anyopaque) void {
    const app: *App = @ptrCast(@alignCast(ctx));
    const e = &app.plugins;
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var files: std.ArrayList(engine.Source) = .empty;
    var dbuf: [512]u8 = undefined;
    if (dirPath(app, &dbuf)) |dir| {
        var count: c_int = 0;
        if (c.SDL_GlobDirectory(dir.ptr, "*.lua", 0, &count)) |names| {
            defer c.SDL_free(@ptrCast(names));
            var list: std.ArrayList([]const u8) = .empty;
            for (0..@intCast(count)) |i| {
                const n = std.mem.span(names[i] orelse continue);
                // Só arquivos diretos da pasta (o glob não desce, mas confere).
                if (std.mem.indexOfAny(u8, n, "/\\") != null or n.len > 120) continue;
                list.append(a, a.dupe(u8, n) catch continue) catch continue;
            }
            @import("../core/sort.zig").stable([]const u8, list.items, {}, struct {
                fn lt(_: void, x: []const u8, y: []const u8) bool {
                    return std.mem.lessThan(u8, x, y);
                }
            }.lt);
            for (list.items[0..@min(list.items.len, engine.max_plugins)]) |n| {
                var pbuf: [700]u8 = undefined;
                const path = std.fmt.bufPrintSentinel(&pbuf, "{s}/{s}", .{ dir, n }, 0) catch continue;
                var info: c.SDL_PathInfo = undefined;
                if (!c.SDL_GetPathInfo(path.ptr, &info) or info.type != c.SDL_PATHTYPE_FILE) continue;
                // Grande demais: entra na lista vazio (e dá erro de "arquivo grande").
                var src: []const u8 = i18n.tr("error('arquivo maior que 256 KB')", "error('file larger than 256 KB')");
                if (info.size <= engine.max_source) {
                    var size: usize = 0;
                    const data = c.SDL_LoadFile(path.ptr, &size) orelse continue;
                    defer c.SDL_free(data);
                    src = a.dupe(u8, @as([*]const u8, @ptrCast(data))[0..size]) catch continue;
                }
                files.append(a, .{ .name = n, .src = src }) catch continue;
            }
        }
    }
    e.load(files.items, app.store.ready);
}

fn prefsPath(buf: []u8) ?[:0]const u8 {
    return fsutil.configPath(buf, "plugins.kdl");
}

fn loadPrefs(app: *App) void {
    var buf: [512]u8 = undefined;
    const path = prefsPath(&buf) orelse return;
    var size: usize = 0;
    const data = c.SDL_LoadFile(path.ptr, &size) orelse return;
    defer c.SDL_free(data);
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const src = arena.allocator().dupe(u8, @as([*]const u8, @ptrCast(data))[0..size]) catch return;
    const nodes = kdl.parse(arena.allocator(), src, null) catch return;
    for (nodes) |*n| app.plugins.applyPrefNode(n);
}

fn save(ctx: *anyopaque) void {
    const app: *App = @ptrCast(@alignCast(ctx));
    if (app.opts.qa or app.opts.shot != null) return;
    var buf: [512]u8 = undefined;
    const path = prefsPath(&buf) orelse return;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(app.gpa);
    app.plugins.writePrefs(app.gpa, &out) catch return;
    _ = fsutil.writePrivate(path, out.items);
}

/// A largura ou o lado do painel mudaram (a interface chama ao soltar o mouse).
pub fn savePrefs() void {
    if (app_global) |app| save(app);
}

// --- Host -------------------------------------------------------------------

/// Quantas notificações do sistema cada plugin manda em 1 minuto, e todos juntos:
/// nem um plugin com defeito nem uma rajada de mensagens enche a área de trabalho,
/// e um plugin barulhento não come o aviso de um lembrete.
const desktop_per_minute = 6;
const desktop_all_per_minute = 20;
const Quota = struct { key: u64 = 0, from: i64 = 0, n: u32 = 0 };
var desktop_quota: [engine.max_plugins + 1]Quota = @splat(.{});

fn quotaFor(plugin: []const u8, now: i64) *Quota {
    const key = std.hash.Wyhash.hash(0, plugin) | 1;
    var oldest = &desktop_quota[1];
    for (desktop_quota[1..]) |*q| {
        if (q.key == key) return q;
        if (q.from < oldest.from) oldest = q;
    }
    oldest.* = .{ .key = key, .from = now };
    return oldest;
}

/// Mais uma notificação cabe nesta cota?
fn quotaTake(q: *Quota, limit: u32, now: i64) bool {
    if (now - q.from >= 60_000) {
        q.from = now;
        q.n = 0;
    }
    if (q.n >= limit) return false;
    q.n += 1;
    return true;
}

fn notify(ctx: *anyopaque, plugin: []const u8, text: []const u8, desktop: bool) void {
    const app: *App = @ptrCast(@alignCast(ctx));
    app.st.showToast(nowMs(), false, "{s}", "{s}", .{text});
    const flags = c.SDL_GetWindowFlags(app.win.window);
    const hidden = flags & c.SDL_WINDOW_HIDDEN != 0;
    const focused = !hidden and flags & c.SDL_WINDOW_INPUT_FOCUS != 0 and !app.qa_blur;
    // Sem `desktop`, só com a pessoa longe da janela (e fora do modo foco, que
    // só deixa passar DMs e menções).
    if (!desktop and (focused or app.st.filtros.focusOn(nowMs()))) return;
    if (!app.st.settings.desktop_notifs) return;
    const now = nowMs();
    if (!quotaTake(quotaFor(plugin, now), desktop_per_minute, now)) return;
    if (!quotaTake(&desktop_quota[0], desktop_all_per_minute, now)) return;
    var tb: [160]u8 = undefined;
    const title = std.fmt.bufPrintSentinel(&tb, "SigmaCord · {s}", .{plugin}, 0) catch return;
    var cut = @min(text.len, 200);
    while (cut > 0 and cut < text.len and (text[cut] & 0xC0) == 0x80) cut -= 1;
    var bb: [208]u8 = undefined;
    const body = std.fmt.bufPrintSentinel(&bb, "{s}", .{text[0..cut]}, 0) catch return;
    if (app.opts.qa) {
        qa_desktop +%= 1;
        qa_desktop_len = @min(body.len, qa_desktop_text.len);
        @memcpy(qa_desktop_text[0..qa_desktop_len], body[0..qa_desktop_len]);
        return;
    }
    app.desktopNotify(title, body);
}

fn send(ctx: *anyopaque, channel: u64, text: []const u8) bool {
    const app: *App = @ptrCast(@alignCast(ctx));
    if (!app.store.ready) return false;
    const ch = if (channel != 0) channel else app.st.activeChannel() orelse return false;
    const cs = app.store.channel(ch) orelse return false;
    if (cs.info.kind != .text) return false;
    app.sendWith(ch, text, 0, false);
    return true;
}

fn where(ctx: *anyopaque) engine.Where {
    const app: *App = @ptrCast(@alignCast(ctx));
    const ch = app.st.activeChannel() orelse return .{};
    if (app.st.friends) return .{};
    const cs = app.store.channel(ch) orelse return .{};
    var w: engine.Where = .{ .channel = ch, .channel_name = cs.info.name };
    if (app.store.guild(cs.info.guild)) |g| {
        w.guild = g.id;
        w.guild_name = g.name;
    }
    return w;
}

fn failed(ctx: *anyopaque, plugin: []const u8, msg: []const u8) void {
    const app: *App = @ptrCast(@alignCast(ctx));
    app.st.showToast(nowMs(), true, "plugin {s}: {s}", "plugin {s}: {s}", .{ plugin, msg });
    std.log.warn("plugin {s}: {s}", .{ plugin, msg });
}

fn insert(ctx: *anyopaque, text: []const u8) void {
    const app: *App = @ptrCast(@alignCast(ctx));
    @import("../ui/popup.zig").insertText(&app.st, text, false);
}

fn jump(ctx: *anyopaque, channel: u64, id: u64) void {
    const app: *App = @ptrCast(@alignCast(ctx));
    app.handle(.{ .open_message = .{ .channel = channel, .id = id } });
}

fn copy(ctx: *anyopaque, text: []const u8) void {
    const app: *App = @ptrCast(@alignCast(ctx));
    app.handle(.{ .copy = app.gpa.dupe(u8, text) catch return });
}

fn openUrl(_: *anyopaque, url: []const u8) void {
    @import("../ui/attachments.zig").openUrl(url);
}

/// A mensagem como o plugin vê. Nunca o que foi apagado (com o registro ligado
/// ela continua na memória) nem o texto de antes de uma edição.
pub fn pluginMessage(app: *const App, store: *const Store, m: *const types.Message) engine.Message {
    const cs = store.channel(m.channel);
    const guild_id: types.Id = if (cs) |x| x.info.guild else 0;
    const g = if (guild_id != 0) store.guild(guild_id) else null;
    return .{
        .id = m.id,
        .content = m.content,
        .author = m.author,
        .author_name = if (store.user(m.author)) |u| u.name else "?",
        .channel = m.channel,
        .channel_name = if (cs) |x| x.info.name else "",
        .guild = if (g) |x| x.id else 0,
        .guild_name = if (g) |x| x.name else "",
        .mine = m.author == store.me,
        .ignored = app.st.filtros.isIgnored(m.author),
        .timestamp = m.timestamp,
        .attachments = @intCast(@min(m.attachments.len, std.math.maxInt(u16))),
        .reply_to = m.reply_to,
    };
}

fn messages(ctx: *anyopaque, channel: u64, limit: u32, out: *engine.MsgList) void {
    const app: *App = @ptrCast(@alignCast(ctx));
    const ch = if (channel != 0) channel else app.st.activeChannel() orelse return;
    const cs = app.store.channel(ch) orelse return;
    out.channel = ch;
    // A linha "novas mensagens" guarda até onde estava lido antes de abrir o canal.
    out.last_read = if (cs.divider_after > 1) cs.divider_after else if (cs.info.unread) cs.read_id else 0;
    const items = cs.messages.items;
    // As últimas `limit`, sem o que foi apagado, as pendentes e as de sistema.
    var first = items.len;
    var kept: u32 = 0;
    while (first > 0 and kept < limit) {
        first -= 1;
        if (visible(&items[first])) kept += 1;
    }
    for (items[first..]) |*m| {
        if (!visible(m) or !out.wants(m.msg.content)) continue;
        var pm = pluginMessage(app, &app.store, &m.msg);
        pm.mentions_me = @import("../core/inbox.zig").mentionsMe(&app.store, cs.info.guild, m);
        var refs: [16]engine.FileRef = undefined;
        if (out.files) {
            var n: usize = 0;
            for (m.msg.attachments) |*att| {
                // O que veio de um link já está no texto da mensagem.
                if (att.embed or n == refs.len) continue;
                refs[n] = .{ .name = att.filename, .url = att.url, .size = att.size };
                n += 1;
            }
            pm.files = refs[0..n];
        }
        out.add(&pm);
    }
}

fn visible(m: *const @import("../core/store.zig").StoredMessage) bool {
    return !m.deleted and !m.pending and m.msg.id != 0 and m.msg.system == .none;
}

fn wake(ctx: *anyopaque) void {
    const app: *App = @ptrCast(@alignCast(ctx));
    platform.Window.wake(app.win.wake_type, .plugins);
}

// --- Dados de cada plugin (na thread dos plugins) -----------------------------------

fn dataPath(app: *const App, buf: []u8, account: u64, plugin: []const u8) ?[:0]const u8 {
    if (app.opts.qa) return std.fmt.bufPrintSentinel(buf, "qa-out/plugin-data/{d}/{s}.json", .{ account, plugin }, 0) catch null;
    var nb: [200]u8 = undefined;
    const rel = std.fmt.bufPrint(&nb, "plugin-data/{d}/{s}.json", .{ account, plugin }) catch return null;
    return fsutil.configPath(buf, rel);
}

fn readData(ctx: *anyopaque, gpa: std.mem.Allocator, account: u64, plugin: []const u8) ?[]u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    var buf: [640]u8 = undefined;
    const path = dataPath(app, &buf, account, plugin) orelse return null;
    var size: usize = 0;
    const data = c.SDL_LoadFile(path.ptr, &size) orelse return null;
    defer c.SDL_free(data);
    return gpa.dupe(u8, @as([*]const u8, @ptrCast(data))[0..size]) catch null;
}

fn writeData(ctx: *anyopaque, account: u64, plugin: []const u8, bytes: []const u8) bool {
    const app: *App = @ptrCast(@alignCast(ctx));
    var buf: [640]u8 = undefined;
    const path = dataPath(app, &buf, account, plugin) orelse return false;
    return fsutil.writePrivate(path, bytes);
}

fn keepBroken(ctx: *anyopaque, account: u64, plugin: []const u8) void {
    const app: *App = @ptrCast(@alignCast(ctx));
    var buf: [640]u8 = undefined;
    const path = dataPath(app, &buf, account, plugin) orelse return;
    fsutil.keepBroken(path);
}

fn keyCode(name: []const u8) ?i32 {
    if (name.len == 1) {
        const ch = name[0];
        if (ch >= 'a' and ch <= 'z') return c.ImGuiKey_A + @as(i32, ch - 'a');
        if (ch >= '0' and ch <= '9') return c.ImGuiKey_0 + @as(i32, ch - '0');
    }
    if (name.len >= 2 and name[0] == 'f') {
        const n = std.fmt.parseInt(u8, name[1..], 10) catch return null;
        if (n >= 1 and n <= 24) return c.ImGuiKey_F1 + @as(i32, n - 1);
        return null;
    }
    const named = [_]struct { n: []const u8, k: c_int }{
        .{ .n = "enter", .k = c.ImGuiKey_Enter },    .{ .n = "space", .k = c.ImGuiKey_Space },
        .{ .n = "tab", .k = c.ImGuiKey_Tab },        .{ .n = "backspace", .k = c.ImGuiKey_Backspace },
        .{ .n = "delete", .k = c.ImGuiKey_Delete },  .{ .n = "insert", .k = c.ImGuiKey_Insert },
        .{ .n = "home", .k = c.ImGuiKey_Home },      .{ .n = "end", .k = c.ImGuiKey_End },
        .{ .n = "pageup", .k = c.ImGuiKey_PageUp },  .{ .n = "pagedown", .k = c.ImGuiKey_PageDown },
        .{ .n = "up", .k = c.ImGuiKey_UpArrow },     .{ .n = "down", .k = c.ImGuiKey_DownArrow },
        .{ .n = "left", .k = c.ImGuiKey_LeftArrow }, .{ .n = "right", .k = c.ImGuiKey_RightArrow },
        .{ .n = ",", .k = c.ImGuiKey_Comma },        .{ .n = ".", .k = c.ImGuiKey_Period },
        .{ .n = "/", .k = c.ImGuiKey_Slash },        .{ .n = ";", .k = c.ImGuiKey_Semicolon },
        .{ .n = "-", .k = c.ImGuiKey_Minus },        .{ .n = "=", .k = c.ImGuiKey_Equal },
    };
    for (named) |x| if (std.mem.eql(u8, x.n, name)) return x.k;
    return null;
}

// --- Ganchos chamados pelo app ----------------------------------------------

/// MESSAGE_CREATE (antes de ir para o Store; os textos ainda são da mensagem).
pub fn onMessage(app: *App, m: types.Message) void {
    if (app.plugins.n_message == 0 or m.system != .none) return;
    const msg = pluginMessage(app, &app.store, &m);
    app.plugins.onMessage(&msg);
}

/// MESSAGE_UPDATE com texto novo (o Store acabou de aplicar). Nunca passa o de antes.
pub fn onEdit(app: *App, id: types.Id) void {
    if (app.plugins.n_edit == 0 or !app.store.ready) return;
    const f = app.store.findAny(id) orelse return;
    if (f.m.deleted or f.m.pending or f.m.msg.system != .none) return;
    const msg = pluginMessage(app, &app.store, &f.m.msg);
    app.plugins.onEdit(&msg);
}

/// MESSAGE_DELETE: a nota de plugin dessa mensagem sai, e quem pediu fica sabendo.
pub fn onDelete(app: *App, channel: types.Id, id: types.Id) void {
    app.plugins.onDelete(channel, id);
}

/// A cada quadro (antes do desenho): custa uma comparação sem plugin rodando.
pub fn frame(app: *App) void {
    const ch: u64 = if (app.st.friends) 0 else app.st.activeChannel() orelse 0;
    app.plugins.frameTick(ch, i18n.en());
}

fn pressed(ctx: *anyopaque, k: *const engine.Keybind) bool {
    const io: *c.ImGuiIO = @ptrCast(@alignCast(ctx));
    if (io.*.KeyCtrl != k.ctrl or io.*.KeyShift != k.shift or io.*.KeyAlt != k.alt or io.*.KeySuper != k.super) return false;
    return c.ImGui_IsKeyPressedEx(k.key, false);
}

/// Atalhos dos plugins (no meio do quadro, depois da interface).
pub fn pollKeys(app: *App) void {
    if (app.plugins.n_keys == 0) return;
    const st = &app.st;
    if (st.settings.open or st.palette.open or app.login.visible()) return;
    app.plugins.pollKeys(app.io, &pressed);
}

pub const MenuHit = struct { plugin: *engine.Plugin, entry: *const engine.MenuEntry };

/// A entrada `index` dos menus de plugin (a ordem em que o menu lista).
pub fn menuEntry(app: *App, kind: engine.MenuKind, index: usize) ?MenuHit {
    var i: usize = 0;
    for (app.plugins.list.items) |p| {
        if (!p.isRunning()) continue;
        for (p.menus.items) |*entry| {
            if (entry.kind != kind) continue;
            if (i == index) return .{ .plugin = p, .entry = entry };
            i += 1;
        }
    }
    return null;
}

/// Clicou na entrada `index` dos menus de plugin. `value`: a escolha da segunda lista.
pub fn menuClick(app: *App, kind: engine.MenuKind, index: usize, id: types.Id, value: ?[]const u8) void {
    const e = &app.plugins;
    const hit = menuEntry(app, kind, index) orelse return;
    switch (kind) {
        .message => {
            const f = app.store.findAny(id) orelse return;
            if (f.m.deleted) return;
            const pm = pluginMessage(app, &app.store, &f.m.msg);
            e.menuMessage(hit.plugin, hit.entry, &pm, value);
        },
        .user => {
            const u = app.store.user(id) orelse return;
            e.menuUser(hit.plugin, hit.entry, id, u.name, value);
        },
    }
}
