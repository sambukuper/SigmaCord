//! Plugins em Lua 5.4: scripts pequenos em ~/.config/sigmacord/plugins/*.lua
//! que reagem a eventos e criam comandos, painéis e menus, sem recompilar.
//!
//! Este é o lado da interface. O Lua roda em outra thread (runtime.zig) e as duas
//! só conversam por filas (wire.zig): um plugin nunca segura um quadro, e o que
//! a interface mostra dele (comandos, painel, erro) é uma cópia que ela mesma
//! guarda. Tudo aqui é da thread da interface.
//!
//! Sem plugin ligado, a thread não existe e nenhum `lua_State` é criado; os
//! ganchos do app só comparam um contador com zero.
//!
//! Este arquivo não depende de janela: o app entra pelo `Host` (ver host.zig) e
//! os testes usam um `Host` falso.
const std = @import("std");
const wire = @import("wire.zig");
const runtime = @import("runtime.zig");
const manifest = @import("manifest.zig");
pub const panel = @import("panel.zig");
pub const deco = @import("deco.zig");
pub const rewrite = @import("rewrite.zig");
const sync = @import("sync.zig");
const kdl = @import("../theme/kdl.zig");

pub const max_plugins = runtime.max_plugins;
pub const max_source = runtime.max_source;
pub const mem_cap = runtime.mem_cap;
pub const Where = wire.Where;
pub const Message = wire.Message;
pub const Host = wire.Host;
pub const Source = wire.Source;
pub const Keybind = wire.Keybind;
pub const LspServer = wire.LspServer;
pub const MenuKind = wire.MenuKind;
pub const MenuEntry = wire.MenuEntry;
pub const FileRef = wire.FileRef;
pub const CompletionSet = wire.CompletionSet;
pub const MsgList = wire.MsgList;
pub const HttpReq = wire.HttpReq;
pub const HttpRes = wire.HttpRes;
pub const HttpError = wire.HttpError;
pub const Cap = manifest.Cap;
pub const parseKeys = runtime.parseKeys;

/// O plugin aberto na página de configurações e os ganchos do app.
pub var current: ?*Engine = null;

/// Quantos pedidos dos plugins a interface atende de cada vez: uma rajada se
/// espalha por vários acordares em vez de pesar num só.
const drain_budget = 512;
/// Gestos lembrados por plugin (a resposta de um pode chegar depois do próximo).
const token_ring = 4;

pub const Status = enum { off, running, failed, waiting };

pub const Plugin = struct {
    engine: *Engine,
    name: []u8,
    src: []u8,
    /// Lido do começo do arquivo, sem rodar nada (aponta para `src`).
    man: manifest.Manifest = .{},
    slot: u16 = 0,
    enabled: bool = true,
    /// Identifica esta partida na thread dos plugins (0 = não está rodando).
    /// O que chega de uma partida velha é ignorado.
    run: u32 = 0,
    err_buf: [300]u8 = undefined,
    err_len: u16 = 0,
    n_message: u16 = 0,
    n_ready: u16 = 0,
    n_delete: u16 = 0,
    n_channel: u16 = 0,
    n_lang: u16 = 0,
    n_edit: u16 = 0,
    n_dismiss: u16 = 0,
    commands: std.ArrayList([]u8) = .empty,
    keys: std.ArrayList(Keybind) = .empty,
    lsp: std.ArrayList(LspServer) = .empty,
    menus: std.ArrayList(MenuEntry) = .empty,
    /// O painel que o plugin publicou.
    tree: ?*panel.Tree = null,
    /// As opções que ele mostra no cartão da página de plugins.
    settings: ?*panel.Tree = null,
    /// Sugestões da caixa de mensagem (sigma.completions).
    completions: ?*wire.CompletionSet = null,
    /// Regras para o texto que a pessoa envia (sigma.rewrite).
    rewrite: []rewrite.Rule = &.{},
    /// Pediu para abrir antes de a árvore chegar.
    want_open: bool = false,
    /// Gestos da pessoa neste plugin: só eles liberam enviar, inserir e pular.
    tokens: [token_ring]u32 = @splat(0),
    token_at: u8 = 0,

    pub fn isRunning(p: *const Plugin) bool {
        return p.run != 0;
    }

    pub fn status(p: *const Plugin) Status {
        if (p.run != 0) return .running;
        if (!p.enabled) return .off;
        return if (p.err_len > 0) .failed else .waiting;
    }

    pub fn err(p: *const Plugin) ?[]const u8 {
        return if (p.err_len > 0) p.err_buf[0..p.err_len] else null;
    }

    /// Bytes de Lua agora.
    pub fn memBytes(p: *const Plugin) usize {
        const w = p.engine.worker orelse return 0;
        return w.mem[p.slot].load(.monotonic);
    }

    /// Mensagens que ele perdeu por estar lento demais com a fila atrasada.
    pub fn shedCount(p: *const Plugin) u32 {
        const w = p.engine.worker orelse return 0;
        return w.shed[p.slot].load(.monotonic);
    }

    pub fn title(p: *const Plugin) []const u8 {
        return p.man.title(runtime.lang_en(), p.name);
    }

    pub fn about(p: *const Plugin) []const u8 {
        return p.man.about(runtime.lang_en());
    }

    fn setErr(p: *Plugin, msg: []const u8) void {
        var n = @min(msg.len, p.err_buf.len);
        // Sem cortar um caractere no meio.
        while (n > 0 and n < msg.len and (msg[n] & 0xC0) == 0x80) n -= 1;
        @memcpy(p.err_buf[0..n], msg[0..n]);
        p.err_len = @intCast(n);
    }

    fn validToken(p: *const Plugin, t: u32) bool {
        if (t == 0) return false;
        for (p.tokens) |k| if (k == t) return true;
        return false;
    }
};

pub const Engine = struct {
    gpa: std.mem.Allocator,
    host: Host,
    list: std.ArrayList(*Plugin) = .empty,
    /// Nomes desligados pela pessoa (persistidos pelo app).
    disabled: std.StringHashMapUnmanaged(void) = .empty,
    /// Hosts aprovados: "arquivo.lua\x00host" (persistidos pelo app).
    approvals: std.StringHashMapUnmanaged(void) = .empty,
    /// Muda a cada carga, troca ou erro (a página e o QA observam).
    generation: u32 = 0,
    /// Muda quando as entradas de menu mudam: a segunda lista aberta deixa de valer.
    menu_gen: u32 = 0,
    /// Somas dos plugins rodando: com zero, os ganchos nem entram.
    n_message: u32 = 0,
    n_ready: u32 = 0,
    n_delete: u32 = 0,
    n_channel: u32 = 0,
    n_lang: u32 = 0,
    n_edit: u32 = 0,
    n_commands: u32 = 0,
    n_keys: u32 = 0,
    n_running: u32 = 0,
    /// Botões na barra da mensagem, plugins com regras de envio, com sugestões e
    /// com número na etiqueta do painel.
    n_toolbar: u32 = 0,
    n_rewrite: u32 = 0,
    n_completions: u32 = 0,
    n_badges: u32 = 0,
    /// O app já recebeu o READY (plugin ligado depois recebe "ready" na hora).
    ready: bool = false,
    /// Plugins só rodam com uma conta aberta: o armazenamento é por conta.
    account: u64 = 0,
    /// Instruções por chamada.
    budget: u32 = 5_000_000,
    /// Pasta lida (para a página de configurações).
    dir_buf: [512]u8 = undefined,
    dir_len: u16 = 0,
    worker: ?*runtime.Worker = null,
    batch: std.ArrayList(wire.Cmd) = .empty,
    batch_at: usize = 0,
    next_run: u32 = 1,
    next_token: u32 = 1,
    next_serial: u32 = 0,
    deco: deco.Index,
    /// Painel lateral: qual está aberto, de que lado e a largura.
    panel_open: ?*Plugin = null,
    panel_left: bool = false,
    panel_w: f32 = 340,
    /// Muda quando uma árvore chega ou o painel troca (a interface e o QA observam).
    panel_gen: u32 = 0,
    /// Abrir este quando a árvore dele chegar (recarregou, ou o app reabriu).
    panel_wanted: [120]u8 = undefined,
    panel_wanted_len: u8 = 0,
    last_channel: u64 = 0,
    last_en: bool = false,
    /// A primeira letra de `sigma.lang()`: de inglês para japonês, `en` não muda.
    last_lang: u8 = 0,

    pub fn init(gpa: std.mem.Allocator, host: Host) Engine {
        return .{ .gpa = gpa, .host = host, .deco = deco.Index.init(gpa) };
    }

    pub fn deinit(e: *Engine) void {
        e.host.http_stop();
        if (e.worker) |w| {
            for (e.list.items) |p| if (p.run != 0) w.push(.{ .stop = p.run });
            w.join(true);
            e.dropBatch();
            w.takeOut(&e.batch);
            e.dropBatch();
            w.destroy();
        }
        e.batch.deinit(e.gpa);
        e.worker = null;
        e.freeViews();
        e.list.deinit(e.gpa);
        var it = e.disabled.keyIterator();
        while (it.next()) |k| e.gpa.free(k.*);
        e.disabled.deinit(e.gpa);
        var ap = e.approvals.keyIterator();
        while (ap.next()) |k| e.gpa.free(k.*);
        e.approvals.deinit(e.gpa);
        e.deco.deinit();
        if (current == e) current = null;
    }

    fn dropBatch(e: *Engine) void {
        for (e.batch.items[e.batch_at..]) |*cmd| runtime.freeCmd(e.gpa, cmd);
        e.batch.clearRetainingCapacity();
        e.batch_at = 0;
    }

    pub fn dir(e: *const Engine) []const u8 {
        return e.dir_buf[0..e.dir_len];
    }

    pub fn setDir(e: *Engine, path: []const u8) void {
        const n = @min(path.len, e.dir_buf.len);
        @memcpy(e.dir_buf[0..n], path[0..n]);
        e.dir_len = @intCast(n);
    }

    /// A thread está de pé? (Sem plugin ligado, não: o QA confere.)
    pub fn threadRunning(e: *const Engine) bool {
        const w = e.worker orelse return false;
        return w.thread != null;
    }

    fn freeViews(e: *Engine) void {
        for (e.list.items) |p| {
            e.forgetRun(p);
            e.gpa.free(p.name);
            e.gpa.free(p.src);
            p.commands.deinit(e.gpa);
            p.keys.deinit(e.gpa);
            p.lsp.deinit(e.gpa);
            p.menus.deinit(e.gpa);
            e.gpa.destroy(p);
        }
        e.list.clearRetainingCapacity();
        e.recount();
    }

    /// Troca todos os plugins pelos arquivos dados (já em ordem).
    /// `app_ready`: o app já está conectado (dispara "ready" nos novos).
    pub fn load(e: *Engine, files: []const Source, app_ready: bool) void {
        e.rememberPanel();
        for (e.list.items) |p| e.stopRun(p);
        e.freeViews();
        e.ready = app_ready;
        for (files[0..@min(files.len, max_plugins)], 0..) |f, i| {
            const p = e.gpa.create(Plugin) catch break;
            const name = e.gpa.dupe(u8, f.name) catch {
                e.gpa.destroy(p);
                break;
            };
            const src = e.gpa.dupe(u8, f.src) catch {
                e.gpa.free(name);
                e.gpa.destroy(p);
                break;
            };
            p.* = .{ .engine = e, .name = name, .src = src, .slot = @intCast(i), .enabled = !e.disabled.contains(f.name), .man = manifest.parse(src) };
            e.list.append(e.gpa, p) catch {
                e.gpa.free(name);
                e.gpa.free(src);
                e.gpa.destroy(p);
                break;
            };
            if (p.enabled) e.startRun(p);
        }
        e.settle();
    }

    /// Lê a pasta de novo (botão "Recarregar").
    pub fn reload(e: *Engine) void {
        e.host.rescan(e.host.ctx);
    }

    /// Ao ler as configurações salvas.
    pub fn setDisabledName(e: *Engine, name: []const u8) void {
        if (e.disabled.contains(name)) return;
        const k = e.gpa.dupe(u8, name) catch return;
        e.disabled.put(e.gpa, k, {}) catch e.gpa.free(k);
    }

    pub fn setEnabled(e: *Engine, p: *Plugin, on: bool) void {
        if (p.enabled == on) return;
        p.enabled = on;
        p.err_len = 0;
        if (on) {
            if (e.disabled.fetchRemove(p.name)) |kv| e.gpa.free(kv.key);
            e.startRun(p);
        } else {
            e.setDisabledName(p.name);
            e.stopRun(p);
        }
        e.settle();
        e.host.save(e.host.ctx);
    }

    /// A conta aberta mudou (0 = nenhuma): os plugins rodam de novo, com os dados dela.
    pub fn setAccount(e: *Engine, id: u64) void {
        if (e.account == id) return;
        e.rememberPanel();
        for (e.list.items) |p| e.stopRun(p);
        e.account = id;
        e.ready = false;
        if (id != 0) for (e.list.items) |p| {
            if (p.enabled) e.startRun(p);
        };
        e.settle();
    }

    /// Depois de ligar/desligar: conta de novo e, sem ninguém rodando, a thread sai.
    fn settle(e: *Engine) void {
        e.recount();
        e.generation +%= 1;
        if (e.n_running == 0) if (e.worker) |w| {
            if (w.thread != null) w.retire();
        };
    }

    fn startRun(e: *Engine, p: *Plugin) void {
        if (e.account == 0 or p.run != 0) return;
        const w = e.ensureThread() orelse {
            p.setErr(runtime_tr("não consegui iniciar a thread dos plugins", "couldn't start the plugin thread"));
            return;
        };
        p.err_len = 0;
        const run = e.next_run;
        e.next_run +%= 1;
        if (e.next_run == 0) e.next_run = 1;
        const args = e.gpa.create(wire.StartArgs) catch return;
        const name = e.gpa.dupe(u8, p.name) catch {
            e.gpa.destroy(args);
            return;
        };
        const src = e.gpa.dupe(u8, p.src) catch {
            e.gpa.free(name);
            e.gpa.destroy(args);
            return;
        };
        args.* = .{ .run = run, .slot = p.slot, .account = e.account, .name = name, .src = src, .approved = e.approvedFor(p), .fire_ready = e.ready, .budget = e.budget };
        p.run = run;
        e.publishWhere(w);
        w.push(.{ .start = args });
    }

    fn stopRun(e: *Engine, p: *Plugin) void {
        if (p.run == 0) return;
        if (e.worker) |w| w.push(.{ .stop = p.run });
        e.forgetRun(p);
    }

    /// Tudo o que a interface guardava desta partida some na hora.
    fn forgetRun(e: *Engine, p: *Plugin) void {
        if (p.run != 0) e.deco.clearRun(p.run);
        p.run = 0;
        e.menu_gen +%= 1;
        if (e.worker) |w| w.shed[p.slot].store(0, .monotonic);
        for (p.commands.items) |s| e.gpa.free(s);
        p.commands.clearRetainingCapacity();
        p.keys.clearRetainingCapacity();
        p.lsp.clearRetainingCapacity();
        for (p.menus.items) |*m| m.free(e.gpa);
        p.menus.clearRetainingCapacity();
        p.n_message = 0;
        p.n_ready = 0;
        p.n_delete = 0;
        p.n_channel = 0;
        p.n_lang = 0;
        p.n_edit = 0;
        p.n_dismiss = 0;
        p.want_open = false;
        if (p.tree) |t| t.destroy();
        p.tree = null;
        if (p.settings) |t| t.destroy();
        p.settings = null;
        if (p.completions) |set| set.free(e.gpa);
        p.completions = null;
        rewrite.freeList(e.gpa, p.rewrite);
        p.rewrite = &.{};
        if (e.panel_open == p) e.panel_open = null;
        e.panel_gen +%= 1;
    }

    fn ensureThread(e: *Engine) ?*runtime.Worker {
        const w = e.worker orelse blk: {
            const nw = runtime.Worker.create(e.gpa, e.host) catch return null;
            e.worker = nw;
            break :blk nw;
        };
        // Saindo: espera acabar (é rápido), para quem liga de novo ler o que ela gravou.
        if (w.thread != null and w.quit) w.join(false);
        return if (w.start()) w else null;
    }

    fn recount(e: *Engine) void {
        e.n_message = 0;
        e.n_ready = 0;
        e.n_delete = 0;
        e.n_channel = 0;
        e.n_lang = 0;
        e.n_edit = 0;
        e.n_commands = 0;
        e.n_keys = 0;
        e.n_running = 0;
        e.n_toolbar = 0;
        e.n_rewrite = 0;
        e.n_completions = 0;
        e.n_badges = 0;
        for (e.list.items) |p| if (p.run != 0) {
            e.n_running += 1;
            e.n_message += p.n_message;
            e.n_ready += p.n_ready;
            e.n_delete += p.n_delete;
            e.n_channel += p.n_channel;
            e.n_lang += p.n_lang;
            e.n_edit += p.n_edit;
            e.n_commands += @intCast(p.commands.items.len);
            e.n_keys += @intCast(p.keys.items.len);
            for (p.menus.items) |*m| if (m.toolbar.len > 0) {
                e.n_toolbar += 1;
            };
            if (p.rewrite.len > 0) e.n_rewrite += 1;
            if (p.completions != null) e.n_completions += 1;
            if (p.tree) |t| if (t.badge.len > 0) {
                e.n_badges += 1;
            };
        };
    }

    // --- Hosts aprovados ----------------------------------------------------------

    fn approvalKey(buf: []u8, plugin: []const u8, host: []const u8) ?[]const u8 {
        if (plugin.len + host.len + 1 > buf.len) return null;
        return std.fmt.bufPrint(buf, "{s}\x00{s}", .{ plugin, host }) catch null;
    }

    pub fn isApproved(e: *const Engine, plugin: []const u8, host: []const u8) bool {
        var buf: [256]u8 = undefined;
        const k = approvalKey(&buf, plugin, host) orelse return false;
        return e.approvals.contains(k);
    }

    /// Ao ler as configurações salvas.
    pub fn setApprovedName(e: *Engine, plugin: []const u8, host: []const u8) void {
        if (e.isApproved(plugin, host)) return;
        var buf: [256]u8 = undefined;
        const k = approvalKey(&buf, plugin, host) orelse return;
        const own = e.gpa.dupe(u8, k) catch return;
        e.approvals.put(e.gpa, own, {}) catch e.gpa.free(own);
    }

    fn approvedFor(e: *Engine, p: *const Plugin) [][]u8 {
        var out: std.ArrayList([]u8) = .empty;
        for (p.man.hostList()) |h| {
            if (!e.isApproved(p.name, h)) continue;
            const own = e.gpa.dupe(u8, h) catch continue;
            out.append(e.gpa, own) catch e.gpa.free(own);
        }
        return out.toOwnedSlice(e.gpa) catch &.{};
    }

    /// O interruptor da página: vale na hora, e fica salvo.
    pub fn setApproved(e: *Engine, p: *Plugin, host: []const u8, on: bool) void {
        if (on) {
            e.setApprovedName(p.name, host);
        } else {
            var buf: [256]u8 = undefined;
            const k = approvalKey(&buf, p.name, host) orelse return;
            if (e.approvals.fetchRemove(k)) |kv| e.gpa.free(kv.key);
        }
        e.generation +%= 1;
        if (p.run != 0) if (e.worker) |w| w.push(.{ .hosts = .{ .run = p.run, .approved = e.approvedFor(p) } });
        e.host.save(e.host.ctx);
    }

    // --- Eventos que o app manda ----------------------------------------------

    pub fn onMessage(e: *Engine, m: *const Message) void {
        if (e.n_message == 0) return;
        const w = e.worker orelse return;
        const own = wire.OwnedMsg.dup(e.gpa, m) orelse return;
        w.push(.{ .message = own });
    }

    /// Editaram uma mensagem: `m` já é o texto novo.
    pub fn onEdit(e: *Engine, m: *const Message) void {
        if (e.n_edit == 0) return;
        const w = e.worker orelse return;
        const own = wire.OwnedMsg.dup(e.gpa, m) orelse return;
        w.push(.{ .edit = own });
    }

    /// A pessoa fechou a nota de um plugin (o × embaixo da mensagem).
    pub fn dismissDeco(e: *Engine, run: u32, id: u64) void {
        e.deco.remove(run, id);
        const p = e.byRun(run) orelse return;
        if (p.n_dismiss == 0) return;
        if (e.worker) |w| w.push(.{ .dismiss = .{ .run = run, .id = id } });
    }

    pub fn onDelete(e: *Engine, channel: u64, id: u64) void {
        e.deco.removeMessage(id);
        if (e.n_delete == 0) return;
        if (e.worker) |w| w.push(.{ .delete = .{ .channel = channel, .id = id } });
    }

    pub fn fireReady(e: *Engine) void {
        e.ready = true;
        if (e.n_running == 0) return;
        if (e.worker) |w| w.push(.ready);
    }

    fn publishWhere(e: *Engine, w: *runtime.Worker) void {
        const wh = e.host.where(e.host.ctx);
        w.setWhere(wh);
        e.last_channel = wh.channel;
    }

    /// A cada quadro, com algum plugin rodando: o canal aberto mudou? O idioma?
    pub fn frameTick(e: *Engine, channel_now: u64, en: bool) void {
        if (e.n_running == 0) return;
        const w = e.worker orelse return;
        if (channel_now != e.last_channel) {
            e.publishWhere(w);
            if (e.n_channel > 0) w.push(.channel);
        }
        const code = runtime.lang_code()[0];
        if (e.last_lang == 0) e.last_lang = code;
        if (en != e.last_en or code != e.last_lang) {
            e.last_en = en;
            e.last_lang = code;
            e.generation +%= 1;
            if (e.n_lang > 0) w.push(.lang);
        }
    }

    fn newToken(e: *Engine, p: *Plugin) u32 {
        const t = e.next_token;
        e.next_token +%= 1;
        if (e.next_token == 0) e.next_token = 1;
        p.tokens[p.token_at] = t;
        p.token_at = (p.token_at + 1) % token_ring;
        return t;
    }

    fn gesture(e: *Engine, p: *Plugin, what: wire.Gesture) void {
        const w = e.worker orelse return;
        w.push(.{ .gesture = .{ .run = p.run, .token = e.newToken(p), .what = what } });
    }

    /// Texto digitado na caixa: "/nome args" de algum plugin? Se sim, roda
    /// e devolve true (não vai para o Discord).
    pub fn command(e: *Engine, text: []const u8) bool {
        if (e.n_commands == 0 or text.len < 2 or text[0] != '/') return false;
        const sp = std.mem.indexOfAny(u8, text, " \t\n") orelse text.len;
        const name = text[0..sp];
        const args = std.mem.trim(u8, text[sp..], " \t\n");
        for (e.list.items) |p| {
            if (p.run == 0) continue;
            for (p.commands.items) |cmd| if (std.mem.eql(u8, cmd, name)) {
                const n = e.gpa.dupe(u8, name) catch return true;
                const a = e.gpa.dupe(u8, args) catch {
                    e.gpa.free(n);
                    return true;
                };
                e.gesture(p, .{ .command = .{ .name = n, .args = a } });
                return true;
            };
        }
        return false;
    }

    /// Roda os atalhos cujas teclas `pressed` diz que foram apertadas.
    pub fn pollKeys(e: *Engine, ctx: *anyopaque, pressed: *const fn (ctx: *anyopaque, k: *const Keybind) bool) void {
        if (e.n_keys == 0) return;
        for (e.list.items) |p| {
            if (p.run == 0) continue;
            for (p.keys.items) |*k| {
                if (pressed(ctx, k)) e.gesture(p, .{ .key = k.slot });
            }
        }
    }

    // --- Menus e painel (a interface chama) -------------------------------------

    /// Clicou numa entrada de menu num mensagem. `value`: a escolha da segunda lista.
    pub fn menuMessage(e: *Engine, p: *Plugin, entry: *const MenuEntry, m: *const Message, value: ?[]const u8) void {
        if (p.run == 0) return;
        const v = if (value) |x| (e.gpa.dupe(u8, x) catch return) else null;
        const own = wire.OwnedMsg.dup(e.gpa, m) orelse {
            if (v) |x| e.gpa.free(x);
            return;
        };
        e.gesture(p, .{ .menu_message = .{ .slot = entry.slot, .msg = own, .value = v } });
    }

    pub fn menuUser(e: *Engine, p: *Plugin, entry: *const MenuEntry, id: u64, name: []const u8, value: ?[]const u8) void {
        if (p.run == 0) return;
        const v = if (value) |x| (e.gpa.dupe(u8, x) catch return) else null;
        const own = e.gpa.dupe(u8, name) catch {
            if (v) |x| e.gpa.free(x);
            return;
        };
        e.gesture(p, .{ .menu_user = .{ .slot = entry.slot, .id = id, .name = own, .value = v } });
    }

    /// Clicou num botão ou item do painel, ou enviou um campo com Enter: é gesto.
    pub fn panelGesture(e: *Engine, p: *Plugin, handle: u32, value: ?[]const u8) void {
        if (p.run == 0 or handle == 0) return;
        const v = if (value) |x| (e.gpa.dupe(u8, x) catch return) else null;
        e.gesture(p, .{ .panel = .{ .handle = handle, .value = v } });
    }

    /// Mudou um interruptor: é um clique, então é gesto.
    pub fn panelToggle(e: *Engine, p: *Plugin, handle: u32, on: bool) void {
        e.generation +%= 1;
        if (p.run == 0 or handle == 0) return;
        e.gesture(p, .{ .panel = .{ .handle = handle, .value = null, .toggled = on } });
    }

    /// O texto de um campo mudou. Não conta como gesto: digitar não libera enviar.
    pub fn panelChange(e: *Engine, p: *Plugin, handle: u32, value: []const u8) void {
        if (p.run == 0 or handle == 0) return;
        const w = e.worker orelse return;
        const v = e.gpa.dupe(u8, value) catch return;
        w.push(.{ .gesture = .{ .run = p.run, .token = 0, .what = .{ .panel = .{ .handle = handle, .value = v } } } });
    }

    fn rememberPanel(e: *Engine) void {
        const p = e.panel_open orelse return;
        e.wantPanel(p.name);
    }

    fn wantPanel(e: *Engine, name: []const u8) void {
        if (name.len > e.panel_wanted.len) return;
        @memcpy(e.panel_wanted[0..name.len], name);
        e.panel_wanted_len = @intCast(name.len);
    }

    pub fn openPanel(e: *Engine, p: ?*Plugin) void {
        e.panel_wanted_len = 0;
        if (e.panel_open == p) return;
        if (e.worker) |w| {
            if (e.panel_open) |old| if (old.run != 0) w.push(.{ .panel_state = .{ .run = old.run, .open = false } });
            if (p) |now| if (now.run != 0) w.push(.{ .panel_state = .{ .run = now.run, .open = true } });
        }
        e.panel_open = p;
        e.panel_gen +%= 1;
    }

    /// Quantos plugins têm painel publicado.
    pub fn panelCount(e: *const Engine) usize {
        var n: usize = 0;
        for (e.list.items) |p| {
            if (p.tree != null) n += 1;
        }
        return n;
    }

    // --- Sugestões e regras de envio (dados: nada aqui chama o plugin) ---------------

    /// Os gatilhos em uso, sem repetir.
    pub fn completionTriggers(e: *const Engine, buf: []u8) []const u8 {
        var n: usize = 0;
        for (e.list.items) |p| {
            const set = p.completions orelse continue;
            if (std.mem.indexOfScalar(u8, buf[0..n], set.trigger) != null or n == buf.len) continue;
            buf[n] = set.trigger;
            n += 1;
        }
        return buf[0..n];
    }

    /// O texto de uma sugestão: a lista pode ter mudado desde a busca.
    pub fn completionText(e: *const Engine, run: u32, trigger: u8, name: []const u8) ?[]const u8 {
        for (e.list.items) |p| {
            if (p.run != run) continue;
            const set = p.completions orelse return null;
            if (set.trigger != trigger) return null;
            for (set.items) |*it| if (std.mem.eql(u8, it.name, name)) return it.text;
        }
        return null;
    }

    /// O texto que a pessoa vai enviar, com as regras dos plugins aplicadas. null =
    /// fica como está. Quem chama fica com o resultado.
    pub fn rewriteOutgoing(e: *Engine, text: []const u8) ?[]u8 {
        if (e.n_rewrite == 0) return null;
        var cur: ?[]u8 = null;
        for (e.list.items) |p| {
            if (p.run == 0 or p.rewrite.len == 0) continue;
            const next = rewrite.apply(e.gpa, cur orelse text, p.rewrite) catch continue;
            if (next) |n| {
                if (cur) |old| e.gpa.free(old);
                cur = n;
            }
        }
        return cur;
    }

    // --- O que os plugins pediram --------------------------------------------------

    /// Atende os pedidos que chegaram da thread dos plugins. Só na thread da
    /// interface e fora do quadro: troca árvores e listas que o desenho lê.
    pub fn drain(e: *Engine) void {
        const w = e.worker orelse return;
        if (w.thread != null and w.exited.load(.acquire)) w.join(false);
        if (e.batch_at >= e.batch.items.len) {
            e.batch.clearRetainingCapacity();
            e.batch_at = 0;
            w.takeOut(&e.batch);
        }
        const end = @min(e.batch.items.len, e.batch_at + drain_budget);
        for (e.batch.items[e.batch_at..end]) |*cmd| e.apply(cmd);
        e.batch_at = end;
        if (e.batch_at < e.batch.items.len) e.host.wake(e.host.ctx);
    }

    fn byRun(e: *Engine, run: u32) ?*Plugin {
        if (run == 0) return null;
        for (e.list.items) |p| if (p.run == run) return p;
        return null;
    }

    /// Assume `cmd`.
    fn apply(e: *Engine, cmd: *wire.Cmd) void {
        // De uma partida que já acabou: joga fora.
        const p = e.byRun(cmd.run) orelse return runtime.freeCmd(e.gpa, cmd);
        switch (cmd.what) {
            .reg => |reg| {
                e.takeReg(p, reg);
                e.recount();
                e.generation +%= 1;
            },
            .failed => |f| {
                p.setErr(f.msg);
                if (f.stopped) {
                    e.forgetRun(p);
                    e.settle();
                } else e.generation +%= 1;
                e.host.failed(e.host.ctx, p.name, p.err() orelse "");
                e.gpa.free(f.msg);
            },
            .notify => |n| {
                e.host.notify(e.host.ctx, p.title(), n.text, n.desktop);
                e.gpa.free(n.text);
            },
            .send => |s| {
                if (p.validToken(s.token) and !e.host.send(e.host.ctx, s.channel, s.text)) {
                    p.setErr(runtime_tr("sigma.send: canal não encontrado", "sigma.send: channel not found"));
                    e.generation +%= 1;
                    e.host.failed(e.host.ctx, p.name, p.err() orelse "");
                }
                e.gpa.free(s.text);
            },
            .insert => |s| {
                if (p.validToken(s.token)) e.host.insert(e.host.ctx, s.text);
                e.gpa.free(s.text);
            },
            .jump => |j| if (p.validToken(j.token)) e.host.jump(e.host.ctx, j.channel, j.id),
            .copy => |s| {
                if (p.validToken(s.token)) e.host.copy(e.host.ctx, s.text);
                e.gpa.free(s.text);
            },
            .open_url => |s| {
                if (p.validToken(s.token)) e.host.open_url(e.host.ctx, s.url);
                e.gpa.free(s.url);
            },
            .settings_tree => |t| {
                if (p.settings) |old| old.destroy();
                p.settings = t;
                e.next_serial +%= 1;
                t.serial = e.next_serial;
                e.generation +%= 1;
            },
            .completions => |set| {
                if (p.completions) |old| old.free(e.gpa);
                p.completions = set;
                e.recount();
            },
            .rewrite => |list| {
                rewrite.freeList(e.gpa, p.rewrite);
                p.rewrite = list;
                e.recount();
            },
            .panel_tree => |t| {
                if (p.tree) |old| old.destroy();
                p.tree = t;
                e.next_serial +%= 1;
                t.serial = e.next_serial;
                e.panel_gen +%= 1;
                e.generation +%= 1;
                e.recount();
                if (p.want_open or std.mem.eql(u8, e.panel_wanted[0..e.panel_wanted_len], p.name)) {
                    p.want_open = false;
                    e.openPanel(p);
                }
            },
            .panel_show => |s| {
                if (!s.open) {
                    p.want_open = false;
                    if (e.panel_open == p) e.openPanel(null);
                } else if (p.validToken(s.token)) {
                    if (p.tree != null) e.openPanel(p) else p.want_open = true;
                }
            },
            .deco_set => |s| {
                // Sem nada para mostrar nem recolher, é o mesmo que tirar.
                if (s.badge.len == 0 and s.note.len == 0 and !s.collapse) {
                    e.deco.remove(p.run, s.id);
                    e.gpa.free(s.badge);
                    e.gpa.free(s.note);
                    e.gpa.free(s.label);
                } else _ = e.deco.set(p.run, s.id, s.badge, s.note, s.label, s.collapse, s.danger);
            },
            .deco_remove => |id| e.deco.remove(p.run, id),
            .deco_rules => |list| e.deco.setRules(p.run, list),
            .want_messages => |q| {
                const w = e.worker orelse return wire.freeNeedles(e.gpa, q.needles);
                const list = e.gpa.create(MsgList) catch return wire.freeNeedles(e.gpa, q.needles);
                list.* = .{ .gpa = e.gpa, .files = q.files, .needles = q.needles };
                e.host.messages(e.host.ctx, q.channel, q.limit, list);
                w.push(.{ .messages = .{ .run = cmd.run, .req = q.req, .list = list } });
            },
        }
    }

    fn takeReg(e: *Engine, p: *Plugin, reg: *wire.Reg) void {
        const a = e.gpa;
        for (p.commands.items) |s| a.free(s);
        p.commands.deinit(a);
        p.commands = .fromOwnedSlice(reg.commands);
        p.keys.deinit(a);
        p.keys = .fromOwnedSlice(reg.keys);
        p.lsp.deinit(a);
        p.lsp = .fromOwnedSlice(reg.lsp);
        for (p.menus.items) |*m| m.free(a);
        p.menus.deinit(a);
        e.menu_gen +%= 1;
        p.menus = .fromOwnedSlice(reg.menus);
        p.n_message = reg.n_message;
        p.n_ready = reg.n_ready;
        p.n_delete = reg.n_delete;
        p.n_channel = reg.n_channel;
        p.n_lang = reg.n_lang;
        p.n_edit = reg.n_edit;
        p.n_dismiss = reg.n_dismiss;
        a.destroy(reg);
    }

    // --- plugins.kdl -----------------------------------------------------------------

    /// `plugin "nome.lua" enabled=#false`, `host-ok "nome.lua" "api.exemplo.com"`,
    /// `panel side="left" width=340 open="nome.lua"`.
    pub fn applyPrefNode(e: *Engine, n: *const kdl.Node) void {
        if (std.mem.eql(u8, n.name, "plugin")) {
            const name = (n.arg(0) orelse return).asString() orelse return;
            if (n.flag("enabled") == false) e.setDisabledName(name);
        } else if (std.mem.eql(u8, n.name, "host-ok")) {
            const name = (n.arg(0) orelse return).asString() orelse return;
            const host = (n.arg(1) orelse return).asString() orelse return;
            e.setApprovedName(name, host);
        } else if (std.mem.eql(u8, n.name, "panel")) {
            if (n.str("side")) |s| e.panel_left = std.mem.eql(u8, s, "left");
            if (n.num("width")) |w| e.panel_w = @floatCast(std.math.clamp(w, 240, 900));
            if (n.str("open")) |name| e.wantPanel(name);
        }
    }

    fn kdlSafe(s: []const u8) bool {
        return std.mem.indexOfAny(u8, s, "\"\\\n") == null;
    }

    pub fn writePrefs(e: *const Engine, gpa: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        try out.appendSlice(gpa, "// gerado pelo SigmaCord: plugins desligados, hosts aprovados e o painel\n");
        var it = e.disabled.keyIterator();
        while (it.next()) |k| {
            // Nomes que o KDL precisaria escapar ficam de fora.
            if (!kdlSafe(k.*)) continue;
            try out.print(gpa, "plugin \"{s}\" enabled=#false\n", .{k.*});
        }
        var ap = e.approvals.keyIterator();
        while (ap.next()) |k| {
            const cut = std.mem.indexOfScalar(u8, k.*, 0) orelse continue;
            if (!kdlSafe(k.*[0..cut]) or !kdlSafe(k.*[cut + 1..])) continue;
            try out.print(gpa, "host-ok \"{s}\" \"{s}\"\n", .{ k.*[0..cut], k.*[cut + 1..] });
        }
        try out.print(gpa, "panel side=\"{s}\" width={d}", .{ if (e.panel_left) "left" else "right", @round(e.panel_w) });
        if (e.panel_open) |p| if (kdlSafe(p.name)) try out.print(gpa, " open=\"{s}\"", .{p.name});
        try out.append(gpa, '\n');
    }

    /// Espera a thread dos plugins terminar tudo o que tem (testes e QA).
    pub fn waitIdle(e: *Engine) void {
        const w = e.worker orelse return;
        var spins: u32 = 0;
        while (spins < 20_000) : (spins += 1) {
            e.drain();
            if (w.idle() and e.batch_at >= e.batch.items.len) return;
            sync.sleepMs(1);
        }
    }
};

