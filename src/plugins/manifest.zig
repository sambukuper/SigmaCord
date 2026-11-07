//! O cabeçalho de um plugin: nome, descrição, versão e o que ele pede. Fica nos
//! comentários do começo do arquivo e é lido aqui, sem rodar Lua: a página de
//! configurações mostra tudo isso com o plugin desligado (e com ele desligado
//! não existe nenhum estado de Lua).
//!
//!     -- @name Bookmarks
//!     -- @name:pt Favoritos
//!     -- @description Save messages and find them later.
//!     -- @description:pt Guarde mensagens e ache depois.
//!     -- @version 1.0.0
//!     -- @capabilities menu, panel, storage
//!     -- @hosts api.exemplo.com
//!
//! Arquivo sem nenhuma diretiva é um plugin antigo: continua funcionando com a
//! API de antes (mensagens, comandos, envio, avisos e LSP) e as novas dão um
//! erro que explica o que acrescentar.
const std = @import("std");

pub const Cap = enum(u4) {
    messages,
    send,
    notify,
    storage,
    timers,
    panel,
    menu,
    decorate,
    composer,
    http,
    lsp,
    settings,
    completions,
    rewrite,
    links,
};

pub const max_hosts = 8;
const max_name = 48;
const max_desc = 320;
const max_version = 16;
/// Até onde o cabeçalho pode ir (um comentário gigante não vira trabalho).
const max_lines = 80;

fn bit(cap: Cap) u16 {
    return @as(u16, 1) << @intFromEnum(cap);
}

/// O que um arquivo sem cabeçalho sempre pôde fazer.
const legacy_caps: u16 = bit(.messages) | bit(.send) | bit(.notify) | bit(.lsp);

pub const Problem = union(enum) {
    none,
    unknown_cap: []const u8,
    bad_host: []const u8,
    discord_host: []const u8,
    too_many_hosts,
    http_without_hosts,
    hosts_without_http,
};

pub const Manifest = struct {
    /// Sem nenhuma diretiva: plugin de antes do cabeçalho.
    legacy: bool = true,
    name: []const u8 = "",
    name_pt: []const u8 = "",
    description: []const u8 = "",
    description_pt: []const u8 = "",
    version: []const u8 = "",
    caps: u16 = legacy_caps,
    hosts: [max_hosts][]const u8 = undefined,
    n_hosts: u8 = 0,
    problem: Problem = .none,

    pub fn has(m: *const Manifest, cap: Cap) bool {
        return m.caps & bit(cap) != 0;
    }

    pub fn hostList(m: *const Manifest) []const []const u8 {
        return m.hosts[0..m.n_hosts];
    }

    pub fn declares(m: *const Manifest, host: []const u8) bool {
        for (m.hostList()) |h| if (std.ascii.eqlIgnoreCase(h, host)) return true;
        return false;
    }

    /// Nome no idioma da interface; sem nenhum, o nome do arquivo.
    pub fn title(m: *const Manifest, en: bool, fallback: []const u8) []const u8 {
        if (!en and m.name_pt.len > 0) return m.name_pt;
        if (m.name.len > 0) return m.name;
        return if (m.name_pt.len > 0) m.name_pt else fallback;
    }

    pub fn about(m: *const Manifest, en: bool) []const u8 {
        if (!en and m.description_pt.len > 0) return m.description_pt;
        return if (m.description.len > 0) m.description else m.description_pt;
    }

    /// O problema do cabeçalho, já em texto (null = nenhum).
    pub fn problemText(m: *const Manifest, buf: []u8, en: bool) ?[]const u8 {
        return switch (m.problem) {
            .none => null,
            .unknown_cap => |s| (if (en) std.fmt.bufPrint(buf, "manifest: unknown capability \"{s}\"", .{s}) else std.fmt.bufPrint(buf, "cabeçalho: capacidade desconhecida \"{s}\"", .{s})) catch "manifest",
            .bad_host => |s| (if (en) std.fmt.bufPrint(buf, "manifest: invalid host \"{s}\" (just the name, like api.example.com: no IP address, no https:// and no port)", .{s}) else std.fmt.bufPrint(buf, "cabeçalho: host inválido \"{s}\" (só o nome, como api.exemplo.com: sem endereço IP, https:// nem porta)", .{s})) catch "manifest",
            .discord_host => |s| (if (en) std.fmt.bufPrint(buf, "manifest: \"{s}\" is Discord; plugins can't talk to Discord directly", .{s}) else std.fmt.bufPrint(buf, "cabeçalho: \"{s}\" é o Discord; plugins não falam direto com o Discord", .{s})) catch "manifest",
            .too_many_hosts => if (en) "manifest: at most 8 hosts" else "cabeçalho: no máximo 8 hosts",
            .http_without_hosts => if (en) "manifest: the http capability needs @hosts" else "cabeçalho: a capacidade http pede @hosts",
            .hosts_without_http => if (en) "manifest: @hosts needs the http capability" else "cabeçalho: @hosts pede a capacidade http",
        };
    }
};

fn clip(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var n = max;
    while (n > 0 and (s[n] & 0xC0) == 0x80) n -= 1;
    return s[0..n];
}

