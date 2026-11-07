//! Estado do cliente: tudo que veio do Discord, indexado por ID.
//! A interface só lê daqui; quem escreve é `apply` (eventos da rede) e
//! `addPending` (mensagem que acabamos de enviar).
//!
//! Cada canal guarda no máximo `max_messages`; as mais antigas são liberadas.
const std = @import("std");
const types = @import("types.zig");
const markdown = @import("markdown.zig");
const Event = @import("event.zig").Event;
const event = @import("event.zig");
const Id = types.Id;

/// SIGMACORD_READ_DEBUG: conta no log por que cada canal ficou não lido (só IDs).
pub var read_debug = false;

/// Strings que chegam em eventos são alocadas com o c_allocator (podem vir
/// de outra thread) e liberadas com ele também.
const ev_alloc = std.heap.c_allocator;
/// Quantas mensagens a mais um canal pode ter antes de cortar para `max_messages`.
const trim_slack = 128;

pub const StoredMessage = struct {
    msg: types.Message,
    spans: []const markdown.Span,
    /// Markdown dos embeds: para cada embed, a descrição e depois o valor de
    /// cada campo, nessa ordem.
    embed_spans: []const []const markdown.Span = &.{},
    pending: bool = false,
    /// O envio falhou (continua `pending`: sem ID, fora do cache e da busca).
    failed: bool = false,
    /// Cache de layout (preenchido pela interface).
    layout_w: f32 = -1,
    layout_variant: u32 = 0xffff_ffff,
    height: f32 = 0,
    /// Largura da linha mais longa (usada pelas bolhas).
    natural_w: f32 = 0,
    /// Registro de mensagens: apagada pelo autor (fica na tela, marcada) e o
    /// texto de antes da primeira edição (ev_alloc).
    deleted: bool = false,
    original: ?[]const u8 = null,
    /// Dia local da mensagem (para os separadores), calculado uma vez pela interface.
    day: i64 = std.math.minInt(i64),
    reactions: [8]types.Reaction = @splat(.{}),
    n_reactions: u8 = 0,
    /// Cache das palavras de alerta/filtro que o texto contém (core/filtros.zig).
    flt_key: u32 = 0,
    flt: u8 = 0,
    /// Cache das regras de decoração dos plugins (plugins/deco.zig) e assinatura
    /// da decoração da última vez que a altura foi medida.
    dc_key: u32 = 0,
    dc_ver: u32 = 0,
    dc_rule: u16 = 0,
    /// Cache de "fala com a gente" (core/inbox.zig `mentionsMe`).
    mm_key: u32 = 0,
    mm: bool = false,
    /// Veio do cache em disco (ver `loadCached`), não do servidor.
    from_cache: bool = false,

    pub fn reactionSlice(m: *const StoredMessage) []const types.Reaction {
        return m.reactions[0..m.n_reactions];
    }
};

pub const History = enum { none, loading, loaded, failed };

pub const Typing = struct { user: Id, until_ms: i64 };

/// Páginas de threads já buscadas de um canal (ativas ou arquivadas).
pub const ThreadPage = struct {
    state: History = .none,
    more: bool = true,
    /// Quantas já vieram: é assim que as ativas paginam.
    offset: u32 = 0,
    /// A mais antiga já vista (s): é assim que as arquivadas paginam.
    before: i64 = 0,
};

/// Quantas threads um canal mostra na lista de canais (o resto: "mais N").
pub const thread_rows_cap = 6;

/// As threads de um canal pai. Refeito só quando algo muda (`dirty`), para a
/// lista de canais não varrer nada a cada quadro.
pub const ThreadIndex = struct {
    /// Todas as que conhecemos, ativas e arquivadas. Mais recente primeiro
    /// depois de `Store.threadIndex`.
    all: std.ArrayList(Id) = .empty,
    dirty: bool = true,
    /// O recorte da lista de canais (fórum: só as nossas e as não lidas).
    shown: [thread_rows_cap]Id = @splat(0),
    n_shown: u8 = 0,
    /// Ativas de um canal de texto que não couberam em `shown`.
    more: u32 = 0,
    /// Alguma das mostradas não foi lida.
    unread: bool = false,
};

pub const ChannelState = struct {
    info: types.Channel,
    messages: std.ArrayList(StoredMessage) = .empty,
    history: History = .none,
    /// Mensagens mais antigas (rolando para cima).
    older: enum { idle, loading, done } = .idle,
    /// Falhou ao buscar as antigas: não tenta de novo antes disso.
    older_retry_ms: i64 = 0,
    /// A pessoa rolou para cima: as que ela está lendo não são cortadas.
    reading: bool = false,
    /// Última vez que a conversa apareceu na tela (a interface marca). As
    /// esquecidas há mais tempo são as primeiras a sair da memória.
    seen_ms: i64 = 0,
    typing: std.ArrayList(Typing) = .empty,
    voice_members: std.ArrayList(Id) = .empty,
    /// Muda sempre que a lista de mensagens muda (invalida offsets na UI).
    version: u32 = 0,
    /// Marcador de leitura: a última mensagem quando o canal foi lido
    /// (0 = não foi lido nesta sessão). A caixa de entrada usa.
    read_id: Id = 0,
    /// Mostrando o cache do disco enquanto o histórico de verdade não chega.
    cached: bool = false,
    /// Linha "NOVAS MENSAGENS": começa depois desta mensagem (0 = sem linha).
    /// Fica até sair do canal, mesmo depois de lido.
    divider_after: Id = 0,
    /// A linha já apareceu na tela: o botão do topo não precisa mais.
    divider_seen: bool = false,
    /// Ao mostrar, posiciona na primeira não lida.
    pos_unread: bool = false,
    /// Marcada como não lida à mão: não confirma leitura sozinho até sair e voltar.
    hold_unread: bool = false,
    /// A lista não chega no presente: é uma página do passado (mensagens ao
    /// vivo não entram, o fim da lista busca as mais novas).
    detached: bool = false,
    newer: enum { idle, loading } = .idle,
    newer_retry_ms: i64 = 0,
    /// Busca em volta de uma mensagem (GET messages?around=).
    around: enum { idle, loading, done, failed } = .idle,
    /// Threads deste canal buscadas sob demanda (ui/forum.zig).
    active_page: ThreadPage = .{},
    archived_page: ThreadPage = .{},
    /// Post de fórum: a primeira mensagem, para a lista (ev_alloc; vazio = não veio).
    preview: []const u8 = "",
    preview_author: Id = 0,
    /// Thread: quem está nela já foi pedido nesta sessão.
    members_asked: bool = false,
};

/// Mensagens fixadas de um canal, como vieram da última vez.
pub const PinList = struct {
    state: History = .none,
    items: std.ArrayList(StoredMessage) = .empty,
};

/// Lista de membros de um servidor, no formato do Discord: posições fixas
/// (a faixa 0..99 que pedimos), com cabeçalhos de grupo no meio.
pub const MemberList = struct {
    list_id: u64 = 0,
    online: u32 = 0,
    total: u32 = 0,
    items: std.ArrayList(types.MemberItem) = .empty,
    /// Já chegou o primeiro SYNC (antes disso, "carregando").
    synced: bool = false,
};

pub const GifList = struct {
    req: u32 = 0,
    state: enum { none, loading, ready, failed } = .none,
    items: []types.Gif = &.{},
};

fn freeGifs(items: []types.Gif) void {
    for (items) |g| {
        ev_alloc.free(g.url);
        ev_alloc.free(g.src);
        ev_alloc.free(g.preview);
        ev_alloc.free(g.title);
    }
    if (items.len > 0) ev_alloc.free(items);
}