fn runtime_tr(pt: []const u8, en: []const u8) []const u8 {
    return if (runtime.lang_en()) en else pt;
}

// --- Testes ------------------------------------------------------------------

const T = struct {
    var notes: [64][256]u8 = undefined;
    var notes_len: [64]usize = @splat(0);
    var notes_desktop: [64]bool = @splat(false);
    var n_notes: usize = 0;
    var sent: [16][128]u8 = undefined;
    var sent_len: [16]usize = @splat(0);
    var sent_ch: [16]u64 = @splat(0);
    var n_sent: usize = 0;
    var n_failed: usize = 0;
    var inserted: [256]u8 = undefined;
    var inserted_len: usize = 0;
    var jumps: usize = 0;
    var jump_id: u64 = 0;
    var copied: [256]u8 = undefined;
    var copied_len: usize = 0;
    var opened: [256]u8 = undefined;
    var opened_len: usize = 0;
    var dummy: u8 = 0;
    var loaded: []const Message = &.{};
    var last_read: u64 = 0;
    // O "disco" do armazenamento, usado pela thread dos plugins.
    var disk_lock: ?sync.Lock = null;
    var disk: [8]struct { name: [32]u8 = undefined, name_len: usize = 0, data: [2 * 1024 * 1024]u8 = undefined, len: usize = 0 } = undefined;
    var disk_n: usize = 0;
    var broken: usize = 0;
    // Pedidos HTTP: o teste responde com `respond`.
    var http_reqs: [8]?*HttpReq = @splat(null);
    var http_n: usize = 0;

    fn lock() *sync.Lock {
        if (disk_lock == null) disk_lock = sync.lockInit();
        return &disk_lock.?;
    }

    fn reset() void {
        n_notes = 0;
        n_sent = 0;
        n_failed = 0;
        inserted_len = 0;
        jumps = 0;
        copied_len = 0;
        opened_len = 0;
        loaded = &.{};
    }
    fn wipeDisk() void {
        const l = lock();
        l.lock();
        defer l.unlock();
        disk_n = 0;
        broken = 0;
    }
    fn note(i: usize) []const u8 {
        return notes[i][0..notes_len[i]];
    }
    fn notify(_: *anyopaque, _: []const u8, text: []const u8, desktop: bool) void {
        if (n_notes == notes.len) return;
        const k = @min(text.len, 256);
        @memcpy(notes[n_notes][0..k], text[0..k]);
        notes_len[n_notes] = k;
        notes_desktop[n_notes] = desktop;
        n_notes += 1;
    }
    fn send(_: *anyopaque, ch: u64, text: []const u8) bool {
        if (n_sent == sent.len) return false;
        const k = @min(text.len, 128);
        @memcpy(sent[n_sent][0..k], text[0..k]);
        sent_len[n_sent] = k;
        sent_ch[n_sent] = if (ch == 0) 42 else ch;
        n_sent += 1;
        return true;
    }
    fn where(_: *anyopaque) Where {
        return .{ .channel = 42, .channel_name = "geral", .guild = 7, .guild_name = "Servidor" };
    }
    fn key(name: []const u8) ?i32 {
        if (name.len == 1 and std.ascii.isAlphabetic(name[0])) return name[0];
        if (std.mem.eql(u8, name, "f5")) return 500;
        return null;
    }
    fn nop(_: *anyopaque) void {}
    fn failed(_: *anyopaque, _: []const u8, _: []const u8) void {
        n_failed += 1;
    }
    fn insert(_: *anyopaque, text: []const u8) void {
        const k = @min(text.len, inserted.len - inserted_len);
        @memcpy(inserted[inserted_len..][0..k], text[0..k]);
        inserted_len += k;
    }
    fn jump(_: *anyopaque, _: u64, id: u64) void {
        jumps += 1;
        jump_id = id;
    }
    fn copy(_: *anyopaque, text: []const u8) void {
        const k = @min(text.len, copied.len);
        @memcpy(copied[0..k], text[0..k]);
        copied_len = k;
    }
    fn openUrl(_: *anyopaque, url: []const u8) void {
        const k = @min(url.len, opened.len);
        @memcpy(opened[0..k], url[0..k]);
        opened_len = k;
    }
    fn messages(_: *anyopaque, _: u64, limit: u32, out: *MsgList) void {
        out.last_read = last_read;
        for (loaded[0..@min(loaded.len, limit)]) |*m| {
            var one = m.*;
            if (!out.files) one.files = &.{};
            out.add(&one);
        }
    }
    fn readData(_: *anyopaque, gpa: std.mem.Allocator, _: u64, plugin: []const u8) ?[]u8 {
        const l = lock();
        l.lock();
        defer l.unlock();
        for (disk[0..disk_n]) |*d| if (std.mem.eql(u8, d.name[0..d.name_len], plugin)) {
            return gpa.dupe(u8, d.data[0..d.len]) catch null;
        };
        return null;
    }
    fn writeData(_: *anyopaque, _: u64, plugin: []const u8, bytes: []const u8) bool {
        const l = lock();
        l.lock();
        defer l.unlock();
        const slot = for (disk[0..disk_n]) |*d| {
            if (std.mem.eql(u8, d.name[0..d.name_len], plugin)) break d;
        } else blk: {
            const d = &disk[disk_n];
            disk_n += 1;
            @memcpy(d.name[0..plugin.len], plugin);
            d.name_len = plugin.len;
            break :blk d;
        };
        @memcpy(slot.data[0..bytes.len], bytes);
        slot.len = bytes.len;
        return true;
    }
    fn keepBroken(_: *anyopaque, _: u64, _: []const u8) void {
        broken += 1;
    }
    fn httpStart(req: *HttpReq) bool {
        const l = lock();
        l.lock();
        defer l.unlock();
        if (http_n == http_reqs.len) return false;
        http_reqs[http_n] = req;
        http_n += 1;
        return true;
    }
    fn httpStop() void {
        while (http_n > 0) {
            http_n -= 1;
            if (http_reqs[http_n]) |r| r.free();
            http_reqs[http_n] = null;
        }
    }
    fn respond(status: u16, body: []const u8) void {
        const req = blk: {
            const l = lock();
            l.lock();
            defer l.unlock();
            http_n -= 1;
            break :blk http_reqs[http_n].?;
        };
        const res = req.gpa.create(HttpRes) catch unreachable;
        res.* = .{ .run = req.run, .id = req.id, .token = req.token, .status = status, .body = req.gpa.dupe(u8, body) catch unreachable };
        req.done(req.done_ctx, res);
        req.free();
    }
    fn engine() Engine {
        reset();
        var e = Engine.init(std.testing.allocator, .{
            .ctx = &dummy,
            .notify = &notify,
            .send = &send,
            .where = &where,
            .key = &key,
            .rescan = &nop,
            .save = &nop,
            .failed = &failed,
            .insert = &insert,
            .jump = &jump,
            .copy = &copy,
            .open_url = &openUrl,
            .messages = &messages,
            .wake = &nop,
            .read_data = &readData,
            .write_data = &writeData,
            .keep_broken_data = &keepBroken,
            .http_start = &httpStart,
            .http_stop = &httpStop,
        });
        e.account = 1;
        return e;
    }
};

fn testOne(e: *Engine, src: []const u8) *Plugin {
    e.load(&.{.{ .name = "t.lua", .src = src }}, false);
    e.waitIdle();
    return e.list.items[0];
}

fn cmdOk(e: *Engine, text: []const u8) !void {
    try std.testing.expect(e.command(text));
    e.waitIdle();
}

test "plugins: sandbox só com as bibliotecas permitidas" {
    var e = T.engine();
    defer e.deinit();
    const p = testOne(&e,
        \\local fora = { io, require, load, loadfile, dofile, debug, package, coroutine,
        \\  collectgarbage, string.dump, os.execute, os.getenv, os.remove, os.exit }
        \\for i = 1, 14 do assert(fora[i] == nil, "vazou " .. i) end
        \\assert(type(os.time()) == "number" and type(os.date("%Y")) == "string")
        \\assert(string.upper("a") == "A" and math.max(1, 2) == 2 and utf8.char(227) == "ã")
        \\assert(table.concat({ "a", "b" }, ",") == "a,b" and ("x"):rep(3) == "xxx")
        \\sigma.notify("ok")
    );
    try std.testing.expectEqual(Status.running, p.status());
    try std.testing.expectEqual(@as(usize, 1), T.n_notes);
    try std.testing.expectEqualStrings("ok", T.note(0));
}

test "plugins: sem plugin ligado não há thread nem estado de Lua" {
    var e = T.engine();
    defer e.deinit();
    e.setDisabledName("a.lua");
    e.load(&.{.{ .name = "a.lua", .src = "-- @name A\nerror('nunca roda')" }}, false);
    e.waitIdle();
    try std.testing.expect(e.worker == null);
    try std.testing.expect(!e.threadRunning());
    const p = e.list.items[0];
    try std.testing.expectEqual(Status.off, p.status());
    // O cabeçalho aparece mesmo assim.
    try std.testing.expectEqualStrings("A", p.title());
    // Ligou: a thread sobe. Desligou o último: ela sai.
    e.setEnabled(p, true);
    e.waitIdle();
    try std.testing.expect(e.threadRunning() or p.status() == .failed);
    e.setEnabled(p, false);
    var spins: usize = 0;
    while (e.threadRunning() and spins < 5000) : (spins += 1) {
        e.drain();
        sync.sleepMs(1);
    }
    try std.testing.expect(!e.threadRunning());
    // E religar depois disso funciona.
    e.setEnabled(p, true);
    e.waitIdle();
    try std.testing.expectEqual(Status.failed, p.status());
    try std.testing.expect(std.mem.indexOf(u8, p.err().?, "nunca roda") != null);
}

test "plugins: sigma.lsp só guarda a proposta e valida tudo" {
    var e = T.engine();
    defer e.deinit();
    const p = testOne(&e,
        \\sigma.lsp("zig", {"zls"})
        \\sigma.lsp("haskell", {"hls", "--lsp"})
        \\sigma.lsp("zig", {"/opt/zls", "--x"})
        \\local ruins = {
        \\  function() sigma.lsp("Zig", {"a"}) end,
        \\  function() sigma.lsp("c#", {"a"}) end,
        \\  function() sigma.lsp("a/b", {"a"}) end,
        \\  function() sigma.lsp("", {"a"}) end,
        \\  function() sigma.lsp("x", {}) end,
        \\  function() sigma.lsp("x", {""}) end,
        \\  function() sigma.lsp("x", {1}) end,
        \\  function() sigma.lsp("x", {"a", {}}) end,
        \\  function() sigma.lsp("x", {"a\0b"}) end,
        \\  function() sigma.lsp("x", "zls") end,
        \\  function() sigma.lsp("x", {string.rep("a", 2000)}) end,
        \\}
        \\for i, f in ipairs(ruins) do assert(not pcall(f), "passou " .. i) end
        \\for i = 1, 6 do sigma.lsp("l" .. i, {"p"}) end
        \\assert(not pcall(sigma.lsp, "demais", {"p"}))
    );
    try std.testing.expectEqual(Status.running, p.status());
    try std.testing.expectEqual(@as(usize, 8), p.lsp.items.len);
    // Chamar de novo troca a proposta.
    try std.testing.expectEqualStrings("zig", p.lsp.items[0].lang.slice());
    var it = p.lsp.items[0].cmd.iterator();
    try std.testing.expectEqualStrings("/opt/zls", it.next().?);
    try std.testing.expectEqualStrings("--x", it.next().?);
    // Desligado, a proposta some.
    e.setEnabled(p, false);
    try std.testing.expectEqual(@as(usize, 0), p.lsp.items.len);
}

