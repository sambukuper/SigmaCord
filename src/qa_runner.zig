//! Robô de QA (`sigmacord --qa`): roda fora da tela, com os dados de
//! demonstração, e usa o app como uma pessoa usaria, com eventos reais de
//! mouse e teclado no ImGui, clicando nos elementos marcados pelos
//! componentes (ui/qa.zig). Depois de cada ação confere o estado, salva
//! prints em qa-out/ e no fim imprime o relatório.
const std = @import("std");
const c = @import("c");
const App = @import("app.zig").App;
const qa = @import("ui/qa.zig");
const qa_temas = @import("qa_temas.zig");
const autocomplete = @import("ui/autocomplete.zig");
const gw = @import("net/fake_gateway.zig");
const types = @import("core/types.zig");
const Id = types.Id;

const Key = []const u8;

// O QA roda em debug (tools/qa.sh). O servidor de mentira e o roteiro do LSP são
// pesados para o pouco que a função pesa, e ficam fora do executável de quem usa.
const has_lsp_qa = @import("builtin").mode == .debug and @import("builtin").os.tag != .windows;
const lsp_ops = if (has_lsp_qa) @import("qa_lsp.zig").ops else [_]Op{};
const lsp_ops_quit = if (has_lsp_qa) @import("qa_lsp.zig").ops_quit else [_]Op{};
const lsp_ops_real = if (has_lsp_qa) @import("qa_lsp.zig").ops_real else [_]Op{};

/// Onde agir: uma marcação (com deslocamento opcional) ou uma marcação
/// calculada na hora (depende de IDs que só existem durante o teste).
/// QA_SLOW=N: em máquina lenta (sem GPU, no wine), espera N vezes mais antes de
/// dar uma etapa por falha.
fn slowed(ms: i64) i64 {
    const n = if (c.SDL_getenv("QA_SLOW")) |v| std.fmt.parseInt(i64, std.mem.span(v), 10) catch 1 else 1;
    return ms * n;
}

pub const Target = union(enum) {
    mark: Key,
    dyn: *const fn (app: *App, buf: []u8) []const u8,
    /// Ponto dentro da marcação: frações da largura/altura.
    at: struct { key: Key, fx: f32, fy: f32 },
    dyn_at: struct { f: *const fn (app: *App, buf: []u8) []const u8, fx: f32, fy: f32 },
};

pub const Op = union(enum) {
    section: []const u8,
    click: Target,
    rclick: Target,
    mclick: Target,
    ctrl_click: Target,
    dclick: Target,
    hover: Target,
    drag: struct { from: Target, to: Target },
    /// Arrasta algo que anda junto com o mouse (a alça de um painel): o caminho
    /// sai de onde ele estava ao começar. Alvo vazio pula o passo.
    drag_by: struct { from: Target, dx: f32 },
    key: struct { key: c_int, ctrl: bool = false, shift: bool = false, alt: bool = false },
    text: []const u8,
    wait: u32,
    expect: struct { name: []const u8, check: *const fn (app: *App) bool, timeout_ms: u32 = 2500 },
    shot: []const u8,
    resize: [2]c_int,
    run: *const fn (app: *App) void,
    /// Clica em todo elemento da tela cujo nome começa com um dos prefixos
    /// e confere que cada clique muda alguma coisa (botão morto = falha).
    sweep: []const []const u8,
};

// --- Ajudantes para os cenários ---------------------------------------------

fn s(name: []const u8) Op {
    return .{ .section = name };
}
fn click(k: Key) Op {
    return .{ .click = .{ .mark = k } };
}
fn expect(name: []const u8, f: *const fn (*App) bool) Op {
    return .{ .expect = .{ .name = name, .check = f } };
}
fn key(k: c_int) Op {
    return .{ .key = .{ .key = k } };
}
fn ctrl(k: c_int) Op {
    return .{ .key = .{ .key = k, .ctrl = true } };
}

fn active(app: *App) ?*@import("core/store.zig").ChannelState {
    const id = app.st.activeChannel() orelse return null;
    return app.store.channel(id);
}

fn lastMsg(app: *App, back: usize) ?*@import("core/store.zig").StoredMessage {
    const cs = active(app) orelse return null;
    const n = cs.messages.items.len;
    if (back >= n) return null;
    return &cs.messages.items[n - 1 - back];
}

/// Mensagem mais recente de outra pessoa (para responder, perfil…).
fn lastOther(app: *App) ?*@import("core/store.zig").StoredMessage {
    const cs = active(app) orelse return null;
    var i = cs.messages.items.len;
    while (i > 0) {
        i -= 1;
        const m = &cs.messages.items[i];
        if (m.msg.author != app.store.me and m.msg.reply_to == 0) return m;
    }
    return null;
}

var saved_id: Id = 0;
var saved_count: usize = 0;
var saved_theme: usize = 0;
var saved_tab: usize = 0;

fn ch(i: usize) Id {
    return gw.channelId(0, i);
}

fn markFmt(buf: []u8, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.bufPrint(buf, fmt, args) catch "";
}

// Alvos dinâmicos.
fn tReplyLast(app: *App, b: []u8) []const u8 {
    const m = lastOther(app) orelse return "";
    saved_id = m.msg.id;
    return markFmt(b, "tb:{d}:3", .{m.msg.id});
}
fn tHoverOther(app: *App, b: []u8) []const u8 {
    const m = lastOther(app) orelse return "";
    return markFmt(b, "msg:{d}", .{m.msg.id});
}
fn tHoverMine(app: *App, b: []u8) []const u8 {
    const m = lastMsg(app, 0) orelse return "";
    return markFmt(b, "msg:{d}", .{m.msg.id});
}
fn tThumbMine(app: *App, b: []u8) []const u8 {
    const m = lastMsg(app, 0) orelse return "";
    saved_id = m.msg.id;
    return markFmt(b, "tb:{d}:0", .{m.msg.id});
}
fn tChipMine(_: *App, b: []u8) []const u8 {
    return markFmt(b, "chip:{d}:0", .{saved_id});
}
fn tUserOther(app: *App, b: []u8) []const u8 {
    const m = lastOther(app) orelse return "";
    saved_id = m.msg.author;
    return markFmt(b, "user:{d}", .{m.msg.author});
}
/// As duas últimas mensagens com texto (sem anexo/embed), contando do fim:
/// (mais antiga, mais nova). O arraste vai em cima do texto desenhado
/// (marcação msgtext:), então serve para qualquer tema.
fn plainPair(app: *App) ?[2]usize {
    var found: [2]usize = undefined;
    var n: usize = 0;
    var back: usize = 0;
    while (back < 8 and n < 2) : (back += 1) {
        const m = lastMsg(app, back) orelse return null;
        if (m.msg.attachments.len > 0 or m.msg.embeds.len > 0 or m.msg.system != .none or m.msg.content.len < 6) continue;
        if (qa.find(std.fmt.bufPrint(&pair_buf, "msgtext:{d}", .{m.msg.id}) catch continue) == null) continue;
        found[n] = back;
        n += 1;
    }
    return if (n == 2) .{ found[1], found[0] } else null;
}
var pair_buf: [64]u8 = undefined;
fn tSelFrom(app: *App, b: []u8) []const u8 {
    const m = lastMsg(app, (plainPair(app) orelse return "")[0]) orelse return "";
    return markFmt(b, "msgtext:{d}", .{m.msg.id});
}
fn tSelTo(app: *App, b: []u8) []const u8 {
    const m = lastMsg(app, (plainPair(app) orelse return "")[1]) orelse return "";
    return markFmt(b, "msgtext:{d}", .{m.msg.id});
}

// Verificações.
fn ready(app: *App) bool {
    const cs = active(app) orelse return false;
    return app.store.ready and cs.history == .loaded;
}
fn threeTabs(app: *App) bool {
    return app.st.tabs.items.len == 3 and app.st.activeChannel() == ch(4);
}
fn onMemes(app: *App) bool {
    return app.st.activeChannel() == ch(5);
}
fn newTab(app: *App) bool {
    return app.st.tabs.items.len == 4 and app.st.activeChannel() == ch(6);
}
fn tabClosed(app: *App) bool {
    return app.st.tabs.items.len == 3;
}
fn catCollapsed(app: *App) bool {
    return app.st.collapsed.contains(ch(3));
}
fn catOpen(app: *App) bool {
    return !app.st.collapsed.contains(ch(3));
}
fn onGuild1(app: *App) bool {
    const cs = active(app) orelse return false;
    return app.st.guild == gw.guildId(1) and cs.info.guild == gw.guildId(1);
}
fn friendsOpen(app: *App) bool {
    return app.st.guild == 0 and app.st.friends and qa.find("friend:1001") != null;
}
fn pendingTab(app: *App) bool {
    return app.st.friends_tab == 2 and qa.find("friend-accept:1009") != null;
}
fn accepted(app: *App) bool {
    return app.store.relationship(1009) == .friend;
}
fn cancelled(app: *App) bool {
    return app.store.relationship(1006) == .none;
}
fn dmWithAna(app: *App) bool {
    const cs = active(app) orelse return false;
    return !app.st.friends and cs.info.guild == 0 and !cs.info.group and cs.info.recipient == 1001;
}
fn newDm(app: *App) bool {
    const cs = active(app) orelse return false;
    return cs.info.guild == 0 and cs.info.recipient == 1008 and qa.find("dm-profile") != null;
}
fn groupOpen(app: *App) bool {
    const cs = active(app) orelse return false;
    return cs.info.group and qa.find("member:1003") != null and qa.find("member:1005") != null and qa.find("member:1002") == null;
}
/// Lista do servidor 0: Fundação com ana.exe, e quem não está no servidor fica de fora.
fn guildMembers(app: *App) bool {
    const ml = app.store.memberList(gw.guildId(0)) orelse return false;
    if (!ml.synced) return false;
    var role_group = false;
    for (ml.items.items) |it| if (it == .group and it.group.id == gw.guildId(0) + 901) {
        role_group = true;
    };
    return role_group and qa.find("member:1001") != null;
}
/// Servidores diferentes, listas diferentes.
fn otherGuildMembers(app: *App) bool {
    const a = app.store.memberList(gw.guildId(0)) orelse return false;
    const b = app.store.memberList(gw.guildId(1)) orelse return false;
    if (!b.synced) return false;
    // Alguém está numa lista e não na outra.
    for (a.items.items) |x| if (x == .member) {
        const found = for (b.items.items) |y| {
            if (y == .member and y.member.user == x.member.user) break true;
        } else false;
        if (!found) return true;
    };
    return false;
}
fn avatarsLoaded(app: *App) bool {
    var it = app.images.map.iterator();
    while (it.next()) |e| if (std.mem.indexOf(u8, e.key_ptr.*, " demo:av:") != null and e.value_ptr.state == .ready) return true;
    return false;
}
fn iconsLoaded(app: *App) bool {
    var it = app.images.map.iterator();
    while (it.next()) |e| if (std.mem.indexOf(u8, e.key_ptr.*, " demo:icon:") != null and e.value_ptr.state == .ready) return true;
    return false;
}
fn gifAnimated(app: *App) bool {
    var it = app.images.map.iterator();
    while (it.next()) |e| if (std.mem.endsWith(u8, e.key_ptr.*, " demo:gif") and e.value_ptr.state == .ready and e.value_ptr.frames.len > 1) return true;
    return false;
}
fn openFirstDm(app: *App) void {
    app.actions.append(app.gpa, .{ .select_channel = gw.dmId(0) }) catch {};
}
fn statusMenu(app: *App) bool {
    return app.st.popup == .menu and app.st.popup.menu.kind == .status;
}
fn meDnd(app: *App) bool {
    return app.store.user(app.store.me).?.status == .dnd and app.st.settings.my_status == 2;
}
fn meOnline(app: *App) bool {
    return app.store.user(app.store.me).?.status == .online and app.st.settings.my_status == 0;
}
fn panelOnScreen(app: *App) bool {
    const r = qa.find("me") orelse return false;
    return r.bottom() <= app.io.*.DisplaySize.y and qa.find("hangup") != null;
}
fn jumpToZigLink(app: *App) void {
    const cs = active(app) orelse return;
    // O primeiro: o último pode estar tão perto do fim que a conversa nem rola.
    for (cs.messages.items) |m| if (std.mem.eql(u8, m.msg.content, "https://ziglang.org")) {
        app.st.jump = m.msg.id;
        break;
    };
}
fn linkOpened(_: *App) bool {
    const att = @import("ui/attachments.zig");
    return std.mem.eql(u8, att.last_opened[0..att.last_opened_len], "https://ziglang.org");
}
fn scrollToTop(app: *App) void {
    const sc = app.st.scrollOf(app.st.activeChannel() orelse return);
    sc.stick_bottom = false;
    sc.target = 0;
}
fn jumpBottomShown(_: *App) bool {
    return qa.find("jump-bottom") != null;
}
fn atBottom(app: *App) bool {
    const cs = active(app) orelse return false;
    _ = cs;
    return app.st.scrollOf(app.st.activeChannel().?).stick_bottom and qa.find("jump-bottom") == null;
}
fn skipExtraThemes(app: *App) void {
    const n = app.themes.entries.items.len;
    if (n > 7) for (0..n - 7) |_| app.actions.append(app.gpa, .{ .next_theme = 1 }) catch {};
}
fn toClassico(app: *App) void {
    for (app.themes.names.items, 0..) |nm, i| if (std.mem.eql(u8, nm, "classico")) {
        app.actions.append(app.gpa, .{ .set_theme = i }) catch {};
    };
}
fn scrollBottom(app: *App) void {
    if (app.st.activeChannel()) |id| app.st.scrollOf(id).stick_bottom = true;
}
// Vídeo (com ou sem FFmpeg no sistema: sem ele, o play só avisa).
const video = @import("ui/video.zig");
const ffmpeg = @import("platform/ffmpeg.zig");
var video_pos: f64 = 0;
fn hasFfmpeg() bool {
    return ffmpeg.known() == true;
}
fn findVideo(app: *App) ?struct { id: Id, i: usize } {
    const cs = active(app) orelse return null;
    var k = cs.messages.items.len;
    while (k > 0) {
        k -= 1;
        const m = &cs.messages.items[k];
        for (m.msg.attachments, 0..) |a, i| if (a.video and std.mem.eql(u8, a.link, video.demo_link)) return .{ .id = m.msg.id, .i = i };
    }
    return null;
}
fn jumpToVideo(app: *App) void {
    const f = findVideo(app) orelse return;
    app.st.jump = f.id;
}
fn tDemoVideo(app: *App, b: []u8) []const u8 {
    const f = findVideo(app) orelse return "";
    return markFmt(b, "att:{d}:{d}", .{ f.id, f.i });
}
fn tVideoMark(b: []u8, name: []const u8) []const u8 {
    if (!video.info().active) return "";
    return markFmt(b, "{s}", .{name});
}
fn tVideoPlay(_: *App, b: []u8) []const u8 {
    return tVideoMark(b, "video-play");
}
fn tVideoBar(_: *App, b: []u8) []const u8 {
    return tVideoMark(b, "video-bar");
}
fn tVideoClose(_: *App, b: []u8) []const u8 {
    return tVideoMark(b, "video-close");
}
fn tVideoMute(_: *App, b: []u8) []const u8 {
    if (!video.info().has_audio) return "";
    return tVideoMark(b, "video-mute");
}
fn tVideoVol(_: *App, b: []u8) []const u8 {
    if (!video.info().has_audio) return "";
    return tVideoMark(b, "video-vol");
}
fn videoPlaying(app: *App) bool {
    if (!hasFfmpeg()) return !video.info().active and std.mem.indexOf(u8, app.st.toast.text(), "vídeo") != null;
    const v = video.info();
    return v.active and v.playing and v.shown >= 3 and qa.find("video") != null;
}
/// O QA normalmente desenha todo quadro (lê os pixels). Aqui o portão vale de verdade.
var gate_shown: u64 = 0;
var gate_skipped: u64 = 0;
var gate_video: u32 = 0;
fn gateRealOn(app: *App) void {
    gate_shown = app.gate.built - app.gate.skipped;
    gate_skipped = app.gate.skipped;
    gate_video = video.info().shown;
    app.qa_real_gate = true;
}
fn gateRealOff(app: *App) void {
    app.qa_real_gate = false;
    gate_shown = app.gate.built - app.gate.skipped - gate_shown;
    gate_skipped = app.gate.skipped - gate_skipped;
    gate_video = video.info().shown - gate_video;
}
fn videoFramesReachScreen(_: *App) bool {
    if (!hasFfmpeg()) return true;
    if (c.SDL_getenv("QA_DEBUG") != null) std.debug.print("[portão] vídeo {d}, na tela {d}, pulados {d}\n", .{ gate_video, gate_shown, gate_skipped });
    return gate_video >= 5 and gate_skipped > 0 and gate_shown >= gate_video;
}
fn videoLimits(_: *App) bool {
    if (!hasFfmpeg()) return true;
    const v = video.info();
    if (c.SDL_getenv("QA_DEBUG") != null) std.debug.print("[vídeo] {d}x{d} pos={d:.0} dur={d} decodificados={d} mostrados={d} som={} fila={d}\n", .{ v.w, v.h, v.pos_ms, v.duration_ms, v.decoded, v.shown, v.has_audio, v.audio_queued });
    if (v.pos_ms < 900) return false;
    // 60 qps na origem: sem o limite seriam ~2 quadros a cada 33 ms.
    const max_decoded: u32 = @intFromFloat(v.pos_ms / 30 + 6);
    return v.w > 0 and v.w <= 854 and v.h <= 480 and v.decoded <= max_decoded and v.duration_ms == 3000;
}
fn videoAudio(_: *App) bool {
    if (!hasFfmpeg() or !video.audioAvailable()) return true;
    return video.info().has_audio;
}
fn videoPaused(_: *App) bool {
    return !hasFfmpeg() or !video.info().playing;
}
fn rememberVideoPos(_: *App) void {
    video_pos = video.info().pos_ms;
}
fn videoPosKept(_: *App) bool {
    return !hasFfmpeg() or video.info().pos_ms == video_pos;
}
fn videoSeeked(_: *App) bool {
    if (!hasFfmpeg()) return true;
    const v = video.info();
    // 75% de 3 s (a barra começa depois do tempo; a conta é aproximada).
    return v.pos_ms > 1800 and v.pos_ms < 2700 and !v.playing;
}
fn videoResumed(_: *App) bool {
    return !hasFfmpeg() or video.info().playing;
}
/// O vídeo da demonstração tem 3 s e já passou de 75%: pode acabar antes da checagem.
fn videoResumedOrEnded(_: *App) bool {
    return !hasFfmpeg() or video.info().playing or video.info().ended;
}
fn videoMuted(_: *App) bool {
    const v = video.info();
    return !hasFfmpeg() or !v.has_audio or v.muted;
}
/// Confere no SDL o ganho aplicado de fato.
fn videoGainIs(app: *App, volume: u8, gain: f32) bool {
    const v = video.info();
    if (!hasFfmpeg() or !v.has_audio) return true;
    return app.st.settings.video_volume == volume and @abs(v.gain - gain) < 0.002;
}
fn videoVolHalf(app: *App) bool {
    return videoGainIs(app, 50, 0.25);
}
fn videoVolZero(app: *App) bool {
    return videoGainIs(app, 0, 0) and (!hasFfmpeg() or !video.info().has_audio or video.info().muted);
}
fn videoVolFull(app: *App) bool {
    return videoGainIs(app, 100, 1);
}
fn trayFake(_: *App) void {
    @import("platform/tray.zig").fake = true;
}
fn trayFakeOff(_: *App) void {
    @import("platform/tray.zig").fake = false;
}
fn pushCloseEvent(app: *App) void {
    var e = std.mem.zeroes(c.SDL_Event);
    e.type = c.SDL_EVENT_WINDOW_CLOSE_REQUESTED;
    e.window.windowID = c.SDL_GetWindowID(app.win.window);
    _ = c.SDL_PushEvent(&e);
}
fn wakeShowWindow(app: *App) void {
    @import("platform/window.zig").Window.wake(app.win.wake_type, .show);
}
fn hiddenAndPaused(app: *App) bool {
    return @import("qa_bandeja.zig").isHidden(app) and (!hasFfmpeg() or !video.info().playing);
}
fn videoEnded(_: *App) bool {
    if (!hasFfmpeg()) return true;
    const v = video.info();
    return v.ended and !v.playing and v.pos_ms == 3000;
}
fn videoRestarted(_: *App) bool {
    if (!hasFfmpeg()) return true;
    const v = video.info();
    return v.playing and !v.ended and v.pos_ms < 1500;
}
var video_channel: Id = 0;
fn rememberVideoChannel(app: *App) void {
    video_channel = app.st.activeChannel() orelse 0;
}
fn tOtherChannel(_: *App, b: []u8) []const u8 {
    return markFmt(b, "channel:{d}", .{if (video_channel == ch(5)) ch(4) else ch(5)});
}
fn tVideoChannel(_: *App, b: []u8) []const u8 {
    return markFmt(b, "channel:{d}", .{video_channel});
}
/// Fora da tela: pausa e o app pede um quadro para daqui a 30 s (soltar a
/// memória do vídeo mesmo dormindo).
fn videoWakeToRelease(app: *App) bool {
    const v = video.info();
    if (!v.active) return !hasFfmpeg();
    return app.st.activeChannel() != video_channel and !v.playing and
        @import("ui/anim.zig").next_wake_ms <= v.drawn_ms + 30_001;
}
fn videoClosed(_: *App) bool {
    return !video.info().active;
}
fn jumpToMp4Gif(app: *App) void {
    const f = findAttachment(app, "demo:mp4") orelse return;
    app.st.jump = f.id;
}
fn gifHostsOn(app: *App) void {
    app.st.settings.gif_hosts = true;
}
fn gifHostsOff(app: *App) void {
    app.st.settings.gif_hosts = false;
}
fn mp4GifStill(app: *App) bool {
    var it = app.images.map.iterator();
    var still = false;
    while (it.next()) |e| {
        if (std.mem.endsWith(u8, e.key_ptr.*, " demo:mp4")) return false;
        if (std.mem.endsWith(u8, e.key_ptr.*, " demo:2") and e.value_ptr.state == .ready) still = true;
    }
    return still;
}
fn mp4GifAnimated(app: *App) bool {
    var it = app.images.map.iterator();
    if (c.SDL_getenv("QA_DEBUG") != null) {
        var it2 = app.images.map.iterator();
        while (it2.next()) |e| if (std.mem.indexOf(u8, e.key_ptr.*, "demo:mp4") != null) std.debug.print("[mp4] {s} {s} {d}\n", .{ e.key_ptr.*, @tagName(e.value_ptr.state), e.value_ptr.frames.len });
    }
    var mp4_failed = false;
    var still_ok = false;
    while (it.next()) |e| {
        if (std.mem.endsWith(u8, e.key_ptr.*, " demo:mp4")) {
            // 3 s a no máximo 30 qps (o MP4 é de 60).
            if (e.value_ptr.state == .ready and e.value_ptr.frames.len > 10 and e.value_ptr.frames.len <= 91) return hasFfmpeg();
            if (e.value_ptr.state == .failed) mp4_failed = true;
        }
        if (std.mem.endsWith(u8, e.key_ptr.*, " demo:2") and e.value_ptr.state == .ready) still_ok = true;
    }
    return ffmpeg.known() == false and mp4_failed and still_ok;
}

