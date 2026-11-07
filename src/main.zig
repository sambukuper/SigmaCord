const std = @import("std");
const sys = @import("platform/sys.zig");
const builtin = @import("builtin");
const c = @import("c");

// Os avisos do app (--stats, conexão) usam info: valem também no build otimizado.
pub const std_options: std.Options = .{
    .log_level = .info,
    .logFn = @import("platform/debug_log.zig").logFn,
    // A pilha de sinal só serve para imprimir o rastro de um travamento, e é
    // TLS: custava 256 KB em cada thread, inclusive as do SDL e do driver.
    .signal_stack_size = if (builtin.mode == .debug) 1 << 18 else null,
};
// Sem símbolos o rastro não diz nada: no build otimizado, só a mensagem.
pub const panic = if (builtin.mode == .debug) std.debug.FullPanic(std.debug.defaultPanic) else std.debug.simple_panic;
const builtin_themes = @import("builtin_themes");
const App = @import("app.zig").App;
const Options = @import("app.zig").Options;
const discord = @import("net/discord.zig");
const ev = @import("core/event.zig");
const Queue = @import("net/queue.zig").Queue;
const timeline = @import("platform/timeline.zig");
const instance = @import("platform/instance.zig");

const usage =
    \\SigmaCord — cliente de Discord nativo e leve
    \\
    \\uso: sigmacord [opções]
    \\  --theme NOME      começa com esse tema (classico, vidro, terminal, bolhas, zen…)
    \\  --list-themes     lista os temas embutidos
    \\  --settings        abre já nas configurações
    \\  --shot ARQ.png    salva um print quando a tela estabilizar e sai
    \\  --mode MODO       claro ou escuro (ignora as configurações)
    \\  --qa              roda o teste automático da interface (prints em qa-out/)
    \\  --demo            usa os dados de demonstração mesmo com token
    \\  --login           mostra a tela de login (ignora o token salvo)
    \\  --lang IDIOMA     pt ou en (ignora as configurações)
    \\  --no-live         desliga as mensagens automáticas do modo demonstração
    \\  --stats           mostra a linha do tempo da abertura e o custo de cada quadro
    \\  --voice-test G C  entra no canal de voz C do servidor G por 25 s
    \\  --tls-check URL   confere se a rede do app funciona neste sistema (certificados e WebSocket)
    \\  --restarted       toma o lugar do SigmaCord que está fechando (usado ao reiniciar)
    \\
    \\atalhos: Ctrl+K paleta · Ctrl+, configurações · F2 próximo tema
    \\         Ctrl+Tab abas · Alt+1..9 · Ctrl+W fecha aba
    \\
;

