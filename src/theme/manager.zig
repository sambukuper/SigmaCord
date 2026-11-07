//! Lista, carrega e recarrega temas.
//!
//! Ordem de busca (o último com o mesmo nome vence):
//!   1. temas embutidos no executável
//!   2. ./themes            (ao rodar de dentro do repositório)
//!   3. $XDG_CONFIG_HOME/sigmacord/themes  (ou ~/.config/sigmacord/themes)
//!
//! As pastas são vigiadas com inotify: salvar um .kdl recarrega na hora.
const std = @import("std");
const sys = @import("../platform/sys.zig");
const c = @import("c");
const builtin_themes = @import("builtin_themes");
const theme = @import("theme.zig");
const Rgba = theme.Rgba;

pub const Preview = struct {
    name: []const u8,
    description: []const u8,
    description_en: []const u8 = "",
    kind: enum { classic, glass, terminal, bubbles, zen, mirror, office, desktop },
    bg: Rgba,
    rail: Rgba,
    sidebar: Rgba,
    surface: Rgba,
    elevated: Rgba,
    accent: Rgba,
    text: Rgba,
    bubble: Rgba,
    transparent: bool,
};

pub const Entry = struct {
    name: []const u8,
    builtin: ?[]const u8 = null,
    path: ?[:0]const u8 = null,
};

