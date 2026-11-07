//! Configurações → Voz: microfone e saída, volumes, medidor, teste do
//! microfone, detecção de voz ou aperte para falar, filtros e sons.
//! Só desenha e guarda em `Settings`: quem abre o áudio é net/voz_audio.zig,
//! que também mede o microfone enquanto esta página está aberta.
const std = @import("std");
const c = @import("c");
const d = @import("draw.zig");
const qa = @import("qa.zig");
const anim = @import("anim.zig");
const icons = @import("icons.zig");
const i18n = @import("i18n.zig");
const S = @import("settings_state.zig");
const voz = @import("../core/voz.zig");
const ruido = @import("../core/ruido.zig");
const voz_audio = @import("../net/voz_audio.zig");
const channels_ui = @import("comp_channels.zig");
const dropdown = @import("dropdown.zig");

/// Ids de `d.hit` desta página (longe dos sequenciais de settings.Page).
const base_id: usize = 0x5E000;

var mic_list: voz_audio.DeviceList = .{};
var out_list: voz_audio.DeviceList = .{};
var list_gen: u32 = 0;

pub fn draw(p: anytype) void {
    const ctx = p.ctx;
    const s = &ctx.st.settings;
    // O medidor anda sozinho: redesenha 20 vezes por segundo só nesta página.
    anim.every(50);
    const gen = voz_audio.sh.list_gen.load(.acquire);
    if (gen != list_gen) {
        list_gen = gen;
        voz_audio.copyDevices(&mic_list, &out_list);
    }

    p.title(i18n.tr("Voz", "Voice"));

    // Entrada à esquerda, saída à direita, como no Discord.
    const col = (p.w - 24) / 2;
    const col2 = p.x + col + 24;
    const top = p.y;
    const mic_end = picker(p, p.x, col, top, 1, i18n.tr("Microfone", "Microphone"), "voz-mic", &mic_list, &s.voice_mic, voz_audio.sh.mic_fallback.load(.monotonic));
    const out_end = picker(p, col2, col, top, 2, i18n.tr("Saída", "Output"), "voz-out", &out_list, &s.voice_out, voz_audio.sh.out_fallback.load(.monotonic));
    p.y = @max(mic_end, out_end);
    p.note(i18n.tr("Trocar vale na hora, mesmo no meio de uma call.", "Changes apply right away, even in the middle of a call."));
    const vol_y = p.y;
    volume(p, p.x, col, vol_y, 10, i18n.tr("Volume de entrada", "Input volume"), &s.voice_in_gain);
    volume(p, col2, col, vol_y, 11, i18n.tr("Volume de saída", "Output volume"), &s.voice_out_gain);
    p.y = vol_y + 66;

    p.divider();
    p.heading(i18n.tr("Modo de entrada", "Input mode"));
    mode(p, &s.voice_ptt);
    if (s.voice_ptt) pushToTalk(p, &s.voice_key) else p.toggle(i18n.tr("Sensibilidade automática", "Automatic sensitivity"), i18n.tr("Aprende o ruído de fundo e ajusta o limiar sozinho.", "Learns the background noise and sets the threshold by itself."), &s.voice_auto);

    d.text(p.dl, p.font(.bold), 12, p.x, p.y, ctx.col(.muted), if (s.voice_ptt) i18n.tr("MICROFONE", "MICROPHONE") else i18n.tr("SENSIBILIDADE", "SENSITIVITY"));
    p.y += 22;
    meter(p, s);
    micTest(p);

    p.divider();
    p.heading(i18n.tr("Filtros", "Filters"));
    denoise(p, &s.voice_denoise);
    p.toggle(i18n.tr("Tirar ronco (passa-altas)", "Remove rumble (high-pass)"), i18n.tr("Corta os graves abaixo de 90 Hz: vento, ventilador, zumbido da tomada.", "Cuts lows below 90 Hz: wind, fans, mains hum."), &s.voice_highpass);
    p.toggle(i18n.tr("Porta de ruído", "Noise gate"), i18n.tr("Abaixa o som quando o microfone só capta o ruído de fundo.", "Lowers the sound while the mic only picks up background noise."), &s.voice_gate);

    p.divider();
    p.heading(i18n.tr("Sons", "Sounds"));
    p.toggle(i18n.tr("Sons da call", "Call sounds"), i18n.tr("Bipes curtos ao entrar, sair, mutar e desmutar.", "Short beeps when you join, leave, mute and unmute."), &s.voice_sounds);
}

