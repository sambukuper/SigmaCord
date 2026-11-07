//! Várias contas, do lado do app: de onde vem o token ao abrir, trocar de
//! conta (desconecta e reconecta com a outra), adicionar (o login aparece
//! por cima sem esquecer as guardadas), remover, sair, e o que guardar
//! quando o READY chega. A lista e os tokens ficam em net/accounts_store.zig.
const std = @import("std");
const App = @import("app.zig").App;
const ev = @import("core/event.zig");
const types = @import("core/types.zig");
const accounts = @import("core/accounts.zig");
const discord = @import("net/discord.zig");
const accounts_store = @import("net/accounts_store.zig");
const msg_cache = @import("net/msg_cache.zig");
const i18n = @import("ui/i18n.zig");
const nowMs = @import("net/fake_gateway.zig").nowMs;
const c = @import("c");
const platform = @import("platform/window.zig");

/// De onde veio o token da conexão atual (decide o que guardar no READY).
/// `env`: SIGMACORD_TOKEN, nunca guardado. `legacy`: a entrada única de antes
/// das várias contas. `saved`: o de uma conta da lista. `typed`: o do login.
pub const TokenSource = union(enum) { none, env, legacy, saved: types.Id, typed };

pub var token_source: TokenSource = .none;
/// Conta do "Voltar" da tela de login.
pub var prev_account: types.Id = 0;

/// SIGMACORD_TOKEN: não precisa perguntar a ninguém.
pub fn envStartupToken() ?[:0]u8 {
    const t = discord.envToken() orelse return null;
    token_source = .env;
    return t;
}

/// A busca no chaveiro roda em outra thread (o `secret-tool` não pode segurar
/// a primeira tela). Ela só mexe nestes campos e na cópia da lista.
const Lookup = struct {
    list: accounts.List = .{},
    wake_type: u32 = 0,
    token: ?[:0]u8 = null,
    source: TokenSource = .none,
};
var lookup: Lookup = .{};
var lookup_running = false;
/// Ainda vale usar a resposta? (Deixa de valer se a pessoa agiu antes dela.)
var lookup_wanted = false;

/// A conta usada da última vez (ou outra guardada) e, por fim, a entrada antiga.
pub fn startStartupLookup(wake_type: u32) void {
    lookup = .{ .list = accounts_store.list, .wake_type = wake_type };
    lookup_running = true;
    lookup_wanted = true;
    if (c.SDL_CreateThread(lookupMain, "token", null)) |t| {
        // Desligada: um chaveiro travado não segura o encerramento do app.
        c.SDL_DetachThread(t);
    } else _ = lookupMain(null);
}

fn lookupMain(_: ?*anyopaque) callconv(.c) c_int {
    var id: types.Id = 0;
    if (accounts_store.startupTokenFrom(&lookup.list, &id)) |t| {
        lookup.token = t;
        lookup.source = .{ .saved = id };
    } else if (discord.loadSavedToken()) |t| {
        lookup.token = t;
        lookup.source = .legacy;
    }
    platform.Window.wake(lookup.wake_type, .token);
    return 0;
}

pub fn abandonStartupLookup() void {
    lookup_wanted = false;
}

/// A resposta do chaveiro chegou (na thread da UI).
pub fn finishStartupLookup(app: *App) void {
    if (!lookup_running) return;
    lookup_running = false;
    const token = lookup.token;
    lookup.token = null;
    if (token) |t| {
        if (!lookup_wanted or app.net != .none) return discardToken(t);
        token_source = lookup.source;
        app.startReal(t) catch {
            discardToken(t);
            return app.login.begin(.form);
        };
        if (app.login.phase != .connecting) app.login.setPhase(.connecting);
    } else if (lookup_wanted and app.login.phase == .connecting and app.net == .none) {
        // Tinha conta na lista, mas o token dela sumiu.
        app.login.begin(.form);
    }
}

fn discardToken(t: [:0]u8) void {
    std.crypto.secureZero(u8, t);
    std.heap.c_allocator.free(t);
}

pub fn handle(app: *App, a: ev.Action) void {
    switch (a) {
        .logout => {
            app.saveSettings();
            // Esquece só esta conta; as outras guardadas continuam.
            const sid = accounts_store.session;
            forget(sid);
            toLogin(app);
        },
        .switch_account => |id| if (id != accounts_store.session) {
            _ = switchAccount(app, id);
        },
        .add_account => {
            // O login aparece por cima; a conta aberta continua conectada
            // até entrar com a outra (ou voltar).
            app.st.popup = .none;
            prev_account = accounts_store.session;
            app.login.begin(.form);
            app.login.t = 10;
            var b: [96]u8 = undefined;
            const name = if (accounts_store.list.find(accounts_store.session)) |acc| acc.name() else if (app.store.user(app.store.me)) |u| u.name else "?";
            app.login.setBack(i18n.fmt(&b, "Voltar para {s}", "Back to {s}", .{name}));
        },
        .remove_account => |id| {
            if (accounts_store.list.find(id) == null) return;
            const current = id == accounts_store.session;
            forget(id);
            if (!current) return app.st.showToast(nowMs(), false, "conta removida", "account removed", .{});
            // Era a aberta: entra em outra guardada, ou volta ao login.
            if (accounts_store.list.len > 0 and switchAccount(app, accounts_store.list.items[0].id)) return;
            toLogin(app);
        },
        else => {},
    }
}

fn toLogin(app: *App) void {
    app.stopNet();
    app.resetSession();
    accounts_store.session = 0;
    app.login.begin(.form);
    app.login.t = 10; // sem a abertura de novo
}