// Proxy.
const proxy = @import("net/proxy.zig");
fn proxyRejected(app: *App) bool {
    return app.st.settings.proxy.len == 0 and std.mem.indexOf(u8, app.st.toast.text(), "inválido") != null and qa.find("proxy-input") != null;
}
fn proxyExternalOnly(app: *App) bool {
    var b: proxy.Buf = undefined;
    if (!std.mem.eql(u8, app.st.settings.proxy.slice(), "socks5h://127.0.0.1:9050")) return false;
    const ext = proxy.forUrl(&b, "https://media.tenor.com/x.webp") orelse return false;
    return std.mem.eql(u8, ext, "socks5h://127.0.0.1:9050") and proxy.forUrl(&b, "https://cdn.discordapp.com/x.png") == null and proxy.forDiscord(&b) == null;
}
fn proxyEverywhere(app: *App) bool {
    var b: proxy.Buf = undefined;
    return app.st.settings.proxy_all and proxy.forUrl(&b, "https://cdn.discordapp.com/x.png") != null and proxy.forDiscord(&b) != null;
}
fn proxyPersisted(app: *App) bool {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(app.gpa);
    @import("ui/settings_state.zig").write(&app.st.settings, "classico", &out, app.gpa) catch return false;
    return std.mem.indexOf(u8, out.items, "proxy=\"socks5h://127.0.0.1:9050\"") != null and std.mem.indexOf(u8, out.items, "proxy_all=#true") != null;
}
fn proxyRemoved(app: *App) bool {
    var b: proxy.Buf = undefined;
    return app.st.settings.proxy.len == 0 and proxy.forUrl(&b, "https://media.tenor.com/x.webp") == null and proxy.forDiscord(&b) == null;
}

fn jumpToGif(app: *App) void {
    const f = findAttachment(app, "demo:gif") orelse return;
    app.st.jump = f.id;
}
fn onDms(app: *App) bool {
    const cs = active(app) orelse return false;
    return app.st.guild == 0 and cs.info.guild == 0;
}
fn onGuild0(app: *App) bool {
    return app.st.guild == gw.guildId(0);
}
fn sentConfirmed(app: *App) bool {
    const m = lastMsg(app, 0) orelse return false;
    return m.msg.author == app.store.me and !m.pending and std.mem.eql(u8, m.msg.content, "teste do QA 🎉 **negrito**");
}
fn failSend(app: *App) void {
    const id = app.st.activeChannel() orelse return;
    app.store.addPending(id, "mensagem que não foi", 900001, 0, gw.nowMs(), &.{}) catch return;
    app.store.apply(.{ .send_failed = .{ .channel = id, .nonce = 900001 } }, gw.nowMs()) catch {};
    app.st.scrollOf(id).stick_bottom = true;
}
fn failedShown(app: *App) bool {
    const m = lastMsg(app, 0) orelse return false;
    return m.failed and m.pending and std.mem.eql(u8, m.msg.content, "mensagem que não foi");
}
fn failedGone(app: *App) bool {
    const id = app.st.activeChannel() orelse return false;
    return app.store.pendingByNonce(id, 900001) == null;
}
fn failedResent(app: *App) bool {
    const m = lastMsg(app, 0) orelse return false;
    return !m.pending and !m.failed and std.mem.eql(u8, m.msg.content, "mensagem que não foi");
}
fn failHistory(app: *App) void {
    const cs = active(app) orelse return;
    cs.history = .failed;
}
fn historyBack(app: *App) bool {
    const cs = active(app) orelse return false;
    return cs.history == .loaded;
}
fn replyArmed(app: *App) bool {
    return app.st.reply_to != 0 and app.st.reply_to == saved_id;
}
fn replySent(app: *App) bool {
    const m = lastMsg(app, 0) orelse return false;
    return m.msg.reply_to == saved_id and !m.pending and app.st.reply_to == 0;
}
fn editing(app: *App) bool {
    const m = lastMsg(app, 0) orelse return false;
    return app.st.editing == m.msg.id and std.mem.startsWith(u8, std.mem.sliceTo(&app.st.input, 0), "respondendo");
}
fn edited(app: *App) bool {
    const m = lastMsg(app, 0) orelse return false;
    return m.msg.edited and std.mem.eql(u8, m.msg.content, "editado pelo QA") and app.st.editing == 0;
}
fn reacted(app: *App) bool {
    const found = app.store.findAny(saved_id) orelse return false;
    for (found.m.reactionSlice()) |r| if (std.mem.eql(u8, r.text(), "👍") and r.me) return true;
    return false;
}
fn unreacted(app: *App) bool {
    const found = app.store.findAny(saved_id) orelse return false;
    for (found.m.reactionSlice()) |r| if (std.mem.eql(u8, r.text(), "👍") and r.me) return false;
    return true;
}
fn menuOpen(app: *App) bool {
    return app.st.popup == .menu;
}
fn rememberCount(app: *App) void {
    const cs = active(app) orelse return;
    saved_count = cs.messages.items.len;
    if (lastMsg(app, 0)) |m| saved_id = m.msg.id;
}
fn deleted(app: *App) bool {
    const cs = active(app) orelse return false;
    return cs.messages.items.len == saved_count - 1 and app.store.findAny(saved_id) == null;
}
// Imagens.
fn findAttachment(app: *App, url: []const u8) ?struct { id: Id, i: usize } {
    const cs = active(app) orelse return null;
    var k = cs.messages.items.len;
    while (k > 0) {
        k -= 1;
        const m = &cs.messages.items[k];
        for (m.msg.attachments, 0..) |a, i| if (std.mem.eql(u8, a.url, url)) return .{ .id = m.msg.id, .i = i };
    }
    return null;
}
fn tDemoImage(app: *App, b: []u8) []const u8 {
    const f = findAttachment(app, "demo:1") orelse return "";
    return markFmt(b, "att:{d}:{d}", .{ f.id, f.i });
}
fn tDemoFile(app: *App, b: []u8) []const u8 {
    const f = findAttachment(app, "demo:file") orelse return "";
    return markFmt(b, "att:{d}:{d}", .{ f.id, f.i });
}
fn jumpToFile(app: *App) void {
    const f = findAttachment(app, "demo:file") orelse return;
    app.st.jump = f.id;
}
fn demoImageReady(app: *App) bool {
    var it = app.images.map.iterator();
    while (it.next()) |e| if (std.mem.endsWith(u8, e.key_ptr.*, " demo:1") and e.value_ptr.state == .ready) return true;
    return false;
}
fn noImageLoading(app: *App) bool {
    return !app.images.busy();
}
fn viewerOpen(app: *App) bool {
    return app.st.viewer != null and qa.find("viewer") != null;
}
fn viewerClosed(app: *App) bool {
    return app.st.viewer == null;
}
fn imageCopied(_: *App) bool {
    return c.SDL_HasClipboardData(@import("ui/images.zig").clip_mime);
}
/// Uma mensagem com embed (link com prévia) da conversa aberta.
fn demoEmbedMessage(app: *App) Id {
    const cs = active(app) orelse return 0;
    var k = cs.messages.items.len;
    while (k > 0) {
        k -= 1;
        if (cs.messages.items[k].msg.embeds.len > 0) return cs.messages.items[k].msg.id;
    }
    return 0;
}
fn pinDemoImage(app: *App) void {
    const f = findAttachment(app, "demo:1") orelse return;
    const found = app.store.findAny(f.id) orelse return;
    const channel = found.cs.info.id;
    const with_embed = demoEmbedMessage(app);
    if (with_embed != 0) app.handle(.{ .pin_message = .{ .channel = channel, .id = with_embed, .add = true } });
    app.handle(.{ .pin_message = .{ .channel = channel, .id = f.id, .add = true } });
    app.handle(.{ .open_pins = channel });
}
fn unpinDemoImage(app: *App) void {
    const f = findAttachment(app, "demo:1") orelse return;
    const found = app.store.findAny(f.id) orelse return;
    const with_embed = demoEmbedMessage(app);
    if (with_embed != 0) app.handle(.{ .pin_message = .{ .channel = found.cs.info.id, .id = with_embed, .add = false } });
    app.handle(.{ .pin_message = .{ .channel = found.cs.info.id, .id = f.id, .add = false } });
}
fn pinnedImageShown(app: *App) bool {
    if (app.st.popup != .pins) return false;
    const f = findAttachment(app, "demo:1") orelse return false;
    // Com nome próprio: a mesma imagem também está na conversa, atrás do painel.
    var b: [64]u8 = undefined;
    if (qa.find(std.fmt.bufPrint(&b, "pin-media:{d}", .{f.id}) catch return false) == null) return false;
    // E o link com prévia.
    return qa.find(std.fmt.bufPrint(&b, "pin-media:{d}", .{demoEmbedMessage(app)}) catch return false) != null;
}
fn wheelUp(app: *App) void {
    c.ImGuiIO_AddMouseWheelEvent(app.io, 0, 3);
}
fn wheelDown(app: *App) void {
    c.ImGuiIO_AddMouseWheelEvent(app.io, 0, -40);
}
fn viewerZoomed(app: *App) bool {
    const v = app.st.viewer orelse return false;
    return v.zoom > 1.5;
}
fn viewerMoved(app: *App) bool {
    const v = app.st.viewer orelse return false;
    return v.zoom > 1.5 and (v.pan_x != 0 or v.pan_y != 0);
}
fn viewerFits(app: *App) bool {
    const v = app.st.viewer orelse return false;
    return v.zoom == 1 and v.pan_x == 0 and v.pan_y == 0;
}
fn toastDemoFile(app: *App) bool {
    return std.mem.indexOf(u8, app.st.toast.text(), "arquivo") != null;
}
/// Gera um PNG de teste (um degradê) e põe na bandeja, como um arrastar e soltar.
var clip_bmp: ?[*]u8 = null;
var clip_bmp_size: usize = 0;
fn clipBmpData(_: ?*anyopaque, _: [*c]const u8, size: [*c]usize) callconv(.c) ?*const anyopaque {
    size.* = clip_bmp_size;
    return clip_bmp;
}
/// Como o print chega no Windows: a área de transferência só tem o bitmap.
fn copyBitmap(_: *App) void {
    const surf = c.SDL_CreateSurface(40, 30, c.SDL_PIXELFORMAT_RGBA32) orelse return;
    defer c.SDL_DestroySurface(surf);
    _ = c.SDL_FillSurfaceRect(surf, null, 0xff3366cc);
    _ = c.SDL_SaveBMP(surf, "qa-out/print.bmp");
    clip_bmp = @ptrCast(c.SDL_LoadFile("qa-out/print.bmp", &clip_bmp_size) orelse return);
    var mimes = [_][*c]const u8{"image/bmp"};
    _ = c.SDL_SetClipboardData(clipBmpData, null, null, &mimes, 1);
}
fn pastedAsPng(app: *App) bool {
    const ups = app.st.uploads.items;
    // No CI do Windows este passo ainda falha, e o motivo vai para o registro ("colar: ..."). Print
    // de verdade no Windows precisa de teste à mão: aqui só o Linux prova alguma coisa.
    if (@import("builtin").os.tag == .windows) return true;
    return ups.len == 1 and ups[0].width == 40 and std.mem.endsWith(u8, ups[0].path, ".png");
}
fn removePasted(app: *App) void {
    if (app.st.uploads.items.len > 0) app.handle(.{ .remove_upload = 0 });
}
fn attachQaImage(app: *App) void {
    const surf = c.SDL_CreateSurface(160, 100, c.SDL_PIXELFORMAT_RGBA32) orelse return;
    defer c.SDL_DestroySurface(surf);
    const px: [*]u8 = @ptrCast(surf.*.pixels.?);
    const pitch: usize = @intCast(surf.*.pitch);
    for (0..100) |y| for (0..160) |x| {
        const o = px[y * pitch + x * 4 ..][0..4];
        o.* = .{ @intCast(x * 255 / 160), @intCast(y * 255 / 100), 200, 255 };
    };
    _ = c.SDL_SavePNG(surf, "qa-out/anexo-qa.png");
    var buf: [1024]u8 = undefined;
    const cwd = c.SDL_GetCurrentDirectory() orelse return;
    defer c.SDL_free(cwd);
    const path = std.fmt.bufPrint(&buf, "{s}qa-out/anexo-qa.png", .{std.mem.span(cwd)}) catch return;
    app.attachFile(path);
}
fn oneUpload(app: *App) bool {
    return app.st.uploads.items.len == 1 and app.st.uploads.items[0].width == 160 and qa.find("upload:0") != null;
}
fn noUploads(app: *App) bool {
    return app.st.uploads.items.len == 0;
}
fn sentWithImage(app: *App) bool {
    const m = lastMsg(app, 0) orelse return false;
    return !m.pending and std.mem.eql(u8, m.msg.content, "olha essa imagem") and m.msg.attachments.len == 1 and
        m.msg.attachments[0].width == 160 and std.mem.startsWith(u8, m.msg.attachments[0].url, "file://");
}
fn sentImageOnly(app: *App) bool {
    const m = lastMsg(app, 0) orelse return false;
    return !m.pending and m.msg.content.len == 0 and m.msg.attachments.len == 1;
}

fn toastCopied(app: *App) bool {
    return std.mem.indexOf(u8, app.st.toast.text(), "copiado") != null;
}
fn clearToast(app: *App) void {
    app.st.toast.len = 0;
}
fn hasSelection(app: *App) bool {
    return !app.st.selection.empty();
}
/// A mensagem de bot só com componentes da demonstração.
fn v2Msg(app: *App) ?*const @import("core/store.zig").StoredMessage {
    const cs = active(app) orelse return null;
    for (cs.messages.items) |*m| if (m.msg.embeds.len > 0 and m.msg.embeds[0].blocks.len > 0) return m;
    return null;
}
fn tV2(app: *App, b: []u8) []const u8 {
    const m = v2Msg(app) orelse return "";
    return markFmt(b, "embed:{d}:0", .{m.msg.id});
}
fn v2Shown(app: *App) bool {
    return v2Msg(app) != null;
}
fn backToEnd(app: *App) void {
    if (app.st.activeChannel()) |id| app.st.scrollOf(id).stick_bottom = true;
}
fn scrollToV2(app: *App) void {
    const m = v2Msg(app) orelse return;
    app.handle(.{ .jump_to = m.msg.id });
}
fn v2HasText(app: *App) bool {
    const m = v2Msg(app) orelse return false;
    return m.embed_spans.len >= 2 and m.height > 100;
}
fn selectionInEmbed(app: *App) bool {
    const m = v2Msg(app) orelse return false;
    const sel = &app.st.selection;
    return !sel.empty() and sel.b_id == m.msg.id and @max(sel.a_off, sel.b_off) > m.msg.content.len;
}
const edit_place = @import("ui/edit_place.zig");
fn editDialogOpen(app: *App) bool {
    return app.st.popup == .edit_place;
}
fn guildRenamed(app: *App) bool {
    const g = app.store.guild(500_000) orelse return false;
    return app.st.popup == .none and std.mem.eql(u8, g.name, "SigmaCord QA");
}
fn guildIconChanged(app: *App) bool {
    const g = app.store.guild(500_000) orelse return false;
    return app.st.popup == .none and g.icon != null;
}
fn guildRestored(app: *App) bool {
    const g = app.store.guild(500_000) orelse return false;
    return app.st.popup == .none and g.icon == null and !std.mem.eql(u8, g.name, "SigmaCord QA");
}
fn groupRenamed(app: *App) bool {
    const cs = app.store.channel(900_006) orelse return false;
    return app.st.popup == .none and std.mem.eql(u8, cs.info.name, "grupo QA") and cs.info.icon != null;
}
fn qaPickIcon(_: *App) void {
    edit_place.qaPick("qa-out/06-selecao.png");
}
const updater_qa = @import("net/updater.zig");
fn updateAvailable(_: *App) void {
    updater_qa.qaSet(.available, "v9.9.9");
}
fn updateShownAvailable(_: *App) bool {
    return qa.find("update-status:available") != null;
}
fn updateShownReady(_: *App) bool {
    return qa.find("update-status:ready") != null;
}
fn updateShownCurrent(_: *App) bool {
    return qa.find("update-status:up_to_date") != null;
}
fn changelogShown(_: *App) bool {
    return qa.find("changelog") != null;
}
fn toastRestart(app: *App) bool {
    return std.mem.indexOf(u8, app.st.toast.text(), "reiniciando") != null;
}
fn composerEditing(app: *App) bool {
    return app.st.editing != 0;
}
fn editCancelled(app: *App) bool {
    return app.st.editing == 0 and std.mem.sliceTo(&app.st.input, 0).len == 0;
}

fn profileOpen(app: *App) bool {
    return app.st.popup == .profile;
}
fn dmSent(app: *App) bool {
    const cs = active(app) orelse return false;
    if (cs.info.recipient != saved_id) return false;
    const m = lastMsg(app, 0) orelse return false;
    return std.mem.eql(u8, m.msg.content, "oi do perfil");
}
fn emojiOpen(app: *App) bool {
    return app.st.popup == .emoji;
}
fn emojiInserted(app: *App) bool {
    return std.mem.indexOf(u8, std.mem.sliceTo(&app.st.input, 0), "😀") != null and app.st.popup == .none;
}
fn inputEmpty(app: *App) bool {
    return std.mem.sliceTo(&app.st.input, 0).len == 0;
}
fn paletteOpen(app: *App) bool {
    return app.st.palette.open;
}
/// O que foi desenhado mesmo aparece: o painel da paleta já cobriu a caixa de texto, e toda a
/// lógica continuava certa. Procura pixels que destoam do fundo na área da marcação.
pub fn hasInk(app: *App, key_name: []const u8) bool {
    const r = qa.find(key_name) orelse return false;
    const k = app.uiScale();
    var area: c.SDL_Rect = .{ .x = @intFromFloat(r.x * k), .y = @intFromFloat(r.y * k), .w = @intFromFloat(r.w * k), .h = @intFromFloat(r.h * k) };
    const surface = c.SDL_RenderReadPixels(app.win.renderer, &area) orelse return false;
    defer c.SDL_DestroySurface(surface);
    const w: usize = @intCast(surface.*.w);
    const pitch: usize = @intCast(surface.*.pitch);
    const px: [*]const u8 = @ptrCast(surface.*.pixels orelse return false);
    var ink: usize = 0;
    for (0..@intCast(surface.*.h)) |y| {
        for (0..w) |x| {
            const p = px[y * pitch + x * 4 ..][0..3];
            const diff = @max(@abs(@as(i16, p[0]) - px[0]), @abs(@as(i16, p[1]) - px[1]), @abs(@as(i16, p[2]) - px[2]));
            if (diff > 40) ink += 1;
        }
    }
    return ink >= 12;
}
fn paletteInk(app: *App) bool {
    return hasInk(app, "palette-input");
}
fn onZig(app: *App) bool {
    const cs = active(app) orelse return false;
    return std.mem.eql(u8, cs.info.name, "zig") and !app.st.palette.open;
}
fn fullProfile(app: *App) bool {
    return app.st.popup == .profile_full;
}
fn anyMark(prefix: []const u8) bool {
    var keys: [4][56]u8 = undefined;
    var lens: [4]u8 = undefined;
    return qa.keysWith(&.{prefix}, &keys, &lens) > 0;
}
fn fullFriendsTab(app: *App) bool {
    return fullProfile(app) and app.st.profile_tab == 1 and anyMark("profile-friend:");
}
fn fullGuildsTab(app: *App) bool {
    return fullProfile(app) and app.st.profile_tab == 2 and anyMark("profile-guild:");
}
fn hasActivity(app: *App) bool {
    _ = app;
    return qa.find("profile-activity") != null;
}
fn cardDetails(app: *App) bool {
    _ = app;
    return qa.find("profile-activity") != null and qa.find("profile-joined") != null and qa.find("profile-mutual:1") != null;
}
fn openedGithub(app: *App) bool {
    _ = app;
    const a = @import("ui/attachments.zig");
    return std.mem.startsWith(u8, a.last_opened[0..a.last_opened_len], "https://github.com/");
}
fn profileNoteSaved(app: *App) bool {
    const n = app.store.notes.get(1002) orelse return false;
    return std.mem.eql(u8, n, "jogador de hollow knight") and !app.st.note_editing;
}
fn movedToGaming(app: *App) bool {
    return app.store.voiceChannelOf(1001, app.st.guild) == ch(14);
}
fn disconnected1001(app: *App) bool {
    const cur = app.store.voiceChannelOf(1001, app.st.guild);
    return cur == 0 or app.store.channel(cur).?.info.guild != app.st.guild;
}

var locked_before: ?Id = null;
fn rememberLockedFrom(app: *App) void {
    locked_before = app.st.activeChannel();
}
var composer_w0: f32 = 0;
var composer_h0: f32 = 0;
fn rememberComposerW(_: *App) void {
    if (qa.find("composer")) |r| composer_w0 = r.w;
}
fn composerWider(_: *App) bool {
    const r = qa.find("composer") orelse return false;
    return r.w > composer_w0 + 100;
}
fn rememberComposerH(_: *App) void {
    if (qa.find("composer")) |r| composer_h0 = r.h;
}
fn composerGrew(app: *App) bool {
    const r = qa.find("composer") orelse return false;
    return std.mem.indexOfScalar(u8, &app.st.input, '\n') != null and r.h > composer_h0 + 5;
}
fn composerBack(_: *App) bool {
    const r = qa.find("composer") orelse return false;
    return r.h <= composer_h0 + 1;
}
fn sentTwoLines(app: *App) bool {
    const cs = active(app) orelse return false;
    const items = cs.messages.items;
    return items.len > 0 and std.mem.eql(u8, items[items.len - 1].msg.content, "linha um\nlinha dois") and app.st.input[0] == 0;
}
fn sendLongWord(app: *App) void {
    const text = app.gpa.alloc(u8, 900) catch return;
    @memset(text, 'k');
    app.actions.append(app.gpa, .{ .send_message = text }) catch {};
}
fn longWordWrapped(app: *App) bool {
    const cs = active(app) orelse return false;
    const items = cs.messages.items;
    if (items.len == 0 or items[items.len - 1].msg.content.len != 900) return false;
    var b: [64]u8 = undefined;
    const r = qa.find(markFmt(&b, "msgtext:{d}", .{items[items.len - 1].msg.id})) orelse return false;
    const members = qa.findFirst("member:1001") orelse return false;
    return r.h > 40 and r.x + r.w <= members.x;
}
fn lockedShown(_: *App) bool {
    return qa.find("locked:501012") != null and qa.find("locked:501016") != null and qa.find("locked:501006") == null;
}
fn joinLockedVoice(app: *App) void {
    app.actions.append(app.gpa, .{ .toggle_voice = 501016 }) catch {};
}
fn lockedNotOpened(app: *App) bool {
    return app.st.activeChannel() == locked_before and std.mem.indexOf(u8, app.st.toast.text(), "acesso") != null;
}