test "plugins: laço infinito é parado, nem pcall segura, e a interface segue" {
    var e = T.engine();
    defer e.deinit();
    e.budget = 200_000;
    const p = testOne(&e, "while true do end");
    try std.testing.expectEqual(Status.failed, p.status());
    try std.testing.expect(std.mem.indexOf(u8, p.err().?, "limite") != null);

    const q = testOne(&e,
        \\sigma.command("/x", function()
        \\  while true do pcall(function() while true do end end) end
        \\end)
    );
    try std.testing.expectEqual(Status.running, q.status());
    try cmdOk(&e, "/x");
    try std.testing.expectEqual(Status.failed, q.status());
    try std.testing.expectEqual(@as(u32, 0), e.n_commands);
    // Parado, o comando volta a ir como texto.
    try std.testing.expect(!e.command("/x"));
}

test "plugins: chamar um plugin nunca espera o Lua" {
    var e = T.engine();
    defer e.deinit();
    // Bem mais instruções que o normal: um segundo inteiro por comando, se deixar.
    e.budget = 4_000_000_000;
    const p = testOne(&e,
        \\sigma.command("/lento", function()
        \\  local t = os.clock()
        \\  while os.clock() - t < 0.3 do end
        \\  sigma.notify("acabou")
        \\end)
    );
    try std.testing.expectEqual(Status.running, p.status());
    const t0 = sync.nowMs();
    try std.testing.expect(e.command("/lento"));
    e.drain();
    try std.testing.expect(sync.nowMs() - t0 < 100);
    try std.testing.expectEqual(@as(usize, 0), T.n_notes);
    e.waitIdle();
    try std.testing.expectEqualStrings("acabou", T.note(0));
}

test "plugins: erro de sintaxe e erro em tempo de execução" {
    var e = T.engine();
    defer e.deinit();
    const p = testOne(&e, "sigma.on('message', function( end");
    try std.testing.expectEqual(Status.failed, p.status());
    try std.testing.expect(std.mem.startsWith(u8, p.err().?, "t.lua:1:"));

    const q = testOne(&e, "sigma.on('message', function(m) error('quebrou') end)");
    const m: Message = .{ .content = "oi", .author = 1, .author_name = "ana", .channel = 42, .channel_name = "geral" };
    e.onMessage(&m);
    e.waitIdle();
    try std.testing.expectEqual(Status.running, q.status());
    try std.testing.expect(std.mem.indexOf(u8, q.err().?, "quebrou") != null);
    try std.testing.expectEqual(@as(usize, 2), T.n_failed); // sintaxe + quebrou
    // Erro toda hora: para depois de 10.
    for (0..9) |_| e.onMessage(&m);
    e.waitIdle();
    try std.testing.expectEqual(Status.failed, q.status());
    try std.testing.expectEqual(@as(u32, 0), e.n_message);
}

test "plugins: send só em gesto, nunca em resposta a mensagem, temporizador ou HTTP" {
    var e = T.engine();
    defer e.deinit();
    const p = testOne(&e,
        \\sigma.on("message", function(msg)
        \\  if msg.content:find("bom dia") then sigma.send(msg.channel, "bom dia, " .. msg.author.name) end
        \\end)
        \\sigma.command("/shrug", function(args)
        \\  sigma.send(sigma.channel(), (args ~= "" and args .. " " or "") .. "¯\\_(ツ)_/¯")
        \\end)
        \\sigma.keybind("Ctrl+Shift+X", function() sigma.send("99", "atalho") end)
    );
    try std.testing.expectEqual(Status.running, p.status());
    try std.testing.expectEqual(@as(u32, 1), e.n_keys);
    try std.testing.expectEqualStrings("Ctrl+Shift+X", p.keys.items[0].label());

    const m: Message = .{ .content = "bom dia!", .author = 1, .author_name = "ana", .channel = 42, .channel_name = "geral", .guild = 7, .guild_name = "S" };
    e.onMessage(&m);
    e.waitIdle();
    try std.testing.expectEqual(@as(usize, 0), T.n_sent);
    try std.testing.expect(std.mem.indexOf(u8, p.err().?, "sigma.send") != null);

    try cmdOk(&e, "/shrug oi");
    try std.testing.expect(!e.command("/outro"));
    try std.testing.expect(!e.command("shrug"));
    try std.testing.expectEqual(@as(usize, 1), T.n_sent);
    try std.testing.expectEqualStrings("oi ¯\\_(ツ)_/¯", T.sent[0][0..T.sent_len[0]]);
    try std.testing.expectEqual(@as(u64, 42), T.sent_ch[0]);

    const P = struct {
        fn all(_: *anyopaque, _: *const Keybind) bool {
            return true;
        }
    };
    e.pollKeys(&T.dummy, &P.all);
    e.waitIdle();
    try std.testing.expectEqual(@as(usize, 2), T.n_sent);
    try std.testing.expectEqual(@as(u64, 99), T.sent_ch[1]);
}

test "plugins: um gesto não vale para o que vem depois dele" {
    var e = T.engine();
    defer e.deinit();
    T.wipeDisk();
    const p = testOne(&e,
        \\-- @name G
        \\-- @capabilities send, timers, composer, panel, messages, menu
        \\sigma.command("/depois", function()
        \\  sigma.after(0.01, function() sigma.send(nil, "do temporizador") end)
        \\end)
        \\sigma.command("/ins", function() sigma.insert("texto") end)
        \\sigma.command("/pula", function() sigma.jump("5", "6") end)
        \\sigma.command("/varias", function() for i = 1, 6 do sigma.send(nil, "x" .. i) end end)
        \\sigma.command("/erro", function() pcall(sigma.after, "x", 1); sigma.after(0, function() sigma.insert("não") end) end)
        \\sigma.on("message", function() sigma.jump("1", "2") end)
    );
    try std.testing.expectEqual(Status.running, p.status());
    try cmdOk(&e, "/depois");
    sync.sleepMs(40);
    e.waitIdle();
    try std.testing.expectEqual(@as(usize, 0), T.n_sent);
    try std.testing.expect(std.mem.indexOf(u8, p.err().?, "sigma.send") != null);
    try cmdOk(&e, "/ins");
    try std.testing.expectEqualStrings("texto", T.inserted[0..T.inserted_len]);
    try cmdOk(&e, "/pula");
    try std.testing.expectEqual(@as(usize, 1), T.jumps);
    try std.testing.expectEqual(@as(u64, 6), T.jump_id);
    // No máximo 5 por gesto.
    try cmdOk(&e, "/varias");
    try std.testing.expectEqual(@as(usize, 5), T.n_sent);
    // Dentro de um temporizador, nem inserir.
    T.inserted_len = 0;
    try cmdOk(&e, "/erro");
    sync.sleepMs(40);
    e.waitIdle();
    try std.testing.expectEqual(@as(usize, 0), T.inserted_len);
    try std.testing.expect(std.mem.indexOf(u8, p.err().?, "sigma.insert") != null);
    const m: Message = .{ .content = "oi", .author = 1, .author_name = "ana", .channel = 42, .channel_name = "geral" };
    e.onMessage(&m);
    e.waitIdle();
    try std.testing.expectEqual(@as(usize, 1), T.jumps);
}

test "plugins: capacidade que o cabeçalho não pede dá erro que explica" {
    var e = T.engine();
    defer e.deinit();
    const a = testOne(&e, "sigma.storage.set('x', 1)");
    try std.testing.expect(std.mem.indexOf(u8, a.err().?, "@capabilities") != null);
    try std.testing.expect(std.mem.indexOf(u8, a.err().?, "storage") != null);
    const b = testOne(&e, "-- @name B\nsigma.send(nil, 'x')");
    try std.testing.expect(std.mem.indexOf(u8, b.err().?, "send") != null);
    // Cabeçalho com problema: nem liga, e o erro diz o que é.
    const c = testOne(&e, "-- @name C\n-- @capabilities http\n-- @hosts discord.com\nsigma.notify('nunca')");
    try std.testing.expectEqual(Status.failed, c.status());
    try std.testing.expect(std.mem.indexOf(u8, c.err().?, "Discord") != null);
    try std.testing.expectEqual(@as(usize, 0), T.n_notes);
}

test "plugins: atalhos inválidos e teto de memória" {
    var name: [16]u8 = undefined;
    var len: usize = 0;
    try std.testing.expect(parseKeys("x", &name, &len) == null);
    try std.testing.expect(parseKeys("shift+a", &name, &len) == null);
    try std.testing.expect(parseKeys("ctrl+a+b", &name, &len) == null);
    try std.testing.expect(parseKeys("f5", &name, &len) != null);
    try std.testing.expectEqualStrings("Alt+F5", parseKeys("alt+F5", &name, &len).?.label());

    var e = T.engine();
    defer e.deinit();
    const p = testOne(&e,
        \\local ok, err = pcall(function()
        \\  local t = {}
        \\  for i = 1, 1e8 do t[i] = ("x"):rep(64) .. i end
        \\end)
        \\sigma.notify(tostring(err))
    );
    try std.testing.expectEqual(Status.running, p.status());
    try std.testing.expect(std.mem.indexOf(u8, T.note(0), "memory") != null);
    try std.testing.expect(p.memBytes() < mem_cap);
}

test "plugins: desligar, religar e ready" {
    var e = T.engine();
    defer e.deinit();
    e.load(&.{
        .{ .name = "a.lua", .src = "sigma.on('ready', function() sigma.notify('pronto a') end)" },
        .{ .name = "b.lua", .src = "sigma.command('/b', function() sigma.notify('b') end)" },
    }, true);
    e.waitIdle();
    try std.testing.expectEqual(@as(usize, 1), T.n_notes);
    try std.testing.expectEqual(@as(u32, 1), e.n_commands);
    e.setEnabled(e.list.items[1], false);
    try std.testing.expect(e.disabled.contains("b.lua"));
    try std.testing.expect(!e.command("/b"));
    // Recarregar lembra quem está desligado.
    e.load(&.{
        .{ .name = "a.lua", .src = "sigma.on('ready', function() sigma.notify('pronto a') end)" },
        .{ .name = "b.lua", .src = "sigma.command('/b', function() sigma.notify('b') end)" },
    }, true);
    e.waitIdle();
    try std.testing.expectEqual(Status.off, e.list.items[1].status());
    e.setEnabled(e.list.items[1], true);
    e.waitIdle();
    try cmdOk(&e, "/b");
    try std.testing.expectEqualStrings("b", T.note(T.n_notes - 1));
}