// --- Dispositivos -----------------------------------------------------------

/// Caixa com o dispositivo atual; clicar abre a lista por cima da página, sem
/// empurrar nada. Devolve onde a coluna terminou.
fn picker(p: anytype, x: f32, wd: f32, y0: f32, which: u8, label: []const u8, comptime tag: []const u8, list: *const voz_audio.DeviceList, value: *S.Text, fallback: bool) f32 {
    const ctx = p.ctx;
    var y = y0;
    d.text(p.dl, p.font(.bold), 12, x, y, ctx.col(.muted), label);
    y += 20;
    const default_label = i18n.tr("Padrão do sistema", "System default");
    const saved = value.slice();
    const r: d.Rect = .{ .x = x, .y = y, .w = wd, .h = 42 };
    const key = base_id + which;
    const hb = d.hit(ctx, key, r);
    qa.mark(r, tag, .{});
    if (hb.clicked) dropdown.toggle(key);
    const opened = dropdown.isOpen(key);
    d.rect(p.dl, r, ctx.col(.rail).mix(ctx.col(.elevated), if (hb.hovered) 0.4 else 0.2), ctx.th.radius);
    d.border(p.dl, r, if (hb.hovered or opened) ctx.col(.accent).alpha(0.6) else ctx.col(.border), ctx.th.radius, 1);
    _ = d.textClipped(p.dl, p.font(.medium), 15, r.x + 12, d.centerY(r, 15), ctx.col(.text), if (saved.len > 0) saved else default_label, r.w - 44);
    icons.chevron(p.dl, r.right() - 20, r.y + 21, ctx.col(.muted).u(), if (opened) 0 else 1);
    y += 46;
    // O escolhido não está ligado agora: o nome fica guardado para quando voltar.
    if (fallback and saved.len > 0) {
        qa.mark(.{ .x = x, .y = y, .w = wd, .h = 22 }, tag ++ "-sumiu", .{});
        _ = d.textClipped(p.dl, p.font(.regular), 13, x, y, ctx.col(.idle), i18n.tr("Não encontrado: usando o padrão até ele voltar.", "Not found: using the default until it comes back."), wd);
        y += 22;
    }
    y += 6;
    const row_h: f32 = 34;
    const rows = 1 + @as(usize, list.n);
    var at: f32 = 0;
    for (0..rows) |i| if (i > 0 and std.mem.eql(u8, saved, list.slice(i - 1))) {
        at = row_h * @as(f32, @floatFromInt(i));
    };
    if (dropdown.beginAt(ctx, key, r, wd, row_h * @as(f32, @floatFromInt(rows)), at)) |dd_c| {
        var dd = dd_c;
        defer dd.end();
        for (0..rows) |i| {
            const name = if (i == 0) default_label else list.slice(i - 1);
            const sel = if (i == 0) saved.len == 0 else std.mem.eql(u8, saved, name);
            const ro = dd.row(row_h, sel);
            qa.mark(ro.rect, tag ++ "-opt:{d}", .{i});
            if (ro.hit.clicked) {
                if (i == 0) value.* = .{} else value.set(name);
                dropdown.close();
            }
            _ = d.textClipped(dd.dl, p.font(if (sel) .semibold else .regular), 14, ro.rect.x + 8, d.centerY(ro.rect, 14), if (sel) ctx.col(.text) else ctx.col(.muted), name, ro.rect.w - 16);
        }
    }
    return y;
}

/// Lista de mentira para o QA ver a rolagem e a virada para cima (o driver mudo
/// só tem um dispositivo).
var qa_mic_saved: voz_audio.DeviceList = .{};
pub fn qaManyDevices(n: u8) void {
    if (!qa.compiled) return;
    if (n == 0) {
        mic_list = qa_mic_saved;
        return;
    }
    qa_mic_saved = mic_list;
    mic_list.n = @min(n, mic_list.names.len);
    for (0..mic_list.n) |i| {
        var b: [32]u8 = undefined;
        mic_list.names[i].set(std.fmt.bufPrint(&b, "Microfone de teste {d}", .{i + 1}) catch "");
    }
}