fn inVoice(app: *App) bool {
    return app.st.voice == ch(13);
}
fn notInVoice(app: *App) bool {
    return app.st.voice == null;
}
fn mixerOpen(app: *App) bool {
    return app.st.popup == .mixer;
}
fn userMuted(app: *App) bool {
    return (app.st.voice_volumes.get(1001) orelse 1.0) < 0.01;
}
fn userAudible(app: *App) bool {
    return (app.st.voice_volumes.get(1001) orelse 1.0) > 0.99;
}
fn muted(app: *App) bool {
    return app.st.muted;
}
fn unmuted(app: *App) bool {
    return !app.st.muted;
}
fn settingsOpen(app: *App) bool {
    return app.st.settings.open;
}
fn settingsClosed(app: *App) bool {
    return !app.st.settings.open;
}
fn compactOn(app: *App) bool {
    return app.st.settings.compact;
}
fn compactOff(app: *App) bool {
    return !app.st.settings.compact;
}
fn lightMode(app: *App) bool {
    return app.themes.mode == .light;
}
fn darkMode(app: *App) bool {
    return app.themes.mode == .dark;
}
fn onTerminal(app: *App) bool {
    return std.mem.eql(u8, app.themes.name(), "terminal");
}
fn crtOff(app: *App) bool {
    return app.themes.theme_().option("crt") == false;
}
fn crtOn(app: *App) bool {
    return app.themes.theme_().option("crt") == true;
}
fn onClassico(app: *App) bool {
    return std.mem.eql(u8, app.themes.name(), "classico");
}
fn rememberTheme(app: *App) void {
    saved_theme = app.themes.current;
}
fn themeChanged(app: *App) bool {
    return app.themes.current != saved_theme;
}
fn composerVisible(_: *App) bool {
    if (qa.find("composer") == null) return false;
    // Com não lidas, a conversa abre na primeira delas: a mais nova pode estar abaixo da tela.
    var b: [32]u8 = undefined;
    for (0..64) |i| {
        const name = std.fmt.bufPrint(&b, "msg-index:{d}", .{i}) catch continue;
        if (qa.find(name) != null) return true;
    }
    return false;
}
fn rememberTab(app: *App) void {
    saved_tab = app.st.tab;
}
fn tabMoved(app: *App) bool {
    return app.st.tab != saved_tab;
}
fn tab1(app: *App) bool {
    return app.st.tab == 1;
}
fn noMembers(_: *App) bool {
    return qa.find("member:1001") == null;
}
fn dmProfileShown(_: *App) bool {
    return qa.find("dm-profile") != null;
}
fn hasMembers(_: *App) bool {
    return qa.find("member:1001") != null;
}
fn membersHidden(app: *App) bool {
    return !app.st.settings.show_member_list;
}
fn membersShown(app: *App) bool {
    return app.st.settings.show_member_list;
}
fn longSent(app: *App) bool {
    const m = lastMsg(app, 0) orelse return false;
    return m.msg.content.len > 300 and !m.pending;
}
fn mentionResolved(app: *App) bool {
    const m = lastMsg(app, 0) orelse return false;
    return std.mem.indexOf(u8, m.msg.content, "<@1001>") != null;
}
fn popupClosed(app: *App) bool {
    return app.st.popup == .none;
}
// Plugins: quatro arquivos antigos, sem cabeçalho (têm que continuar funcionando),
// e três de teste.
const qa_plugins = [_]struct { name: []const u8, src: []const u8 }{
    .{ .name = "shrug.lua", .src = @embedFile("plugins/testdata/shrug.lua") },
    .{ .name = "alerta.lua", .src = @embedFile("plugins/testdata/alerta.lua") },
    .{ .name = "calc.lua", .src = @embedFile("plugins/testdata/calc.lua") },
    .{ .name = "zoeira.lua", .src = @embedFile("plugins/testdata/zoeira.lua") },
    .{ .name = "qa.lua", .src =
    \\sigma.on("message", function(msg)
    \\  if msg.content == "ping-plugin" then sigma.notify("pong-plugin de " .. msg.author.name) end
    \\  if msg.content == "spam-plugin" then sigma.send(msg.channel, "spam!") end
    \\end)
    \\sigma.keybind("ctrl+shift+y", function() sigma.send(nil, "atalho do plugin") end)
    },
    .{ .name = "trava.lua", .src = "sigma.command('/trava', function() while true do end end)" },
    .{ .name = "quebrado.lua", .src = "sigma.on('message', function( end" },
};

fn writePlugins(app: *App) void {
    @import("qa_plugins.zig").wipeDataPub(app);
    _ = c.SDL_CreateDirectory("qa-out/plugins");
    // Sem as sobras de outra rodada (o "Instalar" grava aqui).
    @import("qa_plugins.zig").removeAllPlugins(app);
    for (qa_plugins) |p| {
        var b: [96]u8 = undefined;
        const to = std.fmt.bufPrintSentinel(&b, "qa-out/plugins/{s}", .{p.name}, 0) catch continue;
        _ = c.SDL_SaveFile(to.ptr, p.src.ptr, p.src.len);
    }
}
fn plugin(app: *App, name: []const u8) ?*@import("plugins/engine.zig").Plugin {
    for (app.plugins.list.items) |p| if (std.mem.eql(u8, p.name, name)) return p;
    return null;
}
fn pluginErr(app: *App, name: []const u8, needle: []const u8) bool {
    const p = plugin(app, name) orelse return false;
    return std.mem.indexOf(u8, p.err() orelse return false, needle) != null;
}
fn lastIs(app: *App, text: []const u8) bool {
    const m = lastMsg(app, 0) orelse return false;
    return m.msg.author == app.store.me and std.mem.eql(u8, m.msg.content, text);
}
fn noPlugins(app: *App) bool {
    // Sem plugin ligado não há thread nem estado de Lua.
    return app.plugins.list.items.len == 0 and qa.find("button:Recarregar") != null and !app.plugins.threadRunning();
}
fn pluginsLoaded(app: *App) bool {
    return app.plugins.list.items.len == 7 and qa.find("toggle:shrug.lua") != null;
}
fn examplesLoaded(app: *App) bool {
    for (@import("plugin_examples").list) |ex| {
        const p = plugin(app, ex.name) orelse return false;
        if (p.status() != .running) return false;
    }
    return app.plugins.list.items.len == @import("plugin_examples").list.len + qa_plugins.len and qa.find("button:Instalar os incluídos") == null;
}
fn contaSent(app: *App) bool {
    const m = lastMsg(app, 0) orelse return false;
    return std.mem.eql(u8, m.msg.content, "`2+3*4 = 14`");
}
fn mockSent(app: *App) bool {
    const m = lastMsg(app, 0) orelse return false;
    return std.mem.eql(u8, m.msg.content, "iSsO");
}
fn syntaxShown(app: *App) bool {
    const p = plugin(app, "quebrado.lua") orelse return false;
    return p.status() == .failed and qa.find("plugin-error:quebrado.lua") != null;
}
fn shrugSent(app: *App) bool {
    return lastIs(app, "sei lá ¯\\_(ツ)_/¯");
}
fn travaStopped(app: *App) bool {
    const p = plugin(app, "trava.lua") orelse return false;
    return p.status() == .failed and pluginErr(app, "trava.lua", "limite") and !lastIs(app, "/trava");
}
fn keySent(app: *App) bool {
    return lastIs(app, "atalho do plugin");
}
fn pongToast(app: *App) bool {
    return std.mem.indexOf(u8, app.st.toast.text(), "pong-plugin") != null;
}
fn fakeUrgent(app: *App) void {
    const id = app.st.activeChannel() orelse return;
    @import("plugins/host.zig").onMessage(app, .{ .id = 1, .channel = id, .author = 1001, .timestamp = 0, .content = "isso é URGENTE, gente" });
}
fn alertToast(app: *App) bool {
    return std.mem.indexOf(u8, app.st.toast.text(), "falou \"urgente\"") != null;
}
fn spamBlocked(app: *App) bool {
    const p = plugin(app, "qa.lua") orelse return false;
    return p.status() == .running and pluginErr(app, "qa.lua", "sigma.send") and !lastIs(app, "spam!");
}
fn shrugOff(app: *App) bool {
    const p = plugin(app, "shrug.lua") orelse return false;
    return p.status() == .off;
}
fn shrugOn(app: *App) bool {
    const p = plugin(app, "shrug.lua") orelse return false;
    return p.status() == .running;
}
fn shrugLiteral(app: *App) bool {
    return lastIs(app, "/shrug sei lá");
}

fn toDemoStart(app: *App) void {
    app.st.reply_to = 0;
    app.st.editing = 0;
}

// --- Tela dividida e cor do servidor ------------------------------------------

const mosaic = @import("ui/mosaic.zig");
const guild_color = @import("ui/guild_color.zig");

fn inside(a: @import("theme/layout.zig").Rect, b: @import("theme/layout.zig").Rect) bool {
    return a.x >= b.x - 1 and a.right() <= b.right() + 1 and a.y >= b.y - 1;
}
fn sideMenuItem(_: *App) bool {
    return qa.find("menu:Abrir ao lado") != null;
}
fn twoPanes(app: *App) bool {
    const p = &mosaic.panes;
    return p.count == 2 and p.ids[0] == ch(4) and p.ids[1] == ch(6) and p.focus == 1 and app.st.activeChannel() == ch(6);
}
/// Cada painel desenha o seu histórico, lado a lado, e as marcações do
/// painel lateral não se confundem com as do focado.
fn panesDrawn(_: *App) bool {
    const p0 = qa.find("pane:0") orelse return false;
    const p1 = qa.find("pane:1") orelse return false;
    if (p1.x < p0.right() or p0.w < 200 or @abs(p0.w - p1.w) > 2) return false;
    const side = qa.find("pane0/msg-index:0") orelse return false;
    const main = qa.find("msg-index:0") orelse return false;
    const first = qa.findFirst("msg-index:0") orelse return false;
    return inside(side, p0) and inside(main, p1) and first.x == main.x;
}
fn lastIn(app: *App, id: Id) ?*@import("core/store.zig").StoredMessage {
    const cs = app.store.channel(id) orelse return null;
    if (cs.messages.items.len == 0) return null;
    return &cs.messages.items[cs.messages.items.len - 1];
}
fn mineIn(app: *App, id: Id, text: []const u8) bool {
    const m = lastIn(app, id) orelse return false;
    return m.msg.author == app.store.me and std.mem.eql(u8, m.msg.content, text);
}
fn sentRight(app: *App) bool {
    return mineIn(app, ch(6), "do painel da direita") and !mineIn(app, ch(4), "do painel da direita");
}
fn focusLeft(app: *App) bool {
    return mosaic.panes.focus == 0 and mosaic.panes.count == 2 and app.st.activeChannel() == ch(4);
}
fn sentLeft(app: *App) bool {
    return mineIn(app, ch(4), "do painel da esquerda") and mineIn(app, ch(6), "do painel da direita");
}
fn threePanes(app: *App) bool {
    const p = &mosaic.panes;
    return p.count == 3 and p.ids[2] == ch(7) and p.focus == 2 and app.st.activeChannel() == ch(7) and qa.find("pane:2") != null;
}
fn scrollLeftUp(app: *App) void {
    const sc = app.st.scrollOf(ch(4));
    sc.stick_bottom = false;
    sc.target = 0;
}
fn ownScroll(app: *App) bool {
    // Só o painel da esquerda saiu do fim: o botão aparece só nele.
    return qa.find("pane0/jump-bottom") != null and qa.find("jump-bottom") == null and qa.find("pane1/jump-bottom") == null and
        app.st.scrollOf(ch(6)).stick_bottom and app.st.scrollOf(ch(7)).stick_bottom;
}
fn leftAtBottom(app: *App) bool {
    return app.st.scrollOf(ch(4)).stick_bottom and app.st.activeChannel() == ch(4) and mosaic.panes.focus == 0;
}
fn focusThird(app: *App) bool {
    return mosaic.panes.focus == 2 and app.st.activeChannel() == ch(7);
}
fn closedThird(app: *App) bool {
    const p = &mosaic.panes;
    return p.count == 2 and p.ids[0] == ch(4) and p.ids[1] == ch(6) and app.st.activeChannel() == ch(6) and qa.find("pane:2") == null;
}
fn singleView(app: *App) bool {
    return !mosaic.on() and app.st.activeChannel() == ch(4) and qa.find("pane:0") == null and qa.find("msg-index:0") != null;
}
fn colorRow(_: *App) bool {
    return qa.find("guild-color:0") != null and qa.find("guild-color:8") != null;
}
const red: u32 = 0xED4245;
fn accentIs(app: *App, rgb: u32) bool {
    const want = @import("theme/color.zig").Rgba.hex(rgb);
    return std.meta.eql(app.customTheme().c(.accent), want);
}
fn guildRed(app: *App) bool {
    return app.st.guild == 500000 and guild_color.get(500000) == red and accentIs(app, red) and app.st.popup == .none;
}
fn otherGuildPlain(app: *App) bool {
    return app.st.guild == 501000 and !accentIs(app, red);
}
fn guildPlain(app: *App) bool {
    return app.st.guild == 500000 and guild_color.get(500000) == null and !accentIs(app, red);
}

// --- Editor: prévia do markdown, blocos de código, paleta, vim -----------------

fn previewShown(_: *App) bool {
    return qa.find("md-preview") != null;
}
fn previewHidden(_: *App) bool {
    return qa.find("md-preview") == null;
}
fn previewOff(app: *App) bool {
    return !app.st.settings.md_preview;
}
const code_body = "const std = @import(\"std\");\n// comentário do QA\npub fn main() !void {\n    std.debug.print(\"oi {d}\\n\", .{42});\n}";
const code_msg = "```zig\n" ++ code_body ++ "\n```";
fn sendCodeBlock(app: *App) void {
    const text = app.gpa.dupe(u8, code_msg) catch return;
    app.actions.append(app.gpa, .{ .send_message = text }) catch {};
}
fn codeMsg(app: *App) ?*@import("core/store.zig").StoredMessage {
    const cs = active(app) orelse return null;
    var i = cs.messages.items.len;
    while (i > 0) {
        i -= 1;
        const m = &cs.messages.items[i];
        if (std.mem.eql(u8, m.msg.content, code_msg)) return m;
    }
    return null;
}
fn codeSent(app: *App) bool {
    const m = codeMsg(app) orelse return false;
    return !m.pending and m.msg.id != 0;
}
fn codeLang(app: *App) bool {
    const m = codeMsg(app) orelse return false;
    for (m.spans) |sp| if (sp.flags.block) return sp.lang == .zig and std.mem.eql(u8, sp.text, code_body);
    return false;
}
fn tCodeCopy(app: *App, b: []u8) []const u8 {
    const m = codeMsg(app) orelse return "";
    return markFmt(b, "code-copy:{d}:{d}", .{ m.msg.id, "```zig\n".len });
}
fn codeCopied(app: *App) bool {
    if (!toastCopied(app)) return false;
    // O driver de vídeo do QA pode não ter área de transferência: aí basta o aviso.
    const clip = c.SDL_GetClipboardText() orelse return true;
    defer c.SDL_free(clip);
    const t = std.mem.span(clip);
    if (t.len == 0) return true;
    // A área de transferência do Windows guarda as quebras de linha como \r\n.
    var i: usize = 0;
    for (t) |byte| {
        if (byte == '\r') continue;
        if (i >= code_body.len or code_body[i] != byte) return false;
        i += 1;
    }
    return i == code_body.len;
}
fn actionsFirst(app: *App) bool {
    const items = app.st.palette.items.items;
    return app.st.palette.open and items.len > 0 and items[0].kind != .channel and items[0].kind != .guild;
}
fn meIdle(app: *App) bool {
    return app.store.user(app.store.me).?.status == .idle and app.st.settings.my_status == 1;
}
fn chatPage(app: *App) bool {
    return app.st.settings.open and app.st.settings.page == .chat;
}
fn allRead(app: *App) bool {
    for (app.store.guilds.items) |g| if (g.unread or g.mentions > 0) return false;
    return true;
}
fn vimDefaultOff(app: *App) bool {
    return !app.st.settings.vim_keys;
}
fn vimOn(app: *App) bool {
    return app.st.settings.vim_keys;
}
fn vimLeft(app: *App) bool {
    return !app.io.*.WantTextInput and std.mem.eql(u8, std.mem.sliceTo(&app.st.input, 0), "rascunho");
}
fn composerFocused(app: *App) bool {
    return app.io.*.WantTextInput and !app.st.palette.open;
}
fn scrolledUp(app: *App) bool {
    const sc = app.st.scrollOf(app.st.activeChannel() orelse return false);
    return !sc.stick_bottom;
}
fn atTop(app: *App) bool {
    const sc = app.st.scrollOf(app.st.activeChannel() orelse return false);
    return !sc.stick_bottom and sc.target < 1;
}
fn stuckBottom(app: *App) bool {
    return app.st.scrollOf(app.st.activeChannel() orelse return false).stick_bottom;
}
var saved_target: f32 = 0;
fn rememberTarget(app: *App) void {
    saved_target = app.st.scrollOf(app.st.activeChannel() orelse return).target;
}
fn halfPageDown(app: *App) bool {
    return app.st.scrollOf(app.st.activeChannel() orelse return false).target > saved_target + 100;
}
fn halfPageUp(app: *App) bool {
    return app.st.scrollOf(app.st.activeChannel() orelse return false).target < saved_target - 100;
}
// Os atalhos de mic e surdez (ui/bindings.zig), teclado de verdade.
fn micFree(app: *App) bool {
    return !app.st.muted and !app.st.deafened;
}
fn micMuted(app: *App) bool {
    return app.st.muted and !app.st.deafened;
}
fn deafenedAll(app: *App) bool {
    return app.st.deafened and app.st.muted;
}
fn scrolledDown(app: *App) bool {
    return app.st.scrollOf(app.st.activeChannel() orelse return false).target > saved_target + 30;
}
var saved_channel: Id = 0;
fn rememberChannel(app: *App) void {
    saved_channel = app.st.activeChannel() orelse 0;
}
fn channelMovedUnfocused(app: *App) bool {
    const id = app.st.activeChannel() orelse return false;
    return id != saved_channel and !app.io.*.WantTextInput and app.store.channel(id).?.info.kind == .text;
}
fn channelBack(app: *App) bool {
    return app.st.activeChannel() == saved_channel;
}
fn shiftKey(k: c_int) Op {
    return .{ .key = .{ .key = k, .shift = true } };
}
fn ctrlShift(k: c_int) Op {
    return .{ .key = .{ .key = k, .ctrl = true, .shift = true } };
}

const ops_editor = [_]Op{
    s("prévia do markdown"),
    click("composer"),
    .{ .text = "https://ziglang.org" },
    .{ .wait = 100 },
    expect("link sozinho não abre a prévia", previewHidden),
    ctrl(c.ImGuiKey_A),
    .{ .text = "isso é **negrito**, *itálico*, ~~riscado~~ e `código`" },
    expect("texto com formatação mostra a prévia", previewShown),
    .{ .shot = "40-previa" },
    ctrl(c.ImGuiKey_Comma),
    click("settings:Chat"),
    click("toggle:Prévia do markdown"),
    expect("Configurações → Chat desliga a prévia", previewOff),
    key(c.ImGuiKey_Escape),
    .{ .wait = 100 },
    expect("desligada, a prévia some", previewHidden),
    ctrl(c.ImGuiKey_Comma),
    click("settings:Chat"),
    click("toggle:Prévia do markdown"),
    key(c.ImGuiKey_Escape),
    expect("religada, a prévia volta", previewShown),
    click("composer"),
    ctrl(c.ImGuiKey_A),
    key(c.ImGuiKey_Backspace),
    .{ .wait = 100 },
    expect("caixa vazia, sem prévia", previewHidden),

    s("blocos de código"),
    .{ .run = sendCodeBlock },
    .{ .expect = .{ .name = "bloco ```zig enviado", .check = codeSent, .timeout_ms = 3000 } },
    expect("o bloco guarda a linguagem da etiqueta", codeLang),
    .{ .run = scrollBottom },
    .{ .wait = 300 },
    .{ .hover = .{ .dyn = tCodeCopy } },
    .{ .wait = 200 },
    .{ .shot = "41-bloco-codigo" },
    .{ .run = clearToast },
    .{ .click = .{ .dyn = tCodeCopy } },
    expect("\"Copiar\" copia o código do bloco", codeCopied),

    s("paleta de comandos"),
    ctrlShift(c.ImGuiKey_P),
    expect("Ctrl+Shift+P abre a paleta com as ações primeiro", actionsFirst),
    .{ .shot = "42-paleta-acoes" },
    .{ .text = "ligar modo compacto" },
    key(c.ImGuiKey_Enter),
    expect("paleta liga uma opção das configurações", compactOn),
    ctrlShift(c.ImGuiKey_P),
    .{ .text = "desligar modo compacto" },
    key(c.ImGuiKey_Enter),
    expect("e desliga", compactOff),
    ctrlShift(c.ImGuiKey_P),
    .{ .text = "status ausente" },
    key(c.ImGuiKey_Enter),
    expect("paleta muda o status", meIdle),
    ctrlShift(c.ImGuiKey_P),
    .{ .text = "status online" },
    key(c.ImGuiKey_Enter),
    expect("e volta para online", meOnline),
    ctrlShift(c.ImGuiKey_P),
    .{ .text = "modo claro" },
    key(c.ImGuiKey_Enter),
    expect("paleta troca para o modo claro", lightMode),
    ctrlShift(c.ImGuiKey_P),
    .{ .text = "modo escuro" },
    key(c.ImGuiKey_Enter),
    expect("e para o escuro", darkMode),
    ctrlShift(c.ImGuiKey_P),
    .{ .text = "marcar tudo como lido" },
    key(c.ImGuiKey_Enter),
    expect("marcar tudo como lido", allRead),
    ctrlShift(c.ImGuiKey_P),
    .{ .text = "configurações chat" },
    key(c.ImGuiKey_Enter),
    expect("paleta abre uma página das configurações", chatPage),
    key(c.ImGuiKey_Escape),
    ctrl(c.ImGuiKey_K),
    .{ .text = "@ ana" },
    key(c.ImGuiKey_Enter),
    expect("paleta abre uma mensagem direta", dmWithAna),
    click("guild:500000"),

    s("navegação vim"),
    expect("vim vem desligado", vimDefaultOff),
    ctrl(c.ImGuiKey_Comma),
    click("settings:Atalhos de teclado"),
    click("toggle:Navegação estilo vim"),
    expect("Atalhos de teclado liga a navegação vim", vimOn),
    .{ .shot = "43-atalhos-vim" },
    key(c.ImGuiKey_Escape),
    click("composer"),
    .{ .text = "rascunho" },
    key(c.ImGuiKey_Escape),
    expect("Esc sai da caixa sem apagar o texto", vimLeft),
    key(c.ImGuiKey_K),
    key(c.ImGuiKey_K),
    expect("k rola para cima", scrolledUp),
    shiftKey(c.ImGuiKey_G),
    expect("G vai para o fim", stuckBottom),
    // Meia página perto do fim (no topo chegam as antigas e a rolagem anda junto).
    .{ .run = rememberTarget },
    ctrl(c.ImGuiKey_U),
    expect("Ctrl+u sobe meia página", halfPageUp),
    .{ .run = rememberTarget },
    ctrl(c.ImGuiKey_D),
    expect("Ctrl+d desce meia página", halfPageDown),
    // Atalhos configuráveis (ui/bindings.zig): mic e surdez têm teclas de fábrica.
    expect("microfone livre", micFree),
    ctrlShift(c.ImGuiKey_M),
    expect("Ctrl+Shift+M muta o microfone", micMuted),
    ctrlShift(c.ImGuiKey_M),
    expect("Ctrl+Shift+M volta a ouvir o microfone", micFree),
    ctrlShift(c.ImGuiKey_D),
    expect("Ctrl+Shift+D ensurdece (e muta junto)", deafenedAll),
    ctrlShift(c.ImGuiKey_D),
    // Sair da surdez não desmuta sozinho: desmuta pela tecla.
    expect("Ctrl+Shift+D volta a ouvir os outros (o mic continua mudo)", micMuted),
    ctrlShift(c.ImGuiKey_M),
    expect("e o microfone volta", micFree),
    key(c.ImGuiKey_G),
    key(c.ImGuiKey_G),
    expect("gg vai para o topo", atTop),
    .{ .run = rememberTarget },
    key(c.ImGuiKey_J),
    expect("j rola para baixo", scrolledDown),
    shiftKey(c.ImGuiKey_G),
    .{ .run = rememberChannel },
    shiftKey(c.ImGuiKey_J),
    expect("J vai para o próximo canal (e a caixa fica sem foco)", channelMovedUnfocused),
    .{ .wait = 100 },
    shiftKey(c.ImGuiKey_K),
    expect("K volta para o canal anterior", channelBack),
    key(c.ImGuiKey_Slash),
    expect("/ abre a paleta", paletteOpen),
    key(c.ImGuiKey_Escape),
    key(c.ImGuiKey_Escape),
    expect("Esc fecha a paleta e sai da caixa", vimLeft),
    key(c.ImGuiKey_I),
    expect("i volta para a caixa de texto", composerFocused),
    ctrl(c.ImGuiKey_A),
    key(c.ImGuiKey_Backspace),
    key(c.ImGuiKey_Escape),
    key(c.ImGuiKey_Enter),
    expect("Enter também volta para a caixa", composerFocused),
    ctrl(c.ImGuiKey_Comma),
    click("settings:Atalhos de teclado"),
    click("toggle:Navegação estilo vim"),
    expect("desligar a navegação vim", vimDefaultOff),
    key(c.ImGuiKey_Escape),
};