test "plugins: nada trava dentro de C (__gc, string.rep, padrões, table)" {
    var e = T.engine();
    defer e.deinit();
    // __gc roda com o gancho desligado: nem chega a ser aceito.
    const gc = testOne(&e,
        \\local ok, err = pcall(setmetatable, {}, {__gc = function() while true do end end})
        \\sigma.notify(tostring(ok) .. " " .. tostring(err))
    );
    try std.testing.expectEqual(Status.running, gc.status());
    try std.testing.expect(std.mem.startsWith(u8, T.note(0), "false"));
    T.reset();
    _ = testOne(&e,
        \\local t = setmetatable({}, {__index = function() return 1 end})
        \\sigma.notify(tostring(t.x))
        \\local p = setmetatable({}, {__metatable = "não"})
        \\sigma.notify(tostring(pcall(setmetatable, p, {})))
        \\sigma.notify(tostring(pcall(setmetatable, 1, {})))
        \\sigma.notify(#string.rep("", 1000000000000000000) .. "")
        \\local s = string.rep("a", 100000)
        \\sigma.notify(tostring(pcall(string.find, s, ".-.-.-.-.-.-.-.-b")))
    );
    try std.testing.expectEqualStrings("1", T.note(0));
    try std.testing.expectEqualStrings("false", T.note(1));
    try std.testing.expectEqualStrings("false", T.note(2));
    try std.testing.expectEqualStrings("0", T.note(3));
    try std.testing.expectEqualStrings("false", T.note(4));
    T.reset();
    _ = testOne(&e,
        \\sigma.notify(tostring(pcall(table.move, {}, 1, 1000000000000000, 2)))
        \\local big = setmetatable({}, {__len = function() return 1000000000000000 end})
        \\sigma.notify(tostring(pcall(table.insert, big, 1, "x")))
        \\sigma.notify(tostring(pcall(table.remove, big, 1)))
    );
    for (0..3) |i| try std.testing.expectEqualStrings("false", T.note(i));
}

test "plugins: erro que não é texto e atalhos do dia a dia" {
    var e = T.engine();
    defer e.deinit();
    const p = testOne(&e, "error(123)");
    try std.testing.expect(p.err() != null);

    var name: [16]u8 = undefined;
    var len: usize = 0;
    for ([_][]const u8{ "ctrl+v", "ctrl+c", "ctrl+a", "ctrl+x", "ctrl+z", "ctrl+y" }) |k| try std.testing.expect(parseKeys(k, &name, &len) == null);
    try std.testing.expect(parseKeys("ctrl+shift+v", &name, &len) != null);
    try std.testing.expect(parseKeys("alt+v", &name, &len) != null);
}

test "plugins: arquivos antigos, sem cabeçalho, continuam funcionando" {
    const antigo = struct {
        const calc = @embedFile("testdata/calc.lua");
        const zoeira = @embedFile("testdata/zoeira.lua");
        const dado = @embedFile("testdata/dado.lua");
        const relogio = @embedFile("testdata/relogio.lua");
        const resumo = @embedFile("testdata/resumo.lua");
        const shrug = @embedFile("testdata/shrug.lua");
        const alerta = @embedFile("testdata/alerta.lua");
    };
    for ([_][]const u8{ antigo.calc, antigo.zoeira, antigo.dado, antigo.relogio, antigo.resumo, antigo.shrug, antigo.alerta }) |src| {
        var e = T.engine();
        defer e.deinit();
        const p = testOne(&e, src);
        if (p.err()) |msg| {
            std.debug.print("{s}\n", .{msg});
            return error.ExemploQuebrado;
        }
        try std.testing.expectEqual(Status.running, p.status());
        try std.testing.expect(p.man.legacy);
    }
    const Caso = struct { src: []const u8, cmd: []const u8, enviado: ?[]const u8 = null, aviso: ?[]const u8 = null };
    const casos = [_]Caso{
        .{ .src = antigo.calc, .cmd = "/conta (1 + 2) ^ 3", .enviado = "`(1 + 2) ^ 3 = 27`" },
        .{ .src = antigo.calc, .cmd = "/calc 10 / 4", .aviso = "10 / 4 = 2.5" },
        .{ .src = antigo.calc, .cmd = "/calc sqrt(16) + 2 * -3", .aviso = "sqrt(16) + 2 * -3 = -2" },
        .{ .src = antigo.calc, .cmd = "/calc 1 / 0", .aviso = "Conta inválida: divisão por zero" },
        .{ .src = antigo.calc, .cmd = "/calc (2", .aviso = "Conta inválida: faltou fechar o parêntese" },
        .{ .src = antigo.zoeira, .cmd = "/mock isso aqui", .enviado = "iSsO aQuI" },
        .{ .src = antigo.zoeira, .cmd = "/palmas isso sim", .enviado = "isso 👏 sim" },
        .{ .src = antigo.zoeira, .cmd = "/contrario açaí", .enviado = "íaça" },
        .{ .src = antigo.zoeira, .cmd = "/vapor ab", .enviado = "ａｂ" },
        .{ .src = antigo.zoeira, .cmd = "/spoiler o fim", .enviado = "||o fim||" },
        .{ .src = antigo.zoeira, .cmd = "/mock", .aviso = "Use assim: /mock isso aqui" },
        .{ .src = antigo.dado, .cmd = "/dado 0d6", .aviso = "Use assim: /dado 2d20+3 (até 50 dados de até 1000 lados)" },
        .{ .src = antigo.dado, .cmd = "/dado banana", .aviso = "Use assim: /dado 2d20+3 (até 50 dados de até 1000 lados)" },
        .{ .src = antigo.dado, .cmd = "/escolhe só uma", .aviso = "Use assim: /escolhe pizza, sushi, lasanha" },
        .{ .src = antigo.relogio, .cmd = "/hora marte", .aviso = "Não conheço \"marte\". Acrescente no começo de relogio.lua" },
        .{ .src = antigo.relogio, .cmd = "/cronometro", .aviso = "⏱ Cronômetro valendo" },
        .{ .src = antigo.resumo, .cmd = "/resumo", .aviso = "Nenhuma mensagem nova desde que o app abriu" },
    };
    for (casos) |caso| {
        var e = T.engine();
        defer e.deinit();
        _ = testOne(&e, caso.src);
        try cmdOk(&e, caso.cmd);
        if (caso.enviado) |t| {
            try std.testing.expectEqual(@as(usize, 1), T.n_sent);
            try std.testing.expectEqualStrings(t, T.sent[0][0..T.sent_len[0]]);
        }
        if (caso.aviso) |t| {
            try std.testing.expectEqual(@as(usize, 1), T.n_notes);
            try std.testing.expectEqualStrings(t, T.note(0));
        }
        try std.testing.expectEqual(@as(usize, 0), T.n_failed);
    }
}

test "plugins: temporizadores acabam com o plugin" {
    var e = T.engine();
    defer e.deinit();
    const p = testOne(&e,
        \\-- @name T
        \\-- @capabilities timers, notify
        \\local n = 0
        \\sigma.after(0.01, function() sigma.notify("depois") end)
        \\local cancelado = sigma.after(0.01, function() sigma.notify("cancelado") end)
        \\sigma.cancel(cancelado)
        \\sigma.command("/longe", function() sigma.after(0.05, function() sigma.notify("não deveria") end) end)
        \\assert(not pcall(sigma.every, 0.1, function() end))
        \\assert(not pcall(sigma.after, "x", function() end))
    );
    try std.testing.expectEqual(Status.running, p.status());
    sync.sleepMs(40);
    e.waitIdle();
    try std.testing.expectEqual(@as(usize, 1), T.n_notes);
    try std.testing.expectEqualStrings("depois", T.note(0));
    try cmdOk(&e, "/longe");
    e.setEnabled(p, false);
    sync.sleepMs(90);
    e.waitIdle();
    try std.testing.expectEqual(@as(usize, 1), T.n_notes);
}

test "plugins: sigma.every repete até cancelar" {
    var e = T.engine();
    defer e.deinit();
    e.budget = 5_000_000;
    const p = testOne(&e,
        \\-- @capabilities timers, notify
        \\sigma.command("/n", function(a) sigma.notify(a) end)
        \\local n = 0
        \\local id
        \\id = sigma.every(1, function()
        \\  n = n + 1
        \\  sigma.notify("tique")
        \\  sigma.cancel(id)
        \\end)
    );
    try std.testing.expectEqual(Status.running, p.status());
    var spins: usize = 0;
    while (T.n_notes == 0 and spins < 3000) : (spins += 1) {
        e.drain();
        sync.sleepMs(1);
    }
    try std.testing.expectEqualStrings("tique", T.note(0));
}

test "plugins: armazenamento persiste entre partidas e tem teto" {
    T.wipeDisk();
    var e = T.engine();
    defer e.deinit();
    const src =
        \\-- @name S
        \\-- @capabilities storage, notify
        \\sigma.command("/grava", function()
        \\  sigma.storage.set("n", 42)
        \\  sigma.storage.set("txt", "olá \"mundo\"\n")
        \\  sigma.storage.set("lista", {1, 2, {a = "b"}})
        \\  sigma.storage.set("apaga", true)
        \\  sigma.storage.delete("apaga")
        \\end)
        \\sigma.command("/le", function()
        \\  local s = sigma.storage
        \\  local l = s.get("lista")
        \\  sigma.notify(tostring(s.get("n")) .. "|" .. tostring(s.get("txt")) .. "|" .. l[3].a .. "|" .. tostring(s.get("apaga")) .. "|" .. #s.keys())
        \\end)
        \\sigma.command("/copia", function()
        \\  local l = sigma.storage.get("lista")
        \\  l[1] = 99
        \\  sigma.notify(tostring(sigma.storage.get("lista")[1]))
        \\end)
        \\sigma.command("/grande", function()
        \\  local bloco = string.rep("x", 400 * 1024)
        \\  sigma.storage.set("a", bloco)
        \\  sigma.storage.set("b", bloco)
        \\  local ok, err = pcall(sigma.storage.set, "c", bloco)
        \\  sigma.notify(tostring(ok) .. " " .. tostring(err):sub(1, 30))
        \\  -- Trocar por algo menor cabe, e o que não deu certo não mudou nada.
        \\  sigma.storage.set("a", "pouco")
        \\  sigma.storage.set("c", bloco)
        \\  sigma.storage.delete("b")
        \\  sigma.storage.delete("c")
        \\  sigma.notify(#sigma.storage.get("a") .. "")
        \\end)
        \\sigma.command("/ruim", function()
        \\  sigma.notify(tostring(pcall(sigma.storage.set, "f", function() end)))
        \\  local ciclo = {}
        \\  ciclo.eu = ciclo
        \\  sigma.notify(tostring(pcall(sigma.storage.set, "c", ciclo)))
        \\  sigma.notify(tostring(pcall(sigma.storage.set, "", 1)))
        \\end)
    ;
    const p = testOne(&e, src);
    try cmdOk(&e, "/grava");
    try cmdOk(&e, "/le");
    try std.testing.expectEqualStrings("42|olá \"mundo\"\n|b|nil|3", T.note(0));
    try cmdOk(&e, "/copia");
    try std.testing.expectEqualStrings("1", T.note(1));
    try cmdOk(&e, "/ruim");
    for (2..5) |i| try std.testing.expectEqualStrings("false", T.note(i));
    // Desligar grava; a próxima partida lê do "disco".
    e.setEnabled(p, false);
    e.waitIdle();
    T.reset();
    e.setEnabled(p, true);
    e.waitIdle();
    try cmdOk(&e, "/le");
    try std.testing.expectEqualStrings("42|olá \"mundo\"\n|b|nil|3", T.note(0));
    T.reset();
    try cmdOk(&e, "/grande");
    try std.testing.expect(std.mem.startsWith(u8, T.note(0), "false"));
    try std.testing.expectEqualStrings("5", T.note(1));
    try std.testing.expectEqual(Status.running, p.status());
}

test "plugins: arquivo de dados ilegível fica guardado e o plugin começa do zero" {
    T.wipeDisk();
    _ = T.writeData(&T.dummy, 1, "t.lua", "{isso não é json");
    var e = T.engine();
    defer e.deinit();
    const p = testOne(&e,
        \\-- @capabilities storage, notify
        \\sigma.notify(tostring(sigma.storage.get("x")))
    );
    try std.testing.expectEqual(Status.running, p.status());
    try std.testing.expectEqual(@as(usize, 1), T.broken);
    try std.testing.expect(std.mem.indexOf(u8, p.err().?, ".bad") != null);
    try std.testing.expectEqualStrings("nil", T.note(0));
}

test "plugins: sigma.json vai e volta" {
    var e = T.engine();
    defer e.deinit();
    const p = testOne(&e,
        \\-- @capabilities notify
        \\local j = sigma.json
        \\assert(j.encode({1, 2, 3}) == "[1,2,3]")
        \\assert(j.encode({a = "x\n"}) == '{"a":"x\\n"}')
        \\assert(j.encode("ã") == '"ã"')
        \\assert(j.encode(true) == "true")
        \\local v = j.decode('{"a": [1, 2.5, {"b": "c\\u00e3\\ud83d\\ude00"}], "n": null, "t": true}')
        \\assert(v.a[1] == 1 and v.a[2] == 2.5 and v.a[3].b == "cã😀" and v.n == nil and v.t == true)
        \\assert(j.decode("[1,") == nil)
        \\local _, err = j.decode("{")
        \\assert(err == "invalid json")
        \\assert(j.decode(string.rep("[", 100) .. string.rep("]", 100)) == nil)
        \\assert(not pcall(j.encode, {1, 2, x = 3}))
        \\assert(not pcall(j.encode, 0/0))
        \\assert(not pcall(j.encode, print))
        \\assert(sigma.urlencode("a b&c/ç") == "a%20b%26c%2F%C3%A7")
        \\sigma.notify("ok")
    );
    if (p.err()) |msg| std.debug.print("{s}\n", .{msg});
    try std.testing.expectEqual(Status.running, p.status());
    try std.testing.expectEqualStrings("ok", T.note(0));
}

test "plugins: sigma.tr segue o idioma" {
    var e = T.engine();
    defer e.deinit();
    const p = testOne(&e,
        \\-- @capabilities notify
        \\sigma.command("/fala", function() sigma.notify(sigma.lang() .. " " .. sigma.tr("oi", "hi")) end)
    );
    try std.testing.expectEqual(Status.running, p.status());
    try cmdOk(&e, "/fala");
    try std.testing.expectEqualStrings("pt oi", T.note(0));
    const S = struct {
        fn en() bool {
            return true;
        }
    };
    const saved = runtime.lang_en;
    runtime.lang_en = &S.en;
    defer runtime.lang_en = saved;
    try cmdOk(&e, "/fala");
    try std.testing.expectEqualStrings("en hi", T.note(1));
    // Em japonês o texto fica em inglês, mas o idioma é o de verdade.
    const J = struct {
        fn code() [*:0]const u8 {
            return "ja";
        }
    };
    const saved_code = runtime.lang_code;
    runtime.lang_code = &J.code;
    defer runtime.lang_code = saved_code;
    try cmdOk(&e, "/fala");
    try std.testing.expectEqualStrings("ja hi", T.note(2));
}

test "plugins: painel chega pronto e os botões voltam ao Lua" {
    var e = T.engine();
    defer e.deinit();
    const p = testOne(&e,
        \\-- @name Painel
        \\-- @capabilities panel, notify, send
        \\local cliques = 0
        \\local function desenha()
        \\  sigma.panel.set({
        \\    title = "T" .. cliques,
        \\    {type = "heading", text = "H"},
        \\    {type = "text", text = "texto", style = "muted"},
        \\    {type = "input", key = "campo", placeholder = "dica", value = "v",
        \\      on_change = function(v) sigma.notify("mudou " .. v) end,
        \\      on_submit = function(v) sigma.send(nil, "enviei " .. v) end},
        \\    {type = "row",
        \\      {type = "button", label = "A", on_click = function() cliques = cliques + 1; desenha() end},
        \\      {type = "button", label = "B", style = "danger", on_click = function() sigma.panel.close() end},
        \\    },
        \\    {type = "bar", label = "ana", value = 3, max = 10, text = "3"},
        \\    {type = "separator"},
        \\    {type = "list", empty = "nada", items = {
        \\      {title = "item", subtitle = "sub", meta = "m", on_click = function() sigma.notify("item") end,
        \\        actions = {{label = "x", on_click = function() sigma.notify("ação") end}}},
        \\    }},
        \\  })
        \\end
        \\desenha()
        \\sigma.command("/abre", function() desenha(); sigma.panel.open() end)
        \\sigma.command("/ruim", function()
        \\  sigma.notify(tostring(pcall(sigma.panel.set, {{type = "foguete"}})))
        \\  sigma.notify(tostring(pcall(sigma.panel.set, {{type = "input"}})))
        \\  sigma.notify(tostring(pcall(sigma.panel.set, {"texto"})))
        \\end)
        \\sigma.on("ready", function() pcall(sigma.panel.open) end)
    );
    if (p.err()) |msg| std.debug.print("{s}\n", .{msg});
    try std.testing.expectEqual(Status.running, p.status());
    const t = p.tree orelse return error.SemArvore;
    try std.testing.expectEqualStrings("T0", t.title);
    const n = t.nodes.items;
    try std.testing.expectEqual(panel.Kind.heading, n[t.first].kind);
    const Find = struct {
        fn by(tree: *panel.Tree, kind: panel.Kind, text: []const u8) *panel.Node {
            for (tree.nodes.items) |*x| if (x.kind == kind and std.mem.eql(u8, x.text, text)) return x;
            unreachable;
        }
    };
    const a = Find.by(t, .button, "A");
    try std.testing.expect(a.click != 0);
    try std.testing.expectEqual(panel.Style.danger, Find.by(t, .button, "B").style);
    try std.testing.expectEqualStrings("sub", Find.by(t, .item, "item").sub);
    try std.testing.expectEqual(panel.Kind.button, n[Find.by(t, .item, "item").child].kind);
    const click_item = Find.by(t, .item, "item").click;
    const click_action = Find.by(t, .button, "x").click;
    // Sem pedir, o painel não abre (nem no "ready", que não é gesto).
    e.fireReady();
    e.waitIdle();
    try std.testing.expect(e.panel_open == null);
    try cmdOk(&e, "/abre");
    try std.testing.expect(e.panel_open == p);
    // A árvore anterior morreu; a função de agora roda.
    const t2 = p.tree.?;
    e.panelGesture(p, click_item, null);
    e.panelGesture(p, click_action, null);
    e.waitIdle();
    try std.testing.expectEqualStrings("item", T.note(0));
    try std.testing.expectEqualStrings("ação", T.note(1));
    // O campo: digitar não é gesto; Enter é.
    var inp: *panel.Node = undefined;
    for (t2.nodes.items) |*x| if (x.kind == .input) {
        inp = x;
    };
    try std.testing.expectEqualStrings("v", inp.meta);
    e.panelChange(p, inp.change, "ab");
    e.waitIdle();
    try std.testing.expectEqualStrings("mudou ab", T.note(2));
    e.panelGesture(p, inp.submit, "tudo");
    e.waitIdle();
    try std.testing.expectEqualStrings("enviei tudo", T.sent[0][0..T.sent_len[0]]);
    // Um clique em "A" republica: a função de quem clicou ainda valia.
    const tb = Find.by(t2, .button, "A").click;
    e.panelGesture(p, tb, null);
    e.waitIdle();
    try std.testing.expectEqualStrings("T1", p.tree.?.title);
    // Fechar é da interface e do plugin.
    e.panelGesture(p, Find.by(p.tree.?, .button, "B").click, null);
    e.waitIdle();
    try std.testing.expect(e.panel_open == null);
    T.reset();
    try cmdOk(&e, "/ruim");
    for (0..3) |i| try std.testing.expectEqualStrings("false", T.note(i));
    // Desligou: o painel some.
    e.setEnabled(p, false);
    try std.testing.expect(p.tree == null);
}

test "plugins: menus e decoração, com o plugin parado levando tudo" {
    var e = T.engine();
    defer e.deinit();
    const p = testOne(&e,
        \\-- @name M
        \\-- @capabilities menu, decorate, notify
        \\sigma.menu("message", {pt = "Marcar", en = "Mark"}, function(m)
        \\  sigma.decorate(m, {badge = "ok", note = m.content})
        \\  sigma.notify(m.author.name .. ":" .. m.id)
        \\end)
        \\sigma.menu("user", "Pessoa", function(u) sigma.notify(u.id .. "=" .. u.name) end)
        \\sigma.command("/regras", function()
        \\  sigma.rules({ {word = "SPOILER", collapse = true, label = "fora"}, {user = "9", badge = "!"} })
        \\end)
        \\sigma.command("/tira", function() sigma.undecorate("10") end)
        \\sigma.command("/ruim", function()
        \\  sigma.notify(tostring(pcall(sigma.menu, "canal", "x", print)))
        \\  sigma.notify(tostring(pcall(sigma.decorate, "", {})))
        \\  sigma.notify(tostring(pcall(sigma.rules, {"nada"})))
        \\end)
    );
    try std.testing.expectEqual(Status.running, p.status());
    try std.testing.expectEqual(@as(usize, 2), p.menus.items.len);
    try std.testing.expectEqualStrings("Marcar", p.menus.items[0].pt);
    try std.testing.expectEqualStrings("Mark", p.menus.items[0].en);
    const m: Message = .{ .id = 10, .content = "oi", .author = 1, .author_name = "ana", .channel = 42, .channel_name = "geral" };
    e.menuMessage(p, &p.menus.items[0], &m, null);
    e.waitIdle();
    try std.testing.expectEqualStrings("ana:10", T.note(0));
    var sm: @import("../core/store.zig").StoredMessage = .{ .msg = .{ .id = 10, .channel = 42, .author = 2, .timestamp = 0, .content = "oi" }, .spans = &.{} };
    try std.testing.expect(e.deco.active());
    var v = e.deco.view(&sm, 1);
    try std.testing.expectEqualStrings("ok", v.slice()[0].badge);
    try std.testing.expectEqualStrings("oi", v.slice()[0].note);
    e.menuUser(p, &p.menus.items[1], 77, "bia", null);
    e.waitIdle();
    try std.testing.expectEqualStrings("77=bia", T.note(1));
    try cmdOk(&e, "/tira");
    try std.testing.expect(!e.deco.active());
    try cmdOk(&e, "/regras");
    var sp: @import("../core/store.zig").StoredMessage = .{ .msg = .{ .id = 11, .channel = 42, .author = 2, .timestamp = 0, .content = "um spoiler aqui" }, .spans = &.{} };
    try std.testing.expect(e.deco.collapses(&sp, 1));
    try cmdOk(&e, "/ruim");
    for (2..5) |i| try std.testing.expectEqualStrings("false", T.note(i));
    e.setEnabled(p, false);
    try std.testing.expect(!e.deco.active());
    try std.testing.expect(!e.deco.collapses(&sp, 1));
}

test "plugins: apagar uma mensagem leva a nota junto e avisa quem pediu" {
    var e = T.engine();
    defer e.deinit();
    const p = testOne(&e,
        \\-- @capabilities decorate, messages, notify
        \\sigma.command("/d", function() sigma.decorate("10", {note = "texto"}) end)
        \\sigma.on("delete", function(d) sigma.notify("apagou " .. d.id .. " em " .. d.channel) end)
    );
    try std.testing.expectEqual(Status.running, p.status());
    try cmdOk(&e, "/d");
    try std.testing.expect(e.deco.active());
    e.onDelete(42, 10);
    e.waitIdle();
    try std.testing.expect(!e.deco.active());
    try std.testing.expectEqualStrings("apagou 10 em 42", T.note(0));
}

test "plugins: mensagens carregadas chegam numa cópia" {
    var e = T.engine();
    defer e.deinit();
    const list = [_]Message{
        .{ .id = 1, .content = "um", .author = 5, .author_name = "ana", .channel = 42, .channel_name = "geral", .timestamp = 100 },
        .{ .id = 2, .content = "dois", .author = 6, .author_name = "bia", .channel = 42, .channel_name = "geral", .timestamp = 200, .attachments = 1 },
    };
    T.loaded = &list;
    const p = testOne(&e,
        \\-- @capabilities messages, notify
        \\sigma.command("/le", function()
        \\  local ok = sigma.messages({limit = 10}, function(l)
        \\    sigma.notify(#l .. " " .. l[1].content .. " " .. l[2].author.name .. " " .. l[2].time .. " " .. l[2].attachments)
        \\  end)
        \\  sigma.notify(tostring(ok))
        \\end)
        \\sigma.command("/seguido", function()
        \\  sigma.notify(tostring(sigma.messages(function() end)))
        \\end)
    );
    try std.testing.expectEqual(Status.running, p.status());
    try cmdOk(&e, "/le");
    e.waitIdle();
    try std.testing.expectEqualStrings("true", T.note(0));
    try std.testing.expectEqualStrings("2 um bia 200 1", T.note(1));
    // Pedir de novo logo em seguida não vai.
    try cmdOk(&e, "/seguido");
    try std.testing.expectEqualStrings("false", T.note(2));
}

test "plugins: HTTP só com host declarado e aprovado, e sem cabeçalhos da conta" {
    var e = T.engine();
    defer e.deinit();
    const p = testOne(&e,
        \\-- @name H
        \\-- @capabilities http, notify, send
        \\-- @hosts api.exemplo.com
        \\local function resposta(r)
        \\  sigma.notify(tostring(r.ok) .. "|" .. tostring(r.status) .. "|" .. tostring(r.error) .. "|" .. r.body)
        \\  if r.ok and r.body == "manda" then sigma.send(nil, "automático") end
        \\end
        \\sigma.command("/get", function() sigma.http.get("https://api.exemplo.com/x?q=1", resposta) end)
        \\sigma.command("/post", function()
        \\  sigma.http.post("https://api.exemplo.com/y", {body = "corpo", headers = {
        \\    ["Content-Type"] = "text/plain", Cookie = "a=b", Authorization = "x",
        \\    ["X-Super-Properties"] = "z", Accept = "a\r\nCookie: b"}}, resposta)
        \\end)
        \\sigma.command("/fora", function()
        \\  sigma.notify(tostring(pcall(sigma.http.get, "https://outro.com/", resposta)))
        \\  sigma.notify(tostring(pcall(sigma.http.get, "http://api.exemplo.com/", resposta)))
        \\  sigma.notify(tostring(pcall(sigma.http.get, "https://u:s@api.exemplo.com/", resposta)))
        \\  sigma.notify(tostring(pcall(sigma.http.get, "https://api.exemplo.com:8443/", resposta)))
        \\  sigma.notify(sigma.http.allowed("api.exemplo.com") and "sim" or "não")
        \\end)
    );
    try std.testing.expectEqual(Status.running, p.status());
    // Sem aprovação nada sai, e o plugin fica sabendo (sem morrer por isso).
    try cmdOk(&e, "/get");
    try std.testing.expectEqual(@as(usize, 0), T.http_n);
    try std.testing.expectEqualStrings("false|0|not_approved|", T.note(0));
    T.reset();
    try cmdOk(&e, "/fora");
    for (0..4) |i| try std.testing.expectEqualStrings("false", T.note(i));
    try std.testing.expectEqualStrings("não", T.note(4));
    T.reset();
    e.setApproved(p, "api.exemplo.com", true);
    try std.testing.expect(e.isApproved("t.lua", "api.exemplo.com"));
    try cmdOk(&e, "/get");
    try std.testing.expectEqual(@as(usize, 1), T.http_n);
    try std.testing.expectEqualStrings("https://api.exemplo.com/x?q=1", T.http_reqs[0].?.url);
    try std.testing.expect(!T.http_reqs[0].?.post);
    // A resposta chega fora de um gesto: mandar mensagem não vale.
    T.respond(200, "manda");
    e.waitIdle();
    try std.testing.expectEqualStrings("true|200|nil|manda", T.note(0));
    try std.testing.expectEqual(@as(usize, 0), T.n_sent);
    try std.testing.expect(std.mem.indexOf(u8, p.err().?, "sigma.send") != null);
    // Só os cabeçalhos da lista, e sem quebra de linha.
    try cmdOk(&e, "/post");
    const req = T.http_reqs[0].?;
    try std.testing.expect(req.post);
    try std.testing.expectEqualStrings("corpo", req.body);
    try std.testing.expectEqual(@as(usize, 1), req.headers.len);
    try std.testing.expectEqualStrings("Content-Type: text/plain", req.headers[0]);
    T.respond(500, "");
    e.waitIdle();
    // Tirou a aprovação: vale para o próximo pedido.
    T.reset();
    e.setApproved(p, "api.exemplo.com", false);
    e.waitIdle();
    try cmdOk(&e, "/get");
    try std.testing.expectEqualStrings("false|0|not_approved|", T.note(0));
    try std.testing.expectEqual(@as(usize, 0), T.http_n);
}

test "plugins: HTTP tem limite por plugin" {
    var e = T.engine();
    defer e.deinit();
    const p = testOne(&e,
        \\-- @capabilities http, notify
        \\-- @hosts api.exemplo.com
        \\sigma.command("/rajada", function()
        \\  for i = 1, 5 do
        \\    sigma.http.get("https://api.exemplo.com/" .. i, function(r)
        \\      if r.error then sigma.notify(r.error) end
        \\    end)
        \\  end
        \\end)
    );
    try std.testing.expectEqual(Status.running, p.status());
    e.setApproved(p, "api.exemplo.com", true);
    e.waitIdle();
    try cmdOk(&e, "/rajada");
    // Três no ar; os outros dois recusados na hora.
    try std.testing.expectEqual(@as(usize, 3), T.http_n);
    try std.testing.expectEqual(@as(usize, 2), T.n_notes);
    try std.testing.expectEqualStrings("rate_limited", T.note(0));
    T.respond(200, "");
    T.respond(200, "");
    T.respond(200, "");
    e.waitIdle();
}

test "plugins: um plugin parado não atrapalha o outro" {
    var e = T.engine();
    defer e.deinit();
    e.budget = 200_000;
    e.load(&.{
        .{ .name = "a.lua", .src = "sigma.command('/a', function() while true do end end)" },
        .{ .name = "b.lua", .src = "sigma.command('/b', function() sigma.notify('b vivo') end)" },
    }, false);
    e.waitIdle();
    try cmdOk(&e, "/a");
    try std.testing.expectEqual(Status.failed, e.list.items[0].status());
    try cmdOk(&e, "/b");
    try std.testing.expectEqualStrings("b vivo", T.note(0));
}

test "plugins: uma rajada de mensagens não cresce sem limite" {
    var e = T.engine();
    defer e.deinit();
    const p = testOne(&e,
        \\sigma.on("message", function(m) end)
        \\sigma.command("/fim", function() sigma.notify("vivo") end)
    );
    try std.testing.expectEqual(Status.running, p.status());
    const m: Message = .{ .content = "x", .author = 1, .author_name = "a", .channel = 42, .channel_name = "g" };
    for (0..10_000) |_| e.onMessage(&m);
    e.waitIdle();
    try cmdOk(&e, "/fim");
    try std.testing.expectEqualStrings("vivo", T.note(0));
}

test "plugins: trocar de conta reinicia, cada um com os seus dados" {
    T.wipeDisk();
    var e = T.engine();
    defer e.deinit();
    const p = testOne(&e, "-- @capabilities notify\nsigma.notify('subiu')\nsigma.command('/x', function() end)");
    try std.testing.expectEqual(@as(usize, 1), T.n_notes);
    try std.testing.expectEqual(@as(u32, 1), e.n_commands);
    e.setAccount(0);
    try std.testing.expectEqual(Status.waiting, p.status());
    try std.testing.expectEqual(@as(u32, 0), e.n_commands);
    e.setAccount(2);
    e.waitIdle();
    try std.testing.expectEqual(@as(usize, 2), T.n_notes);
    try std.testing.expectEqual(@as(u32, 1), e.n_commands);
}

test "plugins: escolhas vão e voltam pelo plugins.kdl" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    {
        var e = T.engine();
        defer e.deinit();
        e.setDisabledName("velho.lua");
        const p = testOne(&e, "-- @capabilities panel, http\n-- @hosts api.exemplo.com\nsigma.panel.set({})");
        e.setApproved(p, "api.exemplo.com", true);
        e.panel_left = true;
        e.panel_w = 412;
        e.openPanel(p);
        try e.writePrefs(std.testing.allocator, &out);
    }
    const nodes = try kdl.parse(arena.allocator(), out.items, null);
    var e = T.engine();
    defer e.deinit();
    for (nodes) |*n| e.applyPrefNode(n);
    try std.testing.expect(e.disabled.contains("velho.lua"));
    try std.testing.expect(e.isApproved("t.lua", "api.exemplo.com"));
    try std.testing.expect(!e.isApproved("t.lua", "outro.com"));
    try std.testing.expect(e.panel_left);
    try std.testing.expectEqual(@as(f32, 412), e.panel_w);
    // O painel que estava aberto volta sozinho quando o plugin publica.
    const p = testOne(&e, "-- @capabilities panel\nsigma.panel.set({})");
    try std.testing.expect(e.panel_open == p);
}

test "plugins: recarregar não fecha o painel, e a lista de hosts vale para o próximo" {
    var e = T.engine();
    defer e.deinit();
    const src = "-- @capabilities panel\nsigma.panel.set({title = 'x'})";
    const p = testOne(&e, src);
    e.openPanel(p);
    const q = testOne(&e, src);
    try std.testing.expect(e.panel_open == q);
}

test "plugins: trocar de idioma redesenha o que o plugin pediu" {
    var e = T.engine();
    defer e.deinit();
    T.wipeDisk();
    const p = testOne(&e, @embedFile("testdata/bookmarks.lua"));
    try std.testing.expectEqualStrings("Favoritos", p.tree.?.title);
    try std.testing.expectEqualStrings("Favoritos", p.title());
    const S = struct {
        fn en() bool {
            return true;
        }
    };
    const saved = runtime.lang_en;
    runtime.lang_en = &S.en;
    defer runtime.lang_en = saved;
    e.frameTick(42, true);
    e.waitIdle();
    try std.testing.expectEqualStrings("Bookmarks", p.tree.?.title);
    try std.testing.expectEqualStrings("Bookmarks", p.title());
}

const Bundled = struct {
    fn src(name: []const u8) []const u8 {
        const exemplos = @import("plugin_examples");
        for (exemplos.list) |ex| if (std.mem.eql(u8, ex.name, name)) return ex.source;
        unreachable;
    }
};

fn chega(e: *Engine, content: []const u8) void {
    const m: Message = .{ .id = 500 + T.n_notes, .content = content, .author = 7, .author_name = "ana", .channel = 42, .channel_name = "geral", .timestamp = 1000 };
    e.onMessage(&m);
    e.waitIdle();
}

test "plugins incluídos: destaques pega a palavra inteira e não grava o texto de ninguém" {
    T.wipeDisk();
    var e = T.engine();
    defer e.deinit();
    const p = testOne(&e, Bundled.src("highlights.lua"));
    try cmdOk(&e, "/highlights Pizza");
    try std.testing.expect(e.panel_open == p);
    chega(&e, "hoje tem pizzaria");
    try std.testing.expectEqual(@as(usize, 0), T.n_notes);
    chega(&e, "quem quer PIZZA, gente?");
    try std.testing.expectEqual(@as(usize, 1), T.n_notes);
    try std.testing.expect(std.mem.indexOf(u8, T.note(0), "pizza") != null);
    // O acento também não atrapalha, e "c++" é uma palavra.
    try cmdOk(&e, "/highlights AÇÃO");
    try cmdOk(&e, "/highlights c++");
    chega(&e, "muita ação");
    try std.testing.expectEqual(@as(usize, 2), T.n_notes);
    chega(&e, "programo em c++ hoje");
    try std.testing.expectEqual(@as(usize, 3), T.n_notes);
    // Parou: gravou no disco a palavra e o lugar, nunca o texto.
    e.setEnabled(p, false);
    e.waitIdle();
    const data = T.readData(&T.dummy, std.testing.allocator, 1, "t.lua").?;
    defer std.testing.allocator.free(data);
    try std.testing.expect(std.mem.indexOf(u8, data, "pizza") != null);
    try std.testing.expect(std.mem.indexOf(u8, data, "quem quer") == null);
}

test "plugins incluídos: lembretes entendem o tempo e voltam depois de reiniciar" {
    T.wipeDisk();
    var e = T.engine();
    defer e.deinit();
    const p = testOne(&e, Bundled.src("reminders.lua"));
    try cmdOk(&e, "/remind depois sem tempo");
    try std.testing.expect(std.mem.indexOf(u8, T.note(0), "/remind 10m") != null);
    try cmdOk(&e, "/remind 1h30m ligar");
    try std.testing.expect(std.mem.indexOf(u8, T.note(1), "Vou lembrar") != null);
    try cmdOk(&e, "/remind 2h 30m com dois pedaços");
    try cmdOk(&e, "/remind 1s logo");
    var spins: usize = 0;
    while (T.n_notes < 5 and spins < 4000) : (spins += 1) {
        e.drain();
        sync.sleepMs(1);
    }
    try std.testing.expect(std.mem.indexOf(u8, T.note(4), "logo") != null);
    // O lembrete pede a notificação do sistema mesmo com a janela em foco.
    try std.testing.expect(T.notes_desktop[4]);
    // Reiniciou: os dois longos continuam, e nenhum temporizador fica de pé à toa.
    e.setEnabled(p, false);
    e.waitIdle();
    e.setEnabled(p, true);
    e.waitIdle();
    var titles: usize = 0;
    for (p.tree.?.nodes.items) |*n| if (n.kind == .item) {
        titles += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), titles);
}

test "plugins: favoritos sobrevive e não guarda o que foi apagado" {
    T.wipeDisk();
    var e = T.engine();
    defer e.deinit();
    const p = testOne(&e, @embedFile("testdata/bookmarks.lua"));
    const m: Message = .{ .id = 77, .content = "segredo <@123> com <:ok:5>", .author = 7, .author_name = "ana", .channel = 42, .channel_name = "geral", .guild = 3, .guild_name = "S", .timestamp = 1000 };
    e.menuMessage(p, &p.menus.items[0], &m, null);
    e.waitIdle();
    var sm: @import("../core/store.zig").StoredMessage = .{ .msg = .{ .id = 77, .channel = 42, .author = 7, .timestamp = 0, .content = "x" }, .spans = &.{} };
    try std.testing.expectEqualStrings("🔖", e.deco.view(&sm, 1).slice()[0].badge);
    const hasText = struct {
        fn f(t: *panel.Tree, s: []const u8) bool {
            for (t.nodes.items) |*n| if (std.mem.indexOf(u8, n.sub, s) != null) return true;
            return false;
        }
    }.f;
    try std.testing.expect(hasText(p.tree.?, "segredo @… com :ok:"));
    // Reiniciou: continua lá, com o selo.
    e.setEnabled(p, false);
    e.waitIdle();
    try std.testing.expect(!e.deco.active());
    e.setEnabled(p, true);
    e.waitIdle();
    try std.testing.expect(hasText(p.tree.?, "segredo"));
    try std.testing.expect(e.deco.active());
    // Apagaram: some o texto, inclusive do disco.
    e.onDelete(42, 77);
    e.waitIdle();
    try std.testing.expect(!hasText(p.tree.?, "segredo"));
    e.setEnabled(p, false);
    e.waitIdle();
    const data = T.readData(&T.dummy, std.testing.allocator, 1, "t.lua").?;
    defer std.testing.allocator.free(data);
    try std.testing.expect(std.mem.indexOf(u8, data, "segredo") == null);
}

test "plugins: filtro vira regras, e trechos só põem na caixa" {
    T.wipeDisk();
    var e = T.engine();
    defer e.deinit();
    const f = testOne(&e, @embedFile("testdata/filter.lua"));
    const user_entry = for (f.menus.items) |*m| {
        if (m.kind == .user) break m;
    } else unreachable;
    e.menuUser(f, user_entry, 9, "bia", null);
    e.waitIdle();
    var sm: @import("../core/store.zig").StoredMessage = .{ .msg = .{ .id = 5, .channel = 42, .author = 9, .timestamp = 0, .content = "oi" }, .spans = &.{} };
    try std.testing.expect(e.deco.collapses(&sm, 1));
    // Desligou: as regras saem junto.
    e.setEnabled(f, false);
    try std.testing.expect(!e.deco.collapses(&sm, 1));
    e.setEnabled(f, true);
    e.waitIdle();
    try std.testing.expect(e.deco.collapses(&sm, 1));

    T.wipeDisk();
    const s = testOne(&e, @embedFile("testdata/snippets.lua"));
    try cmdOk(&e, "/snip nada");
    try std.testing.expect(std.mem.indexOf(u8, T.note(T.n_notes - 1), "nada") != null);
    const m: Message = .{ .id = 5, .content = "texto", .author = 7, .author_name = "ana", .channel = 42, .channel_name = "geral" };
    e.menuMessage(s, &s.menus.items[0], &m, null);
    e.waitIdle();
    try std.testing.expect(e.panel_open == s);
    try std.testing.expectEqual(@as(usize, 0), T.n_sent);
}

test "plugins incluídos: tradução não sai sem aprovar, e a nota vem da resposta" {
    var e = T.engine();
    defer e.deinit();
    const host_name = "api.mymemory.translated.net";
    e.load(&.{.{ .name = "t.lua", .src = Bundled.src("translate.lua") }}, true);
    e.waitIdle();
    const p = e.list.items[0];
    try std.testing.expect(p.man.declares(host_name));
    const m: Message = .{ .id = 5, .content = "hello <@1> world", .author = 7, .author_name = "ana", .channel = 42, .channel_name = "geral" };
    e.menuMessage(p, &p.menus.items[0], &m, null);
    e.waitIdle();
    try std.testing.expectEqual(@as(usize, 0), T.http_n);
    try std.testing.expect(std.mem.indexOf(u8, T.note(0), host_name) != null);
    e.setApproved(p, host_name, true);
    e.waitIdle();
    e.menuMessage(p, &p.menus.items[0], &m, null);
    e.waitIdle();
    try std.testing.expectEqual(@as(usize, 1), T.http_n);
    const url = T.http_reqs[0].?.url;
    try std.testing.expect(std.mem.startsWith(u8, url, "https://" ++ host_name ++ "/get?q=hello%20%40%E2%80%A6%20world&langpair="));
    try std.testing.expect(std.mem.endsWith(u8, url, "Autodetect%7Cpt"));
    T.respond(200, "{\"responseData\":{\"translatedText\":\"olá\"},\"responseStatus\":200}");
    e.waitIdle();
    var sm: @import("../core/store.zig").StoredMessage = .{ .msg = .{ .id = 5, .channel = 42, .author = 7, .timestamp = 0, .content = "x" }, .spans = &.{} };
    try std.testing.expect(std.mem.indexOf(u8, e.deco.view(&sm, 1).slice()[0].note, "olá") != null);
    // Clicar de novo tira.
    e.menuMessage(p, &p.menus.items[0], &m, null);
    e.waitIdle();
    try std.testing.expect(!e.deco.active());

    // O serviço responde 200 também quando recusa, com o aviso no lugar da tradução
    // (esta é a resposta real dele para uma mensagem já no idioma pedido).
    e.menuMessage(p, &p.menus.items[0], &m, null);
    e.waitIdle();
    T.respond(200, "{\"responseData\":{\"translatedText\":\"PLEASE SELECT TWO DISTINCT LANGUAGES\",\"match\":0},\"responseStatus\":403}");
    e.waitIdle();
    const same = e.deco.view(&sm, 1).slice()[0].note;
    try std.testing.expect(std.mem.indexOf(u8, same, "seu idioma") != null);
    try std.testing.expect(std.mem.indexOf(u8, same, "DISTINCT") == null);
    e.menuMessage(p, &p.menus.items[0], &m, null);
    e.waitIdle();
    try std.testing.expect(!e.deco.active());

    // Qualquer outra recusa vira "não consegui", e nunca o texto do aviso.
    e.menuMessage(p, &p.menus.items[0], &m, null);
    e.waitIdle();
    T.respond(200, "{\"responseData\":{\"translatedText\":\"MYMEMORY WARNING: YOU USED ALL AVAILABLE FREE TRANSLATIONS\",\"match\":0},\"responseStatus\":429}");
    e.waitIdle();
    const refused = e.deco.view(&sm, 1).slice()[0].note;
    try std.testing.expect(std.mem.indexOf(u8, refused, "traduzir") != null);
    try std.testing.expect(std.mem.indexOf(u8, refused, "WARNING") == null);
}

test "plugins incluídos: todos ligam, com cabeçalho completo e nos dois idiomas" {
    const exemplos = @import("plugin_examples");
    T.wipeDisk();
    for (exemplos.list) |ex| {
        var e = T.engine();
        defer e.deinit();
        e.load(&.{.{ .name = ex.name, .src = ex.source }}, true);
        e.waitIdle();
        const p = e.list.items[0];
        if (p.err()) |msg| {
            std.debug.print("{s}: {s}\n", .{ ex.name, msg });
            return error.ExemploQuebrado;
        }
        try std.testing.expectEqual(Status.running, p.status());
        try std.testing.expect(!p.man.legacy);
        try std.testing.expect(p.man.name.len > 0 and p.man.name_pt.len > 0);
        try std.testing.expect(p.man.description.len > 0 and p.man.description_pt.len > 0);
        try std.testing.expect(p.man.version.len > 0);
        // Estes não precisam de painel: menu, regras ou comando.
        const no_panel = std.mem.eql(u8, ex.name, "translate.lua") or std.mem.eql(u8, ex.name, "cleanlinks.lua") or std.mem.eql(u8, ex.name, "github.lua");
        try std.testing.expect(p.tree != null or no_panel);
    }
}


// --- Opções, escolhas de menu e as outras capacidades ----------------------------

fn firstOf(t: *panel.Tree, kind: panel.Kind) *panel.Node {
    for (t.nodes.items) |*n| if (n.kind == kind) return n;
    unreachable;
}

fn nodeKey(t: *panel.Tree, key: []const u8) *panel.Node {
    for (t.nodes.items) |*n| if (std.mem.eql(u8, n.key, key)) return n;
    unreachable;
}

fn hasKey(t: *panel.Tree, key: []const u8) bool {
    for (t.nodes.items) |*n| if (std.mem.eql(u8, n.key, key)) return true;
    return false;
}

fn lastNote() []const u8 {
    return if (T.n_notes > 0) T.note(T.n_notes - 1) else "";
}

fn noteHas(needle: []const u8) bool {
    for (0..T.n_notes) |i| if (std.mem.indexOf(u8, T.note(i), needle) != null) return true;
    return false;
}

test "plugins: sigma.settings publica opções que respondem, e somem ao desligar" {
    T.wipeDisk();
    var e = T.engine();
    defer e.deinit();
    const p = testOne(&e,
        \\-- @capabilities settings, panel, notify
        \\sigma.settings.set({
        \\  { type = "select", key = "lang", label = "Idioma", value = "b",
        \\    options = { { value = "a", label = "A" }, { value = "b", label = "B" } },
        \\    on_change = function(v) sigma.notify("sel:" .. v) end },
        \\  { type = "toggle", key = "on", label = "Ligado", hint = "dica", value = true,
        \\    on_change = function(v) sigma.notify("tog:" .. tostring(v)) end },
        \\})
        \\sigma.command("/painel", function()
        \\  sigma.panel.set({ { type = "text", text = "oi" } })
        \\end)
    );
    try std.testing.expect(p.err() == null);
    const t = p.settings.?;
    try std.testing.expect(t.settings);
    const sel = nodeKey(t, "lang");
    try std.testing.expectEqual(panel.Kind.select, sel.kind);
    try std.testing.expectEqualStrings("b", sel.meta);
    const first_opt = &t.nodes.items[sel.child];
    try std.testing.expectEqual(panel.Kind.option, first_opt.kind);
    try std.testing.expectEqualStrings("a", first_opt.meta);
    try std.testing.expectEqualStrings("B", t.nodes.items[first_opt.next].text);
    const tog = nodeKey(t, "on");
    try std.testing.expectEqual(@as(f32, 1), tog.value);
    e.panelGesture(p, sel.change, "a");
    e.waitIdle();
    try std.testing.expectEqualStrings("sel:a", lastNote());
    e.panelToggle(p, tog.change, false);
    e.waitIdle();
    try std.testing.expectEqualStrings("tog:false", lastNote());
    // Publicar o painel não tira as funções das opções.
    const handle = sel.change;
    try cmdOk(&e, "/painel");
    try cmdOk(&e, "/painel");
    try cmdOk(&e, "/painel");
    try std.testing.expect(p.tree != null);
    e.panelGesture(p, handle, "b");
    e.waitIdle();
    try std.testing.expectEqualStrings("sel:b", lastNote());
    e.setEnabled(p, false);
    try std.testing.expect(p.settings == null);
}

test "plugins: um clique numa opção é gesto, e o select também vale no painel" {
    T.wipeDisk();
    var e = T.engine();
    defer e.deinit();
    const p = testOne(&e,
        \\-- @capabilities panel, composer
        \\sigma.panel.set({
        \\  { type = "select", key = "k", label = "L", value = "a", options = { { value = "a", label = "A" } },
        \\    on_change = function(v) sigma.insert(v) end },
        \\})
    );
    const sel = nodeKey(p.tree.?, "k");
    e.panelGesture(p, sel.change, "a");
    e.waitIdle();
    try std.testing.expectEqualStrings("a", T.inserted[0..T.inserted_len]);
    try std.testing.expect(!p.tree.?.settings);
}

test "plugins: sigma.settings recusa o que não faz sentido, e explica" {
    const cases = [_]struct { src: []const u8, want: []const u8 }{
        .{ .src = "-- @capabilities notify\nsigma.settings.set({})", .want = "settings" },
        .{ .src = "-- @capabilities settings\nsigma.settings.set({ { type = \"select\", label = \"x\" } })", .want = "key" },
        .{ .src = "-- @capabilities settings\nsigma.settings.set({ { type = \"select\", key = \"x\" } })", .want = "options" },
        .{ .src = "-- @capabilities settings\nsigma.settings.set({ { type = \"toggle\", label = \"x\" } })", .want = "key" },
        .{ .src = "-- @capabilities settings\nsigma.settings.set({ { type = \"option\", label = \"x\" } })", .want = "option" },
        .{ .src = "-- @capabilities settings\nsigma.settings.set({ { type = \"voar\" } })", .want = "voar" },
    };
    for (cases) |k| {
        var e = T.engine();
        defer e.deinit();
        const p = testOne(&e, k.src);
        const msg = p.err() orelse return error.DeviaFalhar;
        try std.testing.expect(std.mem.indexOf(u8, msg, k.want) != null);
    }
}

test "plugins: escolhas de menu chegam como segundo argumento" {
    T.wipeDisk();
    var e = T.engine();
    defer e.deinit();
    const p = testOne(&e,
        \\-- @capabilities menu, notify, composer
        \\sigma.menu("message", "Sem lista", function(m, v) sigma.notify("a:" .. tostring(v)) end)
        \\sigma.menu("message", { pt = "Para", en = "To" }, function(m, v)
        \\  sigma.notify("b:" .. m.id .. ":" .. tostring(v))
        \\  sigma.insert(v)
        \\end, { choices = { { value = "es", pt = "Espanhol", en = "Spanish" }, { value = "fr", en = "French" } }, toolbar = "🌐" })
        \\sigma.menu("user", "Pessoa", function(u, v) sigma.notify("c:" .. u.id .. ":" .. tostring(v)) end,
        \\  { choices = { { value = "x", pt = "X" } } })
    );
    try std.testing.expect(p.err() == null);
    const to = &p.menus.items[1];
    try std.testing.expectEqual(@as(usize, 2), to.choices.len);
    try std.testing.expectEqualStrings("es", to.choices[0].value);
    // Rótulo em um idioma só vale para os dois.
    try std.testing.expectEqualStrings("French", to.choices[1].pt);
    try std.testing.expectEqualStrings("🌐", to.toolbar);
    try std.testing.expectEqual(@as(u32, 1), e.n_toolbar);
    const m: Message = .{ .id = 9, .content = "oi", .author = 7, .author_name = "ana", .channel = 42, .channel_name = "geral" };
    e.menuMessage(p, &p.menus.items[0], &m, null);
    e.waitIdle();
    try std.testing.expectEqualStrings("a:nil", lastNote());
    e.menuMessage(p, to, &m, "fr");
    e.waitIdle();
    try std.testing.expectEqualStrings("b:9:fr", lastNote());
    // Escolher é gesto: libera o que pede um.
    try std.testing.expectEqualStrings("fr", T.inserted[0..T.inserted_len]);
    e.menuUser(p, &p.menus.items[2], 33, "bia", "x");
    e.waitIdle();
    try std.testing.expectEqualStrings("c:33:x", lastNote());
    e.setEnabled(p, false);
    try std.testing.expectEqual(@as(u32, 0), e.n_toolbar);
}

test "plugins: sigma.menu confere as escolhas e a barra" {
    var list_src: std.ArrayList(u8) = .empty;
    defer list_src.deinit(std.testing.allocator);
    const a = std.testing.allocator;
    try list_src.appendSlice(a, "-- @capabilities menu\nsigma.menu(\"message\", \"x\", function() end, { choices = {");
    for (0..17) |_| try list_src.appendSlice(a, "{ value = \"a\", pt = \"A\" },");
    try list_src.appendSlice(a, "} })");
    const cases = [_][]const u8{
        list_src.items,
        "-- @capabilities menu\nsigma.menu(\"message\", \"x\", function() end, { choices = { { pt = \"A\" } } })",
        "-- @capabilities menu\nsigma.menu(\"message\", \"x\", function() end, { choices = { 1 } })",
        "-- @capabilities menu\nsigma.menu(\"user\", \"x\", function() end, { toolbar = \"🌐\" })",
    };
    for (cases) |src| {
        var e = T.engine();
        defer e.deinit();
        const p = testOne(&e, src);
        try std.testing.expect(p.err() != null);
    }
}

test "plugins: copiar e abrir só num gesto, e abrir só http com a capacidade" {
    T.wipeDisk();
    var e = T.engine();
    defer e.deinit();
    _ = testOne(&e,
        \\-- @capabilities links, timers, notify
        \\sigma.command("/ok", function()
        \\  sigma.copy("texto")
        \\  sigma.open("https://exemplo.com/a?b=1")
        \\end)
        \\sigma.command("/ruim", function(a) sigma.open(a) end)
        \\sigma.after(0.01, function()
        \\  local ok1 = pcall(sigma.copy, "x")
        \\  local ok2 = pcall(sigma.open, "https://exemplo.com")
        \\  sigma.notify("sozinho:" .. tostring(ok1) .. ":" .. tostring(ok2))
        \\end)
    );
    var spins: usize = 0;
    while (T.n_notes == 0 and spins < 4000) : (spins += 1) {
        e.drain();
        sync.sleepMs(1);
    }
    try std.testing.expectEqualStrings("sozinho:false:false", T.note(0));
    try std.testing.expectEqual(@as(usize, 0), T.copied_len + T.opened_len);
    try cmdOk(&e, "/ok");
    try std.testing.expectEqualStrings("texto", T.copied[0..T.copied_len]);
    try std.testing.expectEqualStrings("https://exemplo.com/a?b=1", T.opened[0..T.opened_len]);
    for ([_][]const u8{ "/ruim file:///etc/passwd", "/ruim javascript:alert(1)", "/ruim https://a.com/com\tcontrole" }) |bad| {
        T.opened_len = 0;
        try cmdOk(&e, bad);
        try std.testing.expectEqual(@as(usize, 0), T.opened_len);
    }
    try std.testing.expect(runtime.validOpenUrl("http://a.com") and !runtime.validOpenUrl("https://") and !runtime.validOpenUrl("HTTPS://a b"));

    const q = testOne(&e, "-- @capabilities notify\nsigma.command(\"/x\", function() sigma.open(\"https://a.com\") end)");
    try cmdOk(&e, "/x");
    try std.testing.expect(std.mem.indexOf(u8, q.err().?, "links") != null);
}

test "plugins: sugestões ficam com a interface, e o gatilho é conferido" {
    T.wipeDisk();
    var e = T.engine();
    defer e.deinit();
    const p = testOne(&e,
        \\-- @capabilities completions
        \\sigma.completions(";", { { name = "oi", text = "olá, tudo bem?", hint = "saudação" }, { name = "tchau", text = "até mais" } })
        \\sigma.command("/troca", function() sigma.completions(";", { { name = "novo", text = "texto novo" } }) end)
    );
    try std.testing.expect(p.err() == null);
    try std.testing.expectEqual(@as(u32, 1), e.n_completions);
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings(";", e.completionTriggers(&buf));
    try std.testing.expectEqualStrings("olá, tudo bem?", e.completionText(p.run, ';', "oi").?);
    try std.testing.expect(e.completionText(p.run, '!', "oi") == null);
    try std.testing.expect(e.completionText(p.run, ';', "nada") == null);
    try cmdOk(&e, "/troca");
    try std.testing.expect(e.completionText(p.run, ';', "oi") == null);
    try std.testing.expectEqualStrings("texto novo", e.completionText(p.run, ';', "novo").?);
    e.setEnabled(p, false);
    try std.testing.expectEqual(@as(u32, 0), e.n_completions);
    e.setEnabled(p, true);
    for ([_][]const u8{
        "-- @capabilities notify\nsigma.completions(\";\", {})",
        "-- @capabilities completions\nsigma.completions(\"@\", {})",
        "-- @capabilities completions\nsigma.completions(\";;\", {})",
        "-- @capabilities completions\nsigma.completions(\";\", { { name = \"x\" } })",
    }) |src| {
        const q = testOne(&e, src);
        try std.testing.expect(q.err() != null);
    }
}

test "plugins: regras de envio valem enquanto o plugin está ligado" {
    T.wipeDisk();
    var e = T.engine();
    defer e.deinit();
    try std.testing.expect(e.rewriteOutgoing("https://a.com/?utm_x=1") == null);
    const p = testOne(&e, Bundled.src("cleanlinks.lua"));
    try std.testing.expect(p.err() == null);
    try std.testing.expectEqual(@as(u32, 1), e.n_rewrite);
    const cases = [_][2][]const u8{
        .{ "veja https://youtu.be/abc?si=xyz&t=30 aí", "veja https://youtu.be/abc?t=30 aí" },
        .{ "https://www.youtube.com/watch?v=abc&si=xyz&pp=abc", "https://www.youtube.com/watch?v=abc" },
        .{ "https://open.spotify.com/track/1?si=2", "https://open.spotify.com/track/1" },
        .{ "https://site.com/a?utm_source=x&fbclid=y&id=3", "https://site.com/a?id=3" },
        .{ "https://x.com/a/status/1?s=20&t=abc", "https://x.com/a/status/1" },
    };
    for (cases) |k| {
        const got = e.rewriteOutgoing(k[0]) orelse return error.NadaMudou;
        defer e.gpa.free(got);
        try std.testing.expectEqualStrings(k[1], got);
    }
    // O `t` e o `s` só saem onde são rastreio.
    try std.testing.expect(e.rewriteOutgoing("https://outro.com/a?s=20&t=abc") == null);
    try std.testing.expect(e.rewriteOutgoing("sem link") == null);
    try std.testing.expect(e.rewriteOutgoing("`https://a.com/?utm_x=1`") == null);
    e.setEnabled(p, false);
    try std.testing.expectEqual(@as(u32, 0), e.n_rewrite);
    try std.testing.expect(e.rewriteOutgoing("https://a.com/?utm_x=1") == null);
}

test "plugins: sigma.rewrite confere as regras, e dois plugins somam" {
    T.wipeDisk();
    var e = T.engine();
    defer e.deinit();
    for ([_][]const u8{
        "-- @capabilities notify\nsigma.rewrite({})",
        "-- @capabilities rewrite\nsigma.rewrite({ {} })",
        "-- @capabilities rewrite\nsigma.rewrite({ { strip_params = { \"a b\" } } })",
        "-- @capabilities rewrite\nsigma.rewrite({ { replace_host = \"a.com\", with = \"https://b.com\" } })",
        "-- @capabilities rewrite\nsigma.rewrite({ { word = \"duas palavras\", with = \"x\" } })",
        "-- @capabilities rewrite\nsigma.rewrite({ { word = \"x\" } })",
        "-- @capabilities rewrite\nsigma.rewrite({ { word = \"x\", with = \"@everyone\" } })",
        "-- @capabilities rewrite\nsigma.rewrite({ { word = \"x\", with = \"https://a.com\" } })",
    }) |src| {
        const q = testOne(&e, src);
        try std.testing.expect(q.err() != null);
    }
    e.load(&.{
        .{ .name = "a.lua", .src = "-- @capabilities rewrite\nsigma.rewrite({ { word = \"vc\", with = \"você\" } })" },
        .{ .name = "b.lua", .src = "-- @capabilities rewrite\nsigma.rewrite({ { replace_host = \"a.com\", with = \"b.com\" } })" },
    }, false);
    e.waitIdle();
    const got = e.rewriteOutgoing("vc viu https://a.com/x") orelse return error.NadaMudou;
    defer e.gpa.free(got);
    try std.testing.expectEqualStrings("você viu https://b.com/x", got);
}

test "plugins: sigma.on(\"edit\") traz só o texto novo, e pede a capacidade" {
    T.wipeDisk();
    var e = T.engine();
    defer e.deinit();
    const p = testOne(&e, "-- @capabilities messages, notify\nsigma.on(\"edit\", function(m) sigma.notify(m.id .. \":\" .. m.content) end)");
    try std.testing.expectEqual(@as(u32, 1), e.n_edit);
    const m: Message = .{ .id = 3, .content = "novo", .author = 7, .author_name = "ana", .channel = 42, .channel_name = "geral" };
    e.onEdit(&m);
    e.waitIdle();
    try std.testing.expectEqualStrings("3:novo", lastNote());
    e.setEnabled(p, false);
    try std.testing.expectEqual(@as(u32, 0), e.n_edit);
    e.setEnabled(p, true);
    const q = testOne(&e, "-- @capabilities notify\nsigma.on(\"edit\", function() end)");
    try std.testing.expect(std.mem.indexOf(u8, q.err().?, "messages") != null);
}

test "plugins: com a fila atrasada, o lento perde mensagens e o rápido não" {
    T.wipeDisk();
    var e = T.engine();
    defer e.deinit();
    e.load(&.{
        .{ .name = "lento.lua", .src =
        \\-- @capabilities messages
        \\sigma.on("message", function()
        \\  local x = 0
        \\  for i = 1, 1000000 do x = x + i end
        \\end)
        },
        .{ .name = "rapido.lua", .src =
        \\-- @capabilities messages, notify
        \\local n = 0
        \\sigma.on("message", function(m)
        \\  n = n + 1
        \\  if m.content == "fim" then sigma.notify("total:" .. n) end
        \\end)
        },
    }, false);
    e.waitIdle();
    const slow = e.list.items[0];
    const quick = e.list.items[1];
    try std.testing.expect(slow.err() == null and quick.err() == null);
    const m: Message = .{ .id = 3, .content = "oi", .author = 7, .author_name = "ana", .channel = 42, .channel_name = "geral" };
    // Algumas sozinhas, para saber quanto ele custa.
    for (0..4) |_| {
        e.onMessage(&m);
        e.waitIdle();
    }
    for (0..400) |_| e.onMessage(&m);
    const end: Message = .{ .id = 4, .content = "fim", .author = 7, .author_name = "ana", .channel = 42, .channel_name = "geral" };
    e.onMessage(&end);
    e.waitIdle();
    try std.testing.expectEqualStrings("total:405", lastNote());
    try std.testing.expect(slow.shedCount() > 0);
    try std.testing.expectEqual(@as(u32, 0), quick.shedCount());
}

test "plugins: a resposta de um pedido feito num gesto pode pôr texto na caixa, nunca enviar" {
    T.wipeDisk();
    var e = T.engine();
    defer e.deinit();
    const host_name = "api.exemplo.com";
    const p = testOne(&e,
        \\-- @capabilities http, composer, send, notify, timers
        \\-- @hosts api.exemplo.com
        \\sigma.command("/pede", function()
        \\  sigma.http.get("https://api.exemplo.com/a", function(res)
        \\    sigma.insert("veio:" .. res.body)
        \\    local ok = pcall(sigma.send, nil, "não pode")
        \\    sigma.notify("send:" .. tostring(ok))
        \\  end)
        \\end)
        \\sigma.command("/sozinho", function()
        \\  sigma.after(0.01, function()
        \\    sigma.http.get("https://api.exemplo.com/b", function(res)
        \\      local ok = pcall(sigma.insert, "x")
        \\      sigma.notify("insert:" .. tostring(ok))
        \\    end)
        \\  end)
        \\end)
    );
    e.setApproved(p, host_name, true);
    e.waitIdle();
    try cmdOk(&e, "/pede");
    try std.testing.expectEqual(@as(usize, 1), T.http_n);
    T.respond(200, "ok");
    e.waitIdle();
    try std.testing.expectEqualStrings("veio:ok", T.inserted[0..T.inserted_len]);
    try std.testing.expectEqualStrings("send:false", lastNote());
    try std.testing.expectEqual(@as(usize, 0), T.n_sent);
    // Pedido que não veio de um gesto: nada na caixa.
    T.inserted_len = 0;
    try cmdOk(&e, "/sozinho");
    var spins: usize = 0;
    while (T.http_n == 0 and spins < 4000) : (spins += 1) {
        e.drain();
        sync.sleepMs(1);
    }
    T.respond(200, "ok");
    e.waitIdle();
    try std.testing.expectEqualStrings("insert:false", lastNote());
    try std.testing.expectEqual(@as(usize, 0), T.inserted_len);
}

test "plugins: arquivos das mensagens só para quem pede" {
    T.wipeDisk();
    var e = T.engine();
    defer e.deinit();
    const files = [_]FileRef{.{ .name = "foto.png", .url = "https://cdn.exemplo.com/foto.png", .size = 2048 }};
    const msgs = [_]Message{.{ .id = 3, .content = "oi", .author = 7, .author_name = "ana", .channel = 42, .channel_name = "geral", .attachments = 1, .files = &files }};
    T.loaded = &msgs;
    _ = testOne(&e,
        \\-- @capabilities messages, notify
        \\sigma.command("/com", function()
        \\  sigma.messages({ files = true }, function(list)
        \\    local f = list[1].files[1]
        \\    sigma.notify(f.name .. ":" .. f.url .. ":" .. f.size)
        \\  end)
        \\end)
        \\sigma.command("/sem", function()
        \\  sigma.messages(function(list) sigma.notify("files:" .. tostring(list[1].files)) end)
        \\end)
    );
    try cmdOk(&e, "/com");
    try std.testing.expectEqualStrings("foto.png:https://cdn.exemplo.com/foto.png:2048", lastNote());
    sync.sleepMs(520);
    try cmdOk(&e, "/sem");
    try std.testing.expectEqualStrings("files:nil", lastNote());
}

test "plugins: número na etiqueta do painel" {
    T.wipeDisk();
    var e = T.engine();
    defer e.deinit();
    const p = testOne(&e,
        \\-- @capabilities panel
        \\sigma.panel.set({ badge = "3", { type = "text", text = "oi" } })
        \\sigma.command("/lido", function() sigma.panel.set({ { type = "text", text = "oi" } }) end)
    );
    try std.testing.expectEqualStrings("3", p.tree.?.badge);
    try std.testing.expectEqual(@as(u32, 1), e.n_badges);
    try cmdOk(&e, "/lido");
    try std.testing.expectEqual(@as(u32, 0), e.n_badges);
}

test "plugins incluídos: tradução escolhe os idiomas pela página e pelo menu" {
    T.wipeDisk();
    var e = T.engine();
    defer e.deinit();
    const host_name = "api.mymemory.translated.net";
    const p = testOne(&e, Bundled.src("translate.lua"));
    try std.testing.expect(p.err() == null);
    e.setApproved(p, host_name, true);
    e.waitIdle();
    const m: Message = .{ .id = 5, .content = "hello", .author = 7, .author_name = "ana", .channel = 42, .channel_name = "geral" };
    var sm: @import("../core/store.zig").StoredMessage = .{ .msg = .{ .id = 5, .channel = 42, .author = 7, .timestamp = 0, .content = "x" }, .spans = &.{} };
    const urlHas = struct {
        fn f(needle: []const u8) bool {
            return std.mem.indexOf(u8, T.http_reqs[0].?.url, needle) != null;
        }
    }.f;
    // A página: as duas listas, com "automático" e os 15 idiomas.
    const target = nodeKey(p.settings.?, "target");
    try std.testing.expectEqualStrings("auto", target.meta);
    try std.testing.expectEqualStrings("auto", nodeKey(p.settings.?, "source").meta);
    var rows: usize = 0;
    var o = target.child;
    while (o != panel.none) : (o = p.settings.?.nodes.items[o].next) rows += 1;
    try std.testing.expectEqual(@as(usize, 16), rows);
    e.panelGesture(p, target.change, "es");
    e.waitIdle();
    e.menuMessage(p, &p.menus.items[0], &m, null);
    e.waitIdle();
    try std.testing.expect(urlHas("langpair=Autodetect%7Ces"));
    // O idioma aparece na nota, e as marcas do serviço saem.
    T.respond(200, "{\"responseData\":{\"translatedText\":\"<g id=\\\"1\\\">hola</g> &#39;amigo&#39;\"},\"responseStatus\":200}");
    e.waitIdle();
    try std.testing.expectEqualStrings("🌐 ES · hola 'amigo'", e.deco.view(&sm, 1).slice()[0].note);
    e.menuMessage(p, &p.menus.items[0], &m, null);
    e.waitIdle();
    try std.testing.expect(!e.deco.active());

    // A origem muda a primeira metade do par.
    e.panelGesture(p, nodeKey(p.settings.?, "source").change, "en");
    e.waitIdle();
    e.menuMessage(p, &p.menus.items[0], &m, null);
    e.waitIdle();
    try std.testing.expect(urlHas("langpair=en%7Ces"));
    T.respond(200, "{\"responseData\":{\"translatedText\":\"PLEASE SELECT TWO DISTINCT LANGUAGES\"},\"responseStatus\":403}");
    e.waitIdle();
    try std.testing.expect(std.mem.indexOf(u8, e.deco.view(&sm, 1).slice()[0].note, "nesse idioma") != null);

    // O menu: só esta mensagem, a página continua como está (e troca a nota que estava).
    const to = &p.menus.items[1];
    try std.testing.expectEqual(@as(usize, 15), to.choices.len);
    e.menuMessage(p, to, &m, "zh-CN");
    e.waitIdle();
    try std.testing.expect(urlHas("langpair=en%7Czh-CN"));
    T.respond(200, "{\"responseData\":{\"translatedText\":\"你好\"},\"responseStatus\":200}");
    e.waitIdle();
    try std.testing.expectEqualStrings("🌐 ZH-CN · 你好", e.deco.view(&sm, 1).slice()[0].note);
    e.menuMessage(p, &p.menus.items[0], &m, null);
    e.waitIdle();
    try std.testing.expect(!e.deco.active());
    e.menuMessage(p, &p.menus.items[0], &m, null);
    e.waitIdle();
    try std.testing.expect(urlHas("langpair=en%7Ces"));
    T.respond(200, "{\"responseData\":{\"translatedText\":\"hola\"},\"responseStatus\":200}");
    e.waitIdle();

    // Reiniciou: a escolha continua.
    e.setEnabled(p, false);
    e.waitIdle();
    e.setEnabled(p, true);
    e.waitIdle();
    try std.testing.expectEqualStrings("es", nodeKey(p.settings.?, "target").meta);
    try std.testing.expectEqualStrings("en", nodeKey(p.settings.?, "source").meta);
    try std.testing.expect(p.man.has(.settings) and p.man.has(.composer));
}

test "plugins incluídos: tradução com /tr vai para a caixa, e nunca é enviada" {
    T.wipeDisk();
    var e = T.engine();
    defer e.deinit();
    const host_name = "api.mymemory.translated.net";
    const p = testOne(&e, Bundled.src("translate.lua"));
    // Sem aprovar: nada sai.
    try cmdOk(&e, "/tr es bom dia");
    try std.testing.expectEqual(@as(usize, 0), T.http_n);
    try std.testing.expect(noteHas(host_name));
    e.setApproved(p, host_name, true);
    e.waitIdle();
    try cmdOk(&e, "/tr ES bom dia");
    try std.testing.expect(std.mem.indexOf(u8, T.http_reqs[0].?.url, "q=bom%20dia&langpair=Autodetect%7Ces") != null);
    T.respond(200, "{\"responseData\":{\"translatedText\":\"buenos días\"},\"responseStatus\":200}");
    e.waitIdle();
    try std.testing.expectEqualStrings("buenos días", T.inserted[0..T.inserted_len]);
    try std.testing.expectEqual(@as(usize, 0), T.n_sent);
    // Sem código de idioma: o texto inteiro, para o idioma da página.
    T.inserted_len = 0;
    try cmdOk(&e, "/tr bom dia gente");
    try std.testing.expect(std.mem.indexOf(u8, T.http_reqs[0].?.url, "q=bom%20dia%20gente&langpair=Autodetect%7Cpt") != null);
    T.respond(200, "{\"responseData\":{\"translatedText\":\"MYMEMORY WARNING\"},\"responseStatus\":429}");
    e.waitIdle();
    try std.testing.expectEqual(@as(usize, 0), T.inserted_len);
    try std.testing.expect(noteHas("Não consegui"));
    try cmdOk(&e, "/tr");
    try std.testing.expect(noteHas("/tr es"));
}

test "plugins incluídos: lembretes entendem horário, repetição e a segunda lista" {
    T.wipeDisk();
    var e = T.engine();
    defer e.deinit();
    const p = testOne(&e, Bundled.src("reminders.lua"));
    const items = struct {
        fn count(t: *panel.Tree) usize {
            var n: usize = 0;
            for (t.nodes.items) |*x| if (x.kind == .item) {
                n += 1;
            };
            return n;
        }
    }.count;
    for ([_][]const u8{ "/remind 15:30 a", "/remind 15h30 b", "/remind às 15h c", "/remind amanhã 9h d", "/remind tomorrow 9am e", "/remind amanhã f", "/remind 9:30pm g" }) |cmd| {
        const before = items(p.tree.?);
        try cmdOk(&e, cmd);
        try std.testing.expectEqual(before + 1, items(p.tree.?));
    }
    for ([_][]const u8{ "/remind 25:00 x", "/remind às x", "/remind hoje x", "/remind todo dia x" }) |cmd| {
        const before = items(p.tree.?);
        try cmdOk(&e, cmd);
        try std.testing.expectEqual(before, items(p.tree.?));
        try std.testing.expect(std.mem.indexOf(u8, lastNote(), "/remind 10m") != null);
    }
    // Todo dia: mostra o sinal de repetição, e continua lá depois de reiniciar.
    try cmdOk(&e, "/remind todo dia 8:30 reunião");
    const hasRepeat = struct {
        fn f(t: *panel.Tree) bool {
            for (t.nodes.items) |*x| if (std.mem.indexOf(u8, x.text, "🔁 reunião") != null) return true;
            return false;
        }
    }.f;
    try std.testing.expect(hasRepeat(p.tree.?));
    e.setEnabled(p, false);
    e.waitIdle();
    e.setEnabled(p, true);
    e.waitIdle();
    try std.testing.expect(hasRepeat(p.tree.?));

    // O menu: a segunda lista cria direto, e "Outro tempo…" abre o painel.
    const entry = &p.menus.items[0];
    try std.testing.expectEqual(@as(usize, 5), entry.choices.len);
    const m: Message = .{ .id = 5, .content = "lembra disso", .author = 7, .author_name = "ana", .channel = 42, .channel_name = "geral" };
    const before = items(p.tree.?);
    e.menuMessage(p, entry, &m, "600");
    e.waitIdle();
    try std.testing.expectEqual(before + 1, items(p.tree.?));
    try std.testing.expect(e.panel_open != p);
    e.menuMessage(p, entry, &m, "custom");
    e.waitIdle();
    try std.testing.expect(e.panel_open == p);
    try std.testing.expect(hasKey(p.tree.?, "in1h"));
}

test "plugins incluídos: lembrete que já avisou pode voltar daqui a 10 minutos" {
    T.wipeDisk();
    var e = T.engine();
    defer e.deinit();
    const p = testOne(&e, Bundled.src("reminders.lua"));
    try cmdOk(&e, "/remind 1s de novo");
    var spins: usize = 0;
    while (!noteHas("⏰") and spins < 4000) : (spins += 1) {
        e.drain();
        sync.sleepMs(1);
    }
    e.waitIdle();
    const t = p.tree.?;
    var snooze: ?*panel.Node = null;
    for (t.nodes.items) |*n| if (std.mem.startsWith(u8, n.key, "snooze")) {
        snooze = n;
    };
    e.panelGesture(p, snooze.?.click, null);
    e.waitIdle();
    var active: usize = 0;
    for (p.tree.?.nodes.items) |*n| if (std.mem.startsWith(u8, n.key, "cancel")) {
        active += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), active);
}

test "plugins incluídos: destaques silencia canal, conta o que não foi visto e acompanha edições" {
    T.wipeDisk();
    var e = T.engine();
    defer e.deinit();
    const p = testOne(&e, Bundled.src("highlights.lua"));
    try cmdOk(&e, "/highlights pizza");
    e.openPanel(null);
    e.waitIdle();
    chega(&e, "quem quer pizza?");
    try std.testing.expectEqualStrings("1", p.tree.?.badge);
    try std.testing.expect(!T.notes_desktop[T.n_notes - 1]);
    chega(&e, "mais pizza");
    try std.testing.expectEqualStrings("2", p.tree.?.badge);
    // Abriu o painel: viu.
    e.openPanel(p);
    e.waitIdle();
    try std.testing.expectEqualStrings("", p.tree.?.badge);
    chega(&e, "pizza com o painel aberto");
    try std.testing.expectEqualStrings("", p.tree.?.badge);
    e.openPanel(null);
    e.waitIdle();

    // Editaram: o trecho é o novo; sem a palavra, sai da lista.
    const edited: Message = .{ .id = 900, .content = "pizza aqui", .author = 7, .author_name = "ana", .channel = 42, .channel_name = "geral", .timestamp = 1000 };
    e.onMessage(&edited);
    e.waitIdle();
    const again: Message = .{ .id = 900, .content = "agora pizza ali", .author = 7, .author_name = "ana", .channel = 42, .channel_name = "geral", .timestamp = 1000 };
    e.onEdit(&again);
    e.waitIdle();
    try std.testing.expectEqualStrings("agora pizza ali", nodeKey(p.tree.?, "900").sub);
    const gone: Message = .{ .id = 900, .content = "mudei de ideia", .author = 7, .author_name = "ana", .channel = 42, .channel_name = "geral", .timestamp = 1000 };
    e.onEdit(&gone);
    e.waitIdle();
    try std.testing.expect(!hasKey(p.tree.?, "900"));
    // Uma edição que passa a ter a palavra conta.
    const notes = T.n_notes;
    e.onEdit(&again);
    e.waitIdle();
    try std.testing.expectEqual(notes + 1, T.n_notes);
    try std.testing.expect(hasKey(p.tree.?, "900"));

    // Silenciou o canal aberto: nada dele conta mais, e volta ao reativar.
    e.panelGesture(p, nodeKey(p.tree.?, "mute").click, null);
    e.waitIdle();
    const n0 = T.n_notes;
    chega(&e, "pizza no canal silenciado");
    try std.testing.expectEqual(n0, T.n_notes);
    e.panelGesture(p, nodeKey(p.tree.?, "unmute42").click, null);
    e.waitIdle();
    chega(&e, "pizza de novo");
    try std.testing.expectEqual(n0 + 1, T.n_notes);

    // A opção: notificação do sistema também com a janela em foco.
    e.panelToggle(p, nodeKey(p.settings.?, "desktop").change, true);
    e.waitIdle();
    chega(&e, "pizza com aviso");
    try std.testing.expect(T.notes_desktop[T.n_notes - 1]);
    e.setEnabled(p, false);
    e.waitIdle();
    e.setEnabled(p, true);
    e.waitIdle();
    try std.testing.expectEqual(@as(f32, 1), nodeKey(p.settings.?, "desktop").value);
}

test "plugins: trechos viram sugestões da caixa" {
    T.wipeDisk();
    var e = T.engine();
    defer e.deinit();
    _ = T.writeData(&T.dummy, 1, "t.lua", "{\"items\":[{\"name\":\"oi\",\"text\":\"olá, tudo bem?\"}]}");
    const p = testOne(&e, @embedFile("testdata/snippets.lua"));
    try std.testing.expect(p.err() == null);
    try std.testing.expectEqualStrings("olá, tudo bem?", e.completionText(p.run, ';', "oi").?);
    e.panelGesture(p, nodeKey(p.tree.?, "rmoi").click, null);
    e.waitIdle();
    try std.testing.expect(e.completionText(p.run, ';', "oi") == null);
    try std.testing.expectEqual(@as(usize, 0), T.n_sent);
}

test "plugins: horários entendem o pedido e põem na caixa" {
    T.wipeDisk();
    var e = T.engine();
    defer e.deinit();
    const p = testOne(&e, @embedFile("testdata/timestamps.lua"));
    try std.testing.expect(p.err() == null);
    const ok = [_][]const u8{ "/ts", "/ts 15h", "/ts 15:30", "/ts amanhã 15h", "/ts tomorrow 3pm", "/ts sexta 20h", "/ts friday 20:00", "/ts 25/12 20h", "/ts 25/12/2030", "/ts em 2h", "/ts in 1h30m", "/ts +30m", "/ts hoje 23:59" };
    for (ok) |cmd| {
        T.inserted_len = 0;
        try cmdOk(&e, cmd);
        const got = T.inserted[0..T.inserted_len];
        if (!std.mem.startsWith(u8, got, "<t:") or !std.mem.endsWith(u8, got, ":f>")) {
            std.debug.print("{s}: {s}\n", .{ cmd, got });
            return error.HorarioRuim;
        }
    }
    T.inserted_len = 0;
    try cmdOk(&e, "/ts batata");
    try std.testing.expectEqual(@as(usize, 0), T.inserted_len);
    try std.testing.expect(std.mem.indexOf(u8, lastNote(), "/ts") != null);
    for ([_][]const u8{ "/ts 25:00", "/ts 13/13 10h", "/ts em batata", "/ts amanhã 15h e mais" }) |cmd| {
        try cmdOk(&e, cmd);
        try std.testing.expectEqual(@as(usize, 0), T.inserted_len);
    }
    // O formato vem da página.
    e.panelGesture(p, nodeKey(p.settings.?, "style").change, "R");
    e.waitIdle();
    T.inserted_len = 0;
    try cmdOk(&e, "/ts em 2h");
    try std.testing.expect(std.mem.endsWith(u8, T.inserted[0..T.inserted_len], ":R>"));
    try std.testing.expectEqual(@as(usize, 0), T.n_sent);
}

test "plugins incluídos: links e arquivos só olham com o painel aberto, e não guardam nada" {
    T.wipeDisk();
    var e = T.engine();
    defer e.deinit();
    const files = [_]FileRef{.{ .name = "foto.png", .url = "https://cdn.exemplo.com/foto.png", .size = 2048 }};
    const msgs = [_]Message{
        .{ .id = 3, .content = "veja https://a.com/x.", .author = 7, .author_name = "ana", .channel = 42, .channel_name = "geral", .timestamp = 1000 },
        .{ .id = 4, .content = "(https://b.org/y) e de novo https://a.com/x", .author = 8, .author_name = "bia", .channel = 42, .channel_name = "geral", .timestamp = 2000 },
        .{ .id = 5, .content = "", .author = 8, .author_name = "bia", .channel = 42, .channel_name = "geral", .timestamp = 3000, .attachments = 1, .files = &files },
    };
    T.loaded = &msgs;
    const p = testOne(&e, Bundled.src("links.lua"));
    try std.testing.expect(p.err() == null);
    // Fechado: a lista nem existe.
    try std.testing.expect(p.tree != null and !hasKey(p.tree.?, "i1"));
    e.openPanel(p);
    e.waitIdle();
    const titles = struct {
        fn count(t: *panel.Tree) usize {
            var n: usize = 0;
            for (t.nodes.items) |*x| if (x.kind == .item) {
                n += 1;
            };
            return n;
        }
    }.count;
    // O arquivo, b.org, e a.com uma vez só.
    try std.testing.expectEqual(@as(usize, 3), titles(p.tree.?));
    try std.testing.expectEqualStrings("foto.png", nodeKey(p.tree.?, "i1").text);
    try std.testing.expectEqualStrings("https://b.org/y", nodeKey(p.tree.?, "i2").sub);
    try std.testing.expectEqualStrings("https://a.com/x", nodeKey(p.tree.?, "i3").sub);
    // Abrir, copiar e ir até a mensagem.
    e.panelGesture(p, nodeKey(p.tree.?, "open2").click, null);
    e.waitIdle();
    try std.testing.expectEqualStrings("https://b.org/y", T.opened[0..T.opened_len]);
    e.panelGesture(p, nodeKey(p.tree.?, "copy1").click, null);
    e.waitIdle();
    try std.testing.expectEqualStrings("https://cdn.exemplo.com/foto.png", T.copied[0..T.copied_len]);
    e.panelGesture(p, nodeKey(p.tree.?, "i2").click, null);
    e.waitIdle();
    try std.testing.expectEqual(@as(u64, 4), T.jump_id);
    // A busca e o filtro.
    e.panelChange(p, nodeKey(p.tree.?, "search").change, "B.ORG");
    e.waitIdle();
    try std.testing.expectEqual(@as(usize, 1), titles(p.tree.?));
    e.panelChange(p, nodeKey(p.tree.?, "search").change, "");
    e.waitIdle();
    e.panelGesture(p, nodeKey(p.tree.?, "kind").change, "file");
    e.waitIdle();
    try std.testing.expectEqual(@as(usize, 1), titles(p.tree.?));
    e.panelGesture(p, nodeKey(p.tree.?, "kind").change, "all");
    e.waitIdle();
    // Apagaram: sai na hora, com o que veio dela (a.com ficou com a mais recente).
    e.onDelete(42, 4);
    e.waitIdle();
    try std.testing.expectEqual(@as(usize, 1), titles(p.tree.?));
    // Fechou: some da memória.
    e.openPanel(null);
    e.waitIdle();
    try std.testing.expectEqual(@as(usize, 0), titles(p.tree.?));
    try std.testing.expect(!p.man.has(.storage));
}

test "plugins: fechar a nota avisa quem a pôs" {
    T.wipeDisk();
    var e = T.engine();
    defer e.deinit();
    const host_name = "api.mymemory.translated.net";
    const p = testOne(&e, Bundled.src("translate.lua"));
    e.setApproved(p, host_name, true);
    e.waitIdle();
    const m: Message = .{ .id = 5, .content = "hello", .author = 7, .author_name = "ana", .channel = 42, .channel_name = "geral" };
    e.menuMessage(p, &p.menus.items[0], &m, null);
    e.waitIdle();
    T.respond(200, "{\"responseData\":{\"translatedText\":\"olá\"},\"responseStatus\":200}");
    e.waitIdle();
    try std.testing.expect(e.deco.active());
    e.dismissDeco(p.run, 5);
    e.waitIdle();
    try std.testing.expect(!e.deco.active());
    // Depois do ×, "Traduzir" traduz de novo, em vez de só tirar uma nota que nem está lá.
    e.menuMessage(p, &p.menus.items[0], &m, null);
    e.waitIdle();
    try std.testing.expectEqual(@as(usize, 1), T.http_n);
    T.respond(200, "{\"responseData\":{\"translatedText\":\"olá\"},\"responseStatus\":200}");
    e.waitIdle();
    try std.testing.expect(e.deco.active());
}

test "plugins incluídos: destaques só escuta as mensagens quando tem palavra" {
    T.wipeDisk();
    var e = T.engine();
    defer e.deinit();
    const p = testOne(&e, Bundled.src("highlights.lua"));
    try std.testing.expectEqual(@as(u32, 0), e.n_message);
    try std.testing.expectEqual(@as(u32, 0), e.n_edit);
    try cmdOk(&e, "/highlights pizza");
    try std.testing.expectEqual(@as(u32, 1), e.n_message);
    try std.testing.expectEqual(@as(u32, 1), e.n_edit);
    // Reiniciou com palavra guardada: escuta desde o começo, sem repetir.
    e.setEnabled(p, false);
    e.waitIdle();
    e.setEnabled(p, true);
    e.waitIdle();
    try std.testing.expectEqual(@as(u32, 1), e.n_message);
    try cmdOk(&e, "/highlights batata");
    try std.testing.expectEqual(@as(u32, 1), e.n_message);
}

// --- Filtros de texto, nota em vermelho e o que sigma.messages traz a mais ---------

test "plugins: contains só chama a função para o texto pedido, e confere o que recebe" {
    T.wipeDisk();
    var e = T.engine();
    defer e.deinit();
    _ = testOne(&e,
        \\-- @capabilities messages, notify
        \\sigma.on("message", function(m) sigma.notify("a:" .. m.content) end, { contains = { "CVE-", "://" } })
        \\sigma.on("message", function(m) sigma.notify("b:" .. m.content) end, { contains = { "pizza" } })
        \\sigma.on("edit", function(m) sigma.notify("e:" .. m.content) end, { contains = { "cve-" } })
    );
    chega(&e, "conversa normal");
    try std.testing.expectEqual(@as(usize, 0), T.n_notes);
    // Sem ligar para maiúsculas, e cada função só com o dela.
    chega(&e, "veja o cve-2021-44228");
    try std.testing.expectEqual(@as(usize, 1), T.n_notes);
    try std.testing.expectEqualStrings("a:veja o cve-2021-44228", lastNote());
    chega(&e, "PIZZA hoje");
    try std.testing.expectEqualStrings("b:PIZZA hoje", lastNote());
    const notes = T.n_notes;
    const m: Message = .{ .id = 3, .content = "sem nada", .author = 7, .author_name = "ana", .channel = 42, .channel_name = "geral" };
    e.onEdit(&m);
    e.waitIdle();
    try std.testing.expectEqual(notes, T.n_notes);
    const n: Message = .{ .id = 3, .content = "CVE-1", .author = 7, .author_name = "ana", .channel = 42, .channel_name = "geral" };
    e.onEdit(&n);
    e.waitIdle();
    try std.testing.expectEqualStrings("e:CVE-1", lastNote());
    for ([_][]const u8{
        "-- @capabilities messages\nsigma.on(\"message\", function() end, { contains = {} })",
        "-- @capabilities messages\nsigma.on(\"message\", function() end, { contains = { 1 } })",
        "-- @capabilities messages\nsigma.on(\"message\", function() end, { contains = { \"\" } })",
        "-- @capabilities messages\nsigma.on(\"delete\", function() end, { contains = { \"a\" } })",
    }) |src| {
        const q = testOne(&e, src);
        try std.testing.expect(q.err() != null);
    }
}

test "plugins: sigma.messages filtra pelo texto, e traz resposta, menção e até onde foi lido" {
    T.wipeDisk();
    var e = T.engine();
    defer e.deinit();
    const msgs = [_]Message{
        .{ .id = 3, .content = "sem link", .author = 7, .author_name = "ana", .channel = 42, .channel_name = "geral", .mentions_me = true },
        .{ .id = 4, .content = "veja https://a.com", .author = 7, .author_name = "ana", .channel = 42, .channel_name = "geral", .reply_to = 3 },
    };
    T.loaded = &msgs;
    T.last_read = 3;
    defer T.last_read = 0;
    _ = testOne(&e,
        \\-- @capabilities messages, notify
        \\sigma.command("/com", function()
        \\  sigma.messages({ contains = { "://" } }, function(list)
        \\    sigma.notify(#list .. ":" .. list[1].id .. ":" .. list[1].reply_to .. ":" .. tostring(list.last_read))
        \\  end)
        \\end)
        \\sigma.command("/todas", function()
        \\  sigma.messages(function(list) sigma.notify(#list .. ":" .. tostring(list[1].mentions_me) .. ":" .. tostring(list[2].mentions_me)) end)
        \\end)
    );
    try cmdOk(&e, "/com");
    try std.testing.expectEqualStrings("1:4:3:3", lastNote());
    sync.sleepMs(520);
    try cmdOk(&e, "/todas");
    try std.testing.expectEqualStrings("2:true:nil", lastNote());
}

test "plugins: nota em vermelho, e sigma.on(\"hosts\") avisa quando aprovam" {
    T.wipeDisk();
    var e = T.engine();
    defer e.deinit();
    const p = testOne(&e,
        \\-- @capabilities decorate, http, notify
        \\-- @hosts api.exemplo.com
        \\sigma.command("/d", function() sigma.decorate("5", { note = "cuidado", style = "danger" }) end)
        \\sigma.command("/n", function() sigma.decorate("5", { note = "normal" }) end)
        \\sigma.on("hosts", function() sigma.notify("hosts:" .. tostring(sigma.http.allowed("api.exemplo.com"))) end)
    );
    var sm: @import("../core/store.zig").StoredMessage = .{ .msg = .{ .id = 5, .channel = 42, .author = 7, .timestamp = 0, .content = "x" }, .spans = &.{} };
    try cmdOk(&e, "/d");
    try std.testing.expect(e.deco.view(&sm, 1).slice()[0].danger);
    try cmdOk(&e, "/n");
    try std.testing.expect(!e.deco.view(&sm, 1).slice()[0].danger);
    e.setApproved(p, "api.exemplo.com", true);
    e.waitIdle();
    try std.testing.expectEqualStrings("hosts:true", lastNote());
    e.setApproved(p, "api.exemplo.com", false);
    e.waitIdle();
    try std.testing.expectEqualStrings("hosts:false", lastNote());
}

// --- Anti-golpe ---------------------------------------------------------------------

const Scam = struct {
    var next_id: u64 = 10_000;

    /// Manda a mensagem e diz o que ficou nela (null = nada).
    fn check(e: *Engine, content: []const u8) ?[]const u8 {
        next_id += 1;
        const m: Message = .{ .id = next_id, .content = content, .author = 7, .author_name = "ana", .channel = 42, .channel_name = "geral", .timestamp = 1000 };
        e.onMessage(&m);
        e.waitIdle();
        var sm: @import("../core/store.zig").StoredMessage = .{ .msg = .{ .id = next_id, .channel = 42, .author = 7, .timestamp = 0, .content = "x" }, .spans = &.{} };
        const v = e.deco.view(&sm, 1);
        if (v.n == 0) return null;
        const part = v.slice()[0];
        if (!part.danger) return null;
        return part.note;
    }
};

test "anti-golpe: endereços oficiais e conversa normal nunca marcam" {
    T.wipeDisk();
    var e = T.engine();
    defer e.deinit();
    const p = testOne(&e, Bundled.src("scamguard.lua"));
    try std.testing.expect(p.err() == null);
    const clean = [_][]const u8{
        // Os oficiais, com subdomínio e tudo.
        "https://discord.com/channels/1/2",
        "https://discord.gg/abc",
        "https://discordapp.com/invite/abc",
        "https://cdn.discordapp.com/attachments/1/2/a.png",
        "https://media.discordapp.net/attachments/1/2/a.png",
        "https://ptb.discord.com/app",
        "https://canary.discord.com/app",
        "https://discord.gift/AbCdEf",
        "https://support.discord.com/hc/pt-br",
        "https://store.steampowered.com/app/730",
        "https://steamcommunity.com/id/alguem",
        "https://help.steampowered.com/pt-br",
        "HTTPS://DISCORD.COM/channels/1/2",
        // Oficial, mesmo com a isca do lado.
        "free nitro https://discord.gift/AbCdEf",
        "o nitro grátis acabou, leia https://support.discord.com/hc/pt-br",
        "[clique aqui](https://discord.gg/abc)",
        // Conversa sobre nitro, sem link.
        "alguém sabe se tem nitro grátis esse mês?",
        "free nitro é sempre golpe, cuidado",
        "ganhei um presente de nitro do meu irmão",
        "steam gift card vale a pena?",
        // Link qualquer, sem isca.
        "olha esse vídeo https://www.youtube.com/watch?v=abc",
        "https://github.com/discord/discord-api-docs/issues/1",
        "https://exemplo.com/discord-nitro-free",
        "https://bit.ly/abc123",
        "dá uma olhada https://tinyurl.com/abc",
        "comprei um steam gift card em https://loja.exemplo.com/cartoes",
        // Grandes, junto de uma promessa: é conversa.
        "tutorial de free nitro https://www.youtube.com/watch?v=abc",
        "skins grátis é golpe https://www.reddit.com/r/csgo",
        // Terceiros de verdade com nome parecido.
        "https://discordjs.guide/",
        "https://discord.js.org/docs",
        "https://discordpy.readthedocs.io/en/stable/",
        "https://disboard.org/server/1",
        "https://www.discords.com/servers",
        "https://steamdb.info/app/730",
        "https://steamcharts.com/app/730",
        "https://www.steamgifts.com/",
        "https://steamdeck.exemplo.com/",
        "https://discord.projeto.org/convite",
        "https://discordbotlist.com/bots",
        // Parecem, mas não são marcas.
        "https://stream.com/",
        "https://streamlabs.com/",
        "https://team.com/",
        "https://steemit.com/",
        "https://record.com/",
        "https://discard.com/",
        "https://discourse.org/",
        "https://discover.com/",
        // Letras de outros alfabetos não são golpe por si só.
        "https://xn--mnchen-3ya.de/",
        "https://xn--corao-dra1a.com.br/",
        // Rede local e o próprio computador.
        "http://192.168.0.1/admin",
        "http://10.0.0.5:8080/",
        "http://172.16.1.1/",
        "http://127.0.0.1:3000/",
        "http://localhost:3000/",
        // Quem cita entre crases está falando do link, não mandando clicar.
        "cuidado com `https://dlscord.com/nitro`",
        "```\nhttps://discord.com.golpe.ru/x\n```",
        "hxxps://dlscord.com/nitro",
        // Links com texto que não enganam.
        "[README.md](https://github.com/a/b/blob/main/README.md)",
        "[manual.pdf](https://exemplo.com/arquivo/123)",
        "[site](https://exemplo.com)",
        "[exemplo.com](https://www.exemplo.com/x)",
        "[www.exemplo.com](https://exemplo.com/x)",
        "[youtube.com](https://youtu.be/abc)",
    };
    for (clean) |text| {
        if (Scam.check(&e, text)) |note| {
            std.debug.print("marcou o que não devia: {s}\n  nota: {s}\n", .{ text, note });
            return error.FalsoPositivo;
        }
    }
}

test "anti-golpe: os golpes clássicos marcam, e a nota diz o motivo" {
    T.wipeDisk();
    var e = T.engine();
    defer e.deinit();
    const p = testOne(&e, Bundled.src("scamguard.lua"));
    try std.testing.expect(p.err() == null);
    const Case = struct { text: []const u8, why: []const u8 };
    const scams = [_]Case{
        // Letras trocadas.
        .{ .text = "https://dlscord.com/nitro", .why = "letras trocadas" },
        .{ .text = "https://disc0rd.com/nitro", .why = "letras trocadas" },
        .{ .text = "https://d1scord.gg/abc", .why = "letras trocadas" },
        .{ .text = "https://discrod.com/x", .why = "letras trocadas" },
        .{ .text = "https://dicsord.gift/x", .why = "letras trocadas" },
        .{ .text = "https://discordd.com/x", .why = "letras trocadas" },
        .{ .text = "https://dis-cord.com/x", .why = "letras trocadas" },
        .{ .text = "https://discorcl.com/x", .why = "letras trocadas" },
        .{ .text = "https://steamcommunlty.com/tradeoffer", .why = "letras trocadas" },
        .{ .text = "https://stearncommunity.com/x", .why = "letras trocadas" },
        .{ .text = "https://steamcomnunity.ru/x", .why = "letras trocadas" },
        .{ .text = "https://steampowerd.com/x", .why = "letras trocadas" },
        .{ .text = "https://st3am.com/x", .why = "letras trocadas" },
        .{ .text = "https://login.dlscord.com/x", .why = "letras trocadas" },
        // Outro alfabeto, escrito e em punycode.
        .{ .text = "https://d\u{456}scord.com/nitro", .why = "letras trocadas" },
        .{ .text = "https://xn--dscord-pvf.com/nitro", .why = "outro alfabeto" },
        .{ .text = "https://xn--discrd-zqf.com/x", .why = "outro alfabeto" },
        .{ .text = "https://xn--stem-73d.com/x", .why = "outro alfabeto" },
        .{ .text = "https://XN--STEAMCOMMUNTY-EIL.com/x", .why = "outro alfabeto" },
        // Subdomínio enganoso e usuário de disfarce.
        .{ .text = "https://discord.com.golpe.ru/nitro", .why = "parece o discord.com" },
        .{ .text = "https://discordapp.com.login.xyz/", .why = "parece o discordapp.com" },
        .{ .text = "https://steamcommunity.com.tradeoffer.ru/new", .why = "parece o steamcommunity.com" },
        .{ .text = "https://store.steampowered.com.evil.ru/", .why = "parece o steampowered.com" },
        .{ .text = "https://discord.com@golpe.ru/nitro", .why = "disfarce" },
        // O nome certo no lugar errado, e a marca colada numa isca.
        .{ .text = "https://discord.ru/nitro", .why = "não é o site" },
        .{ .text = "https://steamcommunity.xyz/x", .why = "não é o site" },
        .{ .text = "https://discord-nitro.ru/x", .why = "não é o site" },
        .{ .text = "https://discordgift.site/x", .why = "não é o site" },
        .{ .text = "https://discord-login.com/x", .why = "não é o site" },
        .{ .text = "https://steam-gift.ru/x", .why = "não é o site" },
        .{ .text = "https://nitro-discord.com/x", .why = "não é o site" },
        .{ .text = "https://discord-nitro.com.br/x", .why = "não é o site" },
        // Site de Nitro de graça, sem precisar de texto nenhum.
        .{ .text = "https://free-nitro.xyz/x", .why = "Nitro de graça" },
        .{ .text = "https://nitrogift.site/x", .why = "Nitro de graça" },
        // Isca e link.
        .{ .text = "free nitro aqui https://qualquer.site/x", .why = "promessa" },
        .{ .text = "NITRO GRÁTIS por 3 meses https://qualquer.site/x", .why = "promessa" },
        .{ .text = "Ganhe Nitro: <https://qualquer.site/x>", .why = "promessa" },
        .{ .text = "skins grátis no https://loja.exemplo.com/", .why = "promessa" },
        .{ .text = "@everyone free steam gift https://qualquer.site/", .why = "promessa" },
        // Encurtador com isca fraca, e encurtador com isca forte.
        .{ .text = "presente pra você https://bit.ly/abc", .why = "encurtado" },
        .{ .text = "nitro aqui https://tinyurl.com/abc", .why = "encurtado" },
        .{ .text = "free nitro https://cutt.ly/abc", .why = "promessa" },
        // IP.
        .{ .text = "olha http://45.33.32.156/x", .why = "IP" },
        .{ .text = "http://3232235777/", .why = "IP" },
        .{ .text = "http://[2001:db8::1]/x", .why = "IP" },
        // O texto mostra um endereço e o link abre outro.
        .{ .text = "[discord.com/gift](https://qualquer.site/x)", .why = "abre outro" },
        .{ .text = "[https://steamcommunity.com](https://qualquer.site/x)", .why = "abre outro" },
        .{ .text = "[www.exemplo.com](https://qualquer.site/x)", .why = "abre outro" },
    };
    for (scams) |k| {
        const note = Scam.check(&e, k.text) orelse {
            std.debug.print("não marcou: {s}\n", .{k.text});
            return error.GolpeNaoMarcado;
        };
        if (std.mem.indexOf(u8, note, k.why) == null) {
            std.debug.print("{s}\n  nota: {s}\n  esperava: {s}\n", .{ k.text, note, k.why });
            return error.MotivoErrado;
        }
    }
}

test "anti-golpe: \"não é golpe\" guarda o endereço, o painel lista e nada do texto vai para o disco" {
    T.wipeDisk();
    var e = T.engine();
    defer e.deinit();
    const p = testOne(&e, Bundled.src("scamguard.lua"));
    const secret = "segredo-da-ana https://dlscord.com/x";
    try std.testing.expect(Scam.check(&e, secret) != null);
    const id = Scam.next_id;
    var kb: [32]u8 = undefined;
    const key = try std.fmt.bufPrint(&kb, "{d}", .{id});
    // O número no painel, até abrir.
    try std.testing.expectEqualStrings("1", p.tree.?.badge);
    const row = nodeKey(p.tree.?, key);
    try std.testing.expectEqualStrings("dlscord.com", row.text);
    e.panelGesture(p, row.click, null);
    e.waitIdle();
    try std.testing.expectEqual(id, T.jump_id);
    e.openPanel(p);
    e.waitIdle();
    try std.testing.expectEqualStrings("", p.tree.?.badge);
    e.openPanel(null);
    e.waitIdle();
    // A própria mensagem não marca, e quem a pessoa ignora também não.
    const mine: Message = .{ .id = 90_001, .content = "https://dlscord.com/y", .author = 1, .author_name = "eu", .channel = 42, .channel_name = "geral", .mine = true };
    e.onMessage(&mine);
    e.waitIdle();
    try std.testing.expect(!hasKey(p.tree.?, "90001"));
    // No disco, o endereço; nunca o texto.
    e.setEnabled(p, false);
    e.waitIdle();
    const data = T.readData(&T.dummy, std.testing.allocator, 1, "t.lua").?;
    defer std.testing.allocator.free(data);
    try std.testing.expect(std.mem.indexOf(u8, data, "dlscord.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, data, "segredo") == null);
    e.setEnabled(p, true);
    e.waitIdle();
    try std.testing.expect(hasKey(p.tree.?, key));
    // "Não é golpe" pelo menu: sai a nota, sai da lista, e o endereço não marca mais.
    const m: Message = .{ .id = id, .content = secret, .author = 7, .author_name = "ana", .channel = 42, .channel_name = "geral", .timestamp = 1000 };
    e.menuMessage(p, &p.menus.items[0], &m, null);
    e.waitIdle();
    try std.testing.expect(!hasKey(p.tree.?, key));
    try std.testing.expect(hasKey(p.tree.?, "trust1"));
    try std.testing.expect(Scam.check(&e, "https://dlscord.com/z") == null);
    try std.testing.expect(Scam.check(&e, "https://www.dlscord.com/z") == null);
    // E só ele: o resto continua marcando.
    try std.testing.expect(Scam.check(&e, "https://disc0rd.com/z") != null);
    // A escolha fica guardada por conta, e dá para voltar atrás.
    e.setEnabled(p, false);
    e.waitIdle();
    e.setEnabled(p, true);
    e.waitIdle();
    try std.testing.expect(Scam.check(&e, "https://dlscord.com/w") == null);
    e.panelGesture(p, nodeKey(p.tree.?, "untrust1").click, null);
    e.waitIdle();
    try std.testing.expect(Scam.check(&e, "https://dlscord.com/w") != null);
    // Numa mensagem limpa, o menu só avisa.
    const ok: Message = .{ .id = 90_002, .content = "https://discord.com/x", .author = 7, .author_name = "ana", .channel = 42, .channel_name = "geral" };
    e.menuMessage(p, &p.menus.items[0], &ok, null);
    e.waitIdle();
    try std.testing.expect(std.mem.indexOf(u8, lastNote(), "não está marcada") != null);
}

test "anti-golpe: apagaram ou editaram, a marca sai; e dá para não marcar IP" {
    T.wipeDisk();
    var e = T.engine();
    defer e.deinit();
    const p = testOne(&e, Bundled.src("scamguard.lua"));
    try std.testing.expect(Scam.check(&e, "https://dlscord.com/x") != null);
    var id = Scam.next_id;
    var kb: [32]u8 = undefined;
    e.onDelete(42, id);
    e.waitIdle();
    try std.testing.expect(!hasKey(p.tree.?, try std.fmt.bufPrint(&kb, "{d}", .{id})));

    try std.testing.expect(Scam.check(&e, "https://dlscord.com/y") != null);
    id = Scam.next_id;
    const edited: Message = .{ .id = id, .content = "foi engano, é https://discord.com/y", .author = 7, .author_name = "ana", .channel = 42, .channel_name = "geral", .timestamp = 1000 };
    e.onEdit(&edited);
    e.waitIdle();
    var sm: @import("../core/store.zig").StoredMessage = .{ .msg = .{ .id = id, .channel = 42, .author = 7, .timestamp = 0, .content = "x" }, .spans = &.{} };
    try std.testing.expectEqual(@as(u8, 0), e.deco.view(&sm, 1).n);
    try std.testing.expect(!hasKey(p.tree.?, try std.fmt.bufPrint(&kb, "{d}", .{id})));
    // Uma edição que passa a ter o golpe marca.
    const worse: Message = .{ .id = id, .content = "https://disc0rd.com/y", .author = 7, .author_name = "ana", .channel = 42, .channel_name = "geral", .timestamp = 1000 };
    e.onEdit(&worse);
    e.waitIdle();
    try std.testing.expect(e.deco.view(&sm, 1).slice()[0].danger);

    try std.testing.expect(Scam.check(&e, "http://45.33.32.156/x") != null);
    e.panelToggle(p, nodeKey(p.settings.?, "mark_ip").change, false);
    e.waitIdle();
    try std.testing.expect(Scam.check(&e, "http://45.33.32.156/x") == null);
}

test "anti-golpe: olha as mensagens já carregadas ao abrir o canal" {
    T.wipeDisk();
    var e = T.engine();
    defer e.deinit();
    const msgs = [_]Message{
        .{ .id = 30, .content = "https://dlscord.com/velho", .author = 7, .author_name = "ana", .channel = 42, .channel_name = "geral", .timestamp = 1000 },
        .{ .id = 31, .content = "conversa", .author = 7, .author_name = "ana", .channel = 42, .channel_name = "geral", .timestamp = 1000 },
    };
    T.loaded = &msgs;
    const p = testOne(&e, Bundled.src("scamguard.lua"));
    sync.sleepMs(620);
    e.frameTick(77, false);
    e.waitIdle();
    try std.testing.expect(hasKey(p.tree.?, "30"));
    // Da história não vem número no painel: é só o que chegou agora.
    try std.testing.expectEqualStrings("", p.tree.?.badge);
}

// --- Radar de CVE --------------------------------------------------------------------

const Cve = struct {
    const log4j = @embedFile("testdata/cve/CVE-2021-44228.json");
    const xz = @embedFile("testdata/cve/CVE-2024-3094.json");
    const old = @embedFile("testdata/cve/CVE-1999-0001.json");
    const rejected = @embedFile("testdata/cve/CVE-2016-0001.json");
    const many = @embedFile("testdata/cve/CVE-2024-12345.json");
    const missing = "{\"error\":\"CVE_RECORD_DNE\",\"message\":\"The cve record for the cve id does not exist.\"}";

    fn note(e: *Engine, id: u64) []const u8 {
        var sm: @import("../core/store.zig").StoredMessage = .{ .msg = .{ .id = id, .channel = 42, .author = 7, .timestamp = 0, .content = "x" }, .spans = &.{} };
        const v = e.deco.view(&sm, 1);
        return if (v.n > 0) v.slice()[0].note else "";
    }

    fn danger(e: *Engine, id: u64) bool {
        var sm: @import("../core/store.zig").StoredMessage = .{ .msg = .{ .id = id, .channel = 42, .author = 7, .timestamp = 0, .content = "x" }, .spans = &.{} };
        const v = e.deco.view(&sm, 1);
        return v.n > 0 and v.slice()[0].danger;
    }

    fn say(e: *Engine, id: u64, text: []const u8) void {
        const m: Message = .{ .id = id, .content = text, .author = 7, .author_name = "ana", .channel = 42, .channel_name = "geral", .timestamp = 1000 };
        e.onMessage(&m);
        e.waitIdle();
    }

    fn lastUrl() []const u8 {
        return T.http_reqs[T.http_n - 1].?.url;
    }
};

test "radar de CVE: nada sai sem aprovar, e o aprovar solta o que estava esperando" {
    T.wipeDisk();
    var e = T.engine();
    defer e.deinit();
    const p = testOne(&e, Bundled.src("cve.lua"));
    try std.testing.expect(p.err() == null);
    Cve.say(&e, 101, "cuidado com o cve-2021-44228, gente");
    try std.testing.expectEqual(@as(usize, 0), T.http_n);
    try std.testing.expectEqualStrings("", Cve.note(&e, 101));
    e.setApproved(p, "cveawg.mitre.org", true);
    e.waitIdle();
    try std.testing.expectEqual(@as(usize, 1), T.http_n);
    // Em maiúsculas: o serviço recusa em minúsculas.
    try std.testing.expectEqualStrings("https://cveawg.mitre.org/api/cve/CVE-2021-44228", Cve.lastUrl());
    // O texto da mensagem não vai junto.
    try std.testing.expect(std.mem.indexOf(u8, Cve.lastUrl(), "cuidado") == null);
    T.respond(200, Cve.log4j);
    e.waitIdle();
    // A resposta real: a nota vem do complemento do CISA, e o título do fornecedor.
    const n = Cve.note(&e, 101);
    try std.testing.expect(std.mem.startsWith(u8, n, "🛡 CVE-2021-44228 · CRÍTICA · CVSS 10.0 · Apache Log4j2"));
    try std.testing.expect(Cve.danger(&e, 101));
}

test "radar de CVE: respostas reais de cada tipo viram a nota certa" {
    T.wipeDisk();
    var e = T.engine();
    defer e.deinit();
    const p = testOne(&e, Bundled.src("cve.lua"));
    e.setApproved(p, "cveawg.mitre.org", true);
    e.waitIdle();
    // O CVSS do próprio fornecedor.
    Cve.say(&e, 201, "CVE-2024-3094");
    T.respond(200, Cve.xz);
    e.waitIdle();
    try std.testing.expect(std.mem.startsWith(u8, Cve.note(&e, 201), "🛡 CVE-2024-3094 · CRÍTICA · CVSS 10.0 · Xz: malicious code"));
    // Formato antigo: sem nota nenhuma, com o resumo.
    Cve.say(&e, 202, "o velho CVE-1999-0001");
    T.respond(200, Cve.old);
    e.waitIdle();
    const old = Cve.note(&e, 202);
    try std.testing.expect(std.mem.indexOf(u8, old, "sem nota CVSS") != null);
    try std.testing.expect(std.mem.indexOf(u8, old, "ip_input.c") != null);
    try std.testing.expect(!Cve.danger(&e, 202));
    // Várias versões de CVSS no mesmo registro: a 3.1, a mais comum.
    Cve.say(&e, 203, "CVE-2024-12345");
    try std.testing.expectEqualStrings("https://cveawg.mitre.org/api/cve/CVE-2024-12345", Cve.lastUrl());
    T.respond(200, Cve.many);
    e.waitIdle();
    try std.testing.expect(std.mem.indexOf(u8, Cve.note(&e, 203), "CVSS ") != null);
    // Rejeitado e inexistente (404 do serviço oficial).
    Cve.say(&e, 204, "CVE-2016-0001");
    T.respond(200, Cve.rejected);
    e.waitIdle();
    try std.testing.expect(std.mem.indexOf(u8, Cve.note(&e, 204), "rejeitado") != null);
    Cve.say(&e, 205, "CVE-2099-99999");
    T.respond(404, Cve.missing);
    e.waitIdle();
    try std.testing.expect(std.mem.indexOf(u8, Cve.note(&e, 205), "não existe") != null);
    // Corpo vazio com 200 (outra fonte faz isso) também é "não existe", nunca um erro.
    Cve.say(&e, 206, "CVE-2098-1111");
    T.respond(200, "{}\n");
    e.waitIdle();
    try std.testing.expect(std.mem.indexOf(u8, Cve.note(&e, 206), "não existe") != null);
    // Lixo no lugar de JSON: idem, e o plugin continua de pé.
    Cve.say(&e, 207, "CVE-2097-1111");
    T.respond(200, "<html>manutenção</html>");
    e.waitIdle();
    try std.testing.expect(std.mem.indexOf(u8, Cve.note(&e, 207), "não existe") != null);
    try std.testing.expect(p.err() == null);
}

test "radar de CVE: cada um é pedido uma vez, mesmo citado por muitos e depois de reiniciar" {
    T.wipeDisk();
    var e = T.engine();
    defer e.deinit();
    const p = testOne(&e, Bundled.src("cve.lua"));
    e.setApproved(p, "cveawg.mitre.org", true);
    e.waitIdle();
    // Duas mensagens antes de a resposta chegar: um pedido só, e as duas ganham a nota.
    Cve.say(&e, 301, "CVE-2021-44228");
    Cve.say(&e, 302, "de novo cve-2021-44228 e CVE-2021-44228");
    try std.testing.expectEqual(@as(usize, 1), T.http_n);
    T.respond(200, Cve.log4j);
    e.waitIdle();
    try std.testing.expect(Cve.note(&e, 301).len > 0);
    try std.testing.expect(Cve.note(&e, 302).len > 0);
    // Já tem: nem pede.
    Cve.say(&e, 303, "CVE-2021-44228 outra vez");
    try std.testing.expectEqual(@as(usize, 0), T.http_n);
    try std.testing.expect(Cve.note(&e, 303).len > 0);
    // Reiniciou: continua guardado.
    sync.sleepMs(3100);
    e.waitIdle();
    e.setEnabled(p, false);
    e.waitIdle();
    e.setEnabled(p, true);
    e.waitIdle();
    Cve.say(&e, 304, "CVE-2021-44228 depois de reiniciar");
    try std.testing.expectEqual(@as(usize, 0), T.http_n);
    try std.testing.expect(Cve.note(&e, 304).len > 0);
    // Dois na mesma mensagem: a nota cresce conforme chegam, no máximo 2 no ar.
    Cve.say(&e, 305, "CVE-2024-3094 e CVE-1999-0001 e CVE-2016-0001");
    try std.testing.expectEqual(@as(usize, 2), T.http_n);
}

test "radar de CVE: erro de rede e limite do serviço não ficam guardados" {
    T.wipeDisk();
    var e = T.engine();
    defer e.deinit();
    const p = testOne(&e, Bundled.src("cve.lua"));
    e.setApproved(p, "cveawg.mitre.org", true);
    e.waitIdle();
    Cve.say(&e, 401, "CVE-2021-44228");
    T.respond(500, "erro");
    e.waitIdle();
    try std.testing.expectEqualStrings("", Cve.note(&e, 401));
    // Da próxima vez, pede de novo.
    Cve.say(&e, 402, "CVE-2021-44228");
    try std.testing.expectEqual(@as(usize, 1), T.http_n);
    T.respond(429, "{\"error\": \"Too Many Requests\", \"message\": \"20 per 1 minute\"}");
    e.waitIdle();
    // Limite: espera, sem nota e sem insistir; o aviso do serviço nunca aparece.
    try std.testing.expectEqualStrings("", Cve.note(&e, 402));
    try std.testing.expectEqual(@as(usize, 0), T.http_n);
    Cve.say(&e, 403, "CVE-2024-3094");
    try std.testing.expectEqual(@as(usize, 0), T.http_n);
    try std.testing.expect(p.err() == null);
}

test "radar de CVE: o que não é CVE não chega ao Lua, e o painel ordena pelo mais grave" {
    T.wipeDisk();
    var e = T.engine();
    defer e.deinit();
    const p = testOne(&e, Bundled.src("cve.lua"));
    e.setApproved(p, "cveawg.mitre.org", true);
    e.waitIdle();
    for ([_][]const u8{ "conversa normal", "cve sem número", "CVE-21-1", "CVE-2021-1", "cve-abcd-1234" }) |text| {
        Cve.say(&e, 500, text);
        try std.testing.expectEqual(@as(usize, 0), T.http_n);
    }
    // /cve abre o painel e consulta, sem precisar de mensagem.
    try cmdOk(&e, "/cve CVE-1999-0001");
    try std.testing.expect(e.panel_open == p);
    T.respond(200, Cve.old);
    e.waitIdle();
    try cmdOk(&e, "/cve CVE-2021-44228");
    T.respond(200, Cve.log4j);
    e.waitIdle();
    var first: []const u8 = "";
    for (p.tree.?.nodes.items) |*n| if (n.kind == .item) {
        first = n.key;
        break;
    };
    try std.testing.expectEqualStrings("CVE-2021-44228", first);
    e.panelGesture(p, nodeKey(p.tree.?, "openCVE-2021-44228").click, null);
    e.waitIdle();
    try std.testing.expectEqualStrings("https://www.cve.org/CVERecord?id=CVE-2021-44228", T.opened[0..T.opened_len]);
    try cmdOk(&e, "/cve batata");
    try std.testing.expect(std.mem.indexOf(u8, lastNote(), "/cve") != null);
}

// --- O que perdi ---------------------------------------------------------------------

test "o que perdi: resume as não lidas, com menções, perguntas e links" {
    T.wipeDisk();
    var e = T.engine();
    defer e.deinit();
    const files = [_]FileRef{.{ .name = "foto.png", .url = "https://cdn.exemplo.com/foto.png" }};
    const msgs = [_]Message{
        // Já lidas: não contam.
        .{ .id = 100, .content = "velha com pergunta?", .author = 7, .author_name = "ana", .channel = 42, .channel_name = "geral", .timestamp = 1000 },
        .{ .id = 101, .content = "https://velho.com", .author = 7, .author_name = "ana", .channel = 42, .channel_name = "geral", .timestamp = 1001 },
        // Novas.
        .{ .id = 200, .content = "oi <@1>, viu isso?", .author = 7, .author_name = "ana", .channel = 42, .channel_name = "geral", .timestamp = 2000, .mentions_me = true },
        .{ .id = 201, .content = "vi sim", .author = 8, .author_name = "bia", .channel = 42, .channel_name = "geral", .timestamp = 2010, .reply_to = 200 },
        .{ .id = 202, .content = "alguém sabe o preço?", .author = 9, .author_name = "caio", .channel = 42, .channel_name = "geral", .timestamp = 5000 },
        .{ .id = 203, .content = "veja https://a.com/x?y=1.", .author = 9, .author_name = "caio", .channel = 42, .channel_name = "geral", .timestamp = 5010 },
        .{ .id = 204, .content = "isto aqui https://a.com/x?y=1 é um link", .author = 8, .author_name = "bia", .channel = 42, .channel_name = "geral", .timestamp = 9000 },
        .{ .id = 205, .content = "", .author = 8, .author_name = "bia", .channel = 42, .channel_name = "geral", .timestamp = 9010, .attachments = 1, .files = &files },
        .{ .id = 206, .content = "e aí, tudo bem?", .author = 8, .author_name = "bia", .channel = 42, .channel_name = "geral", .timestamp = 20000 },
        .{ .id = 207, .content = "minha própria pergunta?", .author = 1, .author_name = "eu", .channel = 42, .channel_name = "geral", .timestamp = 20700, .mine = true },
    };
    T.loaded = &msgs;
    T.last_read = 101;
    defer T.last_read = 0;
    const p = testOne(&e, Bundled.src("catchup.lua"));
    try std.testing.expect(p.err() == null);
    // Só olha quando pedem: fechado, nada de lista.
    try std.testing.expect(!hasKey(p.tree.?, "person1"));
    try cmdOk(&e, "/perdi");
    try std.testing.expect(e.panel_open == p);
    e.waitIdle();
    const t = p.tree.?;
    // Quantas por pessoa, da que mais falou para a que menos.
    const top = nodeKey(t, "person1");
    try std.testing.expectEqualStrings("bia", top.text);
    try std.testing.expectEqual(@as(f32, 4), top.value);
    try std.testing.expectEqualStrings("caio", nodeKey(t, "person2").text);
    try std.testing.expectEqualStrings("ana", nodeKey(t, "person3").text);
    try std.testing.expect(!hasKey(t, "person4"));
    // A menção, com a marca do Discord trocada por algo legível.
    const mention = nodeKey(t, "mention1");
    try std.testing.expectEqualStrings("ana", mention.text);
    try std.testing.expectEqualStrings("oi @…, viu isso?", mention.sub);
    try std.testing.expect(!hasKey(t, "mention2"));
    // Perguntas: a de "vi sim" foi respondida; a do caio teve resposta logo depois de
    // outra pessoa? Não: ele mesmo continuou, e a próxima pessoa veio muito depois.
    var questions: usize = 0;
    var has_price = false;
    for (t.nodes.items) |*n| if (n.kind == .item and std.mem.startsWith(u8, n.key, "question")) {
        questions += 1;
        if (std.mem.indexOf(u8, n.sub, "preço") != null) has_price = true;
        try std.testing.expect(std.mem.indexOf(u8, n.sub, "viu isso") == null);
        try std.testing.expect(std.mem.indexOf(u8, n.sub, "própria") == null);
        try std.testing.expect(std.mem.indexOf(u8, n.sub, "velha") == null);
        try std.testing.expect(std.mem.indexOf(u8, n.sub, "um link") == null);
    };
    try std.testing.expect(has_price);
    try std.testing.expectEqual(@as(usize, 2), questions);
    // Links e arquivos, sem repetir, e o link velho de fora.
    var links: usize = 0;
    for (t.nodes.items) |*n| if (std.mem.startsWith(u8, n.key, "link") and n.kind == .item) {
        links += 1;
        try std.testing.expect(std.mem.indexOf(u8, n.sub, "velho") == null);
    };
    try std.testing.expectEqual(@as(usize, 2), links);
    // Um clique leva à mensagem.
    e.panelGesture(p, nodeKey(p.tree.?, "mention1").click, null);
    e.waitIdle();
    try std.testing.expectEqual(@as(u64, 200), T.jump_id);
    // Fechou: some da memória.
    e.openPanel(null);
    e.waitIdle();
    try std.testing.expect(!hasKey(p.tree.?, "person1"));
    try std.testing.expect(!p.man.has(.storage));
}

test "o que perdi: sem nada novo mostra as últimas, e dá para escolher quantas" {
    T.wipeDisk();
    var e = T.engine();
    defer e.deinit();
    var msgs: [120]Message = undefined;
    for (&msgs, 0..) |*m, i| {
        m.* = .{ .id = 1000 + i, .content = "oi", .author = if (i < 110) 7 else 8, .author_name = if (i < 110) "ana" else "bia", .channel = 42, .channel_name = "geral", .timestamp = @intCast(1000 + i) };
    }
    T.loaded = &msgs;
    const p = testOne(&e, Bundled.src("catchup.lua"));
    e.openPanel(p);
    e.waitIdle();
    try std.testing.expect(hasKey(p.tree.?, "nothing-new"));
    try std.testing.expectEqual(@as(f32, 90), nodeKey(p.tree.?, "person1").value);
    sync.sleepMs(520);
    e.panelGesture(p, nodeKey(p.tree.?, "mode").change, "50");
    e.waitIdle();
    try std.testing.expect(!hasKey(p.tree.?, "nothing-new"));
    try std.testing.expectEqual(@as(f32, 40), nodeKey(p.tree.?, "person1").value);
    try std.testing.expectEqualStrings("ana", nodeKey(p.tree.?, "person1").text);
    try std.testing.expectEqual(@as(f32, 10), nodeKey(p.tree.?, "person2").value);
}

// --- Cartões do GitHub ---------------------------------------------------------------

const Gh = struct {
    const repo = @embedFile("testdata/github/repo-curl.json");
    /// O #1 do curl é um pull request antigo.
    const old_pr = @embedFile("testdata/github/issue-curl.json");
    const moved = @embedFile("testdata/github/moved.json");
    const missing = @embedFile("testdata/github/missing.json");
    const limit = "{\"message\":\"API rate limit exceeded for 1.2.3.4. (But here's the good news: Authenticated requests get a higher rate limit.)\",\"documentation_url\":\"https://docs.github.com/rest\",\"status\":\"403\"}";

    fn start(e: *Engine) *Plugin {
        const p = testOne(e, Bundled.src("github.lua"));
        e.setApproved(p, "api.github.com", true);
        e.waitIdle();
        return p;
    }
};

test "cartões do GitHub: nada sai sem aprovar, e o que sai é só o nome e o número" {
    T.wipeDisk();
    var e = T.engine();
    defer e.deinit();
    const p = testOne(&e, Bundled.src("github.lua"));
    try std.testing.expect(p.err() == null);
    Cve.say(&e, 601, "olha o curl/curl#1 que coisa");
    try std.testing.expectEqual(@as(usize, 0), T.http_n);
    e.setApproved(p, "api.github.com", true);
    e.waitIdle();
    try std.testing.expectEqual(@as(usize, 1), T.http_n);
    try std.testing.expectEqualStrings("https://api.github.com/repos/curl/curl/issues/1", Cve.lastUrl());
    T.respond(200, Gh.old_pr);
    e.waitIdle();
    try std.testing.expectEqualStrings("🔀 curl/curl#1 · fechado · docs/libcurl/libcurl.m4 bug", Cve.note(&e, 601));
}

test "cartões do GitHub: respostas reais e cada forma de citar" {
    T.wipeDisk();
    var e = T.engine();
    defer e.deinit();
    const p = Gh.start(&e);
    // Repositório: estrelas, linguagem e descrição.
    Cve.say(&e, 611, "usa https://github.com/curl/curl aí");
    try std.testing.expectEqualStrings("https://api.github.com/repos/curl/curl", Cve.lastUrl());
    T.respond(200, Gh.repo);
    e.waitIdle();
    const n = Cve.note(&e, 611);
    try std.testing.expect(std.mem.startsWith(u8, n, "📦 curl/curl · ★ "));
    try std.testing.expect(std.mem.indexOf(u8, n, " · C · ") != null);
    // Mesmo repositório em qualquer forma: já tem.
    Cve.say(&e, 612, "https://www.github.com/curl/curl/blob/master/README.md");
    try std.testing.expectEqual(@as(usize, 0), T.http_n);
    try std.testing.expect(Cve.note(&e, 612).len > 0);
    // Link de pull request e de issue viram o mesmo pedido.
    Cve.say(&e, 613, "https://github.com/zig-lang/zig/pull/42.");
    try std.testing.expectEqualStrings("https://api.github.com/repos/zig-lang/zig/issues/42", Cve.lastUrl());
    T.respond(200, "{\"title\":\"Um PR\",\"state\":\"closed\",\"pull_request\":{\"merged_at\":\"2020-01-01T00:00:00Z\"}}");
    e.waitIdle();
    try std.testing.expectEqualStrings("🔀 zig-lang/zig#42 · mesclado · Um PR", Cve.note(&e, 613));
    Cve.say(&e, 614, "(veja ab/cd#7)");
    T.respond(200, "{\"title\":\"Uma issue\",\"state\":\"open\"}");
    e.waitIdle();
    try std.testing.expectEqualStrings("🐞 ab/cd#7 · aberta · Uma issue", Cve.note(&e, 614));
    Cve.say(&e, 615, "ab/cd#8");
    T.respond(200, "{\"title\":\"Sem plano\",\"state\":\"closed\",\"state_reason\":\"not_planned\"}");
    e.waitIdle();
    try std.testing.expectEqualStrings("🐞 ab/cd#8 · fechada sem correção · Sem plano", Cve.note(&e, 615));
    Cve.say(&e, 616, "ab/cd#9");
    T.respond(200, "{\"title\":\"Em curso\",\"state\":\"open\",\"draft\":true,\"pull_request\":{\"merged_at\":null}}");
    e.waitIdle();
    try std.testing.expectEqualStrings("🔀 ab/cd#9 · rascunho · Em curso", Cve.note(&e, 616));
    // Inexistente ou privado: sem nota nenhuma, e sem pedir de novo.
    Cve.say(&e, 617, "https://github.com/curl/curl/issues/99999999");
    T.respond(404, Gh.missing);
    e.waitIdle();
    try std.testing.expectEqualStrings("", Cve.note(&e, 617));
    Cve.say(&e, 618, "https://github.com/curl/curl/issues/99999999");
    try std.testing.expectEqual(@as(usize, 0), T.http_n);
    try std.testing.expect(p.err() == null);
}

test "cartões do GitHub: o que não é referência não gasta o limite" {
    T.wipeDisk();
    var e = T.engine();
    defer e.deinit();
    _ = Gh.start(&e);
    for ([_][]const u8{
        "conversa normal",
        "canal <#123> e issue #45",
        "e/ou#1 não",
        "https://docs.github.com/rest/guides/best-practices",
        "https://gist.github.com/alguem/abc",
        "https://github.com/",
        "https://github.com/settings/profile",
        "https://github.com/orgs/curl/people",
        "https://github.com/marketplace/actions",
        "https://github.com/curl",
        "https://notgithub.com/curl/curl",
        "`curl/curl#1` em código",
        "```\nhttps://github.com/curl/curl\n```",
        "https://exemplo.com/a/b#1",
    }) |text| {
        Cve.say(&e, 620, text);
        if (T.http_n != 0) {
            std.debug.print("pediu para: {s}\n  {s}\n", .{ text, Cve.lastUrl() });
            return error.PedidoAToa;
        }
    }
}

test "cartões do GitHub: segue um repositório que mudou de nome, uma vez só" {
    T.wipeDisk();
    var e = T.engine();
    defer e.deinit();
    _ = Gh.start(&e);
    Cve.say(&e, 631, "https://github.com/docker/docker");
    T.respond(301, Gh.moved);
    e.waitIdle();
    try std.testing.expectEqualStrings("https://api.github.com/repositories/7691631", Cve.lastUrl());
    T.respond(200, "{\"full_name\":\"moby/moby\",\"stargazers_count\":1500,\"archived\":true}");
    e.waitIdle();
    try std.testing.expectEqualStrings("📦 moby/moby · ★ 1.5k · arquivado", Cve.note(&e, 631));
    // Outro redirecionamento, ou para fora da API: para aí.
    Cve.say(&e, 632, "https://github.com/a/fora");
    T.respond(301, "{\"message\":\"Moved Permanently\",\"url\":\"https://exemplo.com/roubo\"}");
    e.waitIdle();
    try std.testing.expectEqual(@as(usize, 0), T.http_n);
    try std.testing.expectEqualStrings("", Cve.note(&e, 632));
    Cve.say(&e, 633, "https://github.com/a/duas");
    T.respond(301, "{\"url\":\"https://api.github.com/repositories/1\"}");
    e.waitIdle();
    T.respond(301, "{\"url\":\"https://api.github.com/repositories/2\"}");
    e.waitIdle();
    try std.testing.expectEqual(@as(usize, 0), T.http_n);
}

test "cartões do GitHub: passado o limite, espera sem insistir nem mostrar o aviso" {
    T.wipeDisk();
    var e = T.engine();
    defer e.deinit();
    const p = Gh.start(&e);
    Cve.say(&e, 641, "https://github.com/curl/curl");
    T.respond(403, Gh.limit);
    e.waitIdle();
    try std.testing.expectEqualStrings("", Cve.note(&e, 641));
    // Mais citações não geram pedido nenhum até o tempo passar.
    Cve.say(&e, 642, "https://github.com/ziglang/zig");
    Cve.say(&e, 643, "https://github.com/curl/curl");
    try std.testing.expectEqual(@as(usize, 0), T.http_n);
    try std.testing.expect(p.err() == null);
    // No próprio plugin, no máximo 30 pedidos por hora: sobra para o resto da máquina.
    var f = T.engine();
    defer f.deinit();
    T.wipeDisk();
    _ = Gh.start(&f);
    var made: usize = 0;
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        var buf: [64]u8 = undefined;
        Cve.say(&f, 700 + i, std.fmt.bufPrint(&buf, "https://github.com/a/r{d}", .{i}) catch unreachable);
        while (T.http_n > 0) {
            made += 1;
            T.respond(200, "{\"full_name\":\"a/r\"}");
            f.waitIdle();
        }
    }
    try std.testing.expectEqual(@as(usize, 30), made);
}