pub const Store = struct {
    gpa: std.mem.Allocator,
    me: Id = 0,
    ready: bool = false,
    /// Limite por canal das que chegam ao vivo; o que veio rolando para cima
    /// não é cortado (a pessoa está lendo).
    max_messages: usize = 1500,
    /// Teto de mensagens na memória somando todos os canais (Configurações → Desempenho).
    /// Passando dele, descarrega a conversa esquecida há mais tempo, que é buscada de novo
    /// quando voltar para a tela.
    message_budget: usize = 2000,
    latency_ms: u32 = 0,
    connection: @import("event.zig").Connection = .connecting,
    /// Dados de demonstração (sem conta conectada).
    demo: bool = false,
    /// Configurações → Privacidade → Registro de mensagens.
    keep_log: bool = false,
    /// Da nossa conta (Configurações → Minha conta).
    me_username: ?[]const u8 = null,
    me_email: ?[]const u8 = null,
    /// `premium_type` da conta: 0 = sem Nitro (emoji de outro servidor e
    /// animado são recusados pelo Discord).
    premium_type: u8 = 0,
    /// Emojis personalizados de cada servidor (nomes com o ev_alloc) e todos
    /// eles pelo ID (as cópias apontam para os mesmos nomes).
    guild_emojis: std.AutoHashMapUnmanaged(Id, []types.Emoji) = .empty,
    emoji_by_id: std.AutoHashMapUnmanaged(Id, types.Emoji) = .empty,
    users: std.AutoHashMapUnmanaged(Id, types.User) = .empty,
    guilds: std.ArrayList(types.Guild) = .empty,
    channels: std.AutoHashMapUnmanaged(Id, *ChannelState) = .empty,
    /// Canais de cada servidor, na ordem de exibição (categorias incluídas).
    /// Threads não entram aqui: ficam em `threads`, por canal pai.
    guild_channels: std.AutoHashMapUnmanaged(Id, std.ArrayList(Id)) = .empty,
    threads: std.AutoHashMapUnmanaged(Id, ThreadIndex) = .empty,
    /// Quem está em cada thread (só as que já abrimos).
    thread_members: std.AutoHashMapUnmanaged(Id, std.ArrayList(Id)) = .empty,
    /// Muda quando alguma lista de threads muda (invalida a lista do fórum).
    threads_rev: u32 = 0,
    /// Cargos de todos os servidores (o ID do cargo é único no Discord).
    roles: std.AutoHashMapUnmanaged(Id, types.Role) = .empty,
    member_lists: std.AutoHashMapUnmanaged(Id, MemberList) = .empty,
    /// (servidor, usuário) -> cor do nome e cargos.
    members: std.AutoHashMapUnmanaged([2]Id, types.MemberInfo) = .empty,
    relationships: std.AutoHashMapUnmanaged(Id, types.Relationship) = .empty,
    /// Pastas e ordem dos servidores (vazio = a ordem em que vieram).
    folders: []types.GuildFolder = &.{},
    /// Perfis completos já buscados (e a bio já interpretada).
    profiles: std.AutoHashMapUnmanaged(Id, types.Profile) = .empty,
    /// Muda quando `profiles` é esvaziado (dá para pedir os perfis de novo).
    profiles_gen: u32 = 0,
    bios: std.AutoHashMapUnmanaged(Id, []const markdown.Span) = .empty,
    /// Atividades de cada um (jogo, música…), da presença; só quem tem alguma.
    activities: std.AutoHashMapUnmanaged(Id, []types.Activity) = .empty,
    /// Até quando cada pessoa conta como "falando" (o gateway de voz manda
    /// curtinho; o anel verde some sozinho se o pacote de parar se perder).
    speaking: std.AutoHashMapUnmanaged(Id, i64) = .empty,
    /// Mudo/surdo de quem está em alguma call.
    voice_flags: std.AutoHashMapUnmanaged(Id, event.VoiceFlags) = .empty,
    /// Amigos desde (ms), das relações.
    friend_since: std.AutoHashMapUnmanaged(Id, i64) = .empty,
    /// Notas que só a gente vê (buscadas ao abrir o perfil).
    notes: std.AutoHashMapUnmanaged(Id, []const u8) = .empty,
    /// Todos os nossos cargos em cada servidor (para as exceções dos canais).
    my_roles: std.AutoHashMapUnmanaged(Id, []Id) = .empty,
    /// Ícone (hash) de cada aplicação; "" = não tem ou não deu.
    app_icons: std.AutoHashMapUnmanaged(Id, []const u8) = .empty,
    /// Menções recentes (GET /users/@me/mentions), da mais nova para a mais
    /// antiga, e quando chegaram (as que vierem depois entram pela conversa).
    recent_mentions: std.ArrayList(StoredMessage) = .empty,
    mentions_state: History = .none,
    mentions_ms: i64 = 0,
    /// `read_state` do último READY, por canal (o servidor que chega depois
    /// usa também).
    read_index: std.AutoHashMapUnmanaged(Id, types.ReadEntry) = .empty,
    pins: std.AutoHashMapUnmanaged(Id, PinList) = .empty,
    /// O que o seletor de GIFs mostra.
    gif_results: GifList = .{},
    gif_favorites: GifList = .{},
    /// Cartões de convite já pedidos, por código (chave alocada).
    invites: std.StringHashMapUnmanaged(types.Invite) = .empty,
    /// Canais silenciados aqui: não acendem o servidor na barra.
    muted: ?*const std.AutoHashMapUnmanaged(Id, void) = null,
    /// Chamado antes de uma conversa sair da memória (o cache em disco
    /// guarda o que ela tinha).
    on_evict: ?*const fn (*Store, *ChannelState) void = null,
    /// Muda quando algo que a caixa de entrada mostra pode ter mudado
    /// (mensagens, não lidas, marcador de leitura, menções dos servidores):
    /// ela só se refaz quando isto muda, sem olhar todos os canais a cada quadro.
    rev: u32 = 0,
    /// Muda quando nós ou os nossos cargos mudam (invalida `mm` das mensagens).
    me_rev: u32 = 1,

    pub fn init(gpa: std.mem.Allocator) Store {
        return .{ .gpa = gpa };
    }

    pub fn deinit(s: *Store) void {
        var gei = s.guild_emojis.valueIterator();
        while (gei.next()) |list| freeEmojis(list.*);
        s.guild_emojis.deinit(s.gpa);
        s.emoji_by_id.deinit(s.gpa);
        var it = s.channels.valueIterator();
        while (it.next()) |cs| {
            for (cs.*.messages.items) |*m| s.freeMessage(m);
            cs.*.messages.deinit(s.gpa);
            cs.*.typing.deinit(s.gpa);
            cs.*.voice_members.deinit(s.gpa);
            freeChannelInfo(&cs.*.info);
            ev_alloc.free(cs.*.preview);
            s.gpa.destroy(cs.*);
        }
        s.channels.deinit(s.gpa);
        s.read_index.deinit(s.gpa);
        var pli = s.pins.valueIterator();
        while (pli.next()) |pl| s.freePins(pl);
        s.pins.deinit(s.gpa);
        freeGifs(s.gif_results.items);
        freeGifs(s.gif_favorites.items);
        s.clearInvites();
        s.invites.deinit(s.gpa);
        var thi = s.threads.valueIterator();
        while (thi.next()) |ti| ti.all.deinit(s.gpa);
        s.threads.deinit(s.gpa);
        var tmi = s.thread_members.valueIterator();
        while (tmi.next()) |tm| tm.deinit(s.gpa);
        s.thread_members.deinit(s.gpa);
        var ri = s.roles.valueIterator();
        while (ri.next()) |r| ev_alloc.free(r.name);
        s.roles.deinit(s.gpa);
        var mi = s.member_lists.valueIterator();
        while (mi.next()) |ml| ml.items.deinit(s.gpa);
        s.member_lists.deinit(s.gpa);
        s.members.deinit(s.gpa);
        s.relationships.deinit(s.gpa);
        freeFolders(s.folders);
        var pi = s.profiles.valueIterator();
        while (pi.next()) |pr| freeProfile(pr.*);
        s.profiles.deinit(s.gpa);
        var bi = s.bios.valueIterator();
        while (bi.next()) |b| s.gpa.free(b.*);
        s.bios.deinit(s.gpa);
        var ai = s.activities.valueIterator();
        while (ai.next()) |a| freeActivities(a.*);
        s.activities.deinit(s.gpa);
        s.speaking.deinit(s.gpa);
        s.voice_flags.deinit(s.gpa);
        s.friend_since.deinit(s.gpa);
        var ni = s.notes.valueIterator();
        while (ni.next()) |n| ev_alloc.free(n.*);
        s.notes.deinit(s.gpa);
        var ii = s.app_icons.valueIterator();
        while (ii.next()) |n| if (n.len > 0) ev_alloc.free(n.*);
        s.app_icons.deinit(s.gpa);
        var mri = s.my_roles.valueIterator();
        while (mri.next()) |r| ev_alloc.free(r.*);
        s.my_roles.deinit(s.gpa);
        for (s.recent_mentions.items) |*m| s.freeMessage(m);
        s.recent_mentions.deinit(s.gpa);
        var gc = s.guild_channels.valueIterator();
        while (gc.next()) |l| l.deinit(s.gpa);
        s.guild_channels.deinit(s.gpa);
        for (s.guilds.items) |g| freeGuildInfo(g);
        s.guilds.deinit(s.gpa);
        var ui = s.users.valueIterator();
        while (ui.next()) |u| freeUser(u.*);
        s.users.deinit(s.gpa);
        if (s.me_username) |x| ev_alloc.free(x);
        if (s.me_email) |x| ev_alloc.free(x);
    }

    fn freePins(s: *Store, pl: *PinList) void {
        for (pl.items.items) |*m| s.freeMessage(m);
        pl.items.deinit(s.gpa);
    }

    fn clearInvites(s: *Store) void {
        var it = s.invites.iterator();
        while (it.next()) |e| {
            ev_alloc.free(e.key_ptr.*);
            freeInvite(e.value_ptr.*);
        }
        s.invites.clearRetainingCapacity();
    }

    fn freeInvite(i: types.Invite) void {
        if (i.name.len > 0) ev_alloc.free(i.name);
        if (i.icon) |x| ev_alloc.free(x);
        if (i.banner) |x| ev_alloc.free(x);
    }

    /// Guarda o cartão de um convite (com um teto: passando, esquece todos e
    /// eles são pedidos de novo se voltarem à tela).
    pub fn putInvite(s: *Store, code: []const u8, inv: types.Invite) void {
        if (s.invites.getPtr(code)) |old| {
            freeInvite(old.*);
            old.* = inv;
            return;
        }
        if (s.invites.count() >= 128) s.clearInvites();
        const key = ev_alloc.dupe(u8, code) catch return freeInvite(inv);
        s.invites.put(s.gpa, key, inv) catch {
            ev_alloc.free(key);
            freeInvite(inv);
        };
    }

    fn freeUser(u: types.User) void {
        ev_alloc.free(u.name);
        if (u.activity) |a| ev_alloc.free(a);
        if (u.avatar) |a| ev_alloc.free(a);
        if (u.decoration) |a| ev_alloc.free(a);
    }

    fn freeFolders(list: []const types.GuildFolder) void {
        for (list) |f| {
            ev_alloc.free(f.name);
            ev_alloc.free(f.guilds);
        }
        if (list.len > 0) ev_alloc.free(list);
    }

    fn freeProfile(p: types.Profile) void {
        for ([_][]const u8{ p.banner, p.bio, p.pronouns, p.username }) |t| if (t.len > 0) ev_alloc.free(t);
        if (p.mutual_guilds.len > 0) ev_alloc.free(p.mutual_guilds);
        if (p.mutual_friends.len > 0) ev_alloc.free(p.mutual_friends);
        for (p.connections) |cn| for ([_][]const u8{ cn.kind, cn.name, cn.url }) |t| if (t.len > 0) ev_alloc.free(t);
        if (p.connections.len > 0) ev_alloc.free(p.connections);
        for (p.badges) |b| for ([_][]const u8{ b.icon, b.description }) |t| if (t.len > 0) ev_alloc.free(t);
        if (p.badges.len > 0) ev_alloc.free(p.badges);
    }

    pub fn freeActivities(list: []types.Activity) void {
        for (list) |a| for ([_][]const u8{ a.name, a.details, a.state, a.image }) |t| if (t.len > 0) ev_alloc.free(t);
        if (list.len > 0) ev_alloc.free(list);
    }

    /// Canal de voz em que a pessoa está (0 = nenhum); se houver mais de um
    /// (contas de bot, a demonstração), o do servidor `prefer` primeiro.
    pub fn voiceChannelOf(s: *const Store, user_id: Id, prefer: Id) Id {
        var found: Id = 0;
        var it = s.channels.valueIterator();
        while (it.next()) |cs| {
            if (cs.*.voice_members.items.len == 0 or std.mem.indexOfScalar(Id, cs.*.voice_members.items, user_id) == null) continue;
            if (cs.*.info.guild == prefer) return cs.*.info.id;
            if (found == 0) found = cs.*.info.id;
        }
        return found;
    }

    /// Mudo/surdo de quem está numa call (o que o último VOICE_STATE disse).
    pub fn voiceFlags(s: *const Store, user_id: Id) event.VoiceFlags {
        return s.voice_flags.get(user_id) orelse .{};
    }

    /// A pessoa está falando agora? (o anel verde some sozinho)
    pub fn isSpeaking(s: *Store, user_id: Id, now_ms: i64) bool {
        const ptr = s.speaking.getPtr(user_id) orelse return false;
        if (ptr.* < now_ms) {
            _ = s.speaking.remove(user_id);
            return false;
        }
        return true;
    }

    fn freeGuildInfo(g: types.Guild) void {
        ev_alloc.free(g.name);
        ev_alloc.free(g.acronym);
        if (g.icon) |i| ev_alloc.free(i);
        if (g.banner) |b| ev_alloc.free(b);
        if (g.description.len > 0) ev_alloc.free(g.description);
    }

    fn freeChannelInfo(ch: *const types.Channel) void {
        if (ch.overwrites.len > 0) ev_alloc.free(ch.overwrites);
        ev_alloc.free(ch.name);
        ev_alloc.free(ch.topic);
        if (ch.recipients.len > 0) ev_alloc.free(ch.recipients);
        if (ch.icon) |i| ev_alloc.free(i);
        if (ch.thread) |t| if (t.tags.len > 0) ev_alloc.free(t.tags);
        for (ch.tags) |t| {
            ev_alloc.free(t.name);
            if (t.emoji.len > 0) ev_alloc.free(t.emoji);
        }
        if (ch.tags.len > 0) ev_alloc.free(ch.tags);
    }

    /// Troca o avatar e a decoração guardados pelos novos, se vieram
    /// (fica com eles ou os libera).
    fn takeAvatar(old: *types.User, fresh: ?[]const u8) void {
        takeOpt(&old.avatar, fresh);
    }

    fn takeOpt(slot: *?[]const u8, fresh: ?[]const u8) void {
        const f = fresh orelse return;
        if (slot.*) |a| {
            if (std.mem.eql(u8, a, f)) return ev_alloc.free(f);
            ev_alloc.free(a);
        }
        slot.* = f;
    }

    fn freeMessage(s: *Store, m: *StoredMessage) void {
        ev_alloc.free(m.msg.content);
        ev_alloc.free(m.msg.raw);
        types.freeAttachments(ev_alloc, m.msg.attachments);
        types.freeEmbeds(ev_alloc, m.msg.embeds);
        s.gpa.free(m.spans);
        s.freeEmbedSpans(m.embed_spans);
        if (m.original) |o| ev_alloc.free(o);
    }

    fn freeRaw(m: types.Message) void {
        ev_alloc.free(m.content);
        ev_alloc.free(m.raw);
        types.freeAttachments(ev_alloc, m.attachments);
        types.freeEmbeds(ev_alloc, m.embeds);
    }

    fn freeEmbedSpans(s: *Store, list: []const []const markdown.Span) void {
        for (list) |sp| s.gpa.free(sp);
        if (list.len > 0) s.gpa.free(list);
    }

    fn parseEmbeds(s: *Store, embeds: []const types.Embed) ![]const []const markdown.Span {
        var n: usize = 0;
        for (embeds) |e| n += 1 + e.fields.len + e.blocks.len;
        if (n == 0) return &.{};
        const out = try s.gpa.alloc([]const markdown.Span, n);
        var k: usize = 0;
        for (embeds) |e| {
            out[k] = try markdown.parse(s.gpa, e.description);
            k += 1;
            for (e.fields) |f| {
                out[k] = try markdown.parse(s.gpa, f.value);
                k += 1;
            }
            for (e.blocks) |b| {
                out[k] = try markdown.parse(s.gpa, b.text);
                k += 1;
            }
        }
        return out;
    }

    /// Mensagem pronta para guardar: o markdown já interpretado.
    fn stored(s: *Store, m_in: types.Message) !StoredMessage {
        var m = m_in;
        // A thread aberta de uma mensagem tem o ID dela: vale também para o
        // que volta do cache em disco. (Um post de fórum é a própria conversa.)
        if (m.thread == 0 and m.id != m.channel and s.channels.contains(m.id)) m.thread = m.id;
        return .{ .msg = m, .spans = try markdown.parseRaw(s.gpa, m.content, m.raw), .embed_spans = try s.parseEmbeds(m.embeds) };
    }

    /// Quem é bot não deixa de ser: nem todo objeto de usuário diz (a presença, por
    /// exemplo, costuma trazer pouco).
    fn takeBot(old: *types.User, u: types.User) void {
        old.bot = old.bot or u.bot;
        old.verified_bot = old.verified_bot or u.verified_bot;
        old.webhook = old.webhook or u.webhook;
    }

    /// READY pode chegar mais de uma vez (sessão nova depois de uma queda).
    /// Funde por ID em vez de duplicar servidores, canais e usuários.
    fn mergeUser(s: *Store, u: types.User) !void {
        if (s.users.getPtr(u.id)) |old| {
            ev_alloc.free(u.name);
            if (u.activity) |a| ev_alloc.free(a);
            takeAvatar(old, u.avatar);
            takeOpt(&old.decoration, u.decoration);
            takeBot(old, u);
            if (old.status == .offline and u.status != .offline) old.status = u.status;
            return;
        }
        try s.users.put(s.gpa, u.id, u);
    }

    /// Substitui um usuário existente (nome/atividade novos), preservando o
    /// status e a atividade que o evento de update não carrega.
    fn putUser(s: *Store, u: types.User) !void {
        if (s.users.getPtr(u.id)) |old| {
            const old_status = old.status;
            const old_activity = old.activity;
            const old_avatar = old.avatar;
            const old_deco = old.decoration;
            const was: types.User = old.*;
            ev_alloc.free(old.name);
            old.* = u;
            old.avatar = old_avatar;
            old.decoration = old_deco;
            takeBot(old, was);
            takeAvatar(old, u.avatar);
            takeOpt(&old.decoration, u.decoration);
            if (u.status == .offline) old.status = old_status;
            if (u.activity == null) {
                old.activity = old_activity;
            } else if (old_activity) |a| {
                ev_alloc.free(a);
            }
            return;
        }
        try s.users.put(s.gpa, u.id, u);
    }

    fn mergeGuild(s: *Store, g: types.Guild) !void {
        for (s.guilds.items) |*old| {
            if (old.id != g.id) continue;
            ev_alloc.free(old.name);
            ev_alloc.free(old.acronym);
            if (old.icon) |i| ev_alloc.free(i);
            if (old.banner) |b| ev_alloc.free(b);
            if (old.description.len > 0) ev_alloc.free(old.description);
            old.name = g.name;
            old.acronym = g.acronym;
            old.color = g.color;
            old.icon = g.icon;
            old.banner = g.banner;
            old.can_banner = g.can_banner;
            old.description = g.description;
            if (g.owner != 0) old.owner = g.owner;
            if (g.joined_id != 0) old.joined_id = g.joined_id;
            return;
        }
        try s.guilds.append(s.gpa, g);
    }

    fn mergeChannel(s: *Store, ch_in: types.Channel) !void {
        var ch = ch_in;
        var was_known = false;
        if (s.channels.get(ch.id)) |cs| {
            was_known = true;
            const unread = cs.info.unread or ch.unread;
            const last = @max(cs.info.last_message, ch.last_message);
            // THREAD_UPDATE não repete tudo: fica com o que ele não trouxe.
            if (cs.info.thread) |old| if (ch.thread) |*t| {
                if (!t.joined_known) {
                    t.joined = old.joined;
                    t.joined_known = old.joined_known;
                }
                t.last_message = @max(t.last_message, old.last_message);
                if (t.member_count == 0) t.member_count = old.member_count;
            };
            // Mudou de pai (não acontece no Discord, mas a lista não pode mentir).
            if (cs.info.thread != null and cs.info.parent != ch.parent) s.dropFromIndex(ch.id, cs.info.parent);
            freeChannelInfo(&cs.info);
            cs.info = ch;
            cs.info.unread = unread;
            cs.info.last_message = last;
        } else {
            const cs = try s.gpa.create(ChannelState);
            cs.* = .{ .info = ch };
            try s.channels.put(s.gpa, ch.id, cs);
        }
        if (ch.thread != null) return s.indexThread(ch.id, ch.parent, was_known);
        const gop = try s.guild_channels.getOrPut(s.gpa, ch.guild);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        if (std.mem.indexOfScalar(Id, gop.value_ptr.items, ch.id) == null) {
            try gop.value_ptr.append(s.gpa, ch.id);
        }
    }

    /// Thread nova ou atualizada: entra na lista do pai, e a mensagem que a
    /// abriu passa a mostrar o cartão.
    fn indexThread(s: *Store, id: Id, parent: ?Id, was_known: bool) !void {
        const pid = parent orelse return;
        const gop = try s.threads.getOrPut(s.gpa, pid);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        if (!was_known or std.mem.indexOfScalar(Id, gop.value_ptr.all.items, id) == null) {
            try gop.value_ptr.all.append(s.gpa, id);
            if (s.channel(pid)) |pcs| if (s.find(pcs, id)) |m| {
                m.msg.thread = id;
                m.layout_w = -1;
                pcs.version +%= 1;
            };
        }
        s.touchThreads(pid);
    }

    fn touchThreads(s: *Store, parent: ?Id) void {
        s.threads_rev +%= 1;
        if (s.threads.getPtr(parent orelse return)) |ti| ti.dirty = true;
    }

    fn dropFromIndex(s: *Store, id: Id, parent: ?Id) void {
        const ti = s.threads.getPtr(parent orelse return) orelse return;
        if (std.mem.indexOfScalar(Id, ti.all.items, id)) |i| _ = ti.all.orderedRemove(i);
        s.touchThreads(parent);
    }

    /// Mensagem nova numa thread: contagem, "última há…" e a prévia do post.
    fn noteThreadMessage(s: *Store, cs: *ChannelState, m: types.Message) void {
        const t = if (cs.info.thread) |*t| t else return;
        // A primeira mensagem de um post não conta (o Discord também não).
        if (m.id != cs.info.id) t.message_count +|= 1;
        t.last_message = @max(t.last_message, m.id);
        if (m.id == cs.info.id and cs.preview.len == 0) {
            if (ev_alloc.dupe(u8, m.content)) |text| {
                cs.preview = text;
                cs.preview_author = m.author;
            } else |_| {}
        }
        s.touchThreads(cs.info.parent);
    }

    fn removeChannel(s: *Store, id: Id) void {
        const kv = s.channels.fetchRemove(id) orelse return;
        const cs = kv.value;
        if (s.pins.fetchRemove(id)) |pk| {
            var pl = pk.value;
            s.freePins(&pl);
        }
        const parent = cs.info.parent;
        const is_thread = cs.info.thread != null;
        for (cs.messages.items) |*m| s.freeMessage(m);
        cs.messages.deinit(s.gpa);
        cs.typing.deinit(s.gpa);
        cs.voice_members.deinit(s.gpa);
        freeChannelInfo(&cs.info);
        ev_alloc.free(cs.preview);
        s.gpa.destroy(cs);
        if (s.thread_members.fetchRemove(id)) |tm| {
            var list = tm.value;
            list.deinit(s.gpa);
        }
        // Foi embora junto com as threads dele.
        if (s.threads.fetchRemove(id)) |ti| {
            var idx = ti.value;
            for (idx.all.items) |tid| s.removeChannel(tid);
            idx.all.deinit(s.gpa);
            s.threads_rev +%= 1;
        }
        if (is_thread) {
            s.dropFromIndex(id, parent);
            // O cartão some da mensagem que abriu a thread.
            if (parent) |pid| if (s.channel(pid)) |pcs| for (pcs.messages.items) |*m| if (m.msg.thread == id) {
                m.msg.thread = 0;
                m.layout_w = -1;
                pcs.version +%= 1;
            };
            return;
        }
        var it = s.guild_channels.valueIterator();
        while (it.next()) |list| {
            if (std.mem.indexOfScalar(Id, list.items, id)) |i| _ = list.orderedRemove(i);
        }
    }

    fn removeGuild(s: *Store, id: Id) void {
        if (s.guild_channels.fetchRemove(id)) |kv| {
            var list = kv.value;
            for (list.items) |ch| s.removeChannel(ch);
            list.deinit(s.gpa);
        }
        // Thread de um canal que não conhecemos (sem acesso) também vai embora.
        var orphans: std.ArrayList(Id) = .empty;
        defer orphans.deinit(s.gpa);
        var oit = s.channels.valueIterator();
        while (oit.next()) |cs| if (cs.*.info.guild == id and id != 0) orphans.append(s.gpa, cs.*.info.id) catch {};
        for (orphans.items) |ch| s.removeChannel(ch);
        for (s.guilds.items, 0..) |g, i| {
            if (g.id != id) continue;
            freeGuildInfo(g);
            _ = s.guilds.orderedRemove(i);
            if (s.member_lists.fetchRemove(id)) |kv| {
                var ml = kv.value;
                ml.items.deinit(s.gpa);
            }
            // Cargos e membros daquele servidor também saem.
            var gone: std.ArrayList(Id) = .empty;
            defer gone.deinit(s.gpa);
            var ri = s.roles.iterator();
            while (ri.next()) |e| if (e.value_ptr.guild == id) gone.append(s.gpa, e.key_ptr.*) catch {};
            for (gone.items) |rid| if (s.roles.fetchRemove(rid)) |kv| ev_alloc.free(kv.value.name);
            var keys: std.ArrayList([2]Id) = .empty;
            defer keys.deinit(s.gpa);
            var mi = s.members.keyIterator();
            while (mi.next()) |k| if (k.*[0] == id) keys.append(s.gpa, k.*) catch {};
            for (keys.items) |k| _ = s.members.remove(k);
            s.setEmojis(id, &.{});
            return;
        }
    }

    fn freeEmojis(list: []types.Emoji) void {
        for (list) |e| ev_alloc.free(e.name);
        if (list.len > 0) ev_alloc.free(list);
    }

    /// Troca os emojis de um servidor (assume a lista e os nomes).
    fn setEmojis(s: *Store, guild_id: Id, list: []types.Emoji) void {
        if (s.guild_emojis.fetchRemove(guild_id)) |kv| {
            for (kv.value) |e| _ = s.emoji_by_id.remove(e.id);
            freeEmojis(kv.value);
        }
        if (list.len == 0) return;
        s.guild_emojis.put(s.gpa, guild_id, list) catch return freeEmojis(list);
        for (list) |*e| {
            e.guild = guild_id;
            s.emoji_by_id.put(s.gpa, e.id, e.*) catch {};
        }
    }

    pub const EmojiUse = enum { ok, needs_nitro, unavailable };

    /// Dá para usar este emoji numa conversa de `guild_id` (0 = DM)? Sem Nitro
    /// só os do próprio servidor e nenhum animado; o Discord recusa o resto.
    pub fn emojiUse(s: *const Store, e: *const types.Emoji, guild_id: Id) EmojiUse {
        if (!e.available) return .unavailable;
        if (s.premium_type != 0) return .ok;
        return if (e.animated or e.guild != guild_id or guild_id == 0) .needs_nitro else .ok;
    }

    pub fn user(s: *const Store, id: Id) ?*const types.User {
        return s.users.getPtr(id);
    }

    pub fn channel(s: *const Store, id: Id) ?*ChannelState {
        return s.channels.get(id);
    }

    pub fn guild(s: *const Store, id: Id) ?*types.Guild {
        // Cada linha da lista de canais pergunta pelo mesmo servidor: o último
        // achado responde sem varrer (só confere o ID, então nunca fica velho).
        const items = s.guilds.items;
        if (guild_hint < items.len and items[guild_hint].id == id) return &items[guild_hint];
        for (items, 0..) |*g, i| if (g.id == id) {
            guild_hint = i;
            return g;
        };
        return null;
    }

    /// Temos esse cargo no servidor? (Todos: os do cartão de membro são só os 6 maiores.)
    pub fn hasRole(s: *const Store, guild_id: Id, role: Id) bool {
        if (s.my_roles.get(guild_id)) |list| return std.mem.indexOfScalar(Id, list, role) != null;
        const mi = s.memberInfo(guild_id, s.me) orelse return false;
        return std.mem.indexOfScalar(Id, mi.roleSlice(), role) != null;
    }

    pub fn channelsOf(s: *const Store, guild_id: Id) []const Id {
        return if (s.guild_channels.get(guild_id)) |l| l.items else &.{};
    }

    /// Todas as threads conhecidas de um canal, sem ordem garantida.
    pub fn threadsOf(s: *const Store, parent: Id) []const Id {
        return if (s.threads.getPtr(parent)) |ti| ti.all.items else &.{};
    }

    /// O índice de um canal pai, pronto para a lista de canais: a mais recente
    /// primeiro e o recorte refeito se algo mudou. Sem mudança, não custa nada.
    pub fn threadIndex(s: *Store, parent: Id) ?*ThreadIndex {
        const ti = s.threads.getPtr(parent) orelse return null;
        if (ti.dirty) s.refreshIndex(parent, ti);
        return ti;
    }

    /// Mais recente primeiro: a última mensagem, ou o ID (a criação) sem nenhuma.
    pub fn threadActivity(info: *const types.Channel) Id {
        return @max(info.id, if (info.thread) |t| t.last_message else 0);
    }

    fn refreshIndex(s: *Store, parent: Id, ti: *ThreadIndex) void {
        ti.dirty = false;
        const Sort = struct {
            s: *const Store,
            fn key(c: @This(), id: Id) Id {
                return if (c.s.channel(id)) |cs| threadActivity(&cs.info) else 0;
            }
            fn lt(c: @This(), a: Id, b: Id) bool {
                return c.key(a) > c.key(b);
            }
        };
        @import("sort.zig").stable(Id, ti.all.items, Sort{ .s = s }, Sort.lt);
        // Num fórum, cada post seria uma linha: só as nossas e as não lidas.
        const forum = if (s.channel(parent)) |p| p.info.kind == .forum else false;
        ti.n_shown = 0;
        ti.more = 0;
        ti.unread = false;
        for (ti.all.items) |id| {
            const cs = s.channel(id) orelse continue;
            const t = cs.info.thread orelse continue;
            if (t.archived) continue;
            if (forum and !t.joined and !cs.info.unread) continue;
            if (ti.n_shown == ti.shown.len) {
                if (!forum) ti.more += 1;
                continue;
            }
            ti.shown[ti.n_shown] = id;
            ti.n_shown += 1;
            ti.unread = ti.unread or cs.info.unread;
        }
    }

    /// Quem está na thread (vazio = não sabemos: a lista do pai vale).
    pub fn threadMembers(s: *const Store, thread: Id) []const Id {
        return if (s.thread_members.getPtr(thread)) |l| l.items else &.{};
    }

    /// Aplica um evento vindo da rede. O Store assume as alocações do evento.
    pub fn apply(s: *Store, ev: Event, now_ms: i64) !void {
        // O que chega o tempo todo e não aparece na caixa de entrada não conta.
        switch (ev) {
            .typing_start, .presence_update, .voice_state, .voice_member_flags, .voice_speaking, .voice_ping, .voice_audio, .voice_status, .latency, .status, .notice, .member_list, .profile, .relationship, .note, .app_icon, .pins, .pins_changed, .invite, .read, .thread_members, .thread_joined, .thread_open, .threads_page => {},
            else => s.rev +%= 1,
        }
        switch (ev) {
            // Quem cuida é a busca (ver App.afterEvent).
            .search_results, .invite_joined, .invite_created => {},
            .ready => |r| {
                s.me = r.me;
                s.me_rev +%= 1;
                if (r.username) |x| {
                    if (s.me_username) |old| ev_alloc.free(old);
                    s.me_username = x;
                }
                if (r.email) |x| {
                    if (s.me_email) |old| ev_alloc.free(old);
                    s.me_email = x;
                }
                s.premium_type = r.premium_type;
                for (r.users) |u| try s.mergeUser(u);
                for (r.guilds) |g| try s.mergeGuild(g);
                for (r.channels) |ch| try s.mergeChannel(ch);
                // READY é o retrato atual da conta: refaz os estados de voz
                // em vez de empilhar em cima do que sobrou da sessão anterior.
                var vit = s.channels.valueIterator();
                while (vit.next()) |cs| cs.*.voice_members.clearRetainingCapacity();
                s.voice_flags.clearRetainingCapacity();
                for (r.voice) |pair| {
                    if (s.channel(pair[0])) |cs| {
                        if (std.mem.indexOfScalar(Id, cs.voice_members.items, pair[1]) == null) {
                            try cs.voice_members.append(s.gpa, pair[1]);
                        }
                    }
                }
                ev_alloc.free(r.users);
                ev_alloc.free(r.guilds);
                ev_alloc.free(r.channels);
                ev_alloc.free(r.voice);
                s.ready = true;
            },
            .message_create => |m| {
                try s.addMessage(m, now_ms);
                budget_tick +%= 1;
                if (budget_tick % 100 == 0) s.enforceBudget(now_ms);
            },
            .history => |h| {
                defer ev_alloc.free(h.messages);
                const cs = s.channel(h.channel) orelse {
                    for (h.messages) |m| freeRaw(m);
                    return;
                };
                // Vazia e com `more` é falha (sem rede, 5xx...): uma página de
                // verdade sem nada diz `more = false`. Nada do que está na tela
                // (nem o cache do disco) se perde por causa disso.
                if (h.messages.len == 0 and h.more) {
                    if (h.around) {
                        cs.around = .failed;
                    } else if (h.newer) {
                        cs.newer = .idle;
                        cs.newer_retry_ms = now_ms + 5000;
                    } else if (h.older) {
                        cs.older = .idle;
                        cs.older_retry_ms = now_ms + 5000;
                    } else if (cs.detached) {
                        // Pediu para voltar ao presente e não veio: fica onde está.
                        cs.newer = .idle;
                        cs.newer_retry_ms = now_ms + 5000;
                    } else if (!cs.cached and cs.history != .loaded) {
                        cs.history = .failed;
                        cs.version +%= 1;
                    }
                    return;
                }
                if (h.around) return s.applyAround(cs, h.messages, now_ms);
                if (h.newer) return s.applyNewer(cs, h.messages, h.more, now_ms);
                // Página nova por cima do cache do disco: troca o cache pelo
                // que veio, mas fica com as do cache mais antigas que a página
                // quando as duas se encostam (a conversa não pula).
                var keep_before: Id = 0;
                const replacing = !h.older and cs.cached;
                if (replacing) {
                    cs.cached = false;
                    cs.older = .idle;
                    var newest_cached: Id = 0;
                    for (cs.messages.items) |m| if (m.from_cache) {
                        newest_cached = @max(newest_cached, m.msg.id);
                    };
                    if (h.messages.len > 0 and newest_cached >= h.messages[0].id) keep_before = h.messages[0].id;
                }
                const newest_page: Id = if (h.messages.len > 0) h.messages[h.messages.len - 1].id else 0;
                cs.info.last_message = @max(cs.info.last_message, newest_page);
                // Última página: voltou ao presente.
                if (!h.older) {
                    cs.detached = false;
                    cs.newer = .idle;
                }
                // O histórico vem antes do que já temos.
                var fresh: std.ArrayList(StoredMessage) = .empty;
                try fresh.ensureTotalCapacity(s.gpa, h.messages.len + cs.messages.items.len);
                if (replacing) for (cs.messages.items) |m| if (m.from_cache and m.msg.id < keep_before) fresh.appendAssumeCapacity(m);
                for (h.messages) |m| fresh.appendAssumeCapacity(try s.stored(m));
                for (cs.messages.items) |*m| {
                    if (replacing and m.from_cache) {
                        if (m.msg.id >= keep_before) s.freeMessage(m);
                        continue;
                    }
                    // Chegou ao vivo enquanto a página carregava e veio nela também.
                    if (!h.older and m.msg.id != 0 and m.msg.id <= newest_page) {
                        s.freeMessage(m);
                        continue;
                    }
                    fresh.appendAssumeCapacity(m.*);
                }
                cs.messages.deinit(s.gpa);
                cs.messages = fresh;
                cs.history = .loaded;
                cs.seen_ms = now_ms;
                defer s.enforceBudget(now_ms);
                if (h.older) {
                    cs.older = if (h.more and h.messages.len > 0) .idle else .done;
                } else {
                    if (!h.more) cs.older = .done;
                    s.trim(cs);
                }
                cs.version +%= 1;
            },
            .typing_start => |t| {
                const cs = s.channel(t.channel) orelse return;
                for (cs.typing.items) |*ty| if (ty.user == t.user) {
                    ty.until_ms = now_ms + 8000;
                    return;
                };
                try cs.typing.append(s.gpa, .{ .user = t.user, .until_ms = now_ms + 8000 });
            },
            .presence_update => |p| {
                if (s.users.getPtr(p.user)) |u| {
                    u.status = p.status;
                    if (p.activity) |a| {
                        if (u.activity) |old| ev_alloc.free(old);
                        u.activity = if (a.len == 0) null else a;
                    }
                } else if (p.activity) |a| {
                    // Usuário desconhecido: o texto veio alocado, não vaza.
                    if (a.len > 0) ev_alloc.free(@constCast(a));
                }
                if (p.activities) |list| {
                    if (list.len == 0 or s.users.get(p.user) == null) {
                        if (s.activities.fetchRemove(p.user)) |kv| freeActivities(kv.value);
                        freeActivities(list);
                    } else {
                        const gop = try s.activities.getOrPut(s.gpa, p.user);
                        if (gop.found_existing) freeActivities(gop.value_ptr.*);
                        gop.value_ptr.* = list;
                    }
                }
            },
            .voice_state => |v| {
                var it = s.channels.valueIterator();
                var stayed = false;
                while (it.next()) |cs| {
                    const list = &cs.*.voice_members;
                    for (list.items, 0..) |id, i| if (id == v.user) {
                        // Só mudou mudo/surdo: continua no mesmo lugar da lista.
                        if (v.channel == cs.*.info.id) {
                            stayed = true;
                        } else _ = list.orderedRemove(i);
                        break;
                    };
                }
                if (!stayed) if (v.channel) |id| if (s.channel(id)) |cs| try cs.voice_members.append(s.gpa, v.user);
                if (v.channel == null) {
                    _ = s.speaking.remove(v.user);
                    _ = s.voice_flags.remove(v.user);
                } else try s.voice_flags.put(s.gpa, v.user, v.flags);
            },
            .voice_member_flags => |v| try s.voice_flags.put(s.gpa, v.user, v.flags),
            .voice_ping, .voice_audio => {},
            .voice_speaking => |v| {
                if (v.speaking) {
                    try s.speaking.put(s.gpa, v.user, now_ms + 4000);
                } else _ = s.speaking.remove(v.user);
            },
            .voice_status => |v| {
                if (v.status == .disconnected) s.speaking.clearRetainingCapacity();
            },
            .latency => |l| s.latency_ms = l,
            .status => |st| s.connection = st,
            .notice => |n| ev_alloc.free(n),
            .send_failed => |f| if (s.pendingByNonce(f.channel, f.nonce)) |m| {
                m.failed = true;
                m.layout_w = -1;
                s.rev +%= 1;
            },
            .reaction_set => |rs| {
                const cs = s.channel(rs.channel) orelse return;
                const m = s.find(cs, rs.id) orelse return;
                for (m.reactions[0..m.n_reactions]) |*r| if (r.same(&rs.reaction)) {
                    r.* = rs.reaction;
                    m.layout_w = -1;
                    return;
                };
                if (m.n_reactions < m.reactions.len) {
                    m.reactions[m.n_reactions] = rs.reaction;
                    m.n_reactions += 1;
                    m.layout_w = -1;
                }
            },
            .user_upsert => |u| {
                if (s.users.getPtr(u.id)) |old| {
                    ev_alloc.free(u.name);
                    if (u.activity) |a| ev_alloc.free(a);
                    takeAvatar(old, u.avatar);
                    takeOpt(&old.decoration, u.decoration);
                    takeBot(old, u);
                    return;
                }
                try s.users.put(s.gpa, u.id, u);
            },
            .user_update => |u| try s.putUser(u),
            .guild_create => |gc| {
                defer {
                    ev_alloc.free(gc.channels);
                    ev_alloc.free(gc.voice);
                }
                try s.mergeGuild(gc.guild);
                for (gc.channels) |ch| try s.mergeChannel(ch);
                for (gc.channels) |ch| {
                    if (s.channel(ch.id)) |cs| cs.voice_members.clearRetainingCapacity();
                }
                for (gc.voice) |pair| {
                    if (s.channel(pair[0])) |cs| {
                        if (std.mem.indexOfScalar(Id, cs.voice_members.items, pair[1]) == null) {
                            try cs.voice_members.append(s.gpa, pair[1]);
                        }
                    }
                }
            },
            .guild_delete => |id| s.removeGuild(id),
            .channel_upsert => |ch| try s.mergeChannel(ch),
            .channel_delete => |id| s.removeChannel(id),
            .read => |r| s.applyAck(r.channel, r.message, r.manual),
            .read_states => |rs| {
                defer ev_alloc.free(rs.entries);
                s.read_index.clearRetainingCapacity();
                for (rs.entries) |e| try s.read_index.put(s.gpa, e.channel, e);
            },
            .gifs => |g| {
                const list = if (g.favorites) &s.gif_favorites else &s.gif_results;
                // A pessoa continuou digitando: esta resposta já é velha.
                if (g.req != list.req) return freeGifs(g.items);
                freeGifs(list.items);
                list.items = g.items;
                list.state = if (g.ok) .ready else .failed;
            },
            .pins => |p| {
                defer ev_alloc.free(p.messages);
                if (s.channel(p.channel) == null) {
                    for (p.messages) |m| freeRaw(m);
                    return;
                }
                const gop = try s.pins.getOrPut(s.gpa, p.channel);
                if (!gop.found_existing) gop.value_ptr.* = .{};
                const pl = gop.value_ptr;
                if (!p.ok) {
                    pl.state = .failed;
                    return;
                }
                for (pl.items.items) |*m| s.freeMessage(m);
                pl.items.clearRetainingCapacity();
                for (p.messages, 0..) |m, i| {
                    const sm = s.stored(m) catch |err| {
                        for (p.messages[i..]) |rest| freeRaw(rest);
                        return err;
                    };
                    try pl.items.append(s.gpa, sm);
                }
                pl.state = .loaded;
            },
            .pins_changed => |id| if (s.pins.getPtr(id)) |pl| {
                if (pl.state != .loading) pl.state = .none;
            },
            .invite => |inv| s.putInvite(inv.code.slice(), inv.invite),
            .reaction_clear => |rc| {
                const cs = s.channel(rc.channel) orelse return;
                const m = s.find(cs, rc.id) orelse return;
                if (rc.emoji) |e| {
                    for (m.reactions[0..m.n_reactions], 0..) |*r, i| {
                        if (!r.same(&e)) continue;
                        std.mem.copyForwards(types.Reaction, m.reactions[i .. m.n_reactions - 1], m.reactions[i + 1 .. m.n_reactions]);
                        m.n_reactions -= 1;
                        break;
                    }
                } else {
                    m.n_reactions = 0;
                }
                m.layout_w = -1;
                cs.version +%= 1;
            },
            .message_update => |up| {
                const found = if (s.channel(up.channel)) |cs| if (s.find(cs, up.id)) |m| .{ cs, m } else null else null;
                const cs, const m = found orelse {
                    if (up.pinned != null) if (s.pins.getPtr(up.channel)) |pl| {
                        if (pl.state == .loaded) pl.state = .none;
                    };
                    if (up.content) |t| ev_alloc.free(t);
                    if (up.raw) |t| ev_alloc.free(t);
                    if (up.embeds) |e| types.freeEmbeds(ev_alloc, e);
                    if (up.attachments) |a| types.freeAttachments(ev_alloc, a);
                    return;
                };
                if (up.pinned) |p| m.msg.pinned = p;
                if (up.content) |t| {
                    const spans = markdown.parseRaw(s.gpa, t, up.raw orelse "") catch {
                        ev_alloc.free(t);
                        if (up.raw) |x| ev_alloc.free(x);
                        return;
                    };
                    // Registro: guarda o texto de antes da primeira edição.
                    const same = std.mem.eql(u8, t, m.msg.content);
                    if (s.keep_log and !up.local and !same and m.original == null) {
                        m.original = m.msg.content;
                    } else ev_alloc.free(m.msg.content);
                    s.gpa.free(m.spans);
                    m.msg.content = t;
                    ev_alloc.free(m.msg.raw);
                    m.msg.raw = up.raw orelse "";
                    // Fixar também manda o texto, igual: isso não é edição.
                    if (!same) m.msg.edited = true;
                    m.spans = spans;
                }
                if (up.embeds) |e| {
                    types.freeEmbeds(ev_alloc, m.msg.embeds);
                    s.freeEmbedSpans(m.embed_spans);
                    m.msg.embeds = e;
                    m.embed_spans = s.parseEmbeds(e) catch &.{};
                }
                if (up.attachments) |a| merge: {
                    // Só imagens de embed (a atualização não trouxe os anexos):
                    // fica com os anexos de verdade que já tinha.
                    const only_embeds = for (a) |x| {
                        if (!x.embed) break false;
                    } else true;
                    if (only_embeds) {
                        var keep: usize = 0;
                        for (m.msg.attachments) |x| if (!x.embed) {
                            keep += 1;
                        };
                        const merged = ev_alloc.alloc(types.Attachment, keep + a.len) catch break :merge;
                        var k: usize = 0;
                        for (m.msg.attachments) |x| {
                            if (x.embed) {
                                types.freeAttachment(ev_alloc, x);
                                continue;
                            }
                            merged[k] = x;
                            k += 1;
                        }
                        @memcpy(merged[k..], a);
                        if (m.msg.attachments.len > 0) ev_alloc.free(m.msg.attachments);
                        if (a.len > 0) ev_alloc.free(a);
                        m.msg.attachments = merged;
                    } else {
                        types.freeAttachments(ev_alloc, m.msg.attachments);
                        m.msg.attachments = a;
                    }
                }
                m.layout_w = -1;
                cs.version +%= 1;
            },
            .message_delete => |del| {
                const cs = s.channel(del.channel) orelse return;
                for (cs.messages.items, 0..) |*m, i| if (m.msg.id == del.id) {
                    // Registro: apagada por alguém, continua na tela marcada.
                    if (s.keep_log and !del.local and m.msg.author != s.me) {
                        m.deleted = true;
                        m.layout_w = -1;
                        cs.version +%= 1;
                        return;
                    }
                    s.freeMessage(m);
                    _ = cs.messages.orderedRemove(i);
                    cs.version +%= 1;
                    if (cs.info.thread) |*t| {
                        t.message_count -|= 1;
                        s.touchThreads(cs.info.parent);
                    }
                    return;
                };
            },
            .reaction => |r| {
                const cs = s.channel(r.channel) orelse return;
                const m = s.find(cs, r.id) orelse return;
                s.react(m, r.emoji, r.user == s.me, r.add);
            },
            .guild_emojis => |ge| s.setEmojis(ge.guild, ge.emojis),
            .premium => |p| s.premium_type = p,
            .roles => |rs| {
                defer ev_alloc.free(rs.roles);
                for (rs.roles) |r| {
                    const gop = try s.roles.getOrPut(s.gpa, r.id);
                    if (gop.found_existing) ev_alloc.free(gop.value_ptr.name);
                    gop.value_ptr.* = r;
                }
            },
            .member_list => |ml| {
                defer {
                    for (ml.ops) |op| if (op.items.len > 0) ev_alloc.free(op.items);
                    ev_alloc.free(ml.ops);
                    if (ml.counts.len > 0) ev_alloc.free(ml.counts);
                }
                try s.applyMemberList(ml.guild, ml.list_id, ml.online, ml.total, ml.ops);
                // Quantos em cada grupo (os cabeçalhos "CARGO — N").
                if (s.member_lists.getPtr(ml.guild)) |list| for (list.items.items) |*it| if (it.* == .group) {
                    for (ml.counts) |gc| if (gc[0] == it.group.id) {
                        it.group.count = @intCast(@min(gc[1], std.math.maxInt(u32)));
                    };
                };
            },
            .member_info => |mi| try s.putMember(mi.guild, mi.user, mi.info),
            .my_roles => |mr| {
                const gop = try s.my_roles.getOrPut(s.gpa, mr.guild);
                if (gop.found_existing) ev_alloc.free(gop.value_ptr.*);
                gop.value_ptr.* = mr.roles;
            },
            .role_delete => |rid| if (s.roles.fetchRemove(rid)) |kv| ev_alloc.free(kv.value.name),
            .member_remove => |mr| {
                if (mr.user == s.me) s.me_rev +%= 1;
                _ = s.members.remove(.{ mr.guild, mr.user });
            },
            .guild_folders => |list| {
                freeFolders(s.folders);
                s.folders = list;
            },
            .profile => |pr| {
                // Teto de perfis guardados: passando, esquece todos (são
                // buscados de novo ao abrir o cartão).
                if (s.profiles.count() >= 256) {
                    var pit = s.profiles.valueIterator();
                    while (pit.next()) |old| freeProfile(old.*);
                    s.profiles.clearRetainingCapacity();
                    s.profiles_gen +%= 1;
                    var bit = s.bios.valueIterator();
                    while (bit.next()) |b| s.gpa.free(b.*);
                    s.bios.clearRetainingCapacity();
                }
                const gop = try s.profiles.getOrPut(s.gpa, pr.user);
                if (gop.found_existing) freeProfile(gop.value_ptr.*);
                gop.value_ptr.* = pr.profile;
                const spans = try markdown.parse(s.gpa, pr.profile.bio);
                const bg = try s.bios.getOrPut(s.gpa, pr.user);
                if (bg.found_existing) s.gpa.free(bg.value_ptr.*);
                bg.value_ptr.* = spans;
            },
            .relationship => |r| {
                if (r.kind == .none) {
                    _ = s.relationships.remove(r.user);
                    _ = s.friend_since.remove(r.user);
                } else try s.relationships.put(s.gpa, r.user, r.kind);
                if (r.kind == .friend and r.since_ms != 0) try s.friend_since.put(s.gpa, r.user, r.since_ms);
            },
            .note => |n| {
                const gop = try s.notes.getOrPut(s.gpa, n.user);
                if (gop.found_existing) ev_alloc.free(gop.value_ptr.*);
                gop.value_ptr.* = n.text;
            },
            .app_icon => |ai| {
                const gop = try s.app_icons.getOrPut(s.gpa, ai.app);
                if (gop.found_existing and gop.value_ptr.len > 0) ev_alloc.free(gop.value_ptr.*);
                gop.value_ptr.* = ai.icon;
            },
            .recent_mentions => |list| {
                defer ev_alloc.free(list);
                for (s.recent_mentions.items) |*m| s.freeMessage(m);
                s.recent_mentions.clearRetainingCapacity();
                for (list, 0..) |m, i| {
                    const sm = s.stored(m) catch |err| {
                        for (list[i..]) |rest| freeRaw(rest);
                        return err;
                    };
                    try s.recent_mentions.append(s.gpa, sm);
                }
                @import("sort.zig").stable(StoredMessage, s.recent_mentions.items, {}, struct {
                    fn lt(_: void, a: StoredMessage, b: StoredMessage) bool {
                        return a.msg.id > b.msg.id;
                    }
                }.lt);
                s.mentions_state = .loaded;
                s.mentions_ms = now_ms;
            },
            .thread_list_sync => |sy| {
                defer {
                    ev_alloc.free(sy.threads);
                    ev_alloc.free(sy.joined);
                    if (sy.parents) |p| ev_alloc.free(p);
                }
                // A que não veio não está mais ativa. Fica como arquivada, não
                // some: pode estar aberta numa aba.
                var alive: std.AutoHashMapUnmanaged(Id, void) = .empty;
                defer alive.deinit(s.gpa);
                for (sy.threads) |ch| try alive.put(s.gpa, ch.id, {});
                if (sy.parents) |list| {
                    for (list) |p| s.archiveMissing(p, &alive);
                } else for (s.channelsOf(sy.guild)) |p| s.archiveMissing(p, &alive);
                for (sy.threads) |ch| try s.mergeChannel(ch);
                for (sy.joined) |id| s.setJoined(id, true);
            },
            .threads_page => |pg| {
                defer {
                    ev_alloc.free(pg.threads);
                    ev_alloc.free(pg.joined);
                    ev_alloc.free(pg.previews);
                }
                for (pg.threads) |ch| try s.mergeChannel(ch);
                for (pg.joined) |id| s.setJoined(id, true);
                for (pg.previews) |p| {
                    const cs = s.channel(p.thread) orelse {
                        ev_alloc.free(p.text);
                        continue;
                    };
                    ev_alloc.free(cs.preview);
                    cs.preview = p.text;
                    cs.preview_author = p.author;
                }
                s.threads_rev +%= 1;
                const cs = s.channel(pg.channel) orelse return;
                const page = if (pg.archived) &cs.archived_page else &cs.active_page;
                if (pg.failed) {
                    page.state = .failed;
                    return;
                }
                page.state = .loaded;
                page.more = pg.more;
                page.offset += @intCast(pg.threads.len);
                for (pg.threads) |ch| if (ch.thread) |t| {
                    if (t.archive_ts != 0 and (page.before == 0 or t.archive_ts < page.before)) page.before = t.archive_ts;
                };
            },
            .thread_joined => |tj| s.setJoined(tj.thread, tj.joined),
            .thread_members => |tm| {
                defer {
                    ev_alloc.free(tm.added);
                    ev_alloc.free(tm.removed);
                }
                const cs = s.channel(tm.thread) orelse return;
                const gop = try s.thread_members.getOrPut(s.gpa, tm.thread);
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                const list = gop.value_ptr;
                if (tm.replace) list.clearRetainingCapacity();
                for (tm.added) |u| if (std.mem.indexOfScalar(Id, list.items, u) == null) try list.append(s.gpa, u);
                for (tm.removed) |u| if (std.mem.indexOfScalar(Id, list.items, u)) |i| {
                    _ = list.orderedRemove(i);
                };
                if (cs.info.thread) |*t| t.member_count = tm.count orelse @intCast(list.items.len);
                if (std.mem.indexOfScalar(Id, tm.added, s.me) != null) s.setJoined(tm.thread, true);
                if (std.mem.indexOfScalar(Id, tm.removed, s.me) != null) s.setJoined(tm.thread, false);
            },
            // Quem abre é o app (só depois de o canal estar aqui).
            .thread_open => {},
        }
    }

    fn setJoined(s: *Store, thread: Id, joined: bool) void {
        const cs = s.channel(thread) orelse return;
        const t = if (cs.info.thread) |*t| t else return;
        t.joined = joined;
        t.joined_known = true;
        s.touchThreads(cs.info.parent);
    }

    fn archiveMissing(s: *Store, parent: Id, alive: *const std.AutoHashMapUnmanaged(Id, void)) void {
        for (s.threadsOf(parent)) |id| {
            if (alive.contains(id)) continue;
            const cs = s.channel(id) orelse continue;
            if (cs.info.thread) |*t| t.archived = true;
        }
        s.touchThreads(parent);
    }

    fn applyMemberList(s: *Store, guild_id: Id, list_id: u64, online: u32, total: u32, ops: []const types.MemberOp) !void {
        const gop = try s.member_lists.getOrPut(s.gpa, guild_id);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        const ml = gop.value_ptr;
        // Lista de outro canal: só um SYNC novo vale (o resto é de antes).
        if (ml.list_id != list_id) {
            var has_sync = false;
            for (ops) |op| if (op.kind == .sync) {
                has_sync = true;
            };
            if (!has_sync and ml.synced) return;
            ml.items.clearRetainingCapacity();
            ml.list_id = list_id;
        }
        ml.online = online;
        ml.total = total;
        const items = &ml.items;
        for (ops) |op| switch (op.kind) {
            .sync => {
                const end: usize = @as(usize, op.index) + op.items.len;
                if (items.items.len < end) try items.appendNTimes(s.gpa, .none, end - items.items.len);
                @memcpy(items.items[op.index..end], op.items);
                ml.synced = true;
            },
            .invalidate => {
                const end = @min(items.items.len, @as(usize, op.end) + 1);
                if (op.index < end) @memset(items.items[op.index..end], .none);
            },
            .insert => if (op.items.len > 0) {
                if (op.index >= items.items.len) {
                    try items.appendNTimes(s.gpa, .none, op.index - items.items.len);
                    try items.append(s.gpa, op.items[0]);
                } else try items.insert(s.gpa, op.index, op.items[0]);
            },
            .update => if (op.items.len > 0 and op.index < items.items.len) {
                items.items[op.index] = op.items[0];
            },
            .delete => if (op.index < items.items.len) {
                _ = items.orderedRemove(op.index);
            },
        };
        // Guarda cor e cargos de quem apareceu (nome nas mensagens, perfil).
        for (items.items) |it| if (it == .member)
            try s.putMember(guild_id, it.member.user, it.member.info);
    }

    /// Os nossos cargos mudaram: menções a cargo podem ter mudado.
    fn putMember(s: *Store, guild_id: Id, user_id: Id, info: types.MemberInfo) !void {
        if (user_id == s.me) {
            const same = if (s.members.get(.{ guild_id, user_id })) |old| std.mem.eql(Id, old.roleSlice(), info.roleSlice()) else false;
            if (!same) {
                s.me_rev +%= 1;
                s.rev +%= 1;
            }
        }
        try s.members.put(s.gpa, .{ guild_id, user_id }, info);
    }

    pub fn memberList(s: *const Store, guild_id: Id) ?*MemberList {
        return s.member_lists.getPtr(guild_id);
    }

    /// Cor do nome de alguém num servidor (0 = sem cor de cargo).
    pub fn nameColor(s: *const Store, guild_id: Id, user_id: Id) u32 {
        return if (s.memberInfo(guild_id, user_id)) |m| m.color else 0;
    }

    pub fn memberInfo(s: *const Store, guild_id: Id, user_id: Id) ?types.MemberInfo {
        if (guild_id == 0) return null;
        return s.members.get(.{ guild_id, user_id });
    }

    /// Servidores na ordem da barra lateral: primeiro os que não estão na
    /// lista de pastas (novos, como faz o Discord), depois a ordem dela.
    /// Cada item é um servidor solto ou uma pasta.
    pub const RailItem = union(enum) { guild: *types.Guild, folder: *const types.GuildFolder };

    pub fn railOrder(s: *const Store, out: []RailItem) []RailItem {
        var n: usize = 0;
        for (s.guilds.items) |*g| {
            if (n == out.len) break;
            const listed = for (s.folders) |f| {
                if (std.mem.indexOfScalar(Id, f.guilds, g.id) != null) break true;
            } else false;
            if (!listed) {
                out[n] = .{ .guild = g };
                n += 1;
            }
        }
        for (s.folders) |*f| {
            if (n == out.len) break;
            if (f.id == 0) {
                for (f.guilds) |gid| if (s.guild(gid)) |g| if (n < out.len) {
                    out[n] = .{ .guild = g };
                    n += 1;
                };
                continue;
            }
            // Pasta sem nenhum servidor que ainda existe: some.
            const any = for (f.guilds) |gid| {
                if (s.guild(gid) != null) break true;
            } else false;
            if (!any) continue;
            out[n] = .{ .folder = f };
            n += 1;
        }
        return out[0..n];
    }

    /// Nossas permissões no servidor (sem contar as exceções por canal).
    pub fn permissions(s: *const Store, guild_id: Id) u64 {
        const g = s.guild(guild_id) orelse return 0;
        if (g.owner != 0 and g.owner == s.me) return std.math.maxInt(u64);
        // @everyone tem o mesmo ID do servidor.
        var p: u64 = if (s.roles.get(guild_id)) |r| r.permissions else 0;
        if (s.my_roles.get(guild_id)) |list| {
            for (list) |rid| if (s.roles.get(rid)) |r| {
                p |= r.permissions;
            };
        } else if (s.memberInfo(guild_id, s.me)) |mi| for (mi.roleSlice()) |rid| {
            if (s.roles.get(rid)) |r| p |= r.permissions;
        };
        if (p & types.perm.administrator != 0) return std.math.maxInt(u64);
        return p;
    }

    /// Nossas permissões num canal: as do servidor com as exceções do canal
    /// (@everyone, depois os nossos cargos juntos, depois a gente), como o
    /// Discord calcula. Sem saber os cargos do servidor ainda, libera tudo
    /// (melhor não trancar um canal à toa).
    pub fn channelPermissions(s: *const Store, ch: *const types.Channel) u64 {
        const all = std.math.maxInt(u64);
        if (ch.guild == 0) return all;
        // Thread não tem exceções próprias: vale o que vale no canal pai.
        if (ch.thread != null) if (ch.parent) |pid| if (s.channel(pid)) |pcs| return s.channelPermissions(&pcs.info);
        if (s.roles.get(ch.guild) == null) return all;
        var p = s.permissions(ch.guild);
        if (p & types.perm.administrator != 0 or p == all) return all;
        var role_allow: u64 = 0;
        var role_deny: u64 = 0;
        const mine = s.my_roles.get(ch.guild) orelse &.{};
        for (ch.overwrites) |o| {
            if (o.member) continue;
            if (o.id == ch.guild) {
                p = (p & ~o.deny) | o.allow;
            } else if (std.mem.indexOfScalar(Id, mine, o.id) != null) {
                role_allow |= o.allow;
                role_deny |= o.deny;
            }
        }
        p = (p & ~role_deny) | role_allow;
        for (ch.overwrites) |o| if (o.member and o.id == s.me) {
            p = (p & ~o.deny) | o.allow;
        };
        return p;
    }

    /// Dá para abrir o canal? (ver; e, num de voz, também entrar)
    pub fn canAccess(s: *const Store, ch: *const types.Channel) bool {
        const p = s.channelPermissions(ch);
        if (p & types.perm.view_channel == 0) return false;
        if (ch.kind == .voice and p & types.perm.connect == 0) return false;
        return true;
    }

    pub fn canSend(s: *const Store, ch: *const types.Channel) bool {
        const p = s.channelPermissions(ch);
        // Numa thread a permissão é outra; trancada, só quem gerencia threads.
        if (ch.thread) |t| {
            if (p & types.perm.send_messages_in_threads == 0) return false;
            return !t.locked or p & types.perm.manage_threads != 0;
        }
        return p & types.perm.send_messages != 0;
    }

    /// "Criar thread" a partir de uma mensagem deste canal.
    pub fn canCreateThread(s: *const Store, ch: *const types.Channel) bool {
        if (ch.guild == 0 or ch.thread != null or ch.kind != .text) return false;
        return s.channelPermissions(ch) & types.perm.create_public_threads != 0;
    }

    /// Post novo: num fórum, quem pode "enviar mensagens" é quem pode postar.
    pub fn canPost(s: *const Store, forum: *const types.Channel) bool {
        return forum.kind == .forum and s.channelPermissions(forum) & types.perm.send_messages != 0;
    }

    pub fn can(s: *const Store, guild_id: Id, bit: u64) bool {
        return guild_id != 0 and s.permissions(guild_id) & bit != 0;
    }

    /// Posição do nosso cargo mais alto (só se mexe em cargos abaixo dele).
    pub fn topRolePosition(s: *const Store, guild_id: Id) i32 {
        const g = s.guild(guild_id) orelse return 0;
        if (g.owner == s.me) return std.math.maxInt(i32);
        var top: i32 = 0;
        if (s.memberInfo(guild_id, s.me)) |mi| for (mi.roleSlice()) |rid| {
            if (s.roles.get(rid)) |r| top = @max(top, r.position);
        };
        return top;
    }

    /// Dar/tirar um cargo, na hora (o servidor confirma depois).
    pub fn memberRoleLocal(s: *Store, guild_id: Id, user_id: Id, role: Id, add: bool) !void {
        const gop = try s.members.getOrPut(s.gpa, .{ guild_id, user_id });
        if (!gop.found_existing) gop.value_ptr.* = .{};
        const mi = gop.value_ptr;
        const has = std.mem.indexOfScalar(Id, mi.roleSlice(), role);
        if (add and has == null and mi.n_roles < mi.roles.len) {
            mi.roles[mi.n_roles] = role;
            mi.n_roles += 1;
        } else if (!add) if (has) |i| {
            std.mem.copyForwards(Id, mi.roles[i .. mi.n_roles - 1], mi.roles[i + 1 .. mi.n_roles]);
            mi.n_roles -= 1;
        };
        // Cor do nome: a do cargo mais alto com cor.
        var best: i32 = std.math.minInt(i32);
        mi.color = 0;
        for (mi.roleSlice()) |rid| if (s.roles.get(rid)) |r| if (r.color != 0 and r.position > best) {
            best = r.position;
            mi.color = r.color;
        };
    }

    pub fn relationship(s: *const Store, user_id: Id) types.Relationship {
        return s.relationships.get(user_id) orelse .none;
    }

    pub fn find(s: *const Store, cs: *ChannelState, id: Id) ?*StoredMessage {
        _ = s;
        const items = cs.messages.items;
        // As últimas podem estar pendentes (id 0, confirmadas fora de ordem);
        // o resto está em ordem de ID: busca binária.
        const tail_start = items.len -| 16;
        var i = items.len;
        while (i > tail_start) {
            i -= 1;
            if (items[i].msg.id == id) return &items[i];
        }
        var lo: usize = 0;
        var hi: usize = tail_start;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            // Uma que não foi enviada (id 0) pode ter ficado aqui no meio.
            var k = mid;
            while (k < hi and items[k].msg.id == 0) k += 1;
            if (k == hi) {
                hi = mid;
                continue;
            }
            const v = items[k].msg.id;
            if (v == id) return &items[k];
            if (v < id) lo = k + 1 else hi = mid;
        }
        return null;
    }

    /// Procura primeiro no canal dado (uma resposta quase sempre cita o
    /// próprio canal) e depois em todos.
    pub fn findNear(s: *const Store, channel_id: Id, id: Id) ?struct { cs: *ChannelState, m: *StoredMessage } {
        if (s.channel(channel_id)) |cs| if (s.find(cs, id)) |m| return .{ .cs = cs, .m = m };
        const f = s.findAny(id) orelse return null;
        return .{ .cs = f.cs, .m = f.m };
    }

    /// Procura uma mensagem em qualquer canal carregado.
    pub fn findAny(s: *const Store, id: Id) ?struct { cs: *ChannelState, m: *StoredMessage } {
        var it = s.channels.valueIterator();
        while (it.next()) |cs| if (s.find(cs.*, id)) |m| return .{ .cs = cs.*, .m = m };
        return null;
    }

    /// Soma ou tira uma reação. `mine` indica se foi a gente.
    pub fn react(s: *Store, m: *StoredMessage, emoji: types.Reaction, mine: bool, add: bool) void {
        _ = s;
        for (m.reactions[0..m.n_reactions], 0..) |*r, i| if (r.same(&emoji)) {
            if (add) {
                if (mine and r.me) return;
                r.count +|= 1;
                if (mine) r.me = true;
            } else {
                if (mine and !r.me) return;
                r.count -|= 1;
                if (mine) r.me = false;
                if (r.count == 0) {
                    std.mem.copyForwards(types.Reaction, m.reactions[i .. m.n_reactions - 1], m.reactions[i + 1 .. m.n_reactions]);
                    m.n_reactions -= 1;
                }
            }
            m.layout_w = -1;
            return;
        };
        if (!add or m.n_reactions >= m.reactions.len) return;
        var r = emoji;
        r.count = 1;
        r.me = mine;
        m.reactions[m.n_reactions] = r;
        m.n_reactions += 1;
        m.layout_w = -1;
    }

    /// Edição local imediata (o servidor confirma depois).
    /// `raw`: o texto de verdade, se difere do que aparece.
    pub fn editLocal(s: *Store, channel_id: Id, id: Id, content: []const u8, raw: ?[]const u8) !void {
        const owned = try ev_alloc.dupe(u8, content);
        errdefer ev_alloc.free(owned);
        const raw_owned = if (raw) |t| try ev_alloc.dupe(u8, t) else null;
        try s.apply(.{ .message_update = .{ .channel = channel_id, .id = id, .content = owned, .raw = raw_owned, .local = true } }, 0);
    }

    /// A cópia local de uma mensagem nossa ainda sem confirmação.
    pub fn pendingByNonce(s: *const Store, channel_id: Id, nonce: u64) ?*StoredMessage {
        const cs = s.channel(channel_id) orelse return null;
        var i = cs.messages.items.len;
        while (i > 0) {
            i -= 1;
            const m = &cs.messages.items[i];
            if (m.pending and m.msg.nonce == nonce) return m;
        }
        return null;
    }

    /// Joga fora uma mensagem que não foi enviada.
    pub fn discardPending(s: *Store, channel_id: Id, nonce: u64) void {
        const cs = s.channel(channel_id) orelse return;
        const m = s.pendingByNonce(channel_id, nonce) orelse return;
        const i = (@intFromPtr(m) - @intFromPtr(cs.messages.items.ptr)) / @sizeOf(StoredMessage);
        s.freeMessage(m);
        _ = cs.messages.orderedRemove(i);
        cs.version +%= 1;
        s.rev +%= 1;
    }

    fn addMessage(s: *Store, m: types.Message, now_ms: i64) !void {
        const cs = s.channel(m.channel) orelse return freeRaw(m);
        // Já temos (o histórico trouxe antes de o evento ser lido, ou um
        // RESUME repetiu): duas cópias deixariam um fantasma ao apagar.
        if (m.id != 0 and s.find(cs, m.id) != null) return freeRaw(m);
        s.noteThreadMessage(cs, m);
        // Quem mandou parou de digitar.
        for (cs.typing.items, 0..) |ty, i| if (ty.user == m.author) {
            _ = cs.typing.swapRemove(i);
            break;
        };
        _ = now_ms;
        const prev_last = cs.info.last_message;
        cs.info.last_message = @max(prev_last, m.id);
        // Falar é ter lido: o Discord marca sozinho quando mandamos.
        if (m.author == s.me and m.id != 0) {
            cs.read_id = @max(cs.read_id, m.id);
            cs.info.unread = false;
            cs.hold_unread = false;
            // A linha fica no lugar (a conversa não pula); o botão do topo sai.
            cs.divider_seen = true;
            s.refreshGuildUnread(cs.info.guild);
        }
        // Confirmação de uma mensagem nossa: troca a cópia pendente.
        if (m.nonce != 0) {
            for (cs.messages.items, 0..) |*sm, at| if (sm.pending and sm.msg.nonce == m.nonce) {
                var msg = m;
                // Sem anexos na confirmação (demonstração): fica com os locais.
                if (msg.attachments.len == 0) {
                    msg.attachments = sm.msg.attachments;
                    sm.msg.attachments = &.{};
                }
                const fresh = try s.stored(msg);
                s.freeMessage(sm);
                sm.* = fresh;
                // Upload demorado: outras chegaram depois dela. A busca conta
                // com a ordem por ID, então ela vai para o lugar certo.
                var k = at;
                const items = cs.messages.items;
                while (k + 1 < items.len and items[k + 1].msg.id != 0 and items[k + 1].msg.id < items[k].msg.id) : (k += 1) {
                    std.mem.swap(StoredMessage, &items[k], &items[k + 1]);
                }
                cs.version +%= 1;
                return;
            };
        }
        if (m.author != s.me and m.channel != 0) {
            // Estava tudo lido: o marcador é a última de antes desta.
            if (!cs.info.unread and prev_last > cs.read_id) cs.read_id = prev_last;
            if (!cs.info.unread) {
                if (read_debug) std.log.info("leitura: canal {d} (servidor {d}) acendeu: mensagem nova {d}", .{ m.channel, cs.info.guild, m.id });
                cs.info.unread = true;
                s.refreshGuildUnread(cs.info.guild);
            }
        }
        // A conversa na tela é do passado: a nova fica só na contagem (o
        // caminho de volta traz ela).
        if (cs.detached) {
            freeRaw(m);
            cs.version +%= 1;
            return;
        }
        try cs.messages.append(s.gpa, try s.stored(m));
        s.trim(cs);
        cs.version +%= 1;
    }

    /// Página em volta de uma mensagem: substitui a lista (as pendentes ficam).
    /// Se não chega na última mensagem do canal, a conversa fica fora do presente.
    fn applyAround(s: *Store, cs: *ChannelState, msgs: []const types.Message, now_ms: i64) !void {
        cs.around = .done;
        if (msgs.len == 0) return;
        var fresh: std.ArrayList(StoredMessage) = .empty;
        errdefer fresh.deinit(s.gpa);
        try fresh.ensureTotalCapacity(s.gpa, msgs.len + cs.messages.items.len);
        for (msgs) |m| fresh.appendAssumeCapacity(try s.stored(m));
        for (cs.messages.items) |*m| {
            if (m.pending) {
                fresh.appendAssumeCapacity(m.*);
            } else s.freeMessage(m);
        }
        cs.messages.deinit(s.gpa);
        cs.messages = fresh;
        const newest = msgs[msgs.len - 1].id;
        cs.info.last_message = @max(cs.info.last_message, newest);
        cs.detached = newest < cs.info.last_message;
        cs.history = .loaded;
        cs.cached = false;
        cs.older = .idle;
        cs.older_retry_ms = 0;
        cs.newer = .idle;
        cs.newer_retry_ms = 0;
        cs.seen_ms = now_ms;
        cs.version +%= 1;
        s.enforceBudget(now_ms);
    }

    /// Página depois da mais nova que temos. Acabou (e não chegou nada depois
    /// do que ela traz): de volta ao presente.
    fn applyNewer(s: *Store, cs: *ChannelState, msgs: []const types.Message, more: bool, now_ms: i64) !void {
        cs.newer = .idle;
        // Depois das que têm ID, antes das pendentes.
        var at: usize = cs.messages.items.len;
        while (at > 0 and cs.messages.items[at - 1].msg.id == 0) at -= 1;
        var newest: Id = if (at > 0) cs.messages.items[at - 1].msg.id else 0;
        for (msgs) |m| {
            if (m.id <= newest) {
                freeRaw(m);
                continue;
            }
            try cs.messages.insert(s.gpa, at, try s.stored(m));
            at += 1;
            newest = m.id;
        }
        cs.info.last_message = @max(cs.info.last_message, newest);
        // Sem nada novo, a última mensagem que o Discord disse foi apagada.
        if (msgs.len == 0) {
            cs.detached = false;
        } else cs.detached = more or newest < cs.info.last_message;
        cs.seen_ms = now_ms;
        cs.version +%= 1;
    }

    /// Conversa lida do cache em disco, mostrada enquanto o histórico de
    /// verdade não chega (ele substitui o cache em `.history`). Assume os
    /// textos de cada mensagem (ev_alloc), não a lista; `reactions[i]` vai
    /// para `msgs[i]`.
    pub fn loadCached(s: *Store, cs: *ChannelState, msgs: []const types.Message, reactions: []const []const types.Reaction) !void {
        if (cs.history == .loaded) {
            for (msgs) |m| freeRaw(m);
            return;
        }
        const newest: Id = if (msgs.len > 0) msgs[msgs.len - 1].id else 0;
        var fresh: std.ArrayList(StoredMessage) = .empty;
        errdefer fresh.deinit(s.gpa);
        try fresh.ensureTotalCapacity(s.gpa, msgs.len + cs.messages.items.len);
        for (msgs, 0..) |m, i| {
            var sm = s.stored(m) catch {
                freeRaw(m);
                continue;
            };
            sm.from_cache = true;
            if (i < reactions.len) {
                const rs = reactions[i][0..@min(reactions[i].len, sm.reactions.len)];
                @memcpy(sm.reactions[0..rs.len], rs);
                sm.n_reactions = @intCast(rs.len);
            }
            fresh.appendAssumeCapacity(sm);
        }
        // As que chegaram ao vivo antes de abrir ficam depois (sem repetir).
        for (cs.messages.items) |*m| {
            if (m.msg.id != 0 and m.msg.id <= newest) {
                s.freeMessage(m);
                continue;
            }
            fresh.appendAssumeCapacity(m.*);
        }
        cs.messages.deinit(s.gpa);
        cs.messages = fresh;
        cs.history = .loaded;
        cs.cached = true;
        cs.version +%= 1;
        s.rev +%= 1;
    }

    /// Mostra na hora uma mensagem que acabamos de enviar.
    /// `attachments` passa a pertencer ao Store (alocado com o c_allocator).
    pub fn addPending(s: *Store, channel_id: Id, content: []const u8, nonce: u64, reply_to: Id, now_ms: i64, attachments: []const types.Attachment) !void {
        const cs = s.channel(channel_id) orelse return types.freeAttachments(ev_alloc, attachments);
        const owned = try ev_alloc.dupe(u8, content);
        // As fatias dos trechos apontam para `owned`, que vira o conteúdo.
        try cs.messages.append(s.gpa, .{
            .msg = .{ .id = 0, .channel = channel_id, .author = s.me, .timestamp = @divTrunc(now_ms, 1000), .content = owned, .nonce = nonce, .reply_to = reply_to, .attachments = attachments },
            .spans = try markdown.parse(s.gpa, owned),
            .pending = true,
        });
        s.trim(cs);
        cs.version +%= 1;
        s.rev +%= 1;
    }

    var guild_hint: usize = 0;
    var budget_tick: u32 = 0;

    fn enforceBudget(s: *Store, now_ms: i64) void {
        while (true) {
            var total: usize = 0;
            var victim: ?*ChannelState = null;
            var it = s.channels.valueIterator();
            while (it.next()) |cs| {
                total += cs.*.messages.items.len;
                // Só o que não aparece há pelo menos 30 s.
                if (cs.*.messages.items.len == 0 or now_ms - cs.*.seen_ms < 30_000) continue;
                if (victim == null or cs.*.seen_ms < victim.?.seen_ms) victim = cs.*;
            }
            if (total <= s.message_budget) return;
            s.unload(victim orelse return);
        }
    }

    /// Tira a conversa da memória (é buscada de novo quando voltar para a tela).
    pub fn unload(s: *Store, cs: *ChannelState) void {
        if (s.on_evict) |f| f(s, cs);
        for (cs.messages.items) |*m| s.freeMessage(m);
        cs.messages.clearAndFree(s.gpa);
        cs.history = .none;
        cs.older = .idle;
        cs.cached = false;
        cs.detached = false;
        cs.newer = .idle;
        cs.around = .idle;
        cs.version +%= 1;
        s.rev +%= 1;
    }

    fn trim(s: *Store, cs: *ChannelState) void {
        // Em lote: tirar uma de cada vez deslocaria o canal inteiro a cada
        // mensagem nova num canal movimentado.
        if (cs.reading or cs.messages.items.len <= s.max_messages + @min(trim_slack, s.max_messages / 8)) return;
        const drop = cs.messages.items.len - s.max_messages;
        // As cortadas podem ser buscadas de novo rolando para cima.
        if (cs.older == .done) cs.older = .idle;
        for (cs.messages.items[0..drop]) |*m| s.freeMessage(m);
        cs.messages.replaceRangeAssumeCapacity(0, drop, &.{});
    }

    /// Remove indicadores de "digitando" vencidos. Retorna true se mudou algo.
    pub fn expireTyping(s: *Store, now_ms: i64) bool {
        var changed = false;
        var it = s.channels.valueIterator();
        while (it.next()) |cs| {
            var i: usize = 0;
            while (i < cs.*.typing.items.len) {
                if (cs.*.typing.items[i].until_ms <= now_ms) {
                    _ = cs.*.typing.swapRemove(i);
                    changed = true;
                } else i += 1;
            }
        }
        return changed;
    }

    pub fn markRead(s: *Store, channel_id: Id) void {
        const cs = s.channel(channel_id) orelse return;
        if (cs.info.unread) {
            s.rev +%= 1;
            if (cs.info.thread != null) s.touchThreads(cs.info.parent);
        }
        cs.info.unread = false;
        cs.hold_unread = false;
        s.refreshGuildUnread(cs.info.guild);
        if (cs.info.last_message > cs.read_id) {
            cs.read_id = cs.info.last_message;
            s.rev +%= 1;
        }
        // Marcador: a última que já veio do servidor (a pendente não tem ID).
        var i = cs.messages.items.len;
        while (i > 0) {
            i -= 1;
            if (cs.messages.items[i].msg.id != 0) {
                if (cs.messages.items[i].msg.id > cs.read_id) {
                    cs.read_id = cs.messages.items[i].msg.id;
                    s.rev +%= 1;
                }
                return;
            }
        }
    }

    /// MESSAGE_ACK: lido até `message` (0 = até o fim). O eco atrasado de um
    /// ack nosso não volta o marcador; só o manual volta.
    pub fn applyAck(s: *Store, channel_id: Id, message: Id, manual: bool) void {
        if (message == 0) {
            s.rev +%= 1;
            return s.markRead(channel_id);
        }
        const cs = s.channel(channel_id) orelse return;
        const new_read = if (manual) message else @max(cs.read_id, message);
        const unread = cs.info.last_message > new_read;
        cs.hold_unread = manual and unread;
        if (new_read == cs.read_id and unread == cs.info.unread) return;
        if (read_debug and unread and !cs.info.unread) std.log.info("leitura: canal {d} (servidor {d}) acendeu: ack até {d}, última conhecida {d}, manual {}", .{ channel_id, cs.info.guild, message, cs.info.last_message, manual });
        cs.read_id = new_read;
        cs.info.unread = unread;
        s.refreshGuildUnread(cs.info.guild);
        s.rev +%= 1;
    }

    /// O ponto do servidor na barra: algum canal não lido e não silenciado.
    pub fn refreshGuildUnread(s: *Store, guild_id: Id) void {
        if (guild_id == 0) return;
        const g = s.guild(guild_id) orelse return;
        g.unread = false;
        for (s.channelsOf(guild_id)) |id| {
            const cs = s.channel(id) orelse continue;
            if (cs.info.kind != .text or !cs.info.unread) continue;
            if (s.muted) |set| if (set.contains(id)) continue;
            g.unread = true;
            return;
        }
    }
};