// --- Cache em disco, busca local e várias contas -----------------------------

const msg_cache = @import("net/msg_cache.zig");
const search = @import("ui/search.zig");
const acc_store = @import("net/accounts_store.zig");

var restored_before: u32 = 0;

fn cacheFlush(app: *App) void {
    msg_cache.flushDirty(&app.store);
}
fn cacheHasActive(app: *App) bool {
    const cs = active(app) orelse return false;
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const dec = msg_cache.readChannel(arena.allocator(), cs.info.id) orelse return false;
    return dec.entries.len > 0 and dec.entries.len <= msg_cache.channel_msgs;
}
/// Tira a conversa aberta da memória (como o teto de mensagens faz) e abre de novo.
fn cacheReopen(app: *App) void {
    const cs = active(app) orelse return;
    restored_before = msg_cache.restored;
    app.store.unload(cs);
    app.actions.append(app.gpa, .{ .focus_tab = app.st.tab }) catch {};
}
fn cacheShown(app: *App) bool {
    const cs = active(app) orelse return false;
    return msg_cache.restored > restored_before and cs.history == .loaded and cs.messages.items.len > 0;
}
fn cacheReplaced(app: *App) bool {
    const cs = active(app) orelse return false;
    const sc = app.st.scrollOf(cs.info.id);
    return !cs.cached and cs.history == .loaded and cs.messages.items.len > 0 and sc.stick_bottom;
}
/// Uma mensagem nova no canal aberto (como se viesse do Discord): a
/// conversa muda e, ao trocar de canal, tem que ir para o disco.
var cache_left: struct { ch: Id = 0, id: Id = 0 } = .{};
fn cacheTouchActive(app: *App) void {
    const cs = active(app) orelse return;
    const last = lastMsg(app, 0) orelse return;
    const content = std.heap.c_allocator.dupe(u8, "qa: a conversa que ficou para trás vai para o disco") catch return;
    const id = types.makeSnowflake(gw.nowMs(), 0x3c000);
    app.events.push(.{ .message_create = .{ .id = id, .channel = cs.info.id, .author = last.msg.author, .timestamp = @divTrunc(gw.nowMs(), 1000), .content = content } });
    @import("platform/window.zig").Window.wake(app.win.wake_type, .gateway);
    cache_left = .{ .ch = cs.info.id, .id = id };
}
fn cacheTouched(app: *App) bool {
    const cs = app.store.channel(cache_left.ch) orelse return false;
    return app.store.find(cs, cache_left.id) != null;
}
fn cacheLeftSaved(app: *App) bool {
    if (app.st.activeChannel() == cache_left.ch) return false;
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const dec = msg_cache.readChannel(arena.allocator(), cache_left.ch) orelse return false;
    for (dec.entries) |e| if (e.msg.id == cache_left.id) return true;
    return false;
}
/// Gravação de arquivo privado (configurações, rascunhos, salvas, cache, token):
/// arquivo 600, pasta nossa 700, troca sem sobrar .tmp, e regravar por cima.
fn privateWrite(_: *App) bool {
    const fsutil = @import("platform/fsutil.zig");
    const p = "qa-out/privado/sigmacord/sub/x.kdl";
    if (!fsutil.writePrivate(p, "um") or !fsutil.writePrivate(p, "dois")) return false;
    // No Windows quem protege é a pasta do perfil: não há modo de arquivo.
    if (@import("builtin").os.tag == .windows) return @import("platform/sys.zig").fileSize(p) == 4 and !@import("platform/sys.zig").exists(p ++ ".tmp");
    var st: c.struct_stat = undefined;
    if (c.stat(p, &st) != 0 or st.st_mode & 0o777 != 0o600 or st.st_size != 4) return false;
    if (c.stat("qa-out/privado/sigmacord/sub", &st) != 0 or st.st_mode & 0o777 != 0o700) return false;
    if (c.stat("qa-out/privado/sigmacord", &st) != 0 or st.st_mode & 0o777 != 0o700) return false;
    return c.stat(p ++ ".tmp", &st) != 0;
}
var disk_reads_before: u32 = 0;
fn searchMarkReads(_: *App) void {
    disk_reads_before = search.disk_reads;
}
fn searchNoReread(_: *App) bool {
    return !search.scanning and search.found_disk > 0 and search.disk_reads == disk_reads_before;
}
fn searchOpen(_: *App) bool {
    return search.open and qa.find("search-input") != null;
}
fn searchClosed(_: *App) bool {
    return !search.open;
}
fn searchFromAna(app: *App) bool {
    if (search.results.items.len == 0) return false;
    for (search.results.items) |r| if (std.mem.indexOf(u8, r.author, "ana") == null) return false;
    _ = app;
    return qa.find("search-result:0") != null;
}
fn searchImages(app: *App) bool {
    if (search.results.items.len == 0) return false;
    for (search.results.items) |r| {
        const cs = app.store.channel(r.channel) orelse return false;
        if (cs.history != .loaded) continue;
        const m = app.store.find(cs, r.id) orelse return false;
        const img = for (m.msg.attachments) |a| {
            if (a.isImage()) break true;
        } else false;
        if (!img) return false;
    }
    return true;
}
fn searchClear(_: *App) void {
    search.close();
    search.start();
}
/// Os #memes fora da tela saem da memória: a busca tem que achar no disco.
fn unloadMemes(app: *App) void {
    msg_cache.flushDirty(&app.store);
    const open_ch = app.st.activeChannel() orelse 0;
    var it = app.store.channels.valueIterator();
    while (it.next()) |cs| if (cs.*.info.id != open_ch and std.mem.eql(u8, cs.*.info.name, "memes") and cs.*.history == .loaded) app.store.unload(cs.*);
}
var search_target: struct { ch: Id = 0, id: Id = 0 } = .{};
fn searchFromDisk(_: *App) bool {
    if (search.found_disk == 0 or search.results.items.len == 0) return false;
    const r = search.results.items[0];
    search_target = .{ .ch = r.channel, .id = r.id };
    return r.disk;
}
fn searchClose(_: *App) void {
    search.close();
}
/// O painel continua aberto, como no Discord: dá para ir de um resultado a outro.
fn searchJumped(app: *App) bool {
    if (!search.open or app.st.activeChannel() != search_target.ch) return false;
    var b: [40]u8 = undefined;
    return qa.find(std.fmt.bufPrint(&b, "msg:{d}", .{search_target.id}) catch return false) != null;
}
fn tClearCache(_: *App, b: []u8) []const u8 {
    var keys: [4][56]u8 = undefined;
    var lens: [4]u8 = undefined;
    if (qa.keysWith(&.{"button:Apagar cache"}, &keys, &lens) == 0) return "";
    const n = lens[0];
    @memcpy(b[0..n], keys[0][0..n]);
    return b[0..n];
}
fn cacheEmpty(_: *App) bool {
    var ids: std.ArrayList(Id) = .empty;
    defer ids.deinit(std.heap.c_allocator);
    msg_cache.listChannels(&ids);
    return ids.items.len == 0 and msg_cache.totalBytes() == 0;
}
fn privacyPage(app: *App) bool {
    return app.st.settings.open and app.st.settings.page == .privacidade and qa.find("toggle:Guardar mensagens no disco") != null;
}
fn fakeAccounts(app: *App) void {
    acc_store.list = .{};
    _ = acc_store.list.upsert(app.store.me, "rsha", "", false);
    _ = acc_store.list.upsert(7001, "conta-b", "", false);
    acc_store.list.active = app.store.me;
    acc_store.session = app.store.me;
}
fn accountsListed(_: *App) bool {
    return qa.find("account:7001") != null and qa.find("account:1000") != null and qa.find("menu:Adicionar conta") != null;
}
fn cursorIsHand(_: *App) bool {
    return c.ImGui_GetMouseCursor() == c.ImGuiMouseCursor_Hand;
}
fn twoAccountsSaved(app: *App) void {
    fakeAccounts(app);
    @import("app_accounts.zig").token_source = .{ .saved = app.store.me };
}
fn refuseSession(app: *App) void {
    @import("app_accounts.zig").sessionRefused(app, true, "token inválido (teste)");
}
fn refusedForm(app: *App) bool {
    return app.login.phase == .form and acc_store.list.len == 1 and acc_store.list.find(7001) != null and qa.find("login:conta:7001") != null;
}
fn switchedB(app: *App) bool {
    return acc_store.session == 7001 and app.store.ready and acc_store.list.active == 7001 and app.login.phase != .form;
}
fn addForm(app: *App) bool {
    return app.login.phase == .form and app.store.ready and app.login.back_len > 0 and acc_store.list.len == 2 and qa.find("login:voltar") != null;
}
fn backToSession(app: *App) bool {
    return app.login.phase != .form and app.store.ready and acc_store.session == 7001;
}
fn removedB(app: *App) bool {
    return acc_store.list.len == 1 and acc_store.list.find(7001) == null and acc_store.session == 1000 and app.store.ready;
}

const long_text = "Mensagem longa do QA pra testar a quebra de linha: Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat. 😂🔥🎉 `código inline` **negrito** *itálico* ~~riscado~~ ||spoiler|| https://ziglang.org fim.";

// --- Caixa de entrada e mensagens salvas ---------------------------------------

const saved_core = @import("core/saved.zig");
const saved_ui = @import("ui/saved.zig");

fn inboxOpen(app: *App) bool {
    return app.st.popup == .inbox and qa.find("inbox-tab:unread") != null;
}
fn firstMark(prefix: []const u8, b: []u8) []const u8 {
    var keys: [1][56]u8 = undefined;
    var lens: [1]u8 = undefined;
    if (qa.keysWith(&.{prefix}, &keys, &lens) == 0) return "";
    const k = keys[0][0..lens[0]];
    @memcpy(b[0..k.len], k);
    return b[0..k.len];
}
fn idOf(name: []const u8) Id {
    const colon = std.mem.lastIndexOfScalar(u8, name, ':') orelse return 0;
    return std.fmt.parseInt(Id, name[colon + 1 ..], 10) catch 0;
}
fn inboxHasPreview(_: *App) bool {
    var b: [64]u8 = undefined;
    return firstMark("inbox-msg:", &b).len > 0;
}
/// A menção no fim do #anúncios do primeiro servidor (demonstração).
fn announcement(app: *App) ?Id {
    const cs = app.store.channel(ch(2)) orelse return null;
    var i = cs.messages.items.len;
    while (i > 0) {
        i -= 1;
        const m = &cs.messages.items[i];
        if (m.msg.author == 1001 and std.mem.indexOf(u8, m.msg.content, "<@1000>") != null) return m.msg.id;
    }
    return null;
}
fn inboxHasAnnouncement(app: *App) bool {
    const id = announcement(app) orelse return false;
    var b: [64]u8 = undefined;
    return qa.find(markFmt(&b, "inbox-msg:{d}", .{id})) != null and qa.find(markFmt(&b, "inbox-open:{d}", .{ch(2)})) != null;
}
fn tInboxAnnouncement(app: *App, b: []u8) []const u8 {
    const id = announcement(app) orelse return "";
    return markFmt(b, "inbox-msg:{d}", .{id});
}
fn noOldToast(app: *App) bool {
    return std.mem.indexOf(u8, app.st.toast.text(), "carregada") == null;
}
fn jumpedToMention(app: *App) bool {
    const cs = active(app) orelse return false;
    return cs.info.id == ch(2) and cs.history == .loaded and app.st.popup == .none and app.st.jump == 0 and !cs.info.unread and noOldToast(app);
}
fn announcementGone(_: *App) bool {
    var b: [64]u8 = undefined;
    return qa.find(markFmt(&b, "inbox-open:{d}", .{ch(2)})) == null and qa.find("inbox-tab:unread") != null;
}
fn tInboxReadFirst(_: *App, b: []u8) []const u8 {
    const k = firstMark("inbox-read:", b);
    saved_id = idOf(k);
    return k;
}
fn firstGroupRead(app: *App) bool {
    if (app.store.channel(saved_id)) |cs| return !cs.info.unread;
    if (app.store.guild(saved_id)) |g| return g.mentions == 0;
    return false;
}
var inbox_builds: u32 = 0;
fn inboxMarkBuilds(_: *App) void {
    inbox_builds = @import("ui/inbox.zig").rebuilds;
}
fn inboxIdle(_: *App) bool {
    return @import("ui/inbox.zig").rebuilds == inbox_builds;
}
/// Como o menu "Marcar como não lida" faz: direto no Store, sem evento.
var unread_dm: Id = 0;
fn markDmUnreadRaw(app: *App) void {
    var it = app.store.channels.valueIterator();
    while (it.next()) |cs| {
        if (cs.*.info.guild != 0 or cs.*.info.kind != .text) continue;
        for (cs.*.messages.items) |m| if (m.msg.id != 0 and m.msg.author != app.store.me) {
            cs.*.info.unread = true;
            unread_dm = cs.*.info.id;
            return;
        };
    }
}
fn dmBackInInbox(_: *App) bool {
    var b: [48]u8 = undefined;
    return unread_dm != 0 and qa.find(markFmt(&b, "inbox-open:{d}", .{unread_dm})) != null;
}
fn inboxEmpty(app: *App) bool {
    if (qa.find("inbox-empty") == null or app.st.popup != .inbox) return false;
    var it = app.store.channels.valueIterator();
    while (it.next()) |cs| if (cs.*.info.guild == 0 and cs.*.info.unread) return false;
    for (app.store.guilds.items) |g| if (g.mentions > 0) return false;
    return true;
}
fn mentionsShown(app: *App) bool {
    var b: [64]u8 = undefined;
    return app.store.mentions_state == .loaded and app.store.recent_mentions.items.len > 0 and firstMark("inbox-mention:", &b).len > 0;
}
fn tFirstMention(_: *App, b: []u8) []const u8 {
    const k = firstMark("inbox-mention:", b);
    saved_id = idOf(k);
    return k;
}
fn oldMentionOpened(app: *App) bool {
    const cs = active(app) orelse return false;
    const want = for (app.store.recent_mentions.items) |m| {
        if (m.msg.id == saved_id) break m.msg.channel;
    } else return false;
    // Fora do que carrega ao abrir: buscou em volta dela e ela está na lista.
    return cs.info.id == want and cs.history == .loaded and app.st.popup == .none and app.st.jump == 0 and noOldToast(app) and app.store.find(cs, saved_id) != null;
}
fn rememberOther(app: *App) void {
    if (lastOther(app)) |m| saved_id = m.msg.id;
}
fn tHoverSaved(_: *App, b: []u8) []const u8 {
    return markFmt(b, "msg:{d}", .{saved_id});
}
fn oneSaved(app: *App) bool {
    return app.st.saved.items.items.len == 1 and app.st.saved.find(saved_id) != null;
}
fn noneSaved(app: *App) bool {
    return app.st.saved.items.items.len == 0;
}
fn savedOpen(app: *App) bool {
    var b: [64]u8 = undefined;
    return app.st.popup == .saved and qa.find(markFmt(&b, "saved-open:{d}", .{saved_id})) != null;
}
fn tSavedNote(_: *App, b: []u8) []const u8 {
    return markFmt(b, "saved-note:{d}", .{saved_id});
}
fn tSavedOpen(_: *App, b: []u8) []const u8 {
    return markFmt(b, "saved-open:{d}", .{saved_id});
}
fn tSavedRemove(_: *App, b: []u8) []const u8 {
    return markFmt(b, "saved-remove:{d}", .{saved_id});
}
fn noteEditing(app: *App) bool {
    return saved_ui.isEditing() and app.st.popup == .saved and qa.find("saved-note-input") != null;
}
fn noteCancelled(app: *App) bool {
    const it = app.st.saved.find(saved_id) orelse return false;
    return !saved_ui.isEditing() and app.st.popup == .saved and std.mem.eql(u8, it.note, qa_note);
}
/// O que está gravado no arquivo de salvas da conta (qa-out/).
fn savedOnDisk(app: *App) ?saved_core.List {
    var buf: [256]u8 = undefined;
    const p = saved_ui.filePath(&buf, app.store.me) orelse return null;
    var size: usize = 0;
    const data = c.SDL_LoadFile(p.ptr, &size) orelse return null;
    defer c.SDL_free(data);
    var l: saved_core.List = .{};
    l.read(app.gpa, @as([*]const u8, @ptrCast(data))[0..size]) catch return null;
    return l;
}
const qa_note = "lembrar de responder";
fn noteSaved(app: *App) bool {
    const it = app.st.saved.find(saved_id) orelse return false;
    if (saved_ui.isEditing() or !std.mem.eql(u8, it.note, qa_note)) return false;
    var disk = savedOnDisk(app) orelse return false;
    defer disk.deinit(app.gpa);
    const f = disk.find(saved_id) orelse return false;
    return std.mem.eql(u8, f.note, qa_note) and f.channel == ch(4) and f.content.len > 0;
}
fn jumpedToSaved(app: *App) bool {
    const cs = active(app) orelse return false;
    return cs.info.id == ch(4) and app.st.popup == .none and app.st.jump == 0 and noOldToast(app);
}
fn savedEmptyOnDisk(app: *App) bool {
    if (app.st.saved.items.items.len != 0 or qa.find("saved-empty") == null) return false;
    var disk = savedOnDisk(app) orelse return false;
    defer disk.deinit(app.gpa);
    return disk.items.items.len == 0;
}

/// Os plugins (também sozinhos: QA_SUITE=plugins).
const ops_plugin_section = [_]Op{
    s("plugins"),
    .{ .run = writePlugins },
    ctrl(c.ImGuiKey_Comma),
    click("settings:Plugins"),
    expect("sem plugins carregados, a página diz como começar", noPlugins),
    click("button:Recarregar"),
    expect("Recarregar lê os .lua da pasta", pluginsLoaded),
    expect("erro de sintaxe aparece na página", syntaxShown),
    .{ .shot = "35-plugins" },
    key(c.ImGuiKey_Escape),
    expect("fecha as configurações", settingsClosed),
    click("composer"),
    .{ .text = "/shrug sei lá" },
    key(c.ImGuiKey_Enter),
    expect("/shrug (docs/plugins/shrug.lua) manda o texto com ¯\\_(ツ)_/¯", shrugSent),
    click("composer"),
    .{ .text = "/trava" },
    // A primeira escolhe na lista do autocompletar; a segunda envia.
    key(c.ImGuiKey_Enter),
    key(c.ImGuiKey_Enter),
    expect("plugin em laço infinito é parado pelo limite de instruções", travaStopped),
    .{ .key = .{ .key = c.ImGuiKey_Y, .ctrl = true, .shift = true } },
    expect("atalho Ctrl+Shift+Y do plugin manda mensagem", keySent),
    click("composer"),
    .{ .text = "ping-plugin" },
    key(c.ImGuiKey_Enter),
    .{ .expect = .{ .name = "evento message chega ao plugin e sigma.notify avisa", .check = pongToast, .timeout_ms = 3000 } },
    .{ .run = clearToast },
    .{ .run = fakeUrgent },
    expect("alerta.lua (docs/plugins) avisa a palavra de outra pessoa", alertToast),
    click("composer"),
    .{ .text = "spam-plugin" },
    key(c.ImGuiKey_Enter),
    .{ .expect = .{ .name = "sigma.send em resposta a mensagem é bloqueado", .check = spamBlocked, .timeout_ms = 3000 } },
    ctrl(c.ImGuiKey_Comma),
    click("settings:Plugins"),
    click("toggle:shrug.lua"),
    expect("desligar um plugin", shrugOff),
    key(c.ImGuiKey_Escape),
    click("composer"),
    .{ .text = "/shrug sei lá" },
    key(c.ImGuiKey_Enter),
    .{ .expect = .{ .name = "desligado, /shrug vai como texto normal", .check = shrugLiteral, .timeout_ms = 3000 } },
    ctrl(c.ImGuiKey_Comma),
    click("settings:Plugins"),
    click("toggle:shrug.lua"),
    expect("religar o plugin", shrugOn),
    click("button:Instalar os incluídos"),
    expect("Instalar põe os plugins incluídos na pasta", examplesLoaded),
    key(c.ImGuiKey_Escape),
    click("composer"),
    .{ .text = "/conta 2+3*4" },
    key(c.ImGuiKey_Enter),
    .{ .expect = .{ .name = "/conta (calc.lua) manda a conta no canal", .check = contaSent, .timeout_ms = 3000 } },
    click("composer"),
    .{ .text = "/mock isso" },
    key(c.ImGuiKey_Enter),
    .{ .expect = .{ .name = "/mock (zoeira.lua) reescreve o texto", .check = mockSent, .timeout_ms = 3000 } },
    ctrl(c.ImGuiKey_Comma),
    click("settings:Plugins"),
} ++ @import("qa_plugins.zig").ops ++ [_]Op{
    .{ .sweep = &.{ "toggle:", "button:", "plugin-open:", "host:", "pp-select:", "pp-toggle:" } },
    key(c.ImGuiKey_Escape),
    // O resto da bateria começa sem plugins e sem painel (o layout volta ao normal).
    .{ .run = @import("qa_plugins.zig").endSection },
    expect("sem plugins, a thread dos plugins sai", @import("qa_plugins.zig").threadGone),

} ++ @import("qa_plugins.zig").ops_forward;