fn firstProblem(m: *Manifest, p: Problem) void {
    if (m.problem == .none) m.problem = p;
}

/// Lê o cabeçalho (as fatias apontam para `src`). Nunca falha: o que estiver
/// errado fica em `problem`, e o plugin não liga até a pessoa corrigir.
pub fn parse(src: []const u8) Manifest {
    var m: Manifest = .{};
    var body = src;
    // Marca de ordem de bytes que alguns editores põem no Windows.
    if (std.mem.startsWith(u8, body, "\xEF\xBB\xBF")) body = body[3..];
    var lines = std.mem.splitScalar(u8, body, '\n');
    var seen: usize = 0;
    while (lines.next()) |raw| {
        seen += 1;
        if (seen > max_lines) break;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (!std.mem.startsWith(u8, line, "--")) break;
        const text = std.mem.trimStart(u8, line[2..], " \t");
        if (text.len == 0 or text[0] != '@') continue;
        const sp = std.mem.indexOfAny(u8, text, " \t") orelse text.len;
        const key = text[1..sp];
        const value = std.mem.trim(u8, text[sp..], " \t");
        directive(&m, key, value);
    }
    if (m.legacy) return m;
    if (m.has(.http) and m.n_hosts == 0) firstProblem(&m, .http_without_hosts);
    if (!m.has(.http) and m.n_hosts > 0) firstProblem(&m, .hosts_without_http);
    return m;
}

fn directive(m: *Manifest, key: []const u8, value: []const u8) void {
    const eql = std.mem.eql;
    if (eql(u8, key, "name")) {
        m.name = clip(value, max_name);
    } else if (eql(u8, key, "name:pt")) {
        m.name_pt = clip(value, max_name);
    } else if (eql(u8, key, "description")) {
        m.description = clip(value, max_desc);
    } else if (eql(u8, key, "description:pt")) {
        m.description_pt = clip(value, max_desc);
    } else if (eql(u8, key, "version")) {
        m.version = clip(value, max_version);
    } else if (eql(u8, key, "capabilities")) {
        m.caps = 0;
        var it = std.mem.tokenizeAny(u8, value, ", \t");
        while (it.next()) |word| {
            if (std.meta.stringToEnum(Cap, word)) |cap| {
                m.caps |= bit(cap);
            } else firstProblem(m, .{ .unknown_cap = word });
        }
    } else if (eql(u8, key, "hosts")) {
        var it = std.mem.tokenizeAny(u8, value, ", \t");
        while (it.next()) |h| {
            if (m.n_hosts == max_hosts) {
                firstProblem(m, .too_many_hosts);
                break;
            }
            if (isDiscord(h)) {
                firstProblem(m, .{ .discord_host = h });
            } else if (!validHost(h)) {
                firstProblem(m, .{ .bad_host = h });
            } else {
                m.hosts[m.n_hosts] = h;
                m.n_hosts += 1;
            }
        }
    } else return;
    // Primeira diretiva conhecida: a partir daqui as capacidades são só as pedidas.
    if (m.legacy) {
        m.legacy = false;
        if (!eql(u8, key, "capabilities")) m.caps = 0;
    }
}

/// Um nome de verdade: nada de IP (a rede local fica de fora), porta ou caminho.
pub fn validHost(h: []const u8) bool {
    if (h.len < 4 or h.len > 96 or h[0] == '.' or h[0] == '-' or h[h.len - 1] == '.') return false;
    var dot = false;
    var letter = false;
    for (h) |ch| {
        if (ch == '.') {
            dot = true;
        } else if (std.ascii.isAlphabetic(ch)) {
            letter = true;
        } else if (!std.ascii.isDigit(ch) and ch != '-') return false;
    }
    if (!dot or !letter) return false;
    if (std.ascii.endsWithIgnoreCase(h, ".local") or std.ascii.endsWithIgnoreCase(h, ".localhost")) return false;
    return !allDigitsLast(h);
}

/// `1.2.3.4` e afins: o último pedaço de um nome de verdade nunca é só número.
fn allDigitsLast(h: []const u8) bool {
    const at = std.mem.lastIndexOfScalar(u8, h, '.') orelse return false;
    for (h[at + 1..]) |ch| if (!std.ascii.isDigit(ch)) return false;
    return true;
}

/// O Discord e os domínios dele: nem com a aprovação da pessoa.
pub fn isDiscord(h: []const u8) bool {
    const family = [_][]const u8{ "discord.com", "discordapp.com", "discord.gg", "discordapp.net", "discord.media", "discordcdn.com", "discordstatus.com", "discord.gift", "discord.new", "discord.co", "discord.dev", "dis.gd" };
    for (family) |f| {
        if (std.ascii.eqlIgnoreCase(h, f)) return true;
        if (h.len > f.len and h[h.len - f.len - 1] == '.' and std.ascii.endsWithIgnoreCase(h, f)) return true;
    }
    return false;
}

pub const Url = struct { host: []const u8, rest: []const u8 };