pub fn main(init: std.process.Init.Minimal) !void {
    sys.init();
    var opts: Options = .{};
    var restarted = false;
    var it = if (sys.windows) try std.process.Args.Iterator.initAllocator(init.args, std.heap.c_allocator) else std.process.Args.Iterator.init(init.args);
    _ = it.skip();
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--theme")) {
            opts.theme = it.next() orelse return fail("--theme precisa de um nome");
        } else if (std.mem.eql(u8, arg, "--shot")) {
            opts.shot = (it.next() orelse return fail("--shot precisa de um arquivo")).ptr;
            opts.live = false;
        } else if (std.mem.eql(u8, arg, "--no-live")) {
            opts.live = false;
        } else if (std.mem.eql(u8, arg, "--mode")) {
            const m = it.next() orelse return fail("--mode precisa de claro ou escuro");
            opts.mode = if (std.mem.eql(u8, m, "claro") or std.mem.eql(u8, m, "light")) .light else .dark;
        } else if (std.mem.eql(u8, arg, "--qa")) {
            if (!@import("ui/qa.zig").compiled) return fail("este build não tem o QA: compile com -Doptimize=debug ou -Dqa=true");
            opts.qa = true;
            opts.live = false;
            if (@import("c").SDL_getenv("SDL_VIDEO_DRIVER") == null) _ = @import("c").SDL_setenv_unsafe("SDL_VIDEO_DRIVER", "offscreen", 1);
        } else if (std.mem.eql(u8, arg, "--lang")) {
            const l = it.next() orelse return fail("--lang precisa de pt, en ou ja");
            opts.lang = if (std.mem.startsWith(u8, l, "pt"))
                .pt
            else if (std.mem.startsWith(u8, l, "ja"))
                .ja
            else
                .en;
        } else if (std.mem.eql(u8, arg, "--login")) {
            opts.login = true;
        } else if (std.mem.eql(u8, arg, "--restarted")) {
            restarted = true;
        } else if (std.mem.eql(u8, arg, "--demo")) {
            opts.demo = true;
        } else if (std.mem.eql(u8, arg, "--settings")) {
            opts.settings = true;
        } else if (std.mem.eql(u8, arg, "--stats")) {
            opts.stats = true;
        } else if (std.mem.eql(u8, arg, "--tls-check")) {
            return tlsCheck(it.next() orelse return fail("--tls-check precisa de um endereço"));
        } else if (std.mem.eql(u8, arg, "--voice-test")) {
            const g = it.next() orelse return fail("--voice-test precisa do servidor e do canal");
            const ch = it.next() orelse return fail("--voice-test precisa do servidor e do canal");
            const gid = std.fmt.parseInt(u64, g, 10) catch return fail("servidor inválido");
            const cid = std.fmt.parseInt(u64, ch, 10) catch return fail("canal inválido");
            return voiceTest(gid, cid);
        } else if (@import("builtin").mode == .debug and !sys.windows and std.mem.eql(u8, arg, "--qa-lsp-server")) {
            // O servidor de linguagem de mentira do QA (src/qa_lsp_server.zig), só em debug.
            @import("qa_lsp_server.zig").run(it.next() orelse return fail("--qa-lsp-server precisa de um modo"));
        } else if (!sys.windows and std.mem.eql(u8, arg, "--tray-helper")) {
            // Só o próprio app chama (platform/tray.zig): é o processo do ícone da bandeja.
            const open = it.next() orelse return fail("--tray-helper precisa de dois rótulos");
            const quit = it.next() orelse return fail("--tray-helper precisa de dois rótulos");
            @import("platform/tray.zig").helperMain(open.ptr, quit.ptr);
        } else if (std.mem.eql(u8, arg, "--list-themes")) {
            for (builtin_themes.list) |t| std.debug.print("{s}\n", .{t.name});
            return;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            std.debug.print("{s}", .{usage});
            return;
        } else return fail("opção desconhecida (veja --help)");
    }

    // O QA nunca fala com o Discord, nem por um filho dele: quem herdou o ambiente
    // de uma bateria entra na demonstração, nunca com a conta guardada.
    if (!opts.qa and (c.SDL_getenv("QA_SUITE") != null or c.SDL_getenv("QA_SCENE") != null)) opts.demo = true;

    // Um por vez: a demonstração, os prints e o QA não têm conexão para repetir
    // e rodam ao lado do app de verdade (SIGMACORD_INSTANCE=1 liga para testar).
    const single = (!opts.qa and opts.shot == null and !opts.demo) or c.SDL_getenv("SIGMACORD_INSTANCE") != null;
    if (single) switch (instance.begin(restarted)) {
        .primary, .alone => {},
        .signaled => return,
        .stuck => {
            _ = c.SDL_ShowSimpleMessageBox(c.SDL_MESSAGEBOX_ERROR, "SigmaCord", "O SigmaCord já está aberto, mas não está respondendo.\nThe SigmaCord already running isn't responding.", null);
            std.process.exit(1);
        },
    };

    if (opts.stats) timeline.begin();
    const app = try App.create(std.heap.c_allocator, opts);
    instance.listen(app.win.wake_type);
    const ok = app.run();
    // Fechou a janela: o processo termina de qualquer jeito, mesmo que uma
    // thread de rede demore a largar (nunca fica rodando escondido).
    _ = c.SDL_DetachThread(c.SDL_CreateThread(watchdog, "quit", null));
    const restart = app.restart_wanted;
    app.destroy();
    // No QA, reiniciar só confere a saída: a cópia nova entraria na conta de quem roda.
    if (restart and !opts.qa) @import("net/updater.zig").spawnSelf();
    if (!ok) std.process.exit(1);
}