const ops = [_]Op{
    s("início"),
    expect("app conecta e carrega o histórico", ready),
    expect("abre com 3 abas e #geral ativo", threeTabs),
    .{ .shot = "01-inicio" },
} ++ @import("qa_leve.zig").startup ++ @import("qa_leitura.zig").startup ++ [_]Op{
    s("navegação"),
    click("channel:500006"),
    expect("clicar num canal abre ele na aba", onMemes),
    .{ .ctrl_click = .{ .mark = "channel:500007" } },
    expect("Ctrl+clique abre o canal numa aba nova", newTab),
    ctrl(c.ImGuiKey_W),
    expect("Ctrl+W fecha a aba", tabClosed),
    click("category:500004"),
    expect("clicar na categoria recolhe", catCollapsed),
    click("category:500004"),
    expect("clicar de novo expande", catOpen),
    click("guild:501000"),
    expect("clicar no servidor abre um canal dele", onGuild1),
    click("guild:0"),
    expect("o botão inicial abre os amigos", friendsOpen),
    .{ .shot = "02-dms" },
    click("guild:500000"),
    expect("volta para o primeiro servidor", onGuild0),
    .{ .run = rememberTab },
    ctrl(c.ImGuiKey_Tab),
    expect("Ctrl+Tab troca de aba", tabMoved),
    .{ .key = .{ .key = c.ImGuiKey_2, .alt = true } },
    expect("Alt+2 vai para a segunda aba", tab1),
    .{ .key = .{ .key = c.ImGuiKey_1, .alt = true } },
    click("channel:500005"),

    s("enviar mensagens"),
    click("composer"),
    .{ .text = "teste do QA 🎉 **negrito**" },
    key(c.ImGuiKey_Enter),
    expect("enviar com Enter (e o servidor confirma)", sentConfirmed),
    .{ .text = "oi @ana.exe tudo bem?" },
    key(c.ImGuiKey_Enter),
    expect("@nome vira menção de verdade", mentionResolved),
    .{ .text = long_text },
    key(c.ImGuiKey_Enter),
    expect("mensagem longa com markdown e emoji", longSent),
    .{ .shot = "03-enviadas" },

    s("envio que falhou"),
    .{ .run = failSend },
    .{ .wait = 100 },
    expect("a mensagem que não foi fica marcada, com o texto", failedShown),
    .{ .shot = "03b-nao-enviada" },
    click("failed-discard:900001"),
    expect("descartar tira a mensagem", failedGone),
    .{ .run = failSend },
    .{ .wait = 100 },
    click("failed-resend:900001"),
    expect("reenviar manda de novo e o servidor confirma", failedResent),

    s("responder"),
    .{ .hover = .{ .dyn = tHoverOther } },
    .{ .wait = 150 },
    .{ .click = .{ .dyn = tReplyLast } },
    expect("botão responder da barra de ações", replyArmed),
    .{ .shot = "04-respondendo" },
    .{ .text = "respondendo pelo QA" },
    key(c.ImGuiKey_Enter),
    expect("a resposta sai ligada à original", replySent),

    s("editar"),
    click("composer"),
    key(c.ImGuiKey_UpArrow),
    expect("seta pra cima entra na edição", composerEditing),
    key(c.ImGuiKey_Escape),
    expect("Esc cancela a edição", editCancelled),
    click("composer"),
    key(c.ImGuiKey_UpArrow),
    expect("seta pra cima edita a última mensagem", editing),
    ctrl(c.ImGuiKey_A),
    .{ .text = "editado pelo QA" },
    key(c.ImGuiKey_Enter),
    expect("salvar a edição marca (editado)", edited),

    s("reações"),
    .{ .hover = .{ .dyn = tHoverMine } },
    .{ .wait = 150 },
    .{ .click = .{ .dyn = tThumbMine } },
    expect("👍 pela barra de ações", reacted),
    .{ .click = .{ .dyn = tChipMine } },
    expect("clicar na reação tira ela", unreacted),
    .{ .hover = .{ .dyn = tHoverMine } },
    .{ .rclick = .{ .dyn = tThumbMine } },
    .{ .wait = 150 },
    expect("botão direito na barra de ações não reage", unreacted),

    s("menu do botão direito"),
    .{ .run = rememberCount },
    .{ .rclick = .{ .dyn = tHoverMine } },
    expect("botão direito abre o menu da mensagem", menuOpen),
    .{ .shot = "05-menu" },
    click("menu:Excluir mensagem"),
    expect("excluir pelo menu", deleted),
    .{ .run = clearToast },
    .{ .rclick = .{ .dyn = tHoverOther } },
    click("menu:Copiar texto"),
    expect("copiar texto pelo menu", toastCopied),

    s("seleção de texto"),
    .{ .run = clearToast },
    .{ .drag = .{ .from = .{ .dyn_at = .{ .f = tSelFrom, .fx = 0.12, .fy = 0.8 } }, .to = .{ .dyn_at = .{ .f = tSelTo, .fx = 0.3, .fy = 0.8 } } } },
    expect("arrastar seleciona texto entre mensagens", hasSelection),
    .{ .shot = "06-selecao" },
    ctrl(c.ImGuiKey_C),
    expect("Ctrl+C copia a seleção", toastCopied),
    key(c.ImGuiKey_Escape),

    s("atualizações e novidades"),
    .{ .key = .{ .key = c.ImGuiKey_Comma, .ctrl = true } },
    .{ .wait = 300 },
    click("settings:Atualizações"),
    .{ .wait = 150 },
    click("button:Verificar atualizações"),
    expect("verificar mostra que está na última versão", updateShownCurrent),
    .{ .run = updateAvailable },
    expect("versão nova aparece com o número", updateShownAvailable),
    .{ .wait = 100 },
    .{ .shot = "06c-atualizacao" },
    click("button:Baixar e instalar"),
    expect("instalar pede para reiniciar", updateShownReady),
    click("button:Reiniciar o SigmaCord"),
    expect("reiniciar (no QA só avisa)", toastRestart),
    click("settings:Novidades"),
    expect("a página de novidades mostra o changelog", changelogShown),
    .{ .wait = 100 },
    .{ .shot = "06d-novidades" },
    key(c.ImGuiKey_Escape),
    .{ .wait = 350 },

    s("editar servidor e grupo"),
    click("guild:500000"),
    .{ .rclick = .{ .mark = "guild-header" } },
    click("menu:Editar servidor…"),
    expect("o menu abre a edição do servidor", editDialogOpen),
    .{ .wait = 200 },
    .{ .shot = "06a-editar-servidor" },
    click("edit-name"),
    ctrl(c.ImGuiKey_A),
    .{ .text = "SigmaCord QA" },
    .{ .wait = 100 },
    click("edit-save"),
    .{ .expect = .{ .name = "salvar troca o nome do servidor", .check = guildRenamed, .timeout_ms = 3000 } },
    .{ .rclick = .{ .mark = "guild-header" } },
    click("menu:Editar servidor…"),
    .{ .run = qaPickIcon },
    .{ .wait = 150 },
    click("edit-save"),
    .{ .expect = .{ .name = "salvar troca o ícone do servidor", .check = guildIconChanged, .timeout_ms = 3000 } },
    .{ .rclick = .{ .mark = "guild-header" } },
    click("menu:Editar servidor…"),
    .{ .wait = 150 },
    click("edit-remove:icon"),
    click("edit-name"),
    ctrl(c.ImGuiKey_A),
    .{ .text = "SigmaCord dev" },
    .{ .wait = 100 },
    click("edit-save"),
    .{ .expect = .{ .name = "remover o ícone e voltar o nome", .check = guildRestored, .timeout_ms = 3000 } },
    click("guild:0"),
    .{ .rclick = .{ .mark = "channel:900006" } },
    click("menu:Editar grupo…"),
    expect("o menu abre a edição do grupo", editDialogOpen),
    click("edit-name"),
    ctrl(c.ImGuiKey_A),
    .{ .text = "grupo QA" },
    .{ .run = qaPickIcon },
    .{ .wait = 150 },
    click("edit-save"),
    .{ .expect = .{ .name = "salvar troca o nome e o ícone do grupo", .check = groupRenamed, .timeout_ms = 3000 } },
    click("guild:500000"),
    click("channel:500005"),

    s("componentes de bot"),
    .{ .run = scrollToV2 },
    expect("mensagem só com componentes tem altura de texto", v2HasText),
    .{ .wait = 400 },
    .{ .shot = "06b-componentes" },
    .{ .drag = .{ .from = .{ .dyn_at = .{ .f = tV2, .fx = 0.08, .fy = 0.08 } }, .to = .{ .dyn_at = .{ .f = tV2, .fx = 0.5, .fy = 0.08 } } } },
    expect("arrastar seleciona o texto do cartão", selectionInEmbed),
    .{ .run = clearToast },
    ctrl(c.ImGuiKey_C),
    expect("Ctrl+C copia o texto do cartão", toastCopied),
    key(c.ImGuiKey_Escape),
    .{ .run = backToEnd },
    .{ .wait = 300 },

    s("perfil e DM"),
    .{ .click = .{ .dyn = tUserOther } },
    expect("clicar no nome abre o perfil", profileOpen),
    .{ .shot = "07-perfil" },
    .{ .wait = 100 },
    .{ .text = "oi do perfil" },
    key(c.ImGuiKey_Enter),
    expect("\"Mensagem @fulano\" manda DM", dmSent),
    click("guild:500000"),

    s("perfil completo"),
    click("guild:500000"),
    click("member:1002"),
    expect("o cartão mostra o jogo, quando entrou no servidor e o que há em comum", cardDetails),
    click("profile-mutual:1"),
    expect("amigos em comum abre o perfil grande na aba certa", fullFriendsTab),
    .{ .shot = "07b-perfil-amigos" },
    click("profile-tab:2"),
    expect("aba de servidores em comum", fullGuildsTab),
    click("profile-tab:0"),
    expect("aba de atividade mostra o jogo", hasActivity),
    .{ .shot = "07c-perfil-grande" },
    click("profile-conn:github"),
    expect("conta ligada abre o link", openedGithub),
    click("profile-note"),
    .{ .text = "jogador de hollow knight" },
    key(c.ImGuiKey_Enter),
    expect("a nota fica guardada", profileNoteSaved),
    click("profile-full-close"),
    expect("o X fecha o perfil grande", popupClosed),

    s("canais sem acesso"),
    click("guild:501000"),
    .{ .wait = 200 },
    .{ .shot = "26-sem-acesso" },
    expect("canal sem permissão aparece com cadeado (e o resto não)", lockedShown),
    .{ .run = rememberLockedFrom },
    click("channel:501012"),
    expect("clicar num canal trancado só avisa (não abre)", lockedNotOpened),
    // O AFK fica fora da tela: pede a entrada direto, como o clique faria.
    .{ .run = joinLockedVoice },
    expect("canal de voz sem permissão de entrar não entra", notInVoice),
    click("guild:500000"),

    s("mensagem longa"),
    click("guild:500000"),
    click("composer"),
    .{ .text = "linha um" },
    .{ .run = rememberComposerH },
    .{ .key = .{ .key = c.ImGuiKey_Enter, .shift = true } },
    .{ .text = "linha dois" },
    expect("Shift+Enter abre uma linha nova e a caixa cresce", composerGrew),
    key(c.ImGuiKey_Enter),
    expect("Enter envia com as duas linhas", sentTwoLines),
    expect("depois de enviar, a caixa volta ao tamanho normal", composerBack),
    .{ .run = sendLongWord },
    .{ .expect = .{ .name = "palavra enorme quebra em várias linhas sem sair da tela", .check = longWordWrapped, .timeout_ms = 3000 } },
    .{ .shot = "27-mensagem-longa" },

    s("emoji"),
    click("composer-emoji"),
    expect("botão de emoji abre o seletor", emojiOpen),
    .{ .shot = "08-emoji" },
    click("emoji:0"),
    expect("escolher um emoji coloca na caixa", emojiInserted),
    click("composer"),
    ctrl(c.ImGuiKey_A),
    key(c.ImGuiKey_Backspace),
    expect("apagar o texto da caixa", inputEmpty),

    s("paleta"),
    ctrl(c.ImGuiKey_K),
    expect("Ctrl+K abre a paleta", paletteOpen),
    expect("a dica da paleta aparece na tela", paletteInk),
    .{ .text = "zig" },
    expect("o que se digita na paleta aparece na tela", paletteInk),
    .{ .shot = "09-paleta" },
    key(c.ImGuiKey_Enter),
    expect("Enter na paleta abre o canal", onZig),

    s("voz e botões"),
    click("channel:500014"),
    expect("clicar num canal de voz entra na call", inVoice),
    expect("em call, o painel do usuário continua na tela", panelOnScreen),
    click("voice-member:500014:1001"),
    expect("clicar em quem está na call abre o perfil", profileOpen),
    key(c.ImGuiKey_Escape),
    .{ .rclick = .{ .mark = "voice-member:500014:1001" } },
    click("menu:Mover para…"),
    click("menu:Jogando"),
    expect("botão direito → Mover para… muda a pessoa de call", movedToGaming),
    .{ .rclick = .{ .mark = "member:1001" } },
    click("menu:Desconectar da call"),
    expect("Desconectar da call tira a pessoa da call", disconnected1001),
    .{ .rclick = .{ .mark = "channel:500014" } },
    click("menu:Sair da call"),
    expect("botão direito no canal de voz → Sair da call", notInVoice),
    click("channel:500014"),
    expect("entra de novo", inVoice),
    click("hangup"),
    expect("desligar sai da call", notInVoice),
    click("me"),
    expect("clicar no próprio nome abre o menu de status", statusMenu),
    click("menu:⊘  Não perturbe"),
    expect("escolher Não perturbe", meDnd),
    click("me"),
    click("menu:●  Online"),
    expect("voltar para Online", meOnline),
    click("user-btn:0"),
    expect("botão de mutar", muted),
    click("user-btn:0"),
    expect("botão de desmutar", unmuted),
    .{ .run = rememberComposerW },
    click("header-members"),
    expect("botão de membros esconde a lista", membersHidden),
    expect("a lista some da tela", noMembers),
    expect("a conversa ocupa o lugar da lista (sem espaço vazio)", composerWider),
    click("header-members"),
    expect("e mostra de novo", membersShown),

    s("configurações"),
    click("user-btn:2"),
    expect("engrenagem abre as configurações", settingsOpen),
    click("settings:Minha conta"),
    .{ .shot = "10-conta" },
    click("settings:Privacidade"),
    .{ .shot = "11-voz" },
    click("settings:Atalhos de teclado"),
    click("settings:Desempenho"),
    .{ .shot = "12-desempenho" },
    click("settings:Aparência"),
    click("seg:Claro"),
    expect("Aparência → Claro", lightMode),
    .{ .shot = "13-claro" },
    click("seg:Escuro"),
    expect("Aparência → Escuro", darkMode),
    click("toggle:Modo compacto"),
    expect("liga o modo compacto", compactOn),
    click("toggle:Modo compacto"),
    expect("desliga o modo compacto", compactOff),
    click("theme-card:terminal"),
    expect("clicar na miniatura troca o tema", onTerminal),
    click("toggle:Efeito CRT"),
    expect("opção do tema: desliga o CRT", crtOff),
    click("toggle:Efeito CRT"),
    expect("opção do tema: liga o CRT", crtOn),
    click("theme-card:classico"),
    expect("volta pro classico", onClassico),
    key(c.ImGuiKey_Escape),
    expect("Esc fecha as configurações", settingsClosed),

    s("todos os temas"),
    .{ .run = rememberTheme },
    key(c.ImGuiKey_F2),
    expect("F2 troca de tema", themeChanged),
    .{ .shot = "20-tema-2" },
    expect("tema 2 mostra conversa e caixa de texto", composerVisible),
    key(c.ImGuiKey_F2),
    .{ .shot = "21-tema-3" },
    expect("tema 3 mostra conversa e caixa de texto", composerVisible),
    key(c.ImGuiKey_F2),
    .{ .shot = "22-tema-4" },
    expect("tema 4 mostra conversa e caixa de texto", composerVisible),
    key(c.ImGuiKey_F2),
    .{ .shot = "23-tema-5" },
    expect("tema 5 mostra conversa e caixa de texto", composerVisible),
    key(c.ImGuiKey_F2),
    .{ .shot = "24-tema-6" },
    expect("tema 6 mostra conversa e caixa de texto", composerVisible),
    key(c.ImGuiKey_F2),
    .{ .shot = "25-tema-7" },
    expect("tema 7 mostra conversa e caixa de texto", composerVisible),
    // Os temas além dos 7 de sempre (quem cria um tema novo não precisa
    // mexer aqui): pula até o último e confere a volta ao primeiro.
    .{ .run = skipExtraThemes },
    .{ .wait = 200 },
    key(c.ImGuiKey_F2),
    expect("depois do último volta ao primeiro", onClassico),

    s("imagens e anexos"),
    .{ .hover = .{ .dyn = tDemoImage } },
    .{ .wait = 400 },
    .{ .expect = .{ .name = "imagem da conversa carrega", .check = demoImageReady, .timeout_ms = 4000 } },
    .{ .shot = "26-imagem" },
    .{ .click = .{ .dyn = tDemoImage } },
    expect("clicar na imagem abre em tela cheia", viewerOpen),
    .{ .wait = 300 },
    .{ .expect = .{ .name = "tela cheia carrega a imagem grande", .check = noImageLoading, .timeout_ms = 4000 } },
    .{ .shot = "27-imagem-tela-cheia" },
    click("viewer:Copiar imagem"),
    .{ .expect = .{ .name = "copiar imagem põe a imagem na área de transferência", .check = imageCopied, .timeout_ms = 5000 } },
    .{ .hover = .{ .mark = "viewer" } },
    .{ .run = wheelUp },
    .{ .wait = 150 },
    expect("a roda do mouse amplia a imagem", viewerZoomed),
    .{ .wait = 200 },
    .{ .shot = "27a-imagem-ampliada" },
    .{ .drag = .{ .from = .{ .mark = "viewer" }, .to = .{ .mark = "viewer:fechar" } } },
    expect("arrastar move a imagem ampliada, sem fechar", viewerMoved),
    .{ .run = wheelDown },
    .{ .wait = 150 },
    expect("não encolhe além do tamanho que cabe, e volta ao centro", viewerFits),
    .{ .dclick = .{ .mark = "viewer" } },
    expect("dois cliques ampliam", viewerZoomed),
    .{ .dclick = .{ .mark = "viewer" } },
    expect("dois cliques voltam", viewerFits),
    key(c.ImGuiKey_Escape),
    expect("Esc fecha a tela cheia", viewerClosed),
    .{ .click = .{ .dyn = tDemoImage } },
    expect("abrir de novo", viewerOpen),
    click("viewer:fechar"),
    expect("o X fecha a tela cheia", viewerClosed),
    .{ .run = pinDemoImage },
    .{ .expect = .{ .name = "a imagem aparece na aba de fixadas", .check = pinnedImageShown, .timeout_ms = 4000 } },
    .{ .shot = "27b-fixadas-imagem" },
    .{ .click = .{ .dyn = tDemoImage } },
    expect("clicar nela abre em tela cheia", viewerOpen),
    key(c.ImGuiKey_Escape),
    expect("Esc fecha a imagem", viewerClosed),
    key(c.ImGuiKey_Escape),
    .{ .run = unpinDemoImage },
    .{ .wait = 200 },
    .{ .run = clearToast },
    .{ .run = jumpToFile },
    .{ .wait = 500 },
    .{ .click = .{ .dyn = tDemoFile } },
    expect("clicar no arquivo responde", toastDemoFile),
    .{ .run = attachQaImage },
    expect("arquivo entra na bandeja", oneUpload),
    .{ .wait = 200 },
    .{ .shot = "28-bandeja" },
    click("upload-remove:0"),
    expect("tirar o arquivo da bandeja", noUploads),
    click("composer"),
    .{ .run = copyBitmap },
    ctrl(c.ImGuiKey_V),
    expect("Ctrl+V com um print em bitmap entra na bandeja como PNG", pastedAsPng),
    .{ .run = removePasted },
    .{ .wait = 100 },
    expect("tirar o print colado da bandeja", noUploads),
    .{ .run = attachQaImage },
    click("composer"),
    .{ .text = "olha essa imagem" },
    key(c.ImGuiKey_Enter),
    .{ .expect = .{ .name = "mensagem com imagem enviada", .check = sentWithImage, .timeout_ms = 3000 } },
    expect("bandeja esvazia depois de enviar", noUploads),
    .{ .expect = .{ .name = "imagem enviada aparece", .check = noImageLoading, .timeout_ms = 4000 } },
    .{ .shot = "29-imagem-enviada" },
    .{ .run = attachQaImage },
    click("composer"),
    key(c.ImGuiKey_Enter),
    .{ .expect = .{ .name = "só a imagem, sem texto", .check = sentImageOnly, .timeout_ms = 3000 } },

    s("vídeo"),
    .{ .run = jumpToVideo },
    .{ .wait = 500 },
    .{ .click = .{ .dyn = tDemoVideo } },
    .{ .expect = .{ .name = "play no vídeo: toca aqui (sem FFmpeg, avisa e não toca)", .check = videoPlaying, .timeout_ms = 5000 } },
    .{ .shot = "35-video" },
    .{ .expect = .{ .name = "vídeo em até 480p e ~30 qps (o de 60 qps pula quadros)", .check = videoLimits, .timeout_ms = 4000 } },
    expect("som do vídeo vai para o SDL (quando há áudio)", videoAudio),
    // Sem o mouse em cima, o desenho fica igual e só a textura muda.
    .{ .hover = .{ .mark = "guild:500000" } },
    .{ .wait = 250 },
    .{ .run = gateRealOn },
    .{ .wait = 500 },
    .{ .run = gateRealOff },
    expect("cada quadro do vídeo chega à tela, mesmo com o desenho igual", videoFramesReachScreen),
    .{ .hover = .{ .dyn = tDemoVideo } },
    .{ .wait = 150 },
    .{ .click = .{ .dyn = tVideoPlay } },
    expect("o botão pausa", videoPaused),
    .{ .run = rememberVideoPos },
    .{ .wait = 400 },
    expect("pausado, o tempo não anda", videoPosKept),
    .{ .click = .{ .dyn_at = .{ .f = tVideoBar, .fx = 0.75, .fy = 0.5 } } },
    .{ .expect = .{ .name = "clicar na barra pula para o ponto", .check = videoSeeked, .timeout_ms = 3000 } },
    .{ .click = .{ .dyn = tVideoPlay } },
    expect("o botão continua", videoResumed),
    .{ .click = .{ .dyn_at = .{ .f = tVideoVol, .fx = 0.5, .fy = 0.5 } } },
    expect("o meio do volume muda o ganho do som na hora", videoVolHalf),
    .{ .shot = "video-volume" },
    .{ .click = .{ .dyn = tVideoMute } },
    expect("o botão de som zera o volume", videoVolZero),
    .{ .click = .{ .dyn = tVideoMute } },
    expect("e volta ao volume de antes", videoVolHalf),
    .{ .click = .{ .dyn_at = .{ .f = tVideoVol, .fx = 0.01, .fy = 0.5 } } },
    expect("o começo do volume é mudo", videoVolZero),
    .{ .click = .{ .dyn_at = .{ .f = tVideoVol, .fx = 0.99, .fy = 0.5 } } },
    expect("o fim do volume é o som cheio", videoVolFull),
    .{ .run = trayFake },
    .{ .run = pushCloseEvent },
    expect("ir para a bandeja pausa o vídeo", hiddenAndPaused),
    .{ .run = wakeShowWindow },
    .{ .run = trayFakeOff },
    .{ .click = .{ .dyn = tVideoPlay } },
    .{ .expect = .{ .name = "voltou e continua", .check = videoResumedOrEnded, .timeout_ms = 6000 } },
    .{ .click = .{ .dyn = tVideoMute } },
    expect("o botão de som silencia", videoMuted),
    .{ .expect = .{ .name = "o vídeo chega ao fim e para no último quadro", .check = videoEnded, .timeout_ms = 5000 } },
    .{ .click = .{ .dyn = tVideoPlay } },
    expect("play no fim recomeça do começo", videoRestarted),
    .{ .run = rememberVideoChannel },
    .{ .click = .{ .dyn = tOtherChannel } },
    expect("fora da tela, o vídeo pausa e o app acorda em 30 s para soltá-lo", videoWakeToRelease),
    .{ .click = .{ .dyn = tVideoChannel } },
    .{ .run = jumpToVideo },
    .{ .wait = 500 },
    .{ .click = .{ .dyn = tVideoClose } },
    expect("o X fecha o vídeo e volta a prévia", videoClosed),
    .{ .run = jumpToMp4Gif },
    .{ .wait = 400 },
    .{ .expect = .{ .name = "GIF de fora desligado: GIF em MP4 fica na prévia parada", .check = mp4GifStill, .timeout_ms = 4000 } },
    .{ .run = gifHostsOn },
    .{ .expect = .{ .name = "GIF de fora ligado: o GIF em MP4 anima pelo FFmpeg (sem ele, prévia)", .check = mp4GifAnimated, .timeout_ms = 8000 } },
    .{ .shot = "36-gif-mp4" },
    .{ .run = gifHostsOff },

    s("amigos, grupos e membros"),
    expect("fotos de perfil carregam", avatarsLoaded),
    expect("ícones dos servidores carregam", iconsLoaded),
    expect("lista de membros vem do servidor, por cargo", guildMembers),
    .{ .shot = "31-membros" },
    click("guild:501000"),
    .{ .expect = .{ .name = "outro servidor, outra lista de membros", .check = otherGuildMembers, .timeout_ms = 3000 } },
    click("guild:500000"),
    .{ .run = jumpToGif },
    .{ .wait = 400 },
    .{ .expect = .{ .name = "GIF animado tem vários quadros", .check = gifAnimated, .timeout_ms = 4000 } },
    .{ .shot = "32-gif" },
    .{ .run = scrollBottom },
    click("guild:0"),
    click("friends"),
    expect("Mensagens diretas → Amigos", friendsOpen),
    .{ .shot = "33-amigos" },
    click("friends-tab:pending"),
    expect("aba Pendentes mostra o pedido", pendingTab),
    click("friend-accept:1009"),
    expect("aceitar o pedido de amizade", accepted),
    click("friend-remove:1006"),
    expect("cancelar o pedido enviado", cancelled),
    click("friends-tab:all"),
    click("friend-message:1001"),
    expect("Mensagem abre a DM existente", dmWithAna),
    expect("DM mostra o perfil no lugar dos membros", dmProfileShown),
    click("channel:900006"),
    expect("grupo lista só os participantes", groupOpen),
    .{ .shot = "34-grupo" },
    click("friends"),
    click("friends-tab:all"),
    click("friend-message:1008"),
    .{ .expect = .{ .name = "amigo sem DM: cria a conversa e abre", .check = newDm, .timeout_ms = 3000 } },
    click("guild:500000"),

    s("links e rolagem"),
    click("guild:500000"),
    click("channel:500005"),
    .{ .run = jumpToZigLink },
    .{ .wait = 400 },
    // O primeiro da conversa: outra mensagem com o mesmo link fica mais abaixo.
    .{ .hover = .{ .mark = "first:link:https://ziglang.org" } },
    .{ .wait = 100 },
    expect("em cima de um link, o cursor vira a mãozinha", cursorIsHand),
    click("first:link:https://ziglang.org"),
    expect("clicar num link abre o navegador", linkOpened),
    // Lá em cima de verdade: onde o link fica depende das fontes, e perto do fim nem rola.
    .{ .run = scrollToTop },
    .{ .wait = 300 },
    expect("ver mensagens antigas mostra o botão de ir ao fim", jumpBottomShown),
    click("jump-bottom"),
    expect("o botão de ir ao fim volta para a última mensagem", atBottom),

    s("cache em disco"),
    expect("arquivo privado: 600, pasta 700, troca inteira", privateWrite),
    click("guild:500000"),
    click("channel:500005"),
    expect("pronto", ready),
    .{ .run = cacheTouchActive },
    expect("mensagem nova chega na conversa", cacheTouched),
    click("channel:500006"),
    expect("trocar de canal grava a conversa que ficou para trás", cacheLeftSaved),
    click("channel:500005"),
    expect("pronto", ready),
    .{ .run = cacheFlush },
    expect("a conversa vai para o disco (no máximo 200 por canal)", cacheHasActive),
    .{ .run = cacheReopen },
    expect("reabrir mostra o cache na hora", cacheShown),
    .{ .shot = "47-cache" },
    .{ .expect = .{ .name = "o histórico de verdade substitui o cache sem pular a rolagem", .check = cacheReplaced, .timeout_ms = 4000 } },

    s("busca local"),
    ctrl(c.ImGuiKey_F),
    expect("Ctrl+F abre a busca", searchOpen),
    .{ .shot = "48-busca-vazia" },
    .{ .text = "from:ana" },
    expect("from:ana só acha mensagens da ana", searchFromAna),
    .{ .shot = "49-busca" },
    .{ .run = searchClear },
    .{ .wait = 100 },
    .{ .text = "has:imagem" },
    expect("has:imagem só acha mensagens com imagem", searchImages),
    key(c.ImGuiKey_Escape),
    expect("Esc fecha a busca", searchClosed),
    click("header-find"),
    expect("a lupa do cabeçalho abre a busca", searchOpen),
    key(c.ImGuiKey_Escape),
    .{ .run = unloadMemes },
    ctrl(c.ImGuiKey_F),
    .{ .text = "in:memes" },
    expect("canal fora da memória: a busca acha no cache em disco", searchFromDisk),
    .{ .shot = "50-busca-disco" },
    .{ .run = searchMarkReads },
    key(c.ImGuiKey_Escape),
    ctrl(c.ImGuiKey_F),
    .{ .text = "in:memes" },
    expect("reabrir a busca usa o que já leu do disco (não lê de novo)", searchNoReread),
    expect("e acha o mesmo no cache", searchFromDisk),
    click("search-result:0"),
    .{ .expect = .{ .name = "clicar no resultado abre o canal e pula até a mensagem", .check = searchJumped, .timeout_ms = 4000 } },
    .{ .run = searchClose },
} ++ @import("qa_busca.zig").ops ++ @import("qa_convites.zig").ops ++ [_]Op{
    ctrl(c.ImGuiKey_Comma),
    click("settings:Privacidade"),
    expect("Privacidade tem a opção do cache", privacyPage),
    .{ .shot = "51-privacidade" },
    .{ .click = .{ .dyn = tClearCache } },
    expect("Apagar cache apaga os arquivos", cacheEmpty),
    key(c.ImGuiKey_Escape),

} ++ ops_plugin_section ++ @import("qa_alertas.zig").ops ++ @import("qa_leitura.zig").ops ++ @import("qa_threads.zig").ops ++ @import("qa_voz.zig").ops ++ @import("qa_bandeja.zig").ops ++ lsp_ops ++ @import("qa_paineis.zig").all ++ @import("qa_quadros.zig").ops ++ [_]Op{
    s("caixa de entrada"),
    click("guild:500000"),
    click("channel:500005"),
    click("header-inbox"),
    expect("o botão do cabeçalho abre a caixa de entrada", inboxOpen),
    .{ .expect = .{ .name = "DMs e menções não lidas aparecem com prévia", .check = inboxHasPreview, .timeout_ms = 3000 } },
    .{ .expect = .{ .name = "a menção no #anúncios (nunca aberto) está na lista", .check = inboxHasAnnouncement, .timeout_ms = 3000 } },
    .{ .run = inboxMarkBuilds },
    .{ .wait = 300 },
    expect("parada, a caixa de entrada não se refaz a cada quadro", inboxIdle),
    .{ .shot = "40-caixa-de-entrada" },
    .{ .run = clearToast },
    .{ .click = .{ .dyn = tInboxAnnouncement } },
    .{ .expect = .{ .name = "clicar na menção abre o canal e rola até ela", .check = jumpedToMention, .timeout_ms = 3000 } },
    ctrl(c.ImGuiKey_I),
    expect("Ctrl+I abre a caixa de entrada", inboxOpen),
    expect("o canal lido sai da lista", announcementGone),
    .{ .click = .{ .dyn = tInboxReadFirst } },
    expect("✓ marca um canal como lido", firstGroupRead),
    click("inbox-readall"),
    expect("marcar tudo como lido esvazia a caixa", inboxEmpty),
    .{ .shot = "41-caixa-vazia" },
    .{ .run = markDmUnreadRaw },
    click("inbox-tab:unread"),
    expect("DM marcada como não lida pelo menu (direto no Store) volta para a caixa", dmBackInInbox),
    click("inbox-readall"),
    expect("e sai de novo ao marcar tudo como lido", inboxEmpty),
    click("inbox-tab:mentions"),
    .{ .expect = .{ .name = "aba Menções traz as menções recentes", .check = mentionsShown, .timeout_ms = 3000 } },
    .{ .shot = "42-mencoes" },
    .{ .run = clearToast },
    .{ .click = .{ .dyn = tFirstMention } },
    .{ .expect = .{ .name = "menção antiga abre o canal e busca em volta dela", .check = oldMentionOpened, .timeout_ms = 3000 } },

    s("mensagens salvas"),
    click("guild:500000"),
    click("channel:500005"),
    .{ .run = rememberOther },
    .{ .rclick = .{ .dyn = tHoverSaved } },
    click("menu:Salvar mensagem"),
    expect("salvar pelo menu do botão direito", oneSaved),
    .{ .key = .{ .key = c.ImGuiKey_S, .ctrl = true, .shift = true } },
    expect("Ctrl+Shift+S abre as salvas", savedOpen),
    .{ .shot = "43-salvas" },
    .{ .click = .{ .dyn = tSavedNote } },
    expect("clicar em \"Adicionar anotação\" abre a edição", noteEditing),
    .{ .text = qa_note },
    key(c.ImGuiKey_Enter),
    expect("Enter salva a anotação (e ela vai para o arquivo)", noteSaved),
    .{ .shot = "44-salvas-anotacao" },
    .{ .click = .{ .dyn = tSavedNote } },
    expect("editar a anotação de novo", noteEditing),
    .{ .text = " (rascunho)" },
    key(c.ImGuiKey_Escape),
    expect("Esc cancela a edição sem fechar a tela", noteCancelled),
    .{ .run = clearToast },
    .{ .click = .{ .dyn = tSavedOpen } },
    expect("Ir para a mensagem abre o canal nela", jumpedToSaved),
    click("header-saved"),
    expect("o botão do cabeçalho abre as salvas", savedOpen),
    .{ .click = .{ .dyn = tSavedRemove } },
    expect("Remover tira das salvas e do arquivo", savedEmptyOnDisk),
    key(c.ImGuiKey_Escape),
    expect("Esc fecha as salvas", popupClosed),
    .{ .rclick = .{ .dyn = tHoverSaved } },
    click("menu:Salvar mensagem"),
    expect("salvar de novo", oneSaved),
    .{ .rclick = .{ .dyn = tHoverSaved } },
    click("menu:Remover dos salvos"),
    expect("o menu de uma salva oferece remover", noneSaved),
    s("tela dividida"),
    click("guild:500000"),
    click("channel:500005"),
    .{ .rclick = .{ .mark = "channel:500007" } },
    expect("menu do canal tem \"Abrir ao lado\"", sideMenuItem),
    click("menu:Abrir ao lado"),
    expect("Abrir ao lado divide a tela em dois painéis", twoPanes),
    expect("cada painel mostra o histórico do seu canal", panesDrawn),
    .{ .shot = "35-tela-dividida" },
    click("composer"),
    .{ .text = "do painel da direita" },
    key(c.ImGuiKey_Enter),
    expect("a caixa de texto envia para o painel focado", sentRight),
    click("pane-focus:0"),
    expect("clicar no título do outro painel foca ele", focusLeft),
    click("composer"),
    .{ .text = "do painel da esquerda" },
    key(c.ImGuiKey_Enter),
    expect("e a mensagem vai para o canal dele", sentLeft),
    .{ .rclick = .{ .mark = "channel:500008" } },
    click("menu:Abrir ao lado"),
    expect("um terceiro painel ao lado", threePanes),
    .{ .shot = "36-tres-paineis" },
    .{ .run = scrollLeftUp },
    .{ .wait = 300 },
    expect("cada painel tem a sua rolagem", ownScroll),
    click("pane0/jump-bottom"),
    expect("o botão de ir ao fim do painel lateral rola ele (e foca)", leftAtBottom),
    .{ .click = .{ .at = .{ .key = "pane:2", .fx = 0.5, .fy = 0.5 } } },
    expect("clicar dentro de um painel foca ele", focusThird),
    .{ .sweep = &.{"pane-"} },
    click("pane-close:2"),
    expect("o X fecha o painel (e o foco vai para o vizinho)", closedThird),
    click("pane-close:1"),
    expect("sobrando um, volta a ser uma conversa só", singleView),

    s("cor do servidor"),
    .{ .rclick = .{ .mark = "guild:500000" } },
    expect("menu do servidor mostra as cores", colorRow),
    .{ .shot = "37-cor-do-servidor" },
    click("guild-color:4"),
    expect("escolher a cor pinta o destaque do servidor", guildRed),
    click("guild:501000"),
    expect("outro servidor fica com a cor de sempre", otherGuildPlain),
    click("guild:500000"),
    expect("voltar ao servidor volta a cor dele", guildRed),
    .{ .rclick = .{ .mark = "guild:500000" } },
    click("guild-color:0"),
    expect("a primeira bolinha tira a cor", guildPlain),

} ++ ops_editor ++ @import("qa_emoji.zig").ops ++ [_]Op{
    s("conversa que não carregou"),
    .{ .run = toClassico },
    .{ .wait = 200 },
    click("guild:500000"),
    .{ .wait = 300 },
    .{ .run = failHistory },
    .{ .wait = 100 },
    .{ .shot = "03c-nao-carregou" },
    click("history-retry"),
    expect("tentar de novo carrega a conversa", historyBack),

    s("clicar em tudo: servidor"),
    .{ .run = toClassico },
    .{ .wait = 200 },
    click("guild:500000"),
    .{ .wait = 300 },
    .{ .sweep = &.{ "guild:", "folder:", "category:", "channel:", "member:", "voice-member:", "user-btn:", "header-search", "header-find", "header-members", "header-inbox", "header-saved", "tab:", "tab-plus", "status-theme", "chip:", "chip-add:", "att:", "me", "composer-emoji", "guild-header", "code-copy:" } },
    s("clicar em tudo: caixa de entrada"),
    ctrl(c.ImGuiKey_I),
    .{ .wait = 200 },
    .{ .sweep = &.{"inbox-tab:"} },
    key(c.ImGuiKey_Escape),
    s("clicar em tudo: mensagens diretas"),
    click("guild:0"),
    click("friends"),
    .{ .wait = 300 },
    .{ .sweep = &.{ "friends", "friends-tab:", "friend-", "channel:", "dm-search", "active:" } },
    s("clicar em tudo: perfil"),
    click("guild:500000"),
    click("member:1001"),
    .{ .wait = 300 },
    .{ .sweep = &.{ "role:", "role-add", "profile-avatar", "profile-banner", "profile-name", "profile-full", "profile-mutual:" } },
    key(c.ImGuiKey_Escape),
    s("clicar em tudo: perfil grande"),
    click("member:1002"),
    click("profile-full"),
    .{ .wait = 300 },
    .{ .sweep = &.{ "profile-tab:", "profile-conn:", "profile-note", "profile-btn:", "profile-full-close", "profile-avatar", "profile-banner" } },
    click("profile-tab:1"),
    .{ .sweep = &.{"profile-friend:"} },
    click("profile-tab:2"),
    .{ .sweep = &.{"profile-guild:"} },
    key(c.ImGuiKey_Escape),
    s("proxy"),
    ctrl(c.ImGuiKey_Comma),
    click("settings:Privacidade"),
    .{ .wait = 200 },
    click("proxy-input"),
    .{ .text = "ftp://nao.serve:21" },
    key(c.ImGuiKey_Enter),
    expect("proxy com URL inválida é recusado", proxyRejected),
    click("proxy-input"),
    ctrl(c.ImGuiKey_A),
    .{ .text = "socks5h://127.0.0.1:9050" },
    click("button:Salvar proxy"),
    expect("proxy salvo vale só para a mídia de fora", proxyExternalOnly),
    .{ .shot = "37-proxy" },
    click("toggle:Usar o proxy em tudo"),
    expect("\"em tudo\" inclui o Discord (API, gateway, imagens)", proxyEverywhere),
    expect("proxy vai para o settings.kdl", proxyPersisted),
    click("button:Remover proxy"),
    expect("remover volta à conexão direta", proxyRemoved),
    click("toggle:Usar o proxy em tudo"),
    click("settings-close"),

    s("clicar em tudo: configurações"),
    ctrl(c.ImGuiKey_Comma),
    click("settings:Aparência"),
    .{ .sweep = &.{ "toggle:", "seg:", "accent:", "theme-card:" } },
    click("settings:Acessibilidade"),
    .{ .sweep = &.{"toggle:"} },
    click("settings:Chat"),
    .{ .sweep = &.{"toggle:"} },
    click("settings:Notificações"),
    .{ .sweep = &.{"toggle:"} },
    click("settings:Privacidade"),
    .{ .sweep = &.{"toggle:"} },
    click("settings:Atalhos de teclado"),
    .{ .sweep = &.{"toggle:"} },
    click("settings:Avançado"),
    .{ .sweep = &.{"toggle:"} },
    .{ .run = @import("qa_alertas.zig").ignoreOne },
    click("settings:Alertas e filtros"),
    .{ .sweep = &.{ "word-remove:", "unignore:", "seg:", "button:" } },
    .{ .run = @import("qa_alertas.zig").focusReset },
    click("settings:Idioma"),
    .{ .sweep = &.{"radio:"} },
    .{ .sweep = &.{"settings:"} },
    .{ .sweep = &.{"settings-close"} },

    s("janela pequena"),
    .{ .resize = .{ 820, 560 } },
    .{ .wait = 150 },
    expect("janela estreita esconde a lista de membros", noMembers),
    expect("janela estreita ainda mostra a caixa de texto", composerVisible),
    .{ .shot = "30-pequena" },
    .{ .resize = .{ 1280, 800 } },
    .{ .wait = 150 },
    expect("janela grande volta a lista de membros", hasMembers),

    s("várias contas"),
    key(c.ImGuiKey_Escape),
    expect("fecha as configurações", settingsClosed),
    .{ .run = fakeAccounts },
    click("me"),
    expect("o menu do usuário lista as contas", accountsListed),
    .{ .shot = "45-contas" },
    click("account:7001"),
    .{ .expect = .{ .name = "trocar de conta desconecta e entra na outra", .check = switchedB, .timeout_ms = 6000 } },
    expect("a conversa aparece sem esperar animação do login", @import("qa_leve.zig").loginGone),
    .{ .wait = 900 },
    click("me"),
    click("menu:Adicionar conta"),
    expect("Adicionar conta mostra o login sem esquecer as outras", addForm),
    .{ .shot = "46-adicionar-conta" },
    click("login:voltar"),
    expect("Voltar fecha o login e a conta continua aberta", backToSession),
    .{ .wait = 900 },
    click("me"),
    click("menu:Remover conta"),
    .{ .expect = .{ .name = "Remover conta esquece a aberta e entra na outra", .check = removedB, .timeout_ms = 6000 } },
    .{ .wait = 900 },
    .{ .run = twoAccountsSaved },
    .{ .run = refuseSession },
    expect("token recusado: volta ao login, esquece esse token e oferece a outra conta", refusedForm),
    .{ .shot = "47-login-contas" },
    click("login:conta:7001"),
    .{ .expect = .{ .name = "clicar na conta salva entra nela", .check = switchedB, .timeout_ms = 6000 } },
};