/// `https://nome/caminho?busca`, sem usuário, sem porta e sem espaços nem
/// caracteres de controle (quem chama codifica o texto: sigma.urlencode).
pub fn parseHttps(url: []const u8) ?Url {
    const scheme = "https://";
    if (url.len > 2048 or url.len <= scheme.len) return null;
    if (!std.ascii.startsWithIgnoreCase(url, scheme)) return null;
    for (url) |ch| if (ch <= 0x20 or ch >= 0x7F) return null;
    const after = url[scheme.len..];
    const end = std.mem.indexOfAny(u8, after, "/?#") orelse after.len;
    const host = after[0..end];
    if (!validHost(host)) return null;
    if (end < after.len and after[end] == '#') return null;
    return .{ .host = host, .rest = after[end..] };
}

test "cabeçalho completo nos dois idiomas" {
    const m = parse(
        \\-- bookmarks: comentário solto vale
        \\-- @name Bookmarks
        \\-- @name:pt Favoritos
        \\-- @description Save messages.
        \\-- @description:pt Guarde mensagens.
        \\-- @version 1.2.0
        \\-- @capabilities menu, panel storage
        \\
        \\-- @hosts ignorado.com
        \\sigma.notify("oi")
        \\-- @name Depois do código não vale
    );
    try std.testing.expect(!m.legacy);
    try std.testing.expectEqualStrings("Favoritos", m.title(false, "x.lua"));
    try std.testing.expectEqualStrings("Bookmarks", m.title(true, "x.lua"));
    try std.testing.expectEqualStrings("Guarde mensagens.", m.about(false));
    try std.testing.expectEqualStrings("Save messages.", m.about(true));
    try std.testing.expectEqualStrings("1.2.0", m.version);
    try std.testing.expect(m.has(.menu) and m.has(.panel) and m.has(.storage));
    try std.testing.expect(!m.has(.send) and !m.has(.messages));
    // "@hosts" ainda está no bloco de comentários, mas pede http.
    try std.testing.expectEqual(Problem.hosts_without_http, m.problem);
}

test "sem cabeçalho é plugin antigo, com a API de antes" {
    const m = parse("-- só um comentário\nsigma.notify('oi')\n-- @name tarde demais");
    try std.testing.expect(m.legacy);
    try std.testing.expect(m.has(.messages) and m.has(.send) and m.has(.notify) and m.has(.lsp));
    try std.testing.expect(!m.has(.storage) and !m.has(.http) and !m.has(.panel));
    try std.testing.expectEqualStrings("shrug.lua", m.title(true, "shrug.lua"));
}

test "cabeçalho sem capacidades não herda a API antiga" {
    const m = parse("-- @name Só comandos\n");
    try std.testing.expect(!m.legacy);
    try std.testing.expectEqual(@as(u16, 0), m.caps);
    try std.testing.expectEqual(Problem.none, m.problem);
}

test "problemas do cabeçalho viram explicação" {
    var buf: [200]u8 = undefined;
    const a = parse("-- @name x\n-- @capabilities voar\n");
    try std.testing.expectEqualStrings("voar", a.problem.unknown_cap);
    try std.testing.expect(std.mem.indexOf(u8, a.problemText(&buf, false).?, "voar") != null);
    try std.testing.expect(parse("-- @capabilities http\n").problem == .http_without_hosts);
    try std.testing.expect(parse("-- @capabilities http\n-- @hosts discord.com\n").problem == .discord_host);
    try std.testing.expect(parse("-- @capabilities http\n-- @hosts cdn.discordapp.com\n").problem == .discord_host);
    try std.testing.expect(parse("-- @capabilities http\n-- @hosts 127.0.0.1\n").problem == .bad_host);
    try std.testing.expect(parse("-- @capabilities http\n-- @hosts localhost\n").problem == .bad_host);
    try std.testing.expect(parse("-- @capabilities http\n-- @hosts https://a.com\n").problem == .bad_host);
    try std.testing.expect(parse("-- @capabilities http\n-- @hosts a.com:8443\n").problem == .bad_host);
    const ok = parse("-- @capabilities http\n-- @hosts a.com, api.b-c.org\n");
    try std.testing.expectEqual(Problem.none, ok.problem);
    try std.testing.expect(ok.declares("API.B-C.org"));
    try std.testing.expect(!ok.declares("c.org"));
}

test "URL: só https, sem usuário, porta ou caracteres soltos" {
    const u = parseHttps("https://api.a.com/get?q=oi%20gente").?;
    try std.testing.expectEqualStrings("api.a.com", u.host);
    try std.testing.expectEqualStrings("/get?q=oi%20gente", u.rest);
    try std.testing.expectEqualStrings("", parseHttps("https://a.com").?.rest);
    for ([_][]const u8{
        "http://a.com/",
        "ftp://a.com/",
        "https://",
        "https://user:pw@a.com/",
        "https://a.com:8443/",
        "https://1.2.3.4/",
        "https://a.com/com espaço",
        "https://a.com/\r\nCookie: x",
        "https://a.com/ç",
    }) |bad| try std.testing.expect(parseHttps(bad) == null);
    try std.testing.expect(isDiscord("discord.com") and isDiscord("gateway.discord.gg") and !isDiscord("notdiscord.com"));
}