/// Troca de conta: desconecta e entra na outra (a tela de abertura
/// aparece até o READY). false = não achou o token (nada muda).
pub fn switchAccount(app: *App, id: types.Id) bool {
    const acc = accounts_store.list.find(id) orelse return false;
    if (app.opts.qa) {
        // O QA nunca fala com o Discord: a "outra conta" é a demonstração de novo.
        app.stopNet();
        app.resetSession();
        prev_account = accounts_store.session;
        accounts_store.session = id;
        accounts_store.list.active = id;
        token_source = .none;
        app.startDemo() catch return false;
        app.login.begin(.connecting);
        app.login.t = 10;
        return true;
    }
    const token = accounts_store.tokenFor(acc) orelse {
        app.st.showToast(nowMs(), true, "não achei o token dessa conta no chaveiro", "couldn't find that account's token in the keyring", .{});
        return false;
    };
    prev_account = accounts_store.session;
    app.stopNet();
    app.resetSession();
    accounts_store.session = 0;
    app.last_notice_len = 0;
    token_source = .{ .saved = id };
    accounts_store.list.active = id;
    accounts_store.save();
    app.login.begin(.connecting);
    app.login.t = 10;
    app.startReal(token) catch {
        std.crypto.secureZero(u8, token);
        std.heap.c_allocator.free(token);
        app.login.fail(i18n.tr("Não consegui iniciar a conexão.", "Couldn't start the connection."));
    };
    return true;
}

/// Esquece uma conta guardada: token, lugar na lista e o cache dela.
fn forget(id: types.Id) void {
    const a = accounts_store.list.find(id) orelse return;
    const acc = a.*;
    // A conta aberta não grava mais nada no cache (que vai ser apagado).
    if (id == accounts_store.session) msg_cache.detach();
    accounts_store.forgetToken(&acc);
    _ = accounts_store.list.remove(id);
    accounts_store.save();
    msg_cache.removeAccount(id);
    if (prev_account == id) prev_account = 0;
}

/// As contas guardadas que a tela de login oferece: todas menos a aberta.
pub fn others(buf: []*const accounts.Account) []const *const accounts.Account {
    var n: usize = 0;
    for (accounts_store.list.slice()) |*a| {
        if (a.id == accounts_store.session or n == buf.len) continue;
        buf[n] = a;
        n += 1;
    }
    return buf[0..n];
}

/// O Discord encerrou a sessão de vez. `token_dead`: recusou o token, que não volta
/// a valer. Guardado, o app só tentaria de novo a cada abertura: outro login recusado
/// à toa para uma conta que acabou de chamar atenção.
pub fn sessionRefused(app: *App, token_dead: bool, msg: []const u8) void {
    app.stopNet();
    app.resetSession();
    if (token_dead) {
        switch (token_source) {
            .saved => |id| forget(id),
            .legacy => {
                discord.forgetToken();
                forget(accounts_store.session);
            },
            .typed => forget(accounts_store.session),
            .none, .env => {},
        }
        token_source = .none;
    }
    accounts_store.session = 0;
    app.login.fail(msg);
}

/// READY: a conta entrou. Atualiza a lista de contas (nome e foto do
/// READY) e, se veio do login com "Lembrar", guarda o token dela.
pub fn ready(app: *App) void {
    const me = app.store.me;
    const list = &accounts_store.list;
    msg_cache.setAccount(if (app.store.demo) 0 else me);
    if (app.store.demo) {
        // (No QA a troca de conta entra na demonstração: fica a escolhida.)
        if (list.find(accounts_store.session) == null) accounts_store.session = me;
        return;
    }
    accounts_store.session = me;
    const u = app.store.user(me);
    const name = if (u) |x| x.name else app.store.me_username orelse "?";
    const avatar = if (u) |x| x.avatar orelse "" else "";
    switch (token_source) {
        // SIGMACORD_TOKEN nunca é guardado; só atualiza quem já estava na lista.
        .none, .env => if (list.find(me)) |a| {
            a.setName(name);
            a.setAvatar(avatar);
            accounts_store.save();
        },
        .legacy => {
            _ = list.upsert(me, name, avatar, true);
            list.active = me;
            accounts_store.save();
        },
        .saved => |id| {
            const legacy = if (list.find(id)) |a| a.legacy else false;
            // O token guardado era de outra conta (trocou de conta por fora).
            if (id != me) _ = list.remove(id);
            _ = list.upsert(me, name, avatar, legacy);
            list.active = me;
            accounts_store.save();
        },
        .typed => if (app.save_token and app.net == .real) {
            app.save_token = false;
            if (list.find(me) == null and list.len == accounts.max_accounts)
                return app.st.showToast(nowMs(), true, "já tem 8 contas guardadas; remova uma para guardar esta", "8 accounts saved already; remove one to save this one", .{});
            const was_legacy = if (list.find(me)) |a| a.legacy else false;
            switch (accounts_store.storeToken(me, app.net.real.token)) {
                .keyring => app.st.showToast(nowMs(), false, "token guardado no chaveiro do sistema", "token saved to the system keyring", .{}),
                .file => app.st.showToast(nowMs(), false, "token guardado em ~/.config/sigmacord/tokens", "token saved to ~/.config/sigmacord/tokens", .{}),
                .failed => return app.st.showToast(nowMs(), true, "não consegui guardar o token", "couldn't save the token", .{}),
            }
            // A entrada antiga era desta conta: a nova substitui.
            if (was_legacy) discord.forgetToken();
            _ = list.upsert(me, name, avatar, false);
            list.active = me;
            accounts_store.save();
        },
    }
}