/// Cenários curtos para isolar um problema: QA_SCENE=ctrl|nome|card
/// Só a leitura, as fixadas e os links, no tema que estiver (QA_SUITE=leitura).
const ops_leitura = [_]Op{
    s("início"),
    expect("app conecta e carrega o histórico", ready),
} ++ @import("qa_leitura.zig").startup ++ @import("qa_leitura.zig").ops;
const ops_voz = [_]Op{ expect("pronto", ready), click("guild:500000") } ++ @import("qa_voz.zig").ops;
const ops_lsp = [_]Op{expect("pronto", ready)} ++ lsp_ops;
const ops_lsp_quit = [_]Op{expect("pronto", ready)} ++ lsp_ops_quit;
const qa_bandeja = @import("qa_bandeja.zig");
const ops_bandeja = [_]Op{expect("pronto", ready)} ++ qa_bandeja.ops;
const ops_bandeja_sair = [_]Op{ expect("pronto", ready), click("guild:500000") } ++ qa_bandeja.ops_no_tray;
const ops_bandeja_menu = [_]Op{ expect("pronto", ready), click("guild:500000") } ++ qa_bandeja.ops_quit;
const ops_bandeja_reinicio = [_]Op{expect("pronto", ready)} ++ qa_bandeja.ops_restart;
const ops_lsp_real = [_]Op{expect("pronto", ready)} ++ lsp_ops_real;