// --- Volume -----------------------------------------------------------------

fn volume(p: anytype, x: f32, wd: f32, y: f32, id: usize, label: []const u8, value: *u8) void {
    const ctx = p.ctx;
    d.text(p.dl, p.font(.medium), 15, x, y, ctx.col(.text), label);
    var buf: [16]u8 = undefined;
    const txt = std.fmt.bufPrint(&buf, "{d}%", .{value.*}) catch "";
    d.text(p.dl, p.font(.semibold), 14, x + wd - d.width(p.font(.semibold), 14, txt), y + 1, ctx.col(.muted), txt);
    const tr: d.Rect = .{ .x = x + 6, .y = y + 34, .w = wd - 12, .h = 8 };
    const hr: d.Rect = .{ .x = tr.x - 8, .y = tr.y - 10, .w = tr.w + 16, .h = 28 };
    const hb = d.hit(ctx, base_id + id, hr);
    qa.mark(hr, "voz-vol:{d}", .{id});
    if (hb.held) value.* = @intFromFloat(std.math.round(std.math.clamp((ctx.mouse.x - tr.x) / tr.w, 0, 1) * 200));
    const k = @as(f32, @floatFromInt(@min(value.*, 200))) / 200;
    d.rect(p.dl, tr, ctx.col(.elevated).mix(ctx.col(.text), 0.08), 4);
    d.rect(p.dl, .{ .x = tr.x, .y = tr.y, .w = tr.w * k, .h = tr.h }, ctx.col(.accent), 4);
    // 100% = sem mudança.
    d.line(p.dl, tr.x + tr.w / 2, tr.y - 3, tr.x + tr.w / 2, tr.bottom() + 3, ctx.col(.faint), 1);
    const kx = tr.x + tr.w * k;
    d.rect(p.dl, .{ .x = kx - 6, .y = tr.y - 8, .w = 12, .h = 24 }, d.Rgba.white, 3);
}

// --- Modo de entrada --------------------------------------------------------

fn mode(p: anytype, ptt: *bool) void {
    const labels = [_][]const u8{ i18n.tr("Detecção de voz", "Voice activity"), i18n.tr("Aperte para falar", "Push to talk") };
    if (segments(p, &labels, "voz-modo", 20, @intFromBool(ptt.*))) |i| ptt.* = i == 1;
}

/// Supressão de ruído: uma escolha entre motores, na ordem de `ruido.Mode`.
fn denoise(p: anytype, value: *u8) void {
    const ctx = p.ctx;
    d.text(p.dl, p.font(.medium), 16, p.x, p.y, ctx.col(.text), i18n.tr("Supressão de ruído", "Noise suppression"));
    p.y += 28;
    const labels = [_][]const u8{ i18n.tr("Desligada", "Off"), "RNNoise" };
    if (segments(p, &labels, "voz-ruido", 30, @intFromEnum(ruido.Mode.fromByte(value.*)))) |i| value.* = @intCast(i);
    p.y -= 8;
    p.note(i18n.tr("Rede neural pequena que roda neste computador, sem internet. Ouça o efeito em Testar microfone.", "A small neural network that runs on this computer, no internet. Hear it with Test microphone."));
    p.note(i18n.tr("Reduz ruído constante: ventilador, chiado, ar-condicionado. Atrasa o microfone em 20 ms.", "Reduces steady noise: fans, hiss, air conditioning. Delays your mic by 20 ms."));
    p.note(i18n.tr("Teclado e pancadas podem passar, outras vozes ficam e a sua pode abafar um pouco.", "Typing and bangs may get through, other voices stay and yours may get a bit muffled."));
    p.y += 4;
}

