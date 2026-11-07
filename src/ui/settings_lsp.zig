//! Configurações → Erros no código (LSP): o comando e o interruptor de cada
//! linguagem, o que foi achado no PATH e os servidores propostos por plugins.
//! Tudo desligado por padrão: nada sobe sem a pessoa ligar a linguagem aqui.
const std = @import("std");
const c = @import("c");
const d = @import("draw.zig");
const qa = @import("qa.zig");
const i18n = @import("i18n.zig");
const anim = @import("anim.zig");
const S = @import("settings_state.zig");
const L = @import("../core/lsp.zig");
const net = @import("../net/lsp.zig");
const lsp_ui = @import("lsp_ui.zig");
const engine = @import("../plugins/engine.zig");

const base_id: usize = 0x15C00;

var cmd_bufs: [L.known.len][256]u8 = @splat(@splat(0));
var cmd_seen: [L.known.len]S.Text = @splat(.{});
var scanned = false;

pub fn draw(p: anytype) void {
    const s = &p.ctx.st.settings;
    p.title(i18n.tr("Erros no código", "Code diagnostics"));
    p.note(i18n.tr("Mostra erros enquanto você digita um bloco ```zig na caixa de texto, usando um servidor LSP.", "Shows errors while you type a ```zig block in the message box, using an LSP server."));
    p.note(i18n.tr("O SigmaCord não traz nem baixa servidor: é um programa seu, que só roda se você ligar aqui.", "SigmaCord doesn't ship or download servers: it's your own program, and it only runs if you turn it on here."));
    p.note(i18n.tr("Vai para ele só o bloco que você está digitando, nunca as mensagens dos outros.", "Only the block you're typing goes to it, never other people's messages."));
    // A primeira visita procura no PATH (só olha se o arquivo existe, não executa).
    if (!scanned) {
        scanned = true;
        net.scanStart();
    }
    p.divider();
    for (L.known, 0..) |k, i| language(p, s, k, i);
    if (p.button(i18n.tr("Procurar no PATH de novo", "Search PATH again"), false)) net.scanStart();
    p.y += 8;
    plugins(p, s);
}

fn stateText(buf: []u8, st: *const net.Status, on: bool, exe: []const u8) []const u8 {
    var why: [96]u8 = undefined;
    return switch (st.state) {
        .starting => i18n.fmt(buf, "Iniciando {s}…", "Starting {s}…", .{exe}),
        .ready => i18n.fmt(buf, "Rodando {s}. Sai depois de 1 minuto sem digitar.", "Running {s}. Stops after 1 minute without typing.", .{exe}),
        .retrying => i18n.fmt(buf, "{s}; tentando de novo ({d}/3)", "{s}; trying again ({d}/3)", .{ lsp_ui.failureText(&why, st), st.attempts }),
        .stopping => i18n.fmt(buf, "Encerrando {s}…", "Stopping {s}…", .{exe}),
        .failed => i18n.fmt(buf, "Parado: {s}", "Stopped: {s}", .{lsp_ui.failureText(&why, st)}),
        .off => if (on) i18n.tr("Ligado: inicia quando você digitar um bloco dessa linguagem.", "On: starts when you type a block in this language.") else i18n.tr("Desligado", "Off"),
    };
}

fn language(p: anytype, s: *S.Settings, k: L.Known, i: usize) void {
    const ctx = p.ctx;
    const on = S.lspOn(s, i);
    const cmd = S.lspCmd(s, i);
    const st = net.statusOf(k.key);
    var parsed: L.Command = .{};
    const valid = L.splitArgv(cmd.slice(), &parsed);
    var buf: [200]u8 = undefined;
    const wanted_before = on.*;
    p.toggle(k.label, stateText(&buf, &st, on.*, parsed.program()), on);
    // Sem comando não há o que ligar: o interruptor volta e diz por quê.
    if (on.* and !wanted_before and !valid) {
        on.* = false;
        ctx.st.showToast(ctx.now_ms, true, "escreva o comando de {s} antes de ligar", "type the {s} command before turning it on", .{k.label});
    }

    // O comando.
    if (!std.mem.eql(u8, cmd_seen[i].slice(), cmd.slice())) {
        cmd_seen[i] = cmd.*;
        @memset(&cmd_bufs[i], 0);
        @memcpy(cmd_bufs[i][0..cmd.len], cmd.slice());
    }
    const iw = @min(p.w, 520);
    const ir: d.Rect = .{ .x = p.x, .y = p.y - 3, .w = iw, .h = 32 };
    d.rect(p.dl, ir, ctx.col(.elevated), 6);
    d.border(p.dl, ir, if (cmd.len > 0 and !valid) ctx.col(.danger) else ctx.col(.border), 6, 1);
    c.ImGui_SetCursorScreenPos(d.v(p.x + 10, p.y));
    c.ImGui_SetNextItemWidth(iw - 20);
    var hint: [80]u8 = undefined;
    const exe0 = k.exes[0];
    const hint_z = std.fmt.bufPrintSentinel(&hint, "{s}{s}{s}", .{ exe0.name, if (exe0.args.len > 0) " " else "", exe0.args }, 0) catch "";
    c.ImGui_PushIDInt(@intCast(i));
    const enter = c.ImGui_InputTextWithHint("##lsp-cmd", hint_z.ptr, &cmd_bufs[i], cmd_bufs[i].len, c.ImGuiInputTextFlags_EnterReturnsTrue);
    const done = enter or c.ImGui_IsItemDeactivatedAfterEdit();
    c.ImGui_PopID();
    qa.mark(.{ .x = p.x, .y = p.y, .w = iw, .h = 30 }, "lsp-cmd:{s}", .{k.key});
    if (done) {
        cmd.set(std.mem.trim(u8, std.mem.sliceTo(&cmd_bufs[i], 0), " "));
        cmd_seen[i] = cmd.*;
        if (cmd.len == 0) on.* = false;
    }
    p.y += 38;
    if (cmd.len > 0 and !valid) {
        qa.mark(.{ .x = p.x, .y = p.y, .w = p.w, .h = 22 }, "lsp-cmd-ruim:{s}", .{k.key});
        _ = d.textClipped(p.dl, p.font(.regular), 13, p.x, p.y, ctx.col(.danger), i18n.tr("Comando inválido: confira as aspas. O texto não passa por um shell.", "Invalid command: check the quotes. The text doesn't go through a shell."), p.w);
        p.y += 24;
    }

    // Achado no PATH: só uma sugestão; ligar é a pessoa quem faz.
    if (cmd.len == 0) if (net.scanResult(i)) |found| {
        const exe = k.exes[found.exe];
        const path = found.path[0..found.path_len];
        var nb: [600]u8 = undefined;
        qa.mark(.{ .x = p.x, .y = p.y, .w = p.w, .h = 22 }, "lsp-sugestao:{s}", .{k.key});
        _ = d.textClipped(p.dl, p.font(.regular), 13, p.x, p.y, ctx.col(.muted), i18n.fmt(&nb, "Encontrado no PATH (não foi executado): {s}", "Found on PATH (not run): {s}", .{path}), p.w);
        p.y += 24;
        var lb: [80]u8 = undefined;
        if (p.button(i18n.fmt(&lb, "Usar {s} e ligar", "Use {s} and turn on", .{exe.name}), false)) {
            var tb: [600]u8 = undefined;
            cmd.set(L.commandText(&tb, path, exe.args));
            on.* = true;
            anim.active = true;
        }
    };

    if (st.state == .failed) {
        var lb: [80]u8 = undefined;
        if (p.button(i18n.fmt(&lb, "Tentar de novo: {s}", "Try again: {s}", .{k.label}), false)) lsp_ui.retry(k.key);
    }
    p.y += 10;
}