test "limite de mensagens por canal libera as antigas" {
    const c_alloc = std.heap.c_allocator;
    var s = Store.init(std.testing.allocator);
    defer s.deinit();
    s.max_messages = 3;

    const users = try c_alloc.alloc(types.User, 1);
    users[0] = .{ .id = 1, .name = try c_alloc.dupe(u8, "eu") };
    const guilds = try c_alloc.alloc(types.Guild, 0);
    const chans = try c_alloc.alloc(types.Channel, 1);
    chans[0] = .{ .id = 10, .guild = 5, .name = try c_alloc.dupe(u8, "geral"), .topic = try c_alloc.dupe(u8, "") };
    const voice = try c_alloc.alloc([2]Id, 0);
    try s.apply(.{ .ready = .{ .me = 1, .users = users, .guilds = guilds, .channels = chans, .voice = voice } }, 0);

    var i: u64 = 0;
    while (i < 5) : (i += 1) {
        const content = try c_alloc.dupe(u8, "oi");
        try s.apply(.{ .message_create = .{ .id = 100 + i, .channel = 10, .author = 2, .timestamp = 0, .content = content } }, 0);
    }
    const cs = s.channel(10).?;
    try std.testing.expectEqual(@as(usize, 3), cs.messages.items.len);
    try std.testing.expectEqual(@as(Id, 102), cs.messages.items[0].msg.id);
}