/// Botões lado a lado, um escolhido. Devolve o que foi clicado.
fn segments(p: anytype, labels: []const []const u8, comptime tag: []const u8, id: usize, selected: usize) ?usize {
    const ctx = p.ctx;
    const gap: f32 = 8;
    const count: f32 = @floatFromInt(labels.len);
    const bw = (p.w - gap * (count - 1)) / count;
    var clicked: ?usize = null;
    for (labels, 0..) |lb, i| {
        const r: d.Rect = .{ .x = p.x + @as(f32, @floatFromInt(i)) * (bw + gap), .y = p.y, .w = bw, .h = 42 };
        const hb = d.hit(ctx, base_id + id + i, r);
        qa.mark(r, tag ++ ":{d}", .{i});
        if (hb.clicked) clicked = i;
        const sel = selected == i;
        d.rect(p.dl, r, if (sel) ctx.col(.accent).alpha(0.22) else if (hb.hovered) ctx.col(.hover) else ctx.col(.rail).alpha(0.6), ctx.th.radius + 2);
        d.border(p.dl, r, if (sel) ctx.col(.accent) else ctx.col(.border), ctx.th.radius + 2, if (sel) 2 else 1);
        const tw = d.width(p.font(.semibold), 15, lb);
        d.text(p.dl, p.font(.semibold), 15, r.x + (r.w - tw) / 2, d.centerY(r, 15), if (sel) ctx.col(.text) else ctx.col(.muted), lb);
    }
    p.y += 56;
    return clicked;
}

fn pushToTalk(p: anytype, key: *S.Text) void {
    const ctx = p.ctx;
    if (voz_audio.takeCaptured()) |b| {
        var buf: [16]u8 = undefined;
        key.set(b.format(&buf));
    }
    const capturing = voz_audio.isCapturing();
    const binding = voz.Binding.parse(key.slice());
    d.text(p.dl, p.font(.bold), 12, p.x, p.y, ctx.col(.muted), i18n.tr("ATALHO", "SHORTCUT"));
    p.y += 20;
    const r: d.Rect = .{ .x = p.x, .y = p.y, .w = p.w, .h = 42 };
    const hb = d.hit(ctx, base_id + 30, r);
    qa.mark(r, "voz-atalho", .{});
    if (hb.clicked) {
        if (capturing) voz_audio.cancelCapture() else voz_audio.startCapture();
    }
    d.rect(p.dl, r, ctx.col(.rail).mix(ctx.col(.elevated), if (hb.hovered) 0.4 else 0.2), ctx.th.radius);
    d.border(p.dl, r, if (capturing) ctx.col(.accent) else if (hb.hovered) ctx.col(.accent).alpha(0.6) else ctx.col(.border), ctx.th.radius, if (capturing) 2 else 1);
    var nb: [48]u8 = undefined;
    const shown = if (capturing)
        i18n.tr("Aperte uma tecla ou um botão do mouse… (Esc cancela)", "Press a key or a mouse button… (Esc cancels)")
    else if (binding == .none)
        i18n.tr("Nenhum: clique para escolher", "None: click to choose")
    else
        channels_ui.bindingName(&nb, binding);
    d.text(p.dl, p.font(if (binding == .none or capturing) .regular else .semibold), 15, r.x + 12, d.centerY(r, 15), if (capturing) ctx.col(.accent) else if (binding == .none) ctx.col(.muted) else ctx.col(.text), shown);
    if (!capturing and binding != .none) {
        const hint = i18n.tr("clique para trocar", "click to change");
        d.text(p.dl, p.font(.regular), 13, r.right() - 12 - d.width(p.font(.regular), 13, hint), d.centerY(r, 13), ctx.col(.faint), hint);
    }
    p.y += 50;
    p.note(i18n.tr("Só funciona com a janela do SigmaCord em foco: fora dela o programa não vê a tecla.", "Only works while the SigmaCord window is focused: outside it the app can't see the key."));
    p.note(i18n.tr("O envio segue por um instante depois de soltar, para não cortar a última palavra.", "Sending continues for a moment after you release, so the last word isn't cut."));
}

// --- Medidor ----------------------------------------------------------------