pub const Manager = struct {
    gpa: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,
    names: std.ArrayList([]const u8) = .empty,
    previews: std.ArrayList(Preview) = .empty,
    /// As miniaturas interpretam todos os temas: só quando alguém for vê-las.
    previews_stale: bool = true,
    preview_arena: std.heap.ArenaAllocator = .init(std.heap.c_allocator),
    dirs: std.ArrayList([:0]const u8) = .empty,
    current: usize = 0,
    active: ?theme.Theme = null,
    wal: ?[16]Rgba = null,
    mode: theme.Mode = .dark,
    /// Opções escolhidas pelo usuário, por tema: nome do tema -> (opção -> valor).
    choices: std.StringHashMapUnmanaged(std.StringHashMapUnmanaged(bool)) = .empty,
    err_buf: [200]u8 = undefined,
    last_error: ?[]const u8 = null,

    pub fn init(gpa: std.mem.Allocator) !Manager {
        var m: Manager = .{ .gpa = gpa };
        m.wal = readWal();
        if (isDir("themes")) try m.dirs.append(gpa, try gpa.dupeSentinel(u8, "themes", 0));
        if (configDir(gpa)) |dir| {
            if (isDir(dir)) try m.dirs.append(gpa, dir) else gpa.free(dir);
        }
        try m.scan();
        return m;
    }

    pub fn deinit(m: *Manager) void {
        if (m.active) |*t| t.deinit();
        var it = m.choices.iterator();
        while (it.next()) |e| {
            var kit = e.value_ptr.keyIterator();
            while (kit.next()) |k| m.gpa.free(k.*);
            e.value_ptr.deinit(m.gpa);
            m.gpa.free(e.key_ptr.*);
        }
        m.choices.deinit(m.gpa);
        m.clearEntries();
        m.entries.deinit(m.gpa);
        m.names.deinit(m.gpa);
        m.previews.deinit(m.gpa);
        m.preview_arena.deinit();
        for (m.dirs.items) |dir| m.gpa.free(dir);
        m.dirs.deinit(m.gpa);
    }

    fn clearEntries(m: *Manager) void {
        for (m.entries.items) |e| {
            m.gpa.free(e.name);
            if (e.path) |p| m.gpa.free(p);
        }
        m.entries.clearRetainingCapacity();
        m.names.clearRetainingCapacity();
    }

    fn put(m: *Manager, e: Entry) !void {
        for (m.entries.items) |*old| if (std.mem.eql(u8, old.name, e.name)) {
            m.gpa.free(e.name);
            if (old.path) |p| m.gpa.free(p);
            old.path = e.path;
            return;
        };
        try m.entries.append(m.gpa, e);
    }

    /// Reconstrói a lista de temas, mantendo o atual selecionado pelo nome.
    pub fn scan(m: *Manager) !void {
        const keep = if (m.current < m.entries.items.len) try m.gpa.dupe(u8, m.entries.items[m.current].name) else null;
        defer if (keep) |k| m.gpa.free(k);
        m.clearEntries();
        for (builtin_themes.list) |b| try m.put(.{ .name = try m.gpa.dupe(u8, b.name), .builtin = b.source });
        for (m.dirs.items) |dir| try m.scanDir(dir);
        for (m.entries.items) |e| try m.names.append(m.gpa, e.name);
        m.previews_stale = true;
        if (keep) |k| m.current = m.indexOf(k) orelse 0;
    }

    fn scanDir(m: *Manager, dir: [:0]const u8) !void {
        const dp = c.opendir(dir.ptr) orelse return;
        defer _ = c.closedir(dp);
        while (c.readdir(dp)) |ent| {
            const file = std.mem.sliceTo(&ent.*.d_name, 0);
            if (!std.mem.endsWith(u8, file, ".kdl")) continue;
            const path = try std.fmt.allocPrintSentinel(m.gpa, "{s}/{s}", .{ dir, file }, 0);
            try m.put(.{ .name = try m.gpa.dupe(u8, file[0 .. file.len - 4]), .path = path });
        }
    }

    /// Carrega cada tema só para tirar as cores da miniatura.
    pub fn ensurePreviews(m: *Manager) void {
        if (!m.previews_stale) return;
        m.previews_stale = false;
        m.previews.clearRetainingCapacity();
        _ = m.preview_arena.reset(.retain_capacity);
        const a = m.preview_arena.allocator();
        for (m.entries.items) |e| {
            var owned: ?[]u8 = null;
            defer if (owned) |o| c.SDL_free(o.ptr);
            const src: []const u8 = if (e.path) |p| blk: {
                var size: usize = 0;
                const data = c.SDL_LoadFile(p.ptr, &size) orelse break :blk "";
                owned = @as([*]u8, @ptrCast(data))[0..size];
                break :blk owned.?;
            } else e.builtin.?;
            var t = theme.loadWith(m.gpa, src, m.loadOptions(e.name), null) catch {
                m.previews.append(m.gpa, .{ .name = e.name, .description = "(erro ao carregar)", .kind = .classic, .bg = Rgba.black, .rail = Rgba.black, .sidebar = Rgba.black, .surface = Rgba.black, .elevated = Rgba.black, .accent = Rgba.white, .text = Rgba.white, .bubble = Rgba.white, .transparent = false }) catch {};
                continue;
            };
            defer t.deinit();
            m.previews.append(m.gpa, .{
                .name = e.name,
                .description = a.dupe(u8, t.description) catch "",
                .description_en = a.dupe(u8, t.description_en) catch "",
                .kind = std.meta.stringToEnum(@FieldType(Preview, "kind"), t.preview) orelse .classic,
                .bg = t.c(.bg),
                .rail = t.c(.rail),
                .sidebar = t.c(.sidebar),
                .surface = t.c(.surface),
                .elevated = t.c(.elevated),
                .accent = t.c(.accent),
                .text = t.c(.text),
                .bubble = t.c(.bubble_self),
                .transparent = t.transparent,
            }) catch {};
        }
    }

    fn loadOptions(m: *const Manager, theme_name: []const u8) theme.LoadOptions {
        return .{ .wal = if (m.wal) |*w| w else null, .mode = m.mode, .overrides = m.choices.getPtr(theme_name) };
    }

    /// Guarda a escolha de uma opção do tema (não recarrega).
    pub fn choose(m: *Manager, theme_name: []const u8, option: []const u8, value: bool) void {
        const gop = m.choices.getOrPut(m.gpa, theme_name) catch return;
        if (!gop.found_existing) {
            gop.key_ptr.* = m.gpa.dupe(u8, theme_name) catch return;
            gop.value_ptr.* = .empty;
        }
        if (gop.value_ptr.getPtr(option)) |v| {
            v.* = value;
            return;
        }
        const key = m.gpa.dupe(u8, option) catch return;
        gop.value_ptr.put(m.gpa, key, value) catch m.gpa.free(key);
    }

    /// Muda uma opção do tema atual e recarrega para aplicar.
    pub fn setOption(m: *Manager, option: []const u8, value: bool) bool {
        m.choose(m.name(), option, value);
        return m.load(m.current);
    }

    /// Troca entre claro e escuro (recarrega o tema e as miniaturas).
    pub fn setMode(m: *Manager, mode: theme.Mode) bool {
        if (m.mode == mode) return true;
        m.mode = mode;
        m.previews_stale = true;
        return m.load(m.current);
    }

    pub fn indexOf(m: *const Manager, wanted: []const u8) ?usize {
        for (m.entries.items, 0..) |e, i| if (std.mem.eql(u8, e.name, wanted)) return i;
        return null;
    }

    pub fn name(m: *const Manager) []const u8 {
        return m.entries.items[m.current].name;
    }

    /// Carrega o tema `i`. Se falhar, mantém o anterior e guarda o erro.
    pub fn load(m: *Manager, i: usize) bool {
        // A lista recarrega sozinha: um índice guardado pode ter ficado velho.
        if (i >= m.entries.items.len) return false;
        const e = m.entries.items[i];
        var owned: ?[]u8 = null;
        defer if (owned) |o| c.SDL_free(o.ptr);
        const src: []const u8 = if (e.path) |p| blk: {
            var size: usize = 0;
            const data = c.SDL_LoadFile(p.ptr, &size) orelse {
                m.last_error = std.fmt.bufPrint(&m.err_buf, "{s}: não consegui ler o arquivo", .{e.name}) catch null;
                return false;
            };
            owned = @as([*]u8, @ptrCast(data))[0..size];
            break :blk owned.?;
        } else e.builtin.?;

        var diag: theme.Diagnostic = .{};
        const t = theme.loadWith(m.gpa, src, m.loadOptions(e.name), &diag) catch {
            m.last_error = std.fmt.bufPrint(&m.err_buf, "{s}.kdl:{d}:{d}: {s}", .{ e.name, diag.line, diag.column, diag.message }) catch null;
            return false;
        };
        if (m.active) |*old| old.deinit();
        m.active = t;
        m.current = i;
        m.last_error = null;
        return true;
    }

    /// Relê a paleta do pywal, a lista e o tema atual (chamado pelo inotify).
    pub fn reload(m: *Manager) bool {
        m.wal = readWal();
        m.scan() catch {};
        return m.load(m.current);
    }

    pub fn theme_(m: *Manager) *const theme.Theme {
        return &m.active.?;
    }

    /// Thread que espera o sistema avisar e chama `wake` quando um tema muda.
    pub fn watch(m: *Manager, wake: *const fn () void) void {
        if (sys.windows) return m.watchWindows(wake);
        const fd = c.inotify_init1(c.IN_CLOEXEC);
        if (fd < 0) return;
        for (m.dirs.items) |dir| _ = c.inotify_add_watch(fd, dir.ptr, c.IN_CLOSE_WRITE | c.IN_MOVED_TO | c.IN_CREATE | c.IN_DELETE);
        // Também a pasta do pywal, para o tema seguir o wallpaper.
        var buf: [512]u8 = undefined;
        if (walDir(&buf)) |wd| _ = c.inotify_add_watch(fd, wd.ptr, c.IN_CLOSE_WRITE | c.IN_MOVED_TO);
        const W = struct {
            var wake_fn: *const fn () void = undefined;
            var watch_fd: c_int = -1;
            fn run(_: ?*anyopaque) callconv(.c) c_int {
                var events: [4096]u8 align(@alignOf(c.struct_inotify_event)) = undefined;
                while (true) {
                    const n = c.read(watch_fd, &events, events.len);
                    if (n <= 0) return 0;
                    // Junta rajadas de eventos (editores salvam em vários passos).
                    c.SDL_Delay(60);
                    wake_fn();
                }
            }
        };
        W.wake_fn = wake;
        W.watch_fd = fd;
        if (c.SDL_CreateThread(W.run, "theme-watch", null)) |t| c.SDL_DetachThread(t);
    }

    /// No Windows: um aviso de mudança por pasta (a maior parte é só uma).
    fn watchWindows(m: *Manager, wake: *const fn () void) void {
        const W = struct {
            var wake_fn: *const fn () void = undefined;
            var handles: [8]c.HANDLE = undefined;
            var n: u32 = 0;
            fn run(_: ?*anyopaque) callconv(.c) c_int {
                while (true) {
                    const r = c.WaitForMultipleObjects(n, &handles, 0, c.INFINITE);
                    if (r >= c.WAIT_OBJECT_0 + n) return 0;
                    // Junta rajadas de eventos (editores salvam em vários passos).
                    c.SDL_Delay(60);
                    _ = c.FindNextChangeNotification(handles[r - c.WAIT_OBJECT_0]);
                    wake_fn();
                }
            }
        };
        W.wake_fn = wake;
        W.n = 0;
        const what = c.FILE_NOTIFY_CHANGE_LAST_WRITE | c.FILE_NOTIFY_CHANGE_FILE_NAME;
        for (m.dirs.items) |dir| {
            if (W.n == W.handles.len) break;
            const h = c.FindFirstChangeNotificationA(dir.ptr, 0, what);
            if (h == c.INVALID_HANDLE_VALUE) continue;
            W.handles[W.n] = h;
            W.n += 1;
        }
        if (W.n == 0) return;
        if (c.SDL_CreateThread(W.run, "theme-watch", null)) |t| c.SDL_DetachThread(t);
    }
};