test "passando do teto de mensagens, sai a conversa esquecida há mais tempo" {
    const c_alloc = std.heap.c_allocator;
    var s = Store.init(std.testing.allocator);
    defer s.deinit();
    s.message_budget = 3;
    const users = try c_alloc.alloc(types.User, 1);
    users[0] = .{ .id = 1, .name = try c_alloc.dupe(u8, "eu") };
    const guilds = try c_alloc.alloc(types.Guild, 0);
    const chans = try c_alloc.alloc(types.Channel, 2);
    chans[0] = .{ .id = 10, .guild = 5, .name = try c_alloc.dupe(u8, "velho"), .topic = try c_alloc.dupe(u8, "") };
    chans[1] = .{ .id = 20, .guild = 5, .name = try c_alloc.dupe(u8, "aberto"), .topic = try c_alloc.dupe(u8, "") };
    try s.apply(.{ .ready = .{ .me = 1, .users = users, .guilds = guilds, .channels = chans, .voice = try c_alloc.alloc([2]Id, 0) } }, 0);
    for ([_]Id{ 10, 10, 20, 20 }, 0..) |ch, i| {
        try s.apply(.{ .message_create = .{ .id = 100 + i, .channel = ch, .author = 2, .timestamp = 0, .content = try c_alloc.dupe(u8, "oi") } }, 0);
    }
    const velho = s.channel(10).?;
    const aberto = s.channel(20).?;
    velho.seen_ms = 0;
    // O que apareceu há menos de 30 s não sai.
    aberto.seen_ms = 50_000;
    s.enforceBudget(60_000);
    try std.testing.expectEqual(@as(usize, 0), velho.messages.items.len);
    try std.testing.expectEqual(History.none, velho.history);
    try std.testing.expectEqual(@as(usize, 2), aberto.messages.items.len);
}