/// O curl do app contra um endereço qualquer, sem conta nenhuma: confere os certificados
/// deste sistema e se esse curl fala WebSocket, sem o qual o app não conecta.
fn tlsCheck(url: [:0]const u8) void {
    _ = c.curl_global_init(c.CURL_GLOBAL_DEFAULT);
    const h = c.curl_easy_init() orelse std.process.exit(1);
    _ = c.curl_easy_setopt(h, c.CURLOPT_URL, url.ptr);
    _ = c.curl_easy_setopt(h, c.CURLOPT_NOBODY, @as(c_long, 1));
    _ = c.curl_easy_setopt(h, c.CURLOPT_PROTOCOLS_STR, "https");
    _ = c.curl_easy_setopt(h, c.CURLOPT_CONNECTTIMEOUT, @as(c_long, 20));
    sys.curlTls(h);
    const res = c.curl_easy_perform(h);
    std.debug.print("{s}: {s}\n", .{ url, c.curl_easy_strerror(res) });
    const info = c.curl_version_info(c.CURLVERSION_NOW);
    var ws = false;
    var p = info.*.protocols;
    while (p.* != null) : (p += 1) {
        if (std.mem.eql(u8, std.mem.span(p.*), "wss")) ws = true;
    }
    std.debug.print("libcurl {s}, WebSocket: {}\n", .{ info.*.version, ws });
    if (res != c.CURLE_OK or !ws) std.process.exit(1);
}

fn watchdog(_: ?*anyopaque) callconv(.c) c_int {
    c.SDL_Delay(3000);
    std.log.warn("encerramento demorou mais de 3 s; saindo assim mesmo", .{});
    std.c._exit(0);
}

var test_ctx: u8 = 0;

fn voiceTest(guild: u64, channel: u64) !void {
    _ = c.SDL_Init(c.SDL_INIT_AUDIO);
    const alloc = std.heap.c_allocator;
    _ = c.curl_global_init(c.CURL_GLOBAL_DEFAULT);
    const token = discord.loadToken() orelse return fail("defina SIGMACORD_TOKEN para testar a voz");
    var gw: discord.Gateway = .{
        .commands = try Queue(ev.Command).init(alloc),
        .sink = .{ .ctx = &test_ctx, .push = testSink },
        .token = token,
    };
    std.debug.print("voz: conectando ao gateway...\n", .{});
    try gw.start();
    // Sempre mudo: o teste só escuta (não transmite o microfone de ninguém).
    gw.commands.push(.{ .join_voice = .{ .guild = guild, .channel = channel, .mute = true } });
    std.debug.print("voz: pedido de entrar no canal enviado\n", .{});
    var i: u32 = 0;
    while (i < 25) : (i += 1) {
        c.SDL_Delay(1000);
    }
    gw.commands.push(.{ .join_voice = .{ .guild = guild, .channel = null, .mute = true } });
    c.SDL_Delay(1500);
    gw.stop();
    c.SDL_Quit();
    std.debug.print("voz: teste encerrado\n", .{});
}

fn testSink(_: ?*anyopaque, e: ev.Event) void {
    std.debug.print("evento: {t}\n", .{e});
    switch (e) {
        .voice_status => |v| std.debug.print("[voz] status: {t} (canal {d})\n", .{ v.status, v.channel }),
        .voice_speaking => |v| std.debug.print("[voz] {d} falando={}\n", .{ v.user, v.speaking }),
        .notice => |n| std.debug.print("[voz] aviso: {s}\n", .{n}),
        .status => |st| if (st == .failed) std.debug.print("[voz] conexão falhou\n", .{}),
        else => {},
    }
}

fn fail(msg: []const u8) error{InvalidArgs} {
    std.debug.print("sigmacord: {s}\n", .{msg});
    return error.InvalidArgs;
}