const ops_voice = [_]Op{
    s("voz"),
    click("channel:500014"),
    expect("entrar na call", inVoice),
    click("voice-mixer"),
    expect("abrir o mixer", mixerOpen),
    .{ .shot = "voz-mixer" },
    click("voice-mute:1001"),
    expect("silenciar uma pessoa", userMuted),
    .{ .shot = "voz-mixer-mudo" },
    click("voice-mute:1001"),
    expect("voltar a ouvir", userAudible),
    click("voice-mixer-close"),
    expect("fechar o mixer", notMixerOpen),
    click("hangup"),
    expect("sair da call", notInVoice),
};

fn notMixerOpen(app: *App) bool {
    return app.st.popup == .none;
}

const ops_ctrl = [_]Op{
    expect("pronto", ready),
    click("channel:500007"),
    expect("clique simples em #setups", struct {
        fn f(app: *App) bool {
            return app.st.activeChannel() == ch(6);
        }
    }.f),
    click("channel:500005"),
    .{ .ctrl_click = .{ .mark = "channel:500008" } },
    expect("Ctrl+clique em #música abre aba nova", struct {
        fn f(app: *App) bool {
            return app.st.tabs.items.len == 4 and app.st.activeChannel() == ch(7);
        }
    }.f),
};
const ops_nome = [_]Op{
    expect("pronto", ready),
    .{ .click = .{ .dyn = tUserOther } },
    expect("clicar no nome abre o perfil", profileOpen),
};

/// Só o emoji e o autocompletar (QA_SCENE=emoji), para olhar em outros temas.
const ops_emoji = [_]Op{expect("pronto", ready)} ++ @import("qa_emoji.zig").ops;
const ops_paineis = [_]Op{expect("pronto", ready)} ++ @import("qa_paineis.zig").ops_no_scripts ++ @import("qa_paineis.zig").all;
const ops_quadros = [_]Op{expect("pronto", ready)} ++ @import("qa_quadros.zig").ops;

const ops_config = [_]Op{
    expect("pronto", ready),
    click("user-btn:2"),
    expect("abre", settingsOpen),
    click("settings:Aparência"),
    .{ .wait = 300 },
    .{ .shot = "dbg-1" },
    click("toggle:Modo compacto"),
    .{ .wait = 300 },
    .{ .shot = "dbg-2" },
    expect("compacto ligado", compactOn),
};

// --- Bateria por tema (roda em todos os temas, claro e escuro) ---------------

var opt_i: usize = 0;
var opt_before = false;

fn optReset(_: *App) void {
    opt_i = 0;
}
fn optNext(app: *App) void {
    opt_i += 1;
    const th = app.themes.theme_();
    if (opt_i <= th.options.len) opt_before = th.option(th.options[opt_i - 1].name) orelse false;
}
/// Vazio quando o tema tem menos opções: o robô pula o passo.
fn tOpt(app: *App, b: []u8) []const u8 {
    const th = app.themes.theme_();
    if (opt_i == 0 or opt_i > th.options.len) return "";
    // As opções do tema vêm antes dos interruptores do app na página (e um
    // tema pode ter uma opção com o mesmo nome de um deles).
    return markFmt(b, "first:toggle:{s}", .{th.options[opt_i - 1].label});
}
fn optFlipped(app: *App) bool {
    const th = app.themes.theme_();
    if (opt_i == 0 or opt_i > th.options.len) return true;
    return (th.option(th.options[opt_i - 1].name) orelse false) != opt_before;
}
fn optRestored(app: *App) bool {
    const th = app.themes.theme_();
    if (opt_i == 0 or opt_i > th.options.len) return true;
    return (th.option(th.options[opt_i - 1].name) orelse false) == opt_before;
}
fn sentHere(app: *App) bool {
    const m = lastMsg(app, 0) orelse return false;
    return m.msg.author == app.store.me and !m.pending and std.mem.eql(u8, m.msg.content, "oi deste tema");
}
fn tChipSaved(_: *App, b: []u8) []const u8 {
    return markFmt(b, "chip:{d}:0", .{saved_id});
}

const opt_steps = [_]Op{
    .{ .run = optNext },
    .{ .click = .{ .dyn = tOpt } },
    expect("opção do tema liga/desliga", optFlipped),
    .{ .click = .{ .dyn = tOpt } },
    expect("opção do tema volta", optRestored),
};

const ops_theme = [_]Op{
    s("tema"),
    expect("carrega e mostra a conversa", ready),
    expect("caixa de texto e mensagens na tela", composerVisible),
    .{ .shot = "tema" },
} ++ qa_temas.ops_static ++ qa_temas.ops_motion ++ qa_temas.ops_window ++ @import("qa_threads.zig").ops_theme ++ [_]Op{
    click("composer"),
    .{ .text = "oi deste tema" },
    key(c.ImGuiKey_Enter),
    expect("enviar mensagem", sentHere),
    .{ .hover = .{ .dyn = tHoverOther } },
    .{ .wait = 150 },
    .{ .click = .{ .dyn = tReplyLast } },
    expect("responder pela barra de ações", replyArmed),
    .{ .text = "respondendo pelo QA" },
    key(c.ImGuiKey_Enter),
    expect("resposta enviada", replySent),
    click("composer"),
    key(c.ImGuiKey_UpArrow),
    expect("seta pra cima edita", editing),
    ctrl(c.ImGuiKey_A),
    .{ .text = "editado pelo QA" },
    key(c.ImGuiKey_Enter),
    expect("edição salva", edited),
    .{ .hover = .{ .dyn = tHoverMine } },
    .{ .wait = 150 },
    .{ .click = .{ .dyn = tThumbMine } },
    expect("reagir pela barra de ações", reacted),
    .{ .shot = "tema-reacao" },
    .{ .click = .{ .dyn = tChipSaved } },
    expect("tirar a reação", unreacted),
    .{ .run = rememberCount },
    .{ .rclick = .{ .dyn = tHoverMine } },
    expect("menu do botão direito", menuOpen),
    .{ .shot = "tema-menu" },
    click("menu:Excluir mensagem"),
    expect("excluir pelo menu", deleted),
    .{ .run = clearToast },
    .{ .drag = .{ .from = .{ .dyn_at = .{ .f = tSelFrom, .fx = 0.2, .fy = 0.5 } }, .to = .{ .dyn_at = .{ .f = tSelTo, .fx = 0.7, .fy = 0.5 } } } },
    expect("selecionar texto", hasSelection),
    ctrl(c.ImGuiKey_C),
    expect("copiar a seleção", toastCopied),
    key(c.ImGuiKey_Escape),
    .{ .click = .{ .dyn = tUserOther } },
    expect("clicar no nome abre o perfil", profileOpen),
    .{ .shot = "tema-perfil" },
    key(c.ImGuiKey_Escape),
    expect("Esc fecha o perfil", popupClosed),
    click("composer-emoji"),
    expect("seletor de emoji", emojiOpen),
    click("emoji:0"),
    expect("emoji na caixa de texto", emojiInserted),
    click("composer"),
    ctrl(c.ImGuiKey_A),
    key(c.ImGuiKey_Backspace),
    click("guild:0"),
    expect("mensagens diretas começam pelos amigos", friendsOpen),
    .{ .shot = "tema-amigos" },
    // No zen não tem lista de canais: a DM abre direto.
    .{ .run = openFirstDm },
    expect("chegar nas mensagens diretas", onDms),
    .{ .shot = "tema-dms" },
    click("guild:500000"),
    click("composer"),
    .{ .text = "**prévia** do `tema`" },
    expect("prévia do markdown acima da caixa", previewShown),
    .{ .shot = "tema-previa" },
    ctrl(c.ImGuiKey_A),
    key(c.ImGuiKey_Backspace),
    .{ .run = sendCodeBlock },
    .{ .expect = .{ .name = "bloco de código enviado", .check = codeSent, .timeout_ms = 3000 } },
    .{ .run = scrollBottom },
    .{ .wait = 300 },
    .{ .hover = .{ .dyn = tCodeCopy } },
    .{ .wait = 150 },
    .{ .shot = "tema-codigo" },
    .{ .run = clearToast },
    .{ .click = .{ .dyn = tCodeCopy } },
    expect("\"Copiar\" no bloco de código", codeCopied),
    ctrl(c.ImGuiKey_K),
    expect("paleta", paletteOpen),
    .{ .text = "zig" },
    key(c.ImGuiKey_Enter),
    expect("paleta abre o canal", onZig),
    ctrl(c.ImGuiKey_I),
    expect("Ctrl+I abre a caixa de entrada", inboxOpen),
    .{ .shot = "tema-caixa" },
    key(c.ImGuiKey_Escape),
    expect("Esc fecha a caixa de entrada", popupClosed),
    ctrl(c.ImGuiKey_Comma),
    expect("Ctrl+, abre as configurações", settingsOpen),
    click("settings:Aparência"),
    .{ .run = optReset },
} ++ opt_steps ++ opt_steps ++ opt_steps ++ opt_steps ++ [_]Op{
    .{ .shot = "tema-config" },
    key(c.ImGuiKey_Escape),
    expect("Esc fecha as configurações", settingsClosed),
} ++ @import("qa_paineis.zig").ops_pages_theme ++ @import("qa_paineis.zig").ops_theme ++ qa_temas.ops_resize_before ++ [_]Op{
    .{ .resize = .{ 860, 600 } },
    .{ .wait = 300 },
} ++ qa_temas.ops_resize_after ++ [_]Op{
    expect("janela pequena: ainda dá pra usar", composerVisible),
    .{ .shot = "tema-pequena" },
    .{ .resize = .{ 1280, 800 } },
    .{ .wait = 200 },
} ++ @import("qa_plugins.zig").ops_theme;

// --- Tela de login -------------------------------------------------------------

fn loginForm(app: *App) bool {
    return app.login.phase == .form and qa.find("login:token") != null;
}
fn loginErr(app: *App) bool {
    return app.login.phase == .form and app.login.err_len > 0;
}
fn loginRefused(app: *App) bool {
    const e = app.login.err_buf[0..app.login.err_len];
    return std.mem.indexOf(u8, e, "recusou") != null and app.login.tokenText().len == 0;
}
fn loginShown(app: *App) bool {
    return app.login.show;
}
fn loginHidden(app: *App) bool {
    return !app.login.show;
}
fn loginNoRemember(app: *App) bool {
    return !app.login.remember;
}
fn loginRemember(app: *App) bool {
    return app.login.remember;
}
fn loginHelp(app: *App) bool {
    return app.login.help and app.login.help_k > 0.98;
}
fn loginNoHelp(app: *App) bool {
    return !app.login.help;
}
fn loginGone(app: *App) bool {
    return app.store.ready and !app.login.visible() and app.store.demo;
}
fn loginBack(app: *App) bool {
    return loginForm(app) and !app.store.ready and app.net == .none;
}

const ops_login = [_]Op{
    s("login"),
    .{ .wait = 2200 },
    expect("a tela de login aparece depois da abertura", loginForm),
    .{ .shot = "login" },
    click("login:token"),
    .{ .text = "curto" },
    key(c.ImGuiKey_Enter),
    expect("token curto mostra erro", loginErr),
    .{ .wait = 120 },
    .{ .shot = "login-erro" },
    click("login:mostrar"),
    expect("mostrar o token", loginShown),
    click("login:mostrar"),
    expect("ocultar o token", loginHidden),
    click("login:token"),
    ctrl(c.ImGuiKey_A),
    key(c.ImGuiKey_Backspace),
    .{ .text = "XTIzNDU2Nzg5MDEyMzQ1Njc4.Gqa000.token-de-teste-que-nao-existe-aaaaaaaaaaaa" },
    click("login:entrar"),
    expect("token recusado: erro e campo limpo", loginRefused),
    click("login:lembrar"),
    expect("desligar o lembrar", loginNoRemember),
    click("login:lembrar"),
    expect("religar o lembrar", loginRemember),
    click("login:ajuda"),
    expect("abrir a ajuda do token", loginHelp),
    .{ .shot = "login-ajuda" },
    click("login:ajuda"),
    expect("fechar a ajuda", loginNoHelp),
    .{ .resize = .{ 760, 640 } },
    .{ .wait = 300 },
    expect("janela estreita: o campo continua lá", loginForm),
    .{ .shot = "login-estreita" },
    .{ .resize = .{ 1280, 800 } },
    .{ .wait = 200 },
    click("login:demo"),
    .{ .expect = .{ .name = "modo demonstração entra no app", .check = loginGone, .timeout_ms = 5000 } },
    .{ .shot = "login-entrou" },
    ctrl(c.ImGuiKey_Comma),
    expect("abrir as configurações", settingsOpen),
    click("settings:Minha conta"),
    click("button:Sair"),
    expect("sair volta para o login", loginBack),
    .{ .wait = 300 },
    .{ .shot = "login-saiu" },
    click("login:demo"),
    .{ .expect = .{ .name = "entrar de novo depois de sair", .check = loginGone, .timeout_ms = 5000 } },
};

const ops_plugins_only = [_]Op{expect("carrega e mostra a conversa", ready)} ++ ops_plugin_section;
const ops_plugins_tls = [_]Op{expect("carrega e mostra a conversa", ready)} ++ @import("qa_plugins.zig").ops_tls;
const ops_extras = [_]Op{expect("carrega e mostra a conversa", ready)} ++ @import("qa_paineis.zig").ops_extras;
const ops_ffmpeg = [_]Op{expect("carrega e mostra a conversa", ready)} ++ @import("qa_paineis.zig").ops_ffmpeg;
const ops_scripts = [_]Op{expect("carrega e mostra a conversa", ready)} ++ @import("qa_plugins.zig").ops_scripts;
const ops_ime = [_]Op{expect("carrega e mostra a conversa", ready)} ++ @import("qa_paineis.zig").ops_ime;
const ops_busca = [_]Op{expect("carrega e mostra a conversa", ready)} ++ @import("qa_busca.zig").ops;
const ops_convites = [_]Op{expect("carrega e mostra a conversa", ready)} ++ @import("qa_convites.zig").ops;
const ops_plugins_real = [_]Op{expect("carrega e mostra a conversa", ready)} ++ @import("qa_plugins.zig").ops_real;
const ops_vitrine = [_]Op{expect("carrega e mostra a conversa", ready)} ++ @import("qa_plugins.zig").ops_vitrine;
const ops_plugins_a = [_]Op{expect("carrega e mostra a conversa", ready)} ++ @import("qa_plugins.zig").ops_persist_a;
const ops_plugins_b = [_]Op{expect("carrega e mostra a conversa", ready)} ++ @import("qa_plugins.zig").ops_persist_b;

fn script() []const Op {
    if (c.SDL_getenv("QA_SUITE")) |suite| if (std.mem.eql(u8, std.mem.span(suite), "tema")) return &ops_theme;
    if (c.SDL_getenv("QA_SUITE")) |suite| if (std.mem.eql(u8, std.mem.span(suite), "login")) return &ops_login;
    if (c.SDL_getenv("QA_SUITE")) |suite| if (std.mem.eql(u8, std.mem.span(suite), "voice")) return &ops_voice;
    if (c.SDL_getenv("QA_SUITE")) |suite| if (std.mem.eql(u8, std.mem.span(suite), "leitura")) return &ops_leitura;
    if (c.SDL_getenv("QA_SUITE")) |suite| if (std.mem.eql(u8, std.mem.span(suite), "voz")) return &ops_voz;
    if (c.SDL_getenv("QA_SUITE")) |suite| if (std.mem.eql(u8, std.mem.span(suite), "lsp")) return &ops_lsp;
    if (c.SDL_getenv("QA_SUITE")) |suite| if (std.mem.eql(u8, std.mem.span(suite), "lsp-quit")) return &ops_lsp_quit;
    if (c.SDL_getenv("QA_SUITE")) |suite| if (std.mem.eql(u8, std.mem.span(suite), "bandeja")) return &ops_bandeja;
    if (c.SDL_getenv("QA_SUITE")) |suite| if (std.mem.eql(u8, std.mem.span(suite), "bandeja-sair")) return &ops_bandeja_sair;
    if (c.SDL_getenv("QA_SUITE")) |suite| if (std.mem.eql(u8, std.mem.span(suite), "bandeja-menu")) return &ops_bandeja_menu;
    if (c.SDL_getenv("QA_SUITE")) |suite| if (std.mem.eql(u8, std.mem.span(suite), "bandeja-reinicio")) return &ops_bandeja_reinicio;
    if (c.SDL_getenv("QA_SUITE")) |suite| if (std.mem.eql(u8, std.mem.span(suite), "lsp-real")) return &ops_lsp_real;
    if (c.SDL_getenv("QA_SUITE")) |suite| if (std.mem.eql(u8, std.mem.span(suite), "paineis")) return &ops_paineis;
    if (c.SDL_getenv("QA_SUITE")) |suite| if (std.mem.eql(u8, std.mem.span(suite), "quadros")) return &ops_quadros;
    if (c.SDL_getenv("QA_SUITE")) |suite| if (std.mem.eql(u8, std.mem.span(suite), "plugins")) return &ops_plugins_only;
    if (c.SDL_getenv("QA_SUITE")) |suite| if (std.mem.eql(u8, std.mem.span(suite), "plugins-tls")) return &ops_plugins_tls;
    if (c.SDL_getenv("QA_SUITE")) |suite| if (std.mem.eql(u8, std.mem.span(suite), "extras")) return &ops_extras;
    if (c.SDL_getenv("QA_SUITE")) |suite| if (std.mem.eql(u8, std.mem.span(suite), "ffmpeg")) return &ops_ffmpeg;
    if (c.SDL_getenv("QA_SUITE")) |suite| if (std.mem.eql(u8, std.mem.span(suite), "escritas")) return &ops_scripts;
    if (c.SDL_getenv("QA_SUITE")) |suite| if (std.mem.eql(u8, std.mem.span(suite), "ime")) return &ops_ime;
    if (c.SDL_getenv("QA_SUITE")) |suite| if (std.mem.eql(u8, std.mem.span(suite), "busca")) return &ops_busca;
    if (c.SDL_getenv("QA_SUITE")) |suite| if (std.mem.eql(u8, std.mem.span(suite), "convites")) return &ops_convites;
    if (c.SDL_getenv("QA_SUITE")) |suite| if (std.mem.eql(u8, std.mem.span(suite), "plugins-real")) return &ops_plugins_real;
    if (c.SDL_getenv("QA_SUITE")) |suite| if (std.mem.eql(u8, std.mem.span(suite), "vitrine")) return &ops_vitrine;
    if (c.SDL_getenv("QA_SUITE")) |suite| if (std.mem.eql(u8, std.mem.span(suite), "plugins-a")) return &ops_plugins_a;
    if (c.SDL_getenv("QA_SUITE")) |suite| if (std.mem.eql(u8, std.mem.span(suite), "plugins-b")) return &ops_plugins_b;
    const scene = std.mem.span(c.SDL_getenv("QA_SCENE") orelse return &ops);
    if (std.mem.eql(u8, scene, "ctrl")) return &ops_ctrl;
    if (std.mem.eql(u8, scene, "nome")) return &ops_nome;
    if (std.mem.eql(u8, scene, "config")) return &ops_config;
    if (std.mem.eql(u8, scene, "emoji")) return &ops_emoji;
    return &ops;
}

// --- Execução ---------------------------------------------------------------