test "READY repetido funde estado e CHANNEL/GUILD_DELETE limpam" {
    const c_alloc = std.heap.c_allocator;
    var s = Store.init(std.testing.allocator);
    defer s.deinit();

    const us1 = try c_alloc.alloc(types.User, 1);
    us1[0] = .{ .id = 1, .name = try c_alloc.dupe(u8, "eu") };
    const g1 = try c_alloc.alloc(types.Guild, 1);
    g1[0] = .{ .id = 5, .name = try c_alloc.dupe(u8, "g"), .acronym = try c_alloc.dupe(u8, "G") };
    const c1 = try c_alloc.alloc(types.Channel, 1);
    c1[0] = .{ .id = 10, .guild = 5, .name = try c_alloc.dupe(u8, "geral"), .topic = try c_alloc.dupe(u8, "") };
    try s.apply(.{ .ready = .{ .me = 1, .users = us1, .guilds = g1, .channels = c1, .voice = try c_alloc.alloc([2]Id, 0) } }, 0);
    try s.apply(.{ .message_create = .{
        .id = 100,
        .channel = 10,
        .author = 2,
        .timestamp = 0,
        .content = try c_alloc.dupe(u8, "oi"),
    } }, 0);

    // Uma segunda sessão manda o mesmo servidor/canal + um canal novo.
    const us2 = try c_alloc.alloc(types.User, 1);
    us2[0] = .{ .id = 1, .name = try c_alloc.dupe(u8, "eu") };
    const g2 = try c_alloc.alloc(types.Guild, 1);
    g2[0] = .{ .id = 5, .name = try c_alloc.dupe(u8, "g"), .acronym = try c_alloc.dupe(u8, "G") };
    const c2 = try c_alloc.alloc(types.Channel, 2);
    c2[0] = .{ .id = 10, .guild = 5, .name = try c_alloc.dupe(u8, "geral"), .topic = try c_alloc.dupe(u8, "") };
    c2[1] = .{ .id = 11, .guild = 5, .name = try c_alloc.dupe(u8, "novo"), .topic = try c_alloc.dupe(u8, "") };
    try s.apply(.{ .ready = .{ .me = 1, .users = us2, .guilds = g2, .channels = c2, .voice = try c_alloc.alloc([2]Id, 0) } }, 0);

    try std.testing.expectEqual(@as(usize, 1), s.guilds.items.len);
    try std.testing.expectEqual(@as(usize, 2), s.channelsOf(5).len);
    try std.testing.expectEqual(@as(usize, 1), s.channel(10).?.messages.items.len);

    try s.apply(.{ .channel_delete = 11 }, 0);
    try std.testing.expect(s.channel(11) == null);
    try std.testing.expectEqual(@as(usize, 1), s.channelsOf(5).len);

    try s.apply(.{ .guild_delete = 5 }, 0);
    try std.testing.expect(s.channel(10) == null);
    try std.testing.expectEqual(@as(usize, 0), s.guilds.items.len);
}