/// O nível ao vivo sobre a barra de sensibilidade (como no Discord): à direita
/// do limiar, em verde, é o que abre o microfone.
fn meter(p: anytype, s: *S.Settings) void {
    const ctx = p.ctx;
    const sh = &voz_audio.sh;
    const failed = sh.mic_failed.load(.monotonic);
    const db = sh.level_db.load(.monotonic);
    const uses_threshold = !s.voice_ptt;
    const th_db: f32 = if (s.voice_auto) sh.shown_threshold_db.load(.monotonic) else voz.sensToDb(s.voice_sens);
    const tr: d.Rect = .{ .x = p.x + 6, .y = p.y + 6, .w = p.w - 12, .h = 14 };
    const hr: d.Rect = .{ .x = tr.x - 6, .y = tr.y - 8, .w = tr.w + 12, .h = 30 };
    const hb = d.hit(ctx, base_id + 40, hr);
    qa.mark(hr, "voz-sens", .{});
    if (uses_threshold and !s.voice_auto and hb.held)
        s.voice_sens = @intFromFloat(std.math.round(std.math.clamp((ctx.mouse.x - tr.x) / tr.w, 0, 1) * 100));
    d.rect(p.dl, tr, ctx.col(.elevated).mix(ctx.col(.text), 0.08), 4);
    const level_k = voz.dbToPos(db);
    const th_k = voz.dbToPos(th_db);
    if (!failed and level_k > 0) {
        if (uses_threshold) {
            const below = @min(level_k, th_k);
            if (below > 0) d.rect(p.dl, .{ .x = tr.x, .y = tr.y, .w = tr.w * below, .h = tr.h }, ctx.col(.idle), 4);
            if (level_k > th_k) d.rect(p.dl, .{ .x = tr.x + tr.w * th_k, .y = tr.y, .w = tr.w * (level_k - th_k), .h = tr.h }, ctx.col(.online), 4);
        } else d.rect(p.dl, .{ .x = tr.x, .y = tr.y, .w = tr.w * level_k, .h = tr.h }, ctx.col(.online), 4);
    }
    if (uses_threshold) {
        const kx = tr.x + tr.w * th_k;
        // Automático: o limiar anda sozinho, então a marca é só informação.
        if (s.voice_auto) {
            d.rect(p.dl, .{ .x = kx - 1.5, .y = tr.y - 4, .w = 3, .h = tr.h + 8 }, ctx.col(.text).alpha(0.7), 1);
        } else {
            d.rect(p.dl, .{ .x = kx - 6, .y = tr.y - 6, .w = 12, .h = tr.h + 12 }, d.Rgba.white, 3);
        }
    }
    p.y += 32;
    var buf: [120]u8 = undefined;
    const info = if (failed)
        i18n.tr("O microfone não abriu. Confira o dispositivo acima e a permissão do sistema.", "The microphone didn't open. Check the device above and the system permission.")
    else if (db <= voz.db_silence)
        i18n.tr("Sem som no microfone.", "No sound from the microphone.")
    else if (!uses_threshold)
        i18n.fmt(&buf, "Nível: {d:.0} dB", "Level: {d:.0} dB", .{db})
    else if (s.voice_auto)
        i18n.fmt(&buf, "Nível: {d:.0} dB · limiar aprendido: {d:.0} dB", "Level: {d:.0} dB · learned threshold: {d:.0} dB", .{ db, th_db })
    else
        i18n.fmt(&buf, "Nível: {d:.0} dB · limiar: {d:.0} dB (arraste a marca)", "Level: {d:.0} dB · threshold: {d:.0} dB (drag the handle)", .{ db, th_db });
    if (failed) qa.mark(.{ .x = p.x, .y = p.y, .w = p.w, .h = 22 }, "voz-mic-falhou", .{});
    _ = d.textClipped(p.dl, p.font(.regular), 13, p.x, p.y, if (failed) ctx.col(.danger) else ctx.col(.muted), info, p.w);
    p.y += 28;
}

fn micTest(p: anytype) void {
    const ctx = p.ctx;
    const sh = &voz_audio.sh;
    const on = sh.test_on.load(.acquire);
    // O rótulo em português é a marca do QA.
    if (p.button(if (on) i18n.tr("Parar teste", "Stop test") else i18n.tr("Testar microfone", "Test microphone"), on)) sh.test_on.store(!on, .release);
    p.y += 2;
    _ = d.textClipped(p.dl, p.font(.regular), 13, p.x, p.y, ctx.col(.faint), i18n.tr("Toca de volta o que você fala, com os filtros. Use fones para não dar microfonia.", "Plays back what you say, with the filters. Use headphones to avoid feedback."), p.w);
    p.y += 26;
}