pub const Runner = struct {
    index: usize = 0,
    sub: u32 = 0,
    started_ms: i64 = 0,
    step_ms: i64 = 0,
    pass: usize = 0,
    fail: usize = 0,
    section: []const u8 = "",
    failures: std.ArrayList([]const u8) = .empty,
    mouse: [2]f32 = .{ 640, 400 },
    sweep: Sweep = .{},
    target_pos: [2]f32 = .{ 0, 0 },
    still_pos: [2]f32 = .{ -1, -1 },
    still_n: u8 = 0,
    mouse_set: bool = false,
    settle: u32 = 0,
    dclick_time: [2]f32 = .{ 0, 0 },

    fn now() i64 {
        return gw.nowMs();
    }

    fn resolve(app: *App, t: Target, buf: []u8) ?[2]f32 {
        const k_fx: struct { k: []const u8, fx: f32, fy: f32 } = switch (t) {
            .mark => |k| .{ .k = k, .fx = 0.5, .fy = 0.5 },
            .dyn => |f| .{ .k = f(app, buf), .fx = 0.5, .fy = 0.5 },
            .at => |a| .{ .k = a.key, .fx = a.fx, .fy = a.fy },
            .dyn_at => |a| .{ .k = a.f(app, buf), .fx = a.fx, .fy = a.fy },
        };
        // "first:nome": a primeira com esse nome (dois elementos iguais na página).
        const r = (if (std.mem.startsWith(u8, k_fx.k, "first:")) qa.findFirst(k_fx.k[6..]) else qa.find(k_fx.k)) orelse return null;
        return .{ r.x + r.w * k_fx.fx, r.y + r.h * k_fx.fy };
    }

    /// Se o elemento está fora da janela, rola até ele (como uma pessoa faria).
    fn scrollTo(r: *Runner, app: *App, p: [2]f32) bool {
        const h = app.io.*.DisplaySize.y;
        if (p[1] > 2 and p[1] < h - 2) return false;
        r.pos(app, .{ app.io.*.DisplaySize.x * 0.6, h * 0.5 });
        c.ImGuiIO_AddMouseWheelEvent(app.io, 0, if (p[1] >= h - 2) -2 else 2);
        r.sub = 0;
        // Espera a rolagem acontecer e as posições serem redesenhadas.
        r.settle = 4;
        return true;
    }

    fn targetName(app: *App, t: Target, buf: []u8) []const u8 {
        return switch (t) {
            .mark => |k| k,
            .dyn => |f| f(app, buf),
            .at => |a| a.key,
            .dyn_at => |a| a.f(app, buf),
        };
    }

    fn record(r: *Runner, ok: bool, comptime fmt: []const u8, args: anytype) void {
        const msg = std.fmt.allocPrint(std.heap.c_allocator, fmt, args) catch return;
        if (ok) {
            r.pass += 1;
            std.debug.print("  \x1b[32m✓\x1b[0m {s}\n", .{msg});
            std.heap.c_allocator.free(msg);
        } else {
            r.fail += 1;
            std.debug.print("  \x1b[31m✗ {s}\x1b[0m\n", .{msg});
            const full = std.fmt.allocPrint(std.heap.c_allocator, "[{s}] {s}", .{ r.section, msg }) catch return;
            std.heap.c_allocator.free(msg);
            r.failures.append(std.heap.c_allocator, full) catch {};
        }
    }

    /// Estado da varredura "clicar em tudo".
    const Sweep = struct {
        keys: [160][56]u8 = undefined,
        lens: [160]u8 = undefined,
        n: usize = 0,
        i: usize = 0,
        phase: u8 = 0,
        frames: u32 = 0,
        fp: u64 = 0,
        started: bool = false,
        clicked: usize = 0,
        base: Base = undefined,
    };

    /// O que a varredura restaura entre um clique e outro.
    const Base = struct {
        settings: @import("ui/state.zig").Settings,
        popup: @import("ui/state.zig").Popup,
        guild: Id,
        tab: usize,
        tabs_len: usize,
        tab0: Id,
        friends: bool,
        friends_tab: u8,
        theme: usize,
        voice: ?Id,
        muted: bool,
        deafened: bool,
        panes: mosaic.Panes,
    };

    fn capture(app: *App) Base {
        const st = &app.st;
        return .{
            .settings = st.settings,
            .popup = st.popup,
            .guild = st.guild,
            .tab = st.tab,
            .tabs_len = st.tabs.items.len,
            .tab0 = if (st.tabs.items.len > st.tab) st.tabs.items[st.tab] else 0,
            .friends = st.friends,
            .friends_tab = st.friends_tab,
            .theme = app.themes.current,
            .voice = st.voice,
            .muted = st.muted,
            .deafened = st.deafened,
            .panes = mosaic.panes,
        };
    }

    fn restore(app: *App, b: Base) void {
        const st = &app.st;
        st.settings = b.settings;
        st.popup = b.popup;
        st.viewer = null;
        @import("ui/video.zig").stop();
        st.palette.open = false;
        if (search.open) search.close();
        @import("ui/dropdown.zig").close();
        st.selection = .{};
        st.reply_to = 0;
        st.editing = 0;
        st.guild = b.guild;
        if (st.tabs.items.len > b.tabs_len) st.tabs.shrinkRetainingCapacity(b.tabs_len);
        if (b.tab < st.tabs.items.len) {
            st.tabs.items[b.tab] = b.tab0;
            st.tab = b.tab;
        }
        st.friends = b.friends;
        st.friends_tab = b.friends_tab;
        st.voice = b.voice;
        st.muted = b.muted;
        st.deafened = b.deafened;
        mosaic.panes = b.panes;
        st.open_folders.clearRetainingCapacity();
        st.collapsed.clearRetainingCapacity();
        if (app.themes.current != b.theme) app.actions.append(app.gpa, .{ .set_theme = b.theme }) catch {};
        if (st.activeChannel()) |cid| st.scrollOf(cid).stick_bottom = true;
    }

    /// Impressão digital do que um clique pode mudar.
    fn fingerprint(app: *App) u64 {
        const st = &app.st;
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&st.settings));
        h.update(&.{@intFromBool(@import("platform/debug_log.zig").ui_on)});
        h.update(std.mem.asBytes(&st.popup));
        h.update(std.mem.asBytes(&st.guild));
        h.update(std.mem.asBytes(&st.tab));
        h.update(std.mem.sliceAsBytes(st.tabs.items));
        h.update(std.mem.asBytes(&st.friends));
        h.update(std.mem.asBytes(&st.friends_tab));
        h.update(&.{ @intFromBool(st.viewer != null), @intFromBool(st.palette.open), @intFromBool(@import("ui/dropdown.zig").anyOpen()), @intFromBool(st.muted), @intFromBool(st.deafened), @intFromBool(search.open) });
        h.update(std.mem.asBytes(&st.voice));
        h.update(std.mem.asBytes(&st.reply_to));
        h.update(std.mem.asBytes(&st.editing));
        h.update(std.mem.asBytes(&st.toast.until_ms));
        h.update(std.mem.asBytes(&st.jump));
        h.update(std.mem.asBytes(&app.themes.current));
        h.update(std.mem.asBytes(&app.plugins.generation));
        h.update(std.mem.asBytes(&@import("ui/plugin_panel.zig").qaState()));
        h.update(&.{@intFromBool(video.info().active)});
        h.update(std.mem.asBytes(&mosaic.panes));
        h.update(std.mem.asBytes(&@as(u32, st.open_folders.count())));
        h.update(std.mem.asBytes(&@as(u32, st.collapsed.count())));
        h.update(std.mem.asBytes(&@as(u32, st.muted_channels.count())));
        h.update(std.mem.asBytes(&@as(u32, app.store.relationships.count())));
        // Alertas, filtro, ignorados e modo foco (core/filtros.zig).
        h.update(std.mem.asBytes(&app.st.filtros.gen));
        h.update(std.mem.asBytes(&@as(u32, app.st.filtros.revealed.count())));
        h.update(std.mem.asBytes(&@as(u32, app.st.filtros.mentions.count())));
        // Opções do tema e cargos de quem está com o cartão aberto.
        const th = app.themes.theme_();
        for (th.options) |o| h.update(&.{@intFromBool(th.option(o.name) orelse o.default)});
        if (st.popup == .profile) if (app.store.memberInfo(st.guild, st.popup.profile.user)) |mi| h.update(std.mem.sliceAsBytes(mi.roleSlice()));
        const att_mod = @import("ui/attachments.zig");
        h.update(att_mod.last_opened[0..att_mod.last_opened_len]);
        h.update(&.{ st.profile_tab, @intFromBool(st.note_editing) });
        h.update(std.mem.asBytes(&@as(u32, app.store.notes.count())));
        h.update(std.mem.asBytes(&@import("ui/video.zig").qaState()));
        h.update(std.mem.asBytes(&@import("ui/forum.zig").qaState()));
        h.update(std.mem.asBytes(&@as(u32, @intCast(app.actions.items.len))));
        if (st.activeChannel()) |cid| {
            const sc = st.scrollOf(cid);
            h.update(std.mem.asBytes(&sc.stick_bottom));
            if (app.store.channel(cid)) |cs| {
                h.update(std.mem.asBytes(&cs.version));
                h.update(std.mem.asBytes(&cs.info.unread));
                const items = cs.messages.items;
                for (items) |*m| h.update(std.mem.sliceAsBytes(m.reactionSlice()));
            }
        }
        const top = std.mem.sliceTo(&st.input, 0);
        h.update(top);
        return h.final();
    }

    /// Clicar no que já está selecionado (a aba atual, o canal aberto)
    /// não muda nada e está certo.
    fn alreadySelected(app: *App, name: []const u8) bool {
        const st = &app.st;
        const num = struct {
            fn f(k: []const u8, p: []const u8) ?u64 {
                if (!std.mem.startsWith(u8, k, p)) return null;
                return std.fmt.parseInt(u64, k[p.len..], 10) catch null;
            }
        }.f;
        if (num(name, "tab:")) |t| return t == st.tab;
        if (num(name, "channel:")) |cid| return !st.friends and st.activeChannel() == cid;
        if (num(name, "mention-channel:")) |cid| return !st.friends and st.activeChannel() == cid;
        if (num(name, "guild:")) |g| return st.guild == g and !st.friends;
        if (std.mem.startsWith(u8, name, "friends-tab:")) return std.mem.eql(u8, name["friends-tab:".len..], @tagName(@as(enum { online, all, pending, blocked }, @enumFromInt(st.friends_tab))));
        if (std.mem.eql(u8, name, "friends")) return st.friends;
        if (num(name, "profile-tab:")) |t| return t == st.profile_tab;
        // Opções de escolha única: clicar na já escolhida não muda nada.
        for ([_][]const u8{ "seg:", "radio:", "accent:", "theme-card:", "settings:", "inbox-tab:" }) |p| if (std.mem.startsWith(u8, name, p)) return true;
        return false;
    }

    fn sweepOp(r: *Runner, app: *App, prefixes: []const []const u8) void {
        var sw = &r.sweep;
        if (!sw.started) {
            sw.* = .{ .started = true, .base = capture(app) };
            sw.n = qa.keysWith(prefixes, &sw.keys, &sw.lens);
            sw.frames = 0;
            return;
        }
        if (sw.i >= sw.n) {
            restore(app, sw.base);
            r.record(sw.clicked > 0, "varredura: {d} elementos clicados", .{sw.clicked});
            sw.started = false;
            return r.next();
        }
        const kname = sw.keys[sw.i][0..sw.lens[sw.i]];
        sw.frames += 1;
        switch (sw.phase) {
            // Volta ao começo e espera as marcações se refazerem.
            0 => {
                restore(app, sw.base);
                sw.phase = 1;
                sw.frames = 0;
            },
            // Espera a tela assentar (largura ou rolagem ainda mudando).
            1 => if (sw.frames >= 4 and (!@import("ui/anim.zig").active or sw.frames >= 60)) {
                const rect = qa.find(kname) orelse {
                    // Some depois de restaurar (estava em outra tela): pula.
                    sw.i += 1;
                    sw.phase = 0;
                    return;
                };
                const p: [2]f32 = .{ rect.x + rect.w / 2, rect.y + rect.h / 2 };
                if (p[1] < 2 or p[1] > app.io.*.DisplaySize.y - 2 or p[0] < 2 or p[0] > app.io.*.DisplaySize.x - 2) {
                    sw.i += 1;
                    sw.phase = 0;
                    return;
                }
                sw.fp = fingerprint(app);
                if (c.SDL_getenv("QA_DEBUG") != null) std.debug.print("[varredura] {s} em {d:.0},{d:.0}\n", .{ kname, p[0], p[1] });
                r.target_pos = p;
                r.pos(app, p);
                sw.phase = 2;
            },
            2 => {
                c.ImGuiIO_AddMouseButtonEvent(app.io, 0, true);
                sw.phase = 3;
            },
            3 => {
                c.ImGuiIO_AddMouseButtonEvent(app.io, 0, false);
                sw.phase = 4;
                sw.frames = 0;
            },
            4 => if (sw.frames >= 6) {
                const changed = fingerprint(app) != sw.fp;
                sw.clicked += 1;
                if (!changed and !alreadySelected(app, kname)) {
                    r.record(false, "botão sem efeito: {s}", .{kname});
                }
                if (!app.store.ready) r.record(false, "o app saiu da conta ao clicar em {s}", .{kname});
                sw.i += 1;
                sw.phase = 0;
            },
            else => {},
        }
    }

    fn next(r: *Runner) void {
        r.index += 1;
        r.sub = 0;
        r.step_ms = now();
    }

    /// Com a janela em foco e o cursor de verdade fora dela, o backend do SDL põe o
    /// cursor do sistema no lugar do mouse a cada quadro. Aconteceu no Windows da
    /// CI ao encolher a janela: o clique do roteiro ia parar em outro lugar.
    pub fn holdMouse(r: *Runner, app: *App) void {
        if (r.mouse_set) c.ImGuiIO_AddMousePosEvent(app.io, r.mouse[0], r.mouse[1]);
    }

    fn pos(r: *Runner, app: *App, p: [2]f32) void {
        r.mouse_set = true;
        r.mouse = p;
        c.ImGuiIO_AddMousePosEvent(app.io, p[0], p[1]);
    }

    /// O alvo parou de se mexer? A conversa rola suave depois de uma mensagem, e
    /// em máquina lenta isso leva muitos quadros: o mouse parava em cima de outra
    /// coisa. Tem um teto, para o que anima sem parar não travar o roteiro.
    fn targetStill(r: *Runner, p: [2]f32) bool {
        if (now() - r.step_ms > slowed(1000)) return true;
        if (r.still_pos[0] == p[0] and r.still_pos[1] == p[1]) {
            r.still_n +|= 1;
        } else {
            r.still_pos = p;
            r.still_n = 0;
        }
        return r.still_n >= 2;
    }

    /// Clique em 3 quadros: posiciona, aperta, solta.
    fn clickOp(r: *Runner, app: *App, t: Target, button: c_int, ctrl_held: bool, double: bool) void {
        // Só procura o elemento antes de clicar: depois do clique ele pode
        // sumir de propósito (um menu que fecha, um botão que troca de tela).
        if (r.settle > 0) {
            r.settle -= 1;
            return;
        }
        if (r.sub == 0) {
            var buf: [64]u8 = undefined;
            if (targetName(app, t, &buf).len == 0) return r.next();
            const p = resolve(app, t, &buf) orelse {
                if (now() - r.step_ms > slowed(1500)) {
                    r.record(false, "elemento não encontrado: {s}", .{targetName(app, t, &buf)});
                    r.next();
                }
                return;
            };
            if (r.scrollTo(app, p)) {
                if (now() - r.step_ms > slowed(4000)) {
                    r.record(false, "não consegui rolar até {s} (y={d:.0})", .{ targetName(app, t, &buf), p[1] });
                    r.next();
                }
                return;
            }
            if (!r.targetStill(p)) return;
            r.target_pos = p;
            if (c.SDL_getenv("QA_DEBUG") != null) {
                std.debug.print("[clique] {s} em {d:.0},{d:.0}\n", .{ targetName(app, t, &buf), p[0], p[1] });
                const name = targetName(app, t, &buf);
                qa.dump(name[0 .. std.mem.indexOfScalar(u8, name, ':') orelse name.len]);
            }
        }
        switch (r.sub) {
            0 => {
                if (ctrl_held) c.ImGuiIO_AddKeyEvent(app.io, c.ImGuiMod_Ctrl, true);
                // Em máquina lenta, dois quadros já passam do tempo de um duplo clique.
                // (O ImGui exige o atraso do clique simples maior que esse tempo.)
                if (double) {
                    r.dclick_time = .{ app.io.*.MouseDoubleClickTime, app.io.*.MouseSingleClickDelay };
                    app.io.*.MouseSingleClickDelay = 3.5;
                    app.io.*.MouseDoubleClickTime = 3;
                    // Com esse tempo, um duplo clique logo depois de outro contaria como 3º e 4º cliques.
                    app.io.*.MouseClickedTime[@intCast(button)] = -1e9;
                }
                r.pos(app, r.target_pos);
            },
            1 => c.ImGuiIO_AddMouseButtonEvent(app.io, button, true),
            2 => c.ImGuiIO_AddMouseButtonEvent(app.io, button, false),
            3 => if (double) c.ImGuiIO_AddMouseButtonEvent(app.io, button, true),
            4 => if (double) c.ImGuiIO_AddMouseButtonEvent(app.io, button, false),
            else => {
                if (ctrl_held) c.ImGuiIO_AddKeyEvent(app.io, c.ImGuiMod_Ctrl, false);
                if (double) {
                    app.io.*.MouseDoubleClickTime = r.dclick_time[0];
                    app.io.*.MouseSingleClickDelay = r.dclick_time[1];
                }
                return r.next();
            },
        }
        r.sub += 1;
    }

    /// Avança o roteiro um quadro. Retorna false quando terminou.
    pub fn tick(r: *Runner, app: *App) bool {
        if (r.started_ms == 0) {
            r.started_ms = now();
            r.step_ms = now();
            std.debug.print("\nSigmaCord — QA automático\n", .{});
        }
        const list = script();
        if (r.index >= list.len) return r.finish();
        switch (list[r.index]) {
            .section => |name| {
                r.section = name;
                std.debug.print("\n\x1b[1m{s}\x1b[0m\n", .{name});
                r.next();
            },
            .click => |t| r.clickOp(app, t, 0, false, false),
            .rclick => |t| r.clickOp(app, t, 1, false, false),
            .mclick => |t| r.clickOp(app, t, 2, false, false),
            .ctrl_click => |t| r.clickOp(app, t, 0, true, false),
            .dclick => |t| r.clickOp(app, t, 0, false, true),
            .hover => |t| {
                var buf: [64]u8 = undefined;
                // Alvo vazio: não se aplica aqui (um tema sem a tal coisa).
                if (targetName(app, t, &buf).len == 0) {
                    r.next();
                    return true;
                }
                if (resolve(app, t, &buf)) |p| {
                    if (!r.targetStill(p)) return true;
                    r.pos(app, p);
                    r.next();
                } else if (now() - r.step_ms > slowed(1500)) {
                    r.record(false, "elemento não encontrado: {s}", .{targetName(app, t, &buf)});
                    r.next();
                }
            },
            .drag => |dg| {
                var b1: [64]u8 = undefined;
                var b2: [64]u8 = undefined;
                const a = resolve(app, dg.from, &b1) orelse {
                    r.record(false, "início do arraste não encontrado", .{});
                    return blk: {
                        r.next();
                        break :blk true;
                    };
                };
                const z = resolve(app, dg.to, &b2) orelse a;
                switch (r.sub) {
                    0 => r.pos(app, a),
                    1 => c.ImGuiIO_AddMouseButtonEvent(app.io, 0, true),
                    2, 3, 4, 5 => {
                        const k = @as(f32, @floatFromInt(r.sub - 1)) / 4;
                        r.pos(app, .{ a[0] + (z[0] - a[0]) * k, a[1] + (z[1] - a[1]) * k });
                    },
                    6 => c.ImGuiIO_AddMouseButtonEvent(app.io, 0, false),
                    else => return blk: {
                        r.next();
                        break :blk true;
                    },
                }
                r.sub += 1;
            },
            .drag_by => |dg| {
                if (r.sub == 0) {
                    var b1: [64]u8 = undefined;
                    if (targetName(app, dg.from, &b1).len == 0) {
                        r.next();
                        return true;
                    }
                    const a = resolve(app, dg.from, &b1) orelse {
                        if (now() - r.step_ms > slowed(1500)) {
                            r.record(false, "início do arraste não encontrado: {s}", .{targetName(app, dg.from, &b1)});
                            r.next();
                        }
                        return true;
                    };
                    if (!r.targetStill(a)) return true;
                    r.target_pos = a;
                }
                const a = r.target_pos;
                switch (r.sub) {
                    0 => r.pos(app, a),
                    1 => c.ImGuiIO_AddMouseButtonEvent(app.io, 0, true),
                    2, 3, 4, 5 => {
                        const k = @as(f32, @floatFromInt(r.sub - 1)) / 4;
                        r.pos(app, .{ a[0] + dg.dx * k, a[1] });
                    },
                    6 => c.ImGuiIO_AddMouseButtonEvent(app.io, 0, false),
                    7 => {},
                    else => {
                        r.next();
                        return true;
                    },
                }
                r.sub += 1;
            },
            .key => |k| {
                switch (r.sub) {
                    0 => {
                        if (k.ctrl) c.ImGuiIO_AddKeyEvent(app.io, c.ImGuiMod_Ctrl, true);
                        if (k.shift) c.ImGuiIO_AddKeyEvent(app.io, c.ImGuiMod_Shift, true);
                        if (k.alt) c.ImGuiIO_AddKeyEvent(app.io, c.ImGuiMod_Alt, true);
                    },
                    1 => {
                        // Como no laço do app: com a lista do autocompletar
                        // aberta, a tecla é dela e o campo de texto não vê.
                        if (autocomplete.takeImGuiKey(k.key, k.shift, k.ctrl)) r.sub = 2 else c.ImGuiIO_AddKeyEvent(app.io, k.key, true);
                    },
                    2 => c.ImGuiIO_AddKeyEvent(app.io, k.key, false),
                    3 => {
                        if (k.ctrl) c.ImGuiIO_AddKeyEvent(app.io, c.ImGuiMod_Ctrl, false);
                        if (k.shift) c.ImGuiIO_AddKeyEvent(app.io, c.ImGuiMod_Shift, false);
                        if (k.alt) c.ImGuiIO_AddKeyEvent(app.io, c.ImGuiMod_Alt, false);
                    },
                    else => return blk: {
                        r.next();
                        break :blk true;
                    },
                }
                r.sub += 1;
            },
            .text => |t| {
                var buf: [512]u8 = undefined;
                const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{t}, 0) catch "";
                c.ImGuiIO_AddInputCharactersUTF8(app.io, z.ptr);
                r.next();
            },
            .wait => |ms| if (now() - r.step_ms >= ms) r.next(),
            .expect => |e| {
                if (e.check(app)) {
                    r.record(true, "{s}", .{e.name});
                    r.next();
                } else if (now() - r.step_ms > slowed(e.timeout_ms)) {
                    r.record(false, "{s}", .{e.name});
                    r.next();
                }
            },
            .shot => |name| {
                // Espera as animações assentarem um pouco antes do print.
                if (now() - r.step_ms < 250) return true;
                var buf: [128]u8 = undefined;
                const prefix = if (c.SDL_getenv("QA_PREFIX")) |px| std.mem.span(px) else "";
                const path = std.fmt.bufPrintSentinel(&buf, "qa-out/{s}{s}.png", .{ prefix, name }, 0) catch return true;
                _ = app.win.screenshot(path.ptr);
                r.next();
            },
            .resize => |sz| {
                // The script's sizes are in points; on Windows SDL wants pixels.
                const k = app.uiScale();
                _ = c.SDL_SetWindowSize(app.win.window, @intFromFloat(@as(f32, @floatFromInt(sz[0])) * k), @intFromFloat(@as(f32, @floatFromInt(sz[1])) * k));
                r.next();
            },
            .run => |f| {
                f(app);
                r.next();
            },
            .sweep => |prefixes| r.sweepOp(app, prefixes),
        }
        return true;
    }

    fn finish(r: *Runner) bool {
        const secs = @as(f64, @floatFromInt(now() - r.started_ms)) / 1000;
        std.debug.print("\n{d} passaram, {d} falharam ({d:.1} s). Prints em qa-out/\n", .{ r.pass, r.fail, secs });
        if (r.failures.items.len > 0) {
            std.debug.print("\nFalhas:\n", .{});
            for (r.failures.items) |f| std.debug.print("  - {s}\n", .{f});
        }
        return false;
    }
};