test "presença, atividade e troca de nome não vazam" {
    const c_alloc = std.heap.c_allocator;
    var s = Store.init(std.testing.allocator);
    defer s.deinit();

    const us = try c_alloc.alloc(types.User, 1);
    us[0] = .{ .id = 1, .name = try c_alloc.dupe(u8, "eu") };
    try s.apply(.{ .ready = .{
        .me = 1,
        .users = us,
        .guilds = try c_alloc.alloc(types.Guild, 0),
        .channels = try c_alloc.alloc(types.Channel, 0),
        .voice = try c_alloc.alloc([2]Id, 0),
    } }, 0);

    try s.apply(.{ .presence_update = .{
        .user = 1,
        .status = .online,
        .activity = try c_alloc.dupe(u8, "Jogando X"),
    } }, 0);
    try std.testing.expectEqualStrings("Jogando X", s.user(1).?.activity.?);

    try s.apply(.{ .presence_update = .{ .user = 1, .status = .idle, .activity = "" } }, 0);
    try std.testing.expect(s.user(1).?.activity == null);

    try s.apply(.{ .user_update = .{
        .id = 1,
        .name = try c_alloc.dupe(u8, "novo"),
        .role = 2,
        .status = .offline,
    } }, 0);
    try std.testing.expectEqualStrings("novo", s.user(1).?.name);
    try std.testing.expectEqual(types.Status.idle, s.user(1).?.status);
}