fn plugins(p: anytype, s: *S.Settings) void {
    const e = engine.current orelse return;
    var any = false;
    for (e.list.items) |pl| {
        if (pl.isRunning() and pl.lsp.items.len > 0) any = true;
    }
    if (!any) {
        p.note(i18n.tr("Plugins também podem propor um servidor, com sigma.lsp. Guia: docs/lsp.md", "Plugins can also propose a server, with sigma.lsp. Guide: docs/lsp.md"));
        return;
    }
    p.divider();
    p.heading(i18n.tr("Propostos por plugins", "Proposed by plugins"));
    p.note(i18n.tr("Ligue só se confiar no programa abaixo. Se o plugin mudar o comando, ele volta a ficar desligado.", "Only turn on if you trust the program below. If the plugin changes the command, it goes back to off."));
    p.note(i18n.tr("Se a linguagem também tem um comando seu ligado acima, o seu vale.", "If the language also has your own command on above, yours wins."));
    for (e.list.items) |pl| {
        if (!pl.isRunning()) continue;
        for (pl.lsp.items) |*srv| pluginRow(p, s, pl, srv);
    }
}

fn pluginRow(p: anytype, s: *S.Settings, pl: *engine.Plugin, srv: *const engine.LspServer) void {
    const key = L.approvalKey(pl.name, srv.lang.slice(), &srv.cmd);
    var on = L.isApproved(s.lsp_plugins_ok.slice(), &key);
    const was = on;
    var lb: [160]u8 = undefined;
    const label = std.fmt.bufPrint(&lb, "{s} · {s}", .{ srv.lang.slice(), pl.name }) catch pl.name;
    var ab: [300]u8 = undefined;
    p.toggle(label, srv.cmd.display(&ab), &on);
    if (on == was) {
        const key_name = L.canonicalLang(srv.lang.slice());
        const st = net.statusOf(key_name);
        if (on and st.state == .failed) {
            var why: [96]u8 = undefined;
            var bb: [160]u8 = undefined;
            _ = d.textClipped(p.dl, p.font(.regular), 13, p.x, p.y, p.ctx.col(.danger), i18n.fmt(&bb, "Parado: {s}", "Stopped: {s}", .{lsp_ui.failureText(&why, &st)}), p.w);
            p.y += 24;
            var rb: [80]u8 = undefined;
            if (p.button(i18n.fmt(&rb, "Tentar de novo: {s}", "Try again: {s}", .{srv.lang.slice()}), false)) lsp_ui.retry(key_name);
        }
        return;
    }
    var out: [255]u8 = undefined;
    if (on) {
        // A lista é pequena: sem lugar, as liberações mais antigas saem (e voltam
        // a pedir para ligar, que é o lado seguro).
        var list = s.lsp_plugins_ok;
        while (L.withApproval(&out, list.slice(), &key, out.len) == null) {
            var it = std.mem.tokenizeScalar(u8, list.slice(), ' ');
            const first = it.next() orelse break;
            var tmp: [255]u8 = undefined;
            const old: *const [L.approval_len]u8 = first[0..L.approval_len];
            list.set(L.withoutApproval(&tmp, list.slice(), old));
        }
        s.lsp_plugins_ok.set(L.withApproval(&out, list.slice(), &key, out.len) orelse "");
    } else {
        s.lsp_plugins_ok.set(L.withoutApproval(&out, s.lsp_plugins_ok.slice(), &key));
    }
}