fn isDir(path: [:0]const u8) bool {
    var info: c.SDL_PathInfo = undefined;
    return c.SDL_GetPathInfo(path.ptr, &info) and info.type == c.SDL_PATHTYPE_DIRECTORY;
}

fn configDir(gpa: std.mem.Allocator) ?[:0]u8 {
    var hb: [512]u8 = undefined;
    const base = sys.configHome(&hb) orelse return null;
    return std.fmt.allocPrintSentinel(gpa, "{s}/sigmacord/themes", .{base}, 0) catch null;
}

fn walDir(buf: []u8) ?[:0]const u8 {
    const home = c.SDL_getenv("HOME") orelse return null;
    return std.fmt.bufPrintSentinel(buf, "{s}/.cache/wal", .{std.mem.span(home)}, 0) catch null;
}

/// As 16 cores do pywal (~/.cache/wal/colors), se existirem.
fn readWal() ?[16]Rgba {
    var buf: [512]u8 = undefined;
    const dir = walDir(&buf) orelse return null;
    var pbuf: [600]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&pbuf, "{s}/colors", .{dir}, 0) catch return null;
    var size: usize = 0;
    const data = c.SDL_LoadFile(path.ptr, &size) orelse return null;
    defer c.SDL_free(data);
    var pal: [16]Rgba = undefined;
    var it = std.mem.tokenizeAny(u8, @as([*]const u8, @ptrCast(data))[0..size], "\r\n");
    var i: usize = 0;
    while (it.next()) |line| : (i += 1) {
        if (i >= 16) break;
        pal[i] = theme.Rgba.hex(std.fmt.parseInt(u32, std.mem.trim(u8, line, " #"), 16) catch return null);
    }
    return if (i >= 16) pal else null;
}