test "mensagem pendente é confirmada pelo nonce" {
    const c_alloc = std.heap.c_allocator;
    var s = Store.init(std.testing.allocator);
    defer s.deinit();
    const chans = try c_alloc.alloc(types.Channel, 1);
    chans[0] = .{ .id = 10, .guild = 5, .name = try c_alloc.dupe(u8, "g"), .topic = try c_alloc.dupe(u8, "") };
    try s.apply(.{ .ready = .{ .me = 1, .users = try c_alloc.alloc(types.User, 0), .guilds = try c_alloc.alloc(types.Guild, 0), .channels = chans, .voice = try c_alloc.alloc([2]Id, 0) } }, 0);

    try s.addPending(10, "olá", 77, 0, 0, &.{});
    try std.testing.expect(s.channel(10).?.messages.items[0].pending);
    try s.apply(.{ .message_create = .{ .id = 5, .channel = 10, .author = 1, .timestamp = 0, .content = try c_alloc.dupe(u8, "olá"), .nonce = 77 } }, 0);
    const cs = s.channel(10).?;
    try std.testing.expectEqual(@as(usize, 1), cs.messages.items.len);
    try std.testing.expect(!cs.messages.items[0].pending);
}

test "reações, edição e exclusão" {
    const c_alloc = std.heap.c_allocator;
    var s = Store.init(std.testing.allocator);
    defer s.deinit();
    const chans = try c_alloc.alloc(types.Channel, 1);
    chans[0] = .{ .id = 10, .guild = 5, .name = try c_alloc.dupe(u8, "g"), .topic = try c_alloc.dupe(u8, "") };
    try s.apply(.{ .ready = .{ .me = 1, .users = try c_alloc.alloc(types.User, 0), .guilds = try c_alloc.alloc(types.Guild, 0), .channels = chans, .voice = try c_alloc.alloc([2]Id, 0) } }, 0);
    try s.apply(.{ .message_create = .{ .id = 7, .channel = 10, .author = 2, .timestamp = 0, .content = try c_alloc.dupe(u8, "oi") } }, 0);

    const r = types.Reaction.init("👍");
    try s.apply(.{ .reaction = .{ .channel = 10, .id = 7, .emoji = r, .user = 2, .add = true } }, 0);
    try s.apply(.{ .reaction = .{ .channel = 10, .id = 7, .emoji = r, .user = 1, .add = true } }, 0);
    const m = s.find(s.channel(10).?, 7).?;
    try std.testing.expectEqual(@as(u16, 2), m.reactions[0].count);
    try std.testing.expect(m.reactions[0].me);

    try s.editLocal(10, 7, "editado **agora**", null);
    try std.testing.expect(m.msg.edited);
    try std.testing.expectEqualStrings("editado **agora**", m.msg.content);

    try s.apply(.{ .message_delete = .{ .channel = 10, .id = 7 } }, 0);
    try std.testing.expectEqual(@as(usize, 0), s.channel(10).?.messages.items.len);
}

fn testMsgs(ids: []const Id, channel: Id) ![]types.Message {
    const c_alloc = std.heap.c_allocator;
    const out = try c_alloc.alloc(types.Message, ids.len);
    for (ids, out) |id, *m| m.* = .{ .id = id, .channel = channel, .author = 2, .timestamp = @intCast(id), .content = try c_alloc.dupe(u8, "x") };
    return out;
}

test "cache do disco aparece na hora e o histórico funde sem pular" {
    const c_alloc = std.heap.c_allocator;
    var s = Store.init(std.testing.allocator);
    defer s.deinit();
    const chans = try c_alloc.alloc(types.Channel, 1);
    chans[0] = .{ .id = 10, .guild = 5, .name = try c_alloc.dupe(u8, "g"), .topic = try c_alloc.dupe(u8, "") };
    try s.apply(.{ .ready = .{ .me = 1, .users = try c_alloc.alloc(types.User, 0), .guilds = try c_alloc.alloc(types.Guild, 0), .channels = chans, .voice = try c_alloc.alloc([2]Id, 0) } }, 0);
    const cs = s.channel(10).?;
    cs.history = .loading;

    // Cache: 100..105. Uma ao vivo (104, repetida) chegou antes de abrir.
    try s.apply(.{ .message_create = .{ .id = 104, .channel = 10, .author = 2, .timestamp = 0, .content = try c_alloc.dupe(u8, "ao vivo") } }, 0);
    const cached = try testMsgs(&.{ 100, 101, 102, 103, 104, 105 }, 10);
    defer c_alloc.free(cached);
    try s.loadCached(cs, cached, &.{});
    try std.testing.expect(cs.cached and cs.history == .loaded);
    try std.testing.expectEqual(@as(usize, 6), cs.messages.items.len);
    try std.testing.expect(cs.messages.items[0].from_cache);

    // Página do servidor 103..108: as do cache antes de 103 ficam, o resto troca.
    try s.apply(.{ .history = .{ .channel = 10, .messages = try testMsgs(&.{ 103, 104, 105, 106, 107, 108 }, 10) } }, 0);
    try std.testing.expect(!cs.cached);
    const ids = [_]Id{ 100, 101, 102, 103, 104, 105, 106, 107, 108 };
    try std.testing.expectEqual(ids.len, cs.messages.items.len);
    for (ids, cs.messages.items) |id, m| try std.testing.expectEqual(id, m.msg.id);
    try std.testing.expect(cs.messages.items[0].from_cache and !cs.messages.items[3].from_cache);

    // Mais antigas depois disso não apagam as do cache que ficaram.
    try s.apply(.{ .history = .{ .channel = 10, .messages = try testMsgs(&.{ 90, 91 }, 10), .older = true } }, 0);
    try std.testing.expectEqual(ids.len + 2, cs.messages.items.len);
    try std.testing.expectEqual(@as(Id, 100), cs.messages.items[2].msg.id);
}

test "cache sem encostar no histórico é trocado; sem rede, fica" {
    const c_alloc = std.heap.c_allocator;
    var s = Store.init(std.testing.allocator);
    defer s.deinit();
    const chans = try c_alloc.alloc(types.Channel, 1);
    chans[0] = .{ .id = 10, .guild = 5, .name = try c_alloc.dupe(u8, "g"), .topic = try c_alloc.dupe(u8, "") };
    try s.apply(.{ .ready = .{ .me = 1, .users = try c_alloc.alloc(types.User, 0), .guilds = try c_alloc.alloc(types.Guild, 0), .channels = chans, .voice = try c_alloc.alloc([2]Id, 0) } }, 0);
    const cs = s.channel(10).?;
    const cached = try testMsgs(&.{ 1, 2, 3 }, 10);
    defer c_alloc.free(cached);
    try s.loadCached(cs, cached, &.{});
    // Pedido falhou (página vazia, "pode ter mais"): o cache continua.
    try s.apply(.{ .history = .{ .channel = 10, .messages = &.{} } }, 0);
    try std.testing.expect(cs.cached);
    try std.testing.expectEqual(@as(usize, 3), cs.messages.items.len);
    // Página bem mais nova, sem encostar: o cache sai inteiro.
    try s.apply(.{ .history = .{ .channel = 10, .messages = try testMsgs(&.{ 50, 51 }, 10) } }, 0);
    try std.testing.expectEqual(@as(usize, 2), cs.messages.items.len);
    try std.testing.expectEqual(@as(Id, 50), cs.messages.items[0].msg.id);
}

fn testStore(s: *Store) !*ChannelState {
    const c_alloc = std.heap.c_allocator;
    const chans = try c_alloc.alloc(types.Channel, 1);
    chans[0] = .{ .id = 10, .guild = 5, .name = try c_alloc.dupe(u8, "g"), .topic = try c_alloc.dupe(u8, "") };
    try s.apply(.{ .ready = .{ .me = 1, .users = try c_alloc.alloc(types.User, 0), .guilds = try c_alloc.alloc(types.Guild, 0), .channels = chans, .voice = try c_alloc.alloc([2]Id, 0) } }, 0);
    return s.channel(10).?;
}

test "histórico que falhou não finge conversa vazia" {
    var s = Store.init(std.testing.allocator);
    defer s.deinit();
    const cs = try testStore(&s);
    cs.history = .loading;
    try s.apply(.{ .history = .{ .channel = 10, .messages = &.{} } }, 0);
    try std.testing.expectEqual(History.failed, cs.history);
    // Vazia de verdade (o Discord disse que acabou).
    cs.history = .loading;
    try s.apply(.{ .history = .{ .channel = 10, .messages = &.{}, .more = false } }, 0);
    try std.testing.expectEqual(History.loaded, cs.history);
    try s.apply(.{ .history = .{ .channel = 10, .messages = try testMsgs(&.{ 5, 6 }, 10), .more = true } }, 0);
    // Falha ao buscar de novo ou as antigas: o que está na tela fica.
    try s.apply(.{ .history = .{ .channel = 10, .messages = &.{} } }, 0);
    try std.testing.expectEqual(@as(usize, 2), cs.messages.items.len);
    try std.testing.expectEqual(History.loaded, cs.history);
    cs.older = .loading;
    try s.apply(.{ .history = .{ .channel = 10, .messages = &.{}, .older = true } }, 1000);
    try std.testing.expect(cs.older == .idle);
    try std.testing.expect(cs.older_retry_ms > 1000);
}

test "envio que falhou fica marcado e a busca continua achando as outras" {
    const c_alloc = std.heap.c_allocator;
    var s = Store.init(std.testing.allocator);
    defer s.deinit();
    const cs = try testStore(&s);
    cs.history = .loading;
    try s.apply(.{ .history = .{ .channel = 10, .messages = try testMsgs(&.{ 1, 2, 3 }, 10) } }, 0);
    try s.addPending(10, "oi", 77, 0, 0, &.{});
    try s.apply(.{ .send_failed = .{ .channel = 10, .nonce = 77 } }, 0);
    try std.testing.expect(s.pendingByNonce(10, 77).?.failed);
    // A que não foi (id 0) fica para trás, no meio da parte em ordem.
    var id: Id = 100;
    while (id < 140) : (id += 1) {
        try s.apply(.{ .message_create = .{ .id = id, .channel = 10, .author = 2, .timestamp = 1, .content = try c_alloc.dupe(u8, "x") } }, 0);
    }
    id = 100;
    while (id < 140) : (id += 1) try std.testing.expect(s.find(cs, id) != null);
    try std.testing.expect(s.find(cs, 1) != null);
    try std.testing.expect(s.find(cs, 99) == null);
    s.discardPending(10, 77);
    try std.testing.expect(s.pendingByNonce(10, 77) == null);
    try std.testing.expectEqual(@as(usize, 43), cs.messages.items.len);
}

test "voz: mudar mudo/surdo não muda o lugar na lista; sair esquece" {
    const gpa = std.testing.allocator;
    var s: Store = .{ .gpa = gpa };
    defer s.deinit();
    const c_alloc = std.heap.c_allocator;
    const chans = try c_alloc.alloc(types.Channel, 2);
    chans[0] = .{ .id = 10, .guild = 1, .name = try c_alloc.dupe(u8, "a"), .topic = try c_alloc.dupe(u8, ""), .kind = .voice };
    chans[1] = .{ .id = 11, .guild = 1, .name = try c_alloc.dupe(u8, "b"), .topic = try c_alloc.dupe(u8, ""), .kind = .voice };
    try s.apply(.{ .ready = .{ .me = 1, .users = try c_alloc.alloc(types.User, 0), .guilds = try c_alloc.alloc(types.Guild, 0), .channels = chans, .voice = try c_alloc.alloc([2]Id, 0) } }, 0);
    try s.apply(.{ .voice_state = .{ .channel = 10, .user = 5 } }, 0);
    try s.apply(.{ .voice_state = .{ .channel = 10, .user = 6 } }, 0);
    try s.apply(.{ .voice_state = .{ .channel = 10, .user = 5, .flags = .{ .mute = true } } }, 0);
    const list = s.channel(10).?.voice_members.items;
    try std.testing.expectEqualSlices(Id, &.{ 5, 6 }, list);
    try std.testing.expect(s.voiceFlags(5).serverMuted());
    try std.testing.expect(!s.voiceFlags(6).muted());
    // Mudou de canal: sai de um e entra no outro.
    try s.apply(.{ .voice_state = .{ .channel = 11, .user = 5, .flags = .{ .self_deaf = true } } }, 0);
    try std.testing.expectEqualSlices(Id, &.{6}, s.channel(10).?.voice_members.items);
    try std.testing.expectEqualSlices(Id, &.{5}, s.channel(11).?.voice_members.items);
    try std.testing.expect(s.voiceFlags(5).deafened() and s.voiceFlags(5).muted());
    // Saiu da call: esquece.
    try s.apply(.{ .voice_state = .{ .channel = null, .user = 5 } }, 0);
    try std.testing.expect(!s.voiceFlags(5).muted());
    try std.testing.expectEqual(@as(usize, 0), s.channel(11).?.voice_members.items.len);
    // Quem já estava na call ao conectar.
    try s.apply(.{ .voice_member_flags = .{ .user = 6, .flags = .{ .self_mute = true } } }, 0);
    try std.testing.expect(s.voiceFlags(6).self_mute);
}

test "confirmação atrasada vai para o lugar certo e nada duplica" {
    const c_alloc = std.heap.c_allocator;
    var s = Store.init(std.testing.allocator);
    defer s.deinit();
    const cs = try testStore(&s);
    cs.history = .loaded;
    try s.addPending(10, "com anexo", 9, 0, 0, &.{});
    try s.apply(.{ .message_create = .{ .id = 50, .channel = 10, .author = 2, .timestamp = 1, .content = try c_alloc.dupe(u8, "a") } }, 0);
    try s.apply(.{ .message_create = .{ .id = 60, .channel = 10, .author = 1, .timestamp = 1, .content = try c_alloc.dupe(u8, "com anexo"), .nonce = 9 } }, 0);
    try std.testing.expectEqual(@as(Id, 50), cs.messages.items[0].msg.id);
    try std.testing.expectEqual(@as(Id, 60), cs.messages.items[1].msg.id);
    // O evento chega depois de a mesma mensagem já ter vindo no histórico.
    try s.apply(.{ .message_create = .{ .id = 60, .channel = 10, .author = 1, .timestamp = 1, .content = try c_alloc.dupe(u8, "com anexo") } }, 0);
    try std.testing.expectEqual(@as(usize, 2), cs.messages.items.len);
}

test "editar guarda o texto de verdade (emoji personalizado)" {
    const c_alloc = std.heap.c_allocator;
    var s = Store.init(std.testing.allocator);
    defer s.deinit();
    const cs = try testStore(&s);
    cs.history = .loaded;
    try s.apply(.{ .message_create = .{ .id = 7, .channel = 10, .author = 1, .timestamp = 1, .content = try c_alloc.dupe(u8, ":pepe:"), .raw = try c_alloc.dupe(u8, "<:pepe:123>") } }, 0);
    const m = s.find(cs, 7).?;
    try std.testing.expectEqualStrings("<:pepe:123>", m.msg.editable());
    try s.editLocal(10, 7, "oi :pepe:", "oi <:pepe:123>");
    try std.testing.expectEqualStrings("oi :pepe:", m.msg.content);
    try std.testing.expectEqualStrings("oi <:pepe:123>", m.msg.editable());
    try s.editLocal(10, 7, "sem emoji", null);
    try std.testing.expectEqualStrings("sem emoji", m.msg.editable());
}

test "quem está lendo lá em cima não perde mensagens; cortadas voltam a ser buscáveis" {
    const c_alloc = std.heap.c_allocator;
    var s = Store.init(std.testing.allocator);
    defer s.deinit();
    s.max_messages = 8;
    const cs = try testStore(&s);
    cs.history = .loaded;
    cs.older = .done;
    cs.reading = true;
    var id: Id = 1;
    while (id <= 20) : (id += 1) {
        try s.apply(.{ .message_create = .{ .id = id, .channel = 10, .author = 2, .timestamp = 1, .content = try c_alloc.dupe(u8, "x") } }, 0);
    }
    try std.testing.expectEqual(@as(usize, 20), cs.messages.items.len);
    cs.reading = false;
    try s.apply(.{ .message_create = .{ .id = 21, .channel = 10, .author = 2, .timestamp = 1, .content = try c_alloc.dupe(u8, "x") } }, 0);
    try std.testing.expect(cs.messages.items.len < 21);
    try std.testing.expect(cs.older == .idle);
}

fn testThread(id: Id, parent: Id, last: Id) !types.Channel {
    const c_alloc = std.heap.c_allocator;
    return .{ .id = id, .guild = 5, .parent = parent, .name = try c_alloc.dupe(u8, "fio"), .topic = try c_alloc.dupe(u8, ""), .thread = .{ .last_message = last } };
}

test "thread fica fora da lista de canais, no índice do pai, e sai junto com ele" {
    const c_alloc = std.heap.c_allocator;
    var s = Store.init(std.testing.allocator);
    defer s.deinit();
    _ = try testStore(&s);
    try s.apply(.{ .channel_upsert = try testThread(100, 10, 7) }, 0);
    try s.apply(.{ .channel_upsert = try testThread(101, 10, 9) }, 0);
    try std.testing.expectEqual(@as(usize, 1), s.channelsOf(5).len);
    const ti = s.threadIndex(10).?;
    try std.testing.expectEqual(@as(u8, 2), ti.n_shown);
    // Sem mensagem, conta o ID (a criação): 101 é a mais recente.
    try std.testing.expectEqual(@as(Id, 101), ti.shown[0]);
    // Mensagem nova na 100: conta, sobe e marca não lida no recorte.
    try s.apply(.{ .message_create = .{ .id = 500, .channel = 100, .author = 2, .timestamp = 1, .content = try c_alloc.dupe(u8, "oi") } }, 0);
    const ti2 = s.threadIndex(10).?;
    try std.testing.expectEqual(@as(Id, 100), ti2.shown[0]);
    try std.testing.expect(ti2.unread);
    try std.testing.expectEqual(@as(u32, 1), s.channel(100).?.info.thread.?.message_count);
    // Pai apagado leva as threads.
    try s.apply(.{ .channel_delete = 10 }, 0);
    try std.testing.expect(s.channel(100) == null and s.channel(101) == null);
    try std.testing.expect(s.threadIndex(10) == null);
}

test "THREAD_LIST_SYNC arquiva o que não veio e THREAD_UPDATE não esquece que estamos nela" {
    const c_alloc = std.heap.c_allocator;
    var s = Store.init(std.testing.allocator);
    defer s.deinit();
    _ = try testStore(&s);
    try s.apply(.{ .channel_upsert = try testThread(100, 10, 0) }, 0);
    try s.apply(.{ .channel_upsert = try testThread(101, 10, 0) }, 0);
    const parents = try c_alloc.alloc(Id, 1);
    parents[0] = 10;
    const list = try c_alloc.alloc(types.Channel, 1);
    list[0] = try testThread(101, 10, 0);
    const joined = try c_alloc.alloc(Id, 1);
    joined[0] = 101;
    try s.apply(.{ .thread_list_sync = .{ .guild = 5, .parents = parents, .threads = list, .joined = joined } }, 0);
    try std.testing.expect(s.channel(100).?.info.thread.?.archived);
    try std.testing.expect(s.channel(101).?.info.thread.?.joined);
    try std.testing.expectEqual(@as(u8, 1), s.threadIndex(10).?.n_shown);
    try s.apply(.{ .channel_upsert = try testThread(101, 10, 0) }, 0);
    try std.testing.expect(s.channel(101).?.info.thread.?.joined);
    try s.apply(.{ .thread_joined = .{ .thread = 101, .joined = false } }, 0);
    try std.testing.expect(!s.channel(101).?.info.thread.?.joined);
}

test "permissões da thread vêm do pai" {
    const c_alloc = std.heap.c_allocator;
    var s = Store.init(std.testing.allocator);
    defer s.deinit();
    s.me = 1;
    const cs = try testStore(&s);
    const g = try c_alloc.alloc(types.Guild, 1);
    g[0] = .{ .id = 5, .name = try c_alloc.dupe(u8, "g"), .acronym = try c_alloc.dupe(u8, "G"), .owner = 9 };
    try s.apply(.{ .ready = .{ .me = 1, .users = try c_alloc.alloc(types.User, 0), .guilds = g, .channels = try c_alloc.alloc(types.Channel, 0), .voice = try c_alloc.alloc([2]Id, 0) } }, 0);
    const roles = try c_alloc.alloc(types.Role, 1);
    roles[0] = .{ .id = 5, .guild = 5, .name = try c_alloc.dupe(u8, "@everyone"), .permissions = types.perm.view_channel | types.perm.send_messages };
    try s.apply(.{ .roles = .{ .guild = 5, .roles = roles } }, 0);
    try s.apply(.{ .channel_upsert = try testThread(100, 10, 0) }, 0);
    const th = &s.channel(100).?.info;
    try std.testing.expect(s.canAccess(th));
    try std.testing.expect(!s.canSend(th));
    try std.testing.expect(!s.canCreateThread(&cs.info));
    // O pai trancado tranca a thread.
    const ow = try c_alloc.alloc(types.Overwrite, 1);
    ow[0] = .{ .id = 5, .deny = types.perm.view_channel };
    cs.info.overwrites = ow;
    try std.testing.expect(!s.canAccess(th));
}
