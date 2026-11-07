//! Imagens dos anexos: threads de mídia baixam e decodificam (stb_image para
//! PNG/JPEG/GIF/BMP, libwebp para WebP, APNG em apng.zig), a thread
//! principal só cria a textura. Pede ao proxy de mídia do Discord a imagem
//! já no tamanho em que vai aparecer (menos rede e menos memória), guarda as
//! texturas num cache com limite e solta o que não é visto há um tempo.
//!
//! Só baixa de domínios do Discord: um link qualquer na conversa não faz o
//! app se conectar a outro servidor (o que vazaria o seu IP).
const std = @import("std");
const c = @import("c");
const Queue = @import("../net/queue.zig").Queue;
const platform = @import("../platform/window.zig");
const media_url = @import("../net/media_url.zig");
const allowedHost = media_url.allowedHost;
const proxiedUrl = media_url.proxiedUrl;
const apng = @import("apng.zig");
const ffmpeg = @import("../platform/ffmpeg.zig");
const proxy = @import("../net/proxy.zig");
const janela = @import("../core/janela.zig");

const alloc = std.heap.c_allocator;

/// Tempo até soltar uma imagem fora da tela.
const idle_ms: i64 = 60_000;
/// Maior arquivo que a gente baixa (o Discord aceita até 10 MB sem Nitro).
const max_download: usize = 32 * 1024 * 1024;
/// Limite de uma animação (GIF, WebP, APNG) já reduzida: passando disso,
/// pula quadros (o tempo total continua o mesmo, só fica menos fluido).
/// As threads de mídia leem o limite, que vem das Configurações → Desempenho.
pub var gif_limit_bytes: std.atomic.Value(usize) = .init(12 * 1024 * 1024);
const max_gif_frames: usize = 300;
/// Teto de quadros lidos e de tempo decodificando uma animação: um GIF feito
/// para isso (centenas de milhares de quadros) para aqui, com o que já tem.
const max_gif_seen: usize = 20_000;
const max_decode_ms: u64 = 10_000;
/// Tempo por quadro criando texturas: o resto fica para o próximo quadro.
const upload_budget_ns: u64 = 4 * std.time.ns_per_ms;
/// 4 baixando, mas só 2 decodificando ao mesmo tempo (é o pico de memória e
/// de CPU: cada animação passa por quadros em tamanho cheio).
const workers = 4;
var decode_slots: ?*c.SDL_Semaphore = null;

pub const Tex = struct {
    ref: c.ImTextureRef,
    w: u16,
    h: u16,
    /// Tem mais de um quadro (GIF, WebP ou PNG animado).
    animated: bool = false,
};

pub const Lookup = union(enum) { loading, ready: Tex, failed };

const State = enum { loading, ready, failed };

const Frame = struct {
    tex: *c.SDL_Texture,
    /// Fim deste quadro, em ms desde o começo da animação.
    end_ms: u32,
};

const Entry = struct {
    state: State = .loading,
    frames: []Frame = &.{},
    w: u16 = 0,
    h: u16 = 0,
    bytes: usize = 0,
    used_ms: i64 = 0,

    fn free(e: *Entry) void {
        for (e.frames) |f| c.SDL_DestroyTexture(f.tex);
        if (e.frames.len > 0) alloc.free(e.frames);
        e.frames = &.{};
    }

    /// Nunca 0 (é divisor): `add`, `halve` e `pump` somam saturando.
    fn total(e: *const Entry) u32 {
        return if (e.frames.len == 0) 1 else @max(e.frames[e.frames.len - 1].end_ms, 1);
    }
};

/// Pedido de cópia: anda pela mesma fila, mas não entra no cache.
const clip_prefix = "clip:";

/// Uma cópia só, porque ela fica na memória enquanto estiver na área de transferência:
/// BMP no Windows, que é o formato de imagem dele, e PNG no resto.
const clip_is_bmp = @import("builtin").os.tag == .windows;
pub const clip_mime = if (clip_is_bmp) "image/bmp" else "image/png";

fn encoded(surface: *c.SDL_Surface) []u8 {
    const io = c.SDL_IOFromDynamicMem() orelse return &.{};
    defer _ = c.SDL_CloseIO(io);
    const ok = if (clip_is_bmp) c.SDL_SaveBMP_IO(surface, io, false) else c.SDL_SavePNG_IO(surface, io, false);
    if (!ok) return &.{};
    const size: usize = @intCast(@max(c.SDL_GetIOSize(io), 0));
    const data = c.SDL_GetPointerProperty(c.SDL_GetIOProperties(io), c.SDL_PROP_IOSTREAM_DYNAMIC_MEMORY_POINTER, null) orelse return &.{};
    return alloc.dupe(u8, @as([*]const u8, @ptrCast(data))[0..size]) catch &.{};
}

fn clipData(user: ?*anyopaque, _: [*c]const u8, size: [*c]usize) callconv(.c) ?*const anyopaque {
    const clip: *[]u8 = @ptrCast(@alignCast(user.?));
    size.* = clip.len;
    return clip.ptr;
}

fn clipCleanup(user: ?*anyopaque) callconv(.c) void {
    const clip: *[]u8 = @ptrCast(@alignCast(user.?));
    alloc.free(clip.*);
    alloc.destroy(clip);
}

const Job = struct {
    key: []u8,
    url: []u8,
    max_w: u16,
    max_h: u16,
};

/// Quadros decodificados (RGBA, w×h cada), no c_allocator.
const Pixels = struct {
    frames: []PixFrame = &.{},
    w: u16 = 0,
    h: u16 = 0,

    fn deinit(p: Pixels) void {
        for (p.frames) |f| alloc.free(f.data);
        if (p.frames.len > 0) alloc.free(p.frames);
    }

    /// Uma imagem só.
    fn single(data: []u8, w: usize, h: usize) Pixels {
        const fr = alloc.alloc(PixFrame, 1) catch {
            alloc.free(data);
            return .{};
        };
        fr[0] = .{ .data = data, .delay_ms = 0 };
        return .{ .frames = fr, .w = @intCast(w), .h = @intCast(h) };
    }
};

const PixFrame = struct { data: []u8, delay_ms: u32 };

const Result = struct {
    key: []u8,
    px: Pixels = .{},
};

/// Resultado virando texturas aos poucos (ver `pump`).
const Upload = struct {
    r: Result,
    frames: []Frame,
    n: usize = 0,
    end: u32 = 0,
};

const trim_after_bytes = 4 * 1024 * 1024;

pub const Cache = struct {
    renderer: *c.SDL_Renderer,
    wake_type: u32,
    map: std.StringHashMapUnmanaged(Entry) = .empty,
    jobs: Queue(Job),
    results: Queue(Result),
    /// Downloads em paralelo: com uma só, os avatares de uma lista de
    /// membros enfileiram e os ícones dos servidores demoram a aparecer.
    threads: [workers]?*c.SDL_Thread = @splat(null),
    stopping: std.atomic.Value(bool) = .init(false),
    bytes: usize = 0,
    now_ms: i64 = 0,
    /// Quando o próximo quadro de um GIF na tela vence (o laço do app acorda
    /// nessa hora em vez de redesenhar sem parar). Zerado a cada quadro.
    next_frame_ms: i64 = std.math.maxInt(i64),
    evicted_ms: i64 = 0,
    /// Hora do último quadro desenhado (o app marca). É contra ela que se mede
    /// o "não aparece há um tempo": depois de o app dormir mais de um minuto,
    /// o que está na tela não pode ser solto antes de o quadro novo pedir.
    drawn_ms: i64 = 0,
    backlog: std.ArrayList(Result) = .empty,
    uploading: ?Upload = null,
    /// Modo economia (atualizado a cada quadro pelo app): o que ainda não
    /// está no cache só baixa depois de um clique (`allow`).
    data_saver: bool = false,
    allowed: std.StringHashMapUnmanaged(void) = .empty,
    /// Bytes de imagem soltos desde a última devolução ao sistema.
    freed_bytes: usize = 0,
    /// O app olha isto depois de `pump` e pede a devolução.
    trim_due: bool = false,
    copying: bool = false,
    copied: ?bool = null,
    /// Limite de memória das imagens (Configurações → Desempenho).
    budget_bytes: usize = 32 * 1024 * 1024,

    pub fn init(renderer: *c.SDL_Renderer, wake_type: u32) !Cache {
        if (curl_mutex == null) curl_mutex = c.SDL_CreateMutex() orelse return error.SdlMutex;
        if (recent_mutex == null) recent_mutex = c.SDL_CreateMutex() orelse return error.SdlMutex;
        if (decode_slots == null) decode_slots = c.SDL_CreateSemaphore(2) orelse return error.SdlSemaphore;
        return .{
            .renderer = renderer,
            .wake_type = wake_type,
            .jobs = try Queue(Job).init(alloc),
            .results = try Queue(Result).init(alloc),
        };
    }

    /// Só com a primeira imagem pedida: a tela de login não usa nenhuma thread.
    fn startWorkers(cache: *Cache) void {
        if (cache.threads[0] != null) return;
        for (&cache.threads) |*t| {
            t.* = c.SDL_CreateThread(worker, "media", cache);
            if (t.* == null) std.log.warn("não consegui criar uma thread de imagens", .{});
        }
    }

    pub fn deinit(cache: *Cache) void {
        cache.stopping.store(true, .release);
        cache.jobs.wakeAll();
        for (cache.threads) |th| if (th) |t| c.SDL_WaitThread(t, null);
        if (curl_inited) {
            c.curl_global_cleanup();
            curl_inited = false;
        }
        for (cache.jobs.items.items) |jb| freeJob(jb);
        var rest: std.ArrayList(Result) = .empty;
        defer rest.deinit(alloc);
        cache.results.drain(&rest);
        for (rest.items) |r| freeResult(r);
        for (cache.backlog.items) |r| freeResult(r);
        cache.backlog.deinit(alloc);
        if (cache.uploading) |u| {
            for (u.frames[0..u.n]) |f| c.SDL_DestroyTexture(f.tex);
            alloc.free(u.frames);
            freeResult(u.r);
        }
        var it = cache.map.iterator();
        while (it.next()) |e| {
            e.value_ptr.free();
            alloc.free(e.key_ptr.*);
        }
        cache.map.deinit(alloc);
        var ait = cache.allowed.keyIterator();
        while (ait.next()) |k| alloc.free(k.*);
        cache.allowed.deinit(alloc);
        cache.jobs.deinit();
        cache.results.deinit();
    }

    /// A imagem de `url` cabendo em max_w×max_h. Pede se ainda não pediu.
    /// GIFs tocam sozinhos; `getStill` mostra o primeiro quadro.
    pub fn get(cache: *Cache, url: []const u8, max_w: f32, max_h: f32) Lookup {
        return cache.getEx(url, max_w, max_h, true);
    }

    pub fn getStill(cache: *Cache, url: []const u8, max_w: f32, max_h: f32) Lookup {
        return cache.getEx(url, max_w, max_h, false);
    }

    /// No modo economia, `url` ainda espera um clique para baixar (quem
    /// desenha mostra um "clique para carregar" no lugar).
    pub fn blocked(cache: *const Cache, url: []const u8) bool {
        if (!cache.data_saver or std.mem.startsWith(u8, url, "file://")) return false;
        return !cache.allowed.contains(url);
    }

    /// Libera `url` no modo economia (o clique no lugar da imagem).
    pub fn allow(cache: *Cache, url: []const u8) void {
        if (url.len == 0 or cache.allowed.contains(url) or cache.allowed.count() >= 4096) return;
        const owned = alloc.dupe(u8, url) catch return;
        cache.allowed.put(alloc, owned, {}) catch alloc.free(owned);
    }

    pub fn getEx(cache: *Cache, url: []const u8, max_w: f32, max_h: f32, play: bool) Lookup {
        // Tamanhos arredondados: quem pede 301 ou 330 de largura usa a mesma.
        const bw = media_url.sizeBucket(max_w);
        const bh = media_url.sizeBucket(max_h);
        var kbuf: [2200]u8 = undefined;
        const key = std.fmt.bufPrint(&kbuf, "{d}x{d} {s}", .{ bw, bh, url }) catch return .failed;
        if (cache.map.getPtr(key)) |e| {
            e.used_ms = cache.now_ms;
            return switch (e.state) {
                .loading => .loading,
                .failed => .failed,
                .ready => .{ .ready = .{ .ref = .{ ._TexData = null, ._TexID = @intFromPtr(cache.frameOf(e, play)) }, .w = e.w, .h = e.h, .animated = e.frames.len > 1 } },
            };
        }
        // Modo economia: nada de rede até a pessoa pedir.
        if (cache.blocked(url)) return .failed;
        const owned = alloc.dupe(u8, key) catch return .failed;
        cache.map.put(alloc, owned, .{ .used_ms = cache.now_ms }) catch {
            alloc.free(owned);
            return .failed;
        };
        const job: Job = .{
            .key = alloc.dupe(u8, key) catch return .failed,
            .url = alloc.dupe(u8, url) catch return .failed,
            .max_w = bw,
            .max_h = bh,
        };
        cache.startWorkers();
        cache.jobs.push(job);
        return .loading;
    }

    /// O quadro de agora (todos os GIFs andam no mesmo relógio) e quando
    /// o próximo vence.
    fn frameOf(cache: *Cache, e: *const Entry, play: bool) *c.SDL_Texture {
        if (e.frames.len == 1 or !play) return e.frames[0].tex;
        const total = e.total();
        const t: u32 = @intCast(@mod(cache.now_ms, @as(i64, total)));
        for (e.frames) |f| if (t < f.end_ms) {
            cache.next_frame_ms = @min(cache.next_frame_ms, cache.now_ms + (f.end_ms - t));
            return f.tex;
        };
        return e.frames[0].tex;
    }

    /// Copia a imagem para a área de transferência: baixa e decodifica fora da thread da
    /// interface, e o resultado sai em `takeCopied`.
    pub fn copyImage(cache: *Cache, url: []const u8) void {
        if (cache.copying) return;
        const key = std.fmt.allocPrint(alloc, clip_prefix ++ "{s}", .{url}) catch return;
        const owned_url = alloc.dupe(u8, url) catch {
            alloc.free(key);
            return;
        };
        cache.copying = true;
        cache.startWorkers();
        cache.jobs.push(.{ .key = key, .url = owned_url, .max_w = 4096, .max_h = 4096 });
    }

    /// true/false quando uma cópia acabou de dar certo ou falhar.
    pub fn takeCopied(cache: *Cache) ?bool {
        const r = cache.copied;
        cache.copied = null;
        return r;
    }

    fn finishCopy(cache: *Cache, r: Result) void {
        defer freeResult(r);
        cache.copying = false;
        cache.copied = false;
        if (r.px.frames.len == 0) return;
        const first = r.px.frames[0];
        const surface = c.SDL_CreateSurfaceFrom(r.px.w, r.px.h, c.SDL_PIXELFORMAT_RGBA32, first.data.ptr, @as(c_int, r.px.w) * 4) orelse return;
        defer c.SDL_DestroySurface(surface);
        const data = encoded(surface);
        if (data.len == 0) return;
        const clip = alloc.create([]u8) catch return alloc.free(data);
        clip.* = data;
        var mimes = [_][*c]const u8{clip_mime};
        cache.copied = c.SDL_SetClipboardData(clipData, clipCleanup, @ptrCast(clip), &mimes, mimes.len);
    }

    /// Alguma imagem ainda está baixando (os prints esperam por isso).
    pub fn busy(cache: *const Cache) bool {
        var it = cache.map.valueIterator();
        while (it.next()) |e| if (e.state == .loading) return true;
        return false;
    }

    /// Thread principal: cria as texturas que chegaram e solta as velhas.
    /// Retorna true se chegou alguma imagem (precisa redesenhar). Um GIF inteiro
    /// (até 300 texturas) não trava o quadro: passou do orçamento, o resto fica
    /// para a próxima volta.
    pub fn pump(cache: *Cache) bool {
        var batch: std.ArrayList(Result) = .empty;
        defer batch.deinit(alloc);
        cache.results.drain(&batch);
        for (batch.items) |r| {
            if (std.mem.startsWith(u8, r.key, clip_prefix)) {
                cache.finishCopy(r);
            } else cache.backlog.append(alloc, r) catch freeResult(r);
        }
        const worked = cache.backlog.items.len > 0 or cache.uploading != null;
        // Passou a rajada: bastante memória foi solta nas arenas das threads.
        if (!worked and cache.freed_bytes >= trim_after_bytes) {
            cache.freed_bytes = 0;
            cache.trim_due = true;
        }
        const t0 = c.SDL_GetTicksNS();
        while (true) {
            if (cache.uploading == null) {
                if (cache.backlog.items.len == 0) break;
                cache.beginUpload(cache.backlog.orderedRemove(0));
                continue;
            }
            cache.stepUpload();
            if (c.SDL_GetTicksNS() - t0 >= upload_budget_ns) break;
        }
        // A varredura do cache não precisa ser a cada quadro.
        if (worked or cache.now_ms - cache.evicted_ms > 500) {
            cache.evicted_ms = cache.now_ms;
            cache.evict();
        }
        return worked;
    }

    fn freeResult(r: Result) void {
        alloc.free(r.key);
        r.px.deinit();
    }

    fn beginUpload(cache: *Cache, r: Result) void {
        const e = cache.map.getPtr(r.key) orelse return freeResult(r);
        if (r.px.frames.len == 0) {
            e.state = .failed;
            return freeResult(r);
        }
        const frames = alloc.alloc(Frame, r.px.frames.len) catch {
            e.state = .failed;
            return freeResult(r);
        };
        cache.uploading = .{ .r = r, .frames = frames };
    }

    /// Mais uma textura do resultado em andamento (ou o fim dele).
    fn stepUpload(cache: *Cache) void {
        const u = &cache.uploading.?;
        const px = u.r.px;
        if (u.n < px.frames.len) created: {
            const pf = px.frames[u.n];
            const tex = c.SDL_CreateTexture(cache.renderer, c.SDL_PIXELFORMAT_RGBA32, c.SDL_TEXTUREACCESS_STATIC, px.w, px.h) orelse break :created;
            _ = c.SDL_UpdateTexture(tex, null, pf.data.ptr, @as(c_int, px.w) * 4);
            _ = c.SDL_SetTextureScaleMode(tex, c.SDL_SCALEMODE_LINEAR);
            _ = c.SDL_SetTextureBlendMode(tex, c.SDL_BLENDMODE_BLEND);
            u.end +|= @max(pf.delay_ms, 1);
            u.frames[u.n] = .{ .tex = tex, .end_ms = u.end };
            u.n += 1;
            if (u.n < px.frames.len) return;
        }
        // Acabou (ou o SDL não criou mais: fica com o que deu).
        const done = u.*;
        cache.uploading = null;
        cache.freed_bytes +|= @as(usize, px.w) * @as(usize, px.h) * 4 * px.frames.len;
        defer freeResult(done.r);
        const e = cache.map.getPtr(done.r.key) orelse {
            for (done.frames[0..done.n]) |f| c.SDL_DestroyTexture(f.tex);
            alloc.free(done.frames);
            return;
        };
        if (done.n == 0) {
            alloc.free(done.frames);
            e.state = .failed;
            return;
        }
        const bytes = @as(usize, px.w) * px.h * 4 * done.n;
        e.* = .{ .state = .ready, .frames = alloc.realloc(done.frames, done.n) catch done.frames[0..done.n], .w = px.w, .h = px.h, .bytes = bytes, .used_ms = cache.now_ms };
        cache.bytes += bytes;
    }

    /// Solta o que não aparece há `idle_ms` e, se passar do limite, as menos
    /// usadas recentemente (nunca as que estão na tela agora).
    fn evict(cache: *Cache) void {
        while (true) {
            var oldest: ?[]const u8 = null;
            var oldest_ms: i64 = std.math.maxInt(i64);
            var it = cache.map.iterator();
            while (it.next()) |e| {
                if (e.value_ptr.state == .loading) continue;
                const idle = cache.drawn_ms - e.value_ptr.used_ms;
                if (idle > idle_ms or (cache.bytes > cache.budget_bytes and idle > 1000)) {
                    if (e.value_ptr.used_ms < oldest_ms) {
                        oldest_ms = e.value_ptr.used_ms;
                        oldest = e.key_ptr.*;
                    }
                }
            }
            cache.drop(oldest orelse return);
            // O que saiu precisa voltar ao sistema, senão a RAM não desce.
            cache.trim_due = true;
        }
    }

    fn drop(cache: *Cache, key: []const u8) void {
        var kv = cache.map.fetchRemove(key).?;
        kv.value.free();
        cache.bytes -= kv.value.bytes;
        alloc.free(kv.key);
    }

    /// A janela está na bandeja ou minimizada há um tempo (ver janela.zig). Sem
    /// quadros, `evict` não solta nada: o relógio dele é o último quadro desenhado.
    /// Retorna true se soltou alguma coisa. O que ainda chega é solto na próxima vez.
    pub fn releaseHidden(cache: *Cache) bool {
        var freed = false;
        while (true) {
            var victim: ?[]const u8 = null;
            var it = cache.map.iterator();
            while (it.next()) |e| {
                const v = e.value_ptr;
                if (v.state == .loading) continue;
                if (v.state == .ready and janela.keepsImageHidden(v.bytes, v.frames.len, cache.drawn_ms - v.used_ms)) continue;
                victim = e.key_ptr.*;
                break;
            }
            cache.drop(victim orelse return freed);
            freed = true;
        }
    }

    /// Quantas imagens estão prontas (a página de Desempenho mostra).
    pub fn readyCount(cache: *const Cache) usize {
        var n: usize = 0;
        var it = cache.map.valueIterator();
        while (it.next()) |e| if (e.state == .ready) {
            n += 1;
        };
        return n;
    }

    fn freeJob(jb: Job) void {
        alloc.free(jb.key);
        alloc.free(jb.url);
    }

    // --- Thread de mídia --------------------------------------------------------

    fn worker(data: ?*anyopaque) callconv(.c) c_int {
        const cache: *Cache = @ptrCast(@alignCast(data.?));
        // Mídia nunca disputa a CPU com a interface.
        _ = c.SDL_SetCurrentThreadPriority(c.SDL_THREAD_PRIORITY_LOW);
        var curl: ?*c.CURL = null;
        defer if (curl) |h| c.curl_easy_cleanup(h);
        while (!cache.stopping.load(.acquire)) {
            // O pedido mais novo primeiro: é o que está na tela agora.
            const jb = cache.jobs.waitPop(1000) orelse continue;
            defer freeJob(jb);
            const res = load(&curl, jb, &cache.stopping);
            const key = alloc.dupe(u8, jb.key) catch {
                res.deinit();
                continue;
            };
            if (cache.stopping.load(.acquire)) {
                // Encerrando: ninguém mais vai ler a fila de resultados.
                alloc.free(key);
                res.deinit();
                continue;
            }
            cache.results.push(.{ .key = key, .px = res });
            platform.Window.wake(cache.wake_type, .media);
        }
        return 0;
    }
};

/// Os últimos arquivos pequenos baixados: a mesma foto em dois tamanhos (conversa e lista de
/// membros) não baixa duas vezes. 48 arquivos de até 96 KB; solta junto com as imagens.
const Recent = struct { url_hash: u64 = 0, data: []u8 = &.{} };
var recent: [48]Recent = @splat(.{});
var recent_next: usize = 0;
var recent_mutex: ?*c.SDL_Mutex = null;

fn recentGet(url: []const u8, out: *std.ArrayList(u8)) bool {
    const h = std.hash.Wyhash.hash(0, url);
    c.SDL_LockMutex(recent_mutex);
    defer c.SDL_UnlockMutex(recent_mutex);
    for (recent) |e| {
        if (e.url_hash == h and e.data.len > 0) {
            out.appendSlice(alloc, e.data) catch return false;
            return true;
        }
    }
    return false;
}

fn recentPut(url: []const u8, data: []const u8) void {
    if (data.len == 0 or data.len > 96 * 1024) return;
    const copy = alloc.dupe(u8, data) catch return;
    c.SDL_LockMutex(recent_mutex);
    defer c.SDL_UnlockMutex(recent_mutex);
    const slot = &recent[recent_next];
    if (slot.data.len > 0) alloc.free(slot.data);
    slot.* = .{ .url_hash = std.hash.Wyhash.hash(0, url), .data = copy };
    recent_next = (recent_next + 1) % recent.len;
}

pub fn recentClear() void {
    c.SDL_LockMutex(recent_mutex);
    defer c.SDL_UnlockMutex(recent_mutex);
    for (&recent) |*e| {
        if (e.data.len > 0) alloc.free(e.data);
        e.* = .{};
    }
}

fn load(curl: *?*c.CURL, jb: Job, stop: *std.atomic.Value(bool)) Pixels {
    if (std.mem.startsWith(u8, jb.url, "demo:")) return demo(jb, stop);
    // Vídeo vira animação só no GIF antigo do Tenor. Em qualquer outro endereço
    // (um .mp4 renomeado para .gif, por exemplo), os decodificadores do sistema
    // não rodam em algo que a pessoa só passou o olho: vídeo é com um clique.
    var allow_video = false;
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(alloc);
    if (std.mem.startsWith(u8, jb.url, "file://")) {
        var pbuf: [1024]u8 = undefined;
        const path = std.fmt.bufPrintSentinel(&pbuf, "{s}", .{jb.url[7..]}, 0) catch return .{};
        var size: usize = 0;
        const data = c.SDL_LoadFile(path.ptr, &size) orelse {
            logFail(jb.url, "não abriu o arquivo", .{});
            return .{};
        };
        defer c.SDL_free(data);
        if (size > max_download) {
            logFail(jb.url, "grande demais ({d} bytes)", .{size});
            return .{};
        }
        bytes.appendSlice(alloc, @as([*]const u8, @ptrCast(data))[0..size]) catch return .{};
    } else if (std.mem.startsWith(u8, jb.url, media_url.tenor_page)) {
        // GIF antigo do Tenor: a página diz o endereço novo do vídeo, e dele
        // sai o WebP animado (só com Configurações → Privacidade → GIFs ligado).
        var page: std.ArrayList(u8) = .empty;
        defer page.deinit(alloc);
        var pj = jb;
        pj.url = @constCast(jb.url[media_url.tenor_page.len..]);
        if (!download(curl, pj, &page, stop)) return .{};
        var ub: [512]u8 = undefined;
        const video = media_url.tenorVideoFromPage(page.items) orelse {
            logFail(pj.url, "página do Tenor sem og:video", .{});
            return .{};
        };
        var got = false;
        if (media_url.gifFromVideo(&ub, video)) |webp| {
            pj.url = @constCast(webp);
            got = download(curl, pj, &bytes, stop);
        }
        // Sem o WebP (os GIFs mais antigos só existem em MP4): o próprio MP4,
        // decodificado pelo FFmpeg do sistema, se tiver.
        if (!got) {
            if (ffmpeg.get() == null) return .{};
            bytes.clearRetainingCapacity();
            pj.url = @constCast(video);
            if (!download(curl, pj, &bytes, stop)) return .{};
            allow_video = true;
        }
    } else if (!recentGet(jb.url, &bytes)) {
        if (!download(curl, jb, &bytes, stop)) return .{};
        recentPut(jb.url, bytes.items);
    }
    // Vaga de decodificação (no máximo 2 ao mesmo tempo).
    c.SDL_WaitSemaphore(decode_slots);
    const px = decode(bytes.items, jb.max_w, jb.max_h, stop, allow_video);
    c.SDL_SignalSemaphore(decode_slots);
    if (px.frames.len == 0) logFail(jb.url, "não decodificou ({d} bytes, começa com {x})", .{ bytes.items.len, bytes.items[0..@min(4, bytes.items.len)] });
    return px;
}

/// Com SIGMACORD_DEBUG_MEDIA, diz no log por que uma imagem falhou. Só host e
/// caminho: a query das URLs do Discord leva assinaturas.
fn logFail(url: []const u8, comptime fmt: []const u8, args: anytype) void {
    if (c.SDL_getenv("SIGMACORD_DEBUG_MEDIA") == null and !@import("../platform/debug_log.zig").isOn()) return;
    std.log.info("mídia {s}: " ++ fmt, .{media_url.logPart(url)} ++ args);
}

/// Para onde vão os bytes de um `fetch`: `write(ctx, pedaço, tamanho total
/// ou -1)`; false interrompe. Só recebe o corpo de uma resposta 200.
pub const Sink = struct {
    ctx: *anyopaque,
    write: *const fn (*anyopaque, []const u8, i64) bool,
};

const Transfer = struct { sink: Sink, h: *c.CURL, stopped: bool = false };

fn writeCb(ptr: [*]const u8, size: usize, n: usize, ud: *anyopaque) callconv(.c) usize {
    const t: *Transfer = @ptrCast(@alignCast(ud));
    const len = size * n;
    var status: c_long = 0;
    _ = c.curl_easy_getinfo(t.h, c.CURLINFO_RESPONSE_CODE, &status);
    // O corpo de um redirecionamento (ou de um erro) não é a mídia.
    if (status != 200) return len;
    var total: c.curl_off_t = -1;
    _ = c.curl_easy_getinfo(t.h, c.CURLINFO_CONTENT_LENGTH_DOWNLOAD_T, &total);
    if (!t.sink.write(t.sink.ctx, ptr[0..len], total)) {
        t.stopped = true;
        return 0;
    }
    return len;
}

/// Tudo num ArrayList, até `max_download`.
const ListSink = struct {
    list: *std.ArrayList(u8),
    too_big: bool = false,

    fn sink(s: *ListSink) Sink {
        return .{ .ctx = s, .write = write };
    }

    fn write(ud: *anyopaque, chunk: []const u8, total: i64) bool {
        const s: *ListSink = @ptrCast(@alignCast(ud));
        if (s.list.items.len + chunk.len > max_download or total > @as(i64, max_download)) {
            s.too_big = true;
            return false;
        }
        s.list.appendSlice(alloc, chunk) catch return false;
        return true;
    }
};

fn abortCb(ud: ?*anyopaque, _: c.curl_off_t, _: c.curl_off_t, _: c.curl_off_t, _: c.curl_off_t) callconv(.c) c_int {
    const stop: *std.atomic.Value(bool) = @ptrCast(@alignCast(ud.?));
    return @intFromBool(stop.load(.acquire));
}

/// O libcurl só é iniciado quando a primeira imagem de verdade é pedida
/// (a demonstração não usa rede). Várias threads chegam aqui ao mesmo tempo.
var curl_mutex: ?*c.SDL_Mutex = null;
var curl_inited = false;

pub fn curlGlobalInit() void {
    c.SDL_LockMutex(curl_mutex);
    defer c.SDL_UnlockMutex(curl_mutex);
    if (curl_inited) return;
    _ = c.curl_global_init(c.CURL_GLOBAL_DEFAULT);
    curl_inited = true;
}

fn download(curl: *?*c.CURL, jb: Job, out: *std.ArrayList(u8), stop: *std.atomic.Value(bool)) bool {
    var ubuf: [2048]u8 = undefined;
    const url = proxiedUrl(&ubuf, jb.url, jb.max_w, jb.max_h) orelse return false;
    var ls: ListSink = .{ .list = out };
    if (!fetch(curl, url, ls.sink(), stop, 25)) {
        if (ls.too_big) logFail(jb.url, "grande demais (mais de {d} MB)", .{max_download / (1024 * 1024)});
        return false;
    }
    if (out.items.len == 0) {
        logFail(jb.url, "resposta vazia", .{});
        return false;
    }
    return true;
}

/// Baixa `url` como está (sem pedir tamanho ao proxy de mídia) para `sink`.
/// Só de domínios permitidos, redirecionamentos conferidos um a um e com o
/// proxy das configurações. `timeout_s` = 0: sem limite total (vídeo), mas
/// desiste se ficar 20 s quase parado.
pub fn fetch(curl: *?*c.CURL, url: [:0]const u8, sink: Sink, stop: *std.atomic.Value(bool), timeout_s: c_long) bool {
    if (!allowedHost(url)) {
        logFail(url, "domínio não permitido", .{});
        return false;
    }
    if (curl.* == null) {
        curlGlobalInit();
        curl.* = c.curl_easy_init();
        if (curl.*) |h| @import("../platform/sys.zig").curlTls(h);
    }
    const h = curl.* orelse return false;
    // Redirecionamentos seguidos à mão: cada destino passa pelo allowedHost
    // (o curl seguiria qualquer um e o app se conectaria a outro servidor).
    var cur: [2048]u8 = undefined;
    var cur_url: [:0]const u8 = url;
    var hops: u8 = 0;
    while (true) : (hops += 1) {
        var t: Transfer = .{ .sink = sink, .h = h };
        c.curl_easy_reset(h);
        @import("../platform/sys.zig").curlTls(h);
        _ = c.curl_easy_setopt(h, c.CURLOPT_URL, cur_url.ptr);
        _ = c.curl_easy_setopt(h, c.CURLOPT_NOSIGNAL, @as(c_long, 1));
        _ = c.curl_easy_setopt(h, c.CURLOPT_USERAGENT, "Mozilla/5.0 (X11; Linux x86_64) SigmaCord/0.1");
        _ = c.curl_easy_setopt(h, c.CURLOPT_WRITEFUNCTION, writeCb);
        _ = c.curl_easy_setopt(h, c.CURLOPT_WRITEDATA, &t);
        if (timeout_s > 0) {
            _ = c.curl_easy_setopt(h, c.CURLOPT_TIMEOUT, timeout_s);
        } else {
            _ = c.curl_easy_setopt(h, c.CURLOPT_CONNECTTIMEOUT, @as(c_long, 20));
            _ = c.curl_easy_setopt(h, c.CURLOPT_LOW_SPEED_LIMIT, @as(c_long, 1024));
            _ = c.curl_easy_setopt(h, c.CURLOPT_LOW_SPEED_TIME, @as(c_long, 20));
        }
        _ = c.curl_easy_setopt(h, c.CURLOPT_FOLLOWLOCATION, @as(c_long, 0));
        _ = c.curl_easy_setopt(h, c.CURLOPT_PROTOCOLS_STR, "https");
        _ = c.curl_easy_setopt(h, c.CURLOPT_ACCEPT_ENCODING, "");
        // Proxy das configurações (mídia de fora, ou tudo).
        var pbuf: proxy.Buf = undefined;
        if (proxy.forUrl(&pbuf, cur_url)) |p| _ = c.curl_easy_setopt(h, c.CURLOPT_PROXY, p.ptr);
        // Fechar o app interrompe o download na hora.
        _ = c.curl_easy_setopt(h, c.CURLOPT_NOPROGRESS, @as(c_long, 0));
        _ = c.curl_easy_setopt(h, c.CURLOPT_XFERINFOFUNCTION, abortCb);
        _ = c.curl_easy_setopt(h, c.CURLOPT_XFERINFODATA, stop);
        const rc = c.curl_easy_perform(h);
        if (rc != c.CURLE_OK) {
            if (!t.stopped and !stop.load(.acquire)) logFail(url, "erro do curl: {s}", .{std.mem.span(c.curl_easy_strerror(rc))});
            return false;
        }
        var status: c_long = 0;
        _ = c.curl_easy_getinfo(h, c.CURLINFO_RESPONSE_CODE, &status);
        if (status >= 300 and status < 400) {
            var loc: [*c]u8 = null;
            _ = c.curl_easy_getinfo(h, c.CURLINFO_REDIRECT_URL, &loc);
            if (loc == null or hops >= 3) {
                logFail(url, "redirecionamento sem destino ou demais", .{});
                return false;
            }
            const next = std.mem.span(loc);
            if (!allowedHost(next)) {
                logFail(url, "redirecionou para um domínio não permitido", .{});
                return false;
            }
            cur_url = std.fmt.bufPrintSentinel(&cur, "{s}", .{next}, 0) catch return false;
            continue;
        }
        if (status != 200) {
            logFail(url, "HTTP {d}", .{status});
            return false;
        }
        return true;
    }
}

/// Tamanho final de uma imagem sw×sh cabendo em max_w×max_h (nunca aumenta).
fn fit(sw: usize, sh: usize, max_w: u16, max_h: u16) [2]usize {
    const scale = @min(1.0, @min(@as(f32, @floatFromInt(max_w)) / @as(f32, @floatFromInt(sw)), @as(f32, @floatFromInt(max_h)) / @as(f32, @floatFromInt(sh))));
    return .{
        @max(1, @as(usize, @intFromFloat(@round(@as(f32, @floatFromInt(sw)) * scale)))),
        @max(1, @as(usize, @intFromFloat(@round(@as(f32, @floatFromInt(sh)) * scale)))),
    };
}

/// Decodifica e reduz para caber em max_w×max_h. Os pixels voltam no
/// c_allocator (RGBA, 4 bytes por pixel). GIF, WebP e PNG animados viram
/// vários quadros. O formato vem dos primeiros bytes, não da URL.
fn decode(data: []const u8, max_w: u16, max_h: u16, stop: *std.atomic.Value(bool), allow_video: bool) Pixels {
    if (data.len > std.math.maxInt(c_int)) return .{};
    if (isWebp(data)) return decodeWebp(data, max_w, max_h, stop);
    // GIF que só existe em MP4 (Tenor antigo): pelo FFmpeg, se tiver.
    if (ffmpeg.looksLikeVideo(data)) return if (allow_video) decodeVideo(data, max_w, max_h, stop) else .{};
    if (data.len > 6 and std.mem.startsWith(u8, data, "GIF8")) {
        // a tiny gif can allocate alot of memory
        // check the size first and skip if too big
        if (!media_url.gifSizeAllowed(data)) return .{};
        const anim_px = decodeGif(data, max_w, max_h, stop);
        if (anim_px.frames.len > 0) return anim_px;
    }
    if (apng.isAnimated(data)) {
        const anim_px = decodeApng(data, max_w, max_h, stop);
        if (anim_px.frames.len > 0) return anim_px;
    }
    var w: c_int = 0;
    var h: c_int = 0;
    var comp: c_int = 0;
    const px = c.stbi_load_from_memory(data.ptr, @intCast(data.len), &w, &h, &comp, 4) orelse return .{};
    defer c.stbi_image_free(px);
    return still(px, w, h, max_w, max_h);
}

/// Uma imagem só (RGBA w×h), copiada e reduzida.
fn still(px: [*]const u8, w: c_int, h: c_int, max_w: u16, max_h: u16) Pixels {
    if (w <= 0 or h <= 0 or w > 16384 or h > 16384) return .{};
    const sw: usize = @intCast(w);
    const sh: usize = @intCast(h);
    const dims = fit(sw, sh, max_w, max_h);
    const out = alloc.alloc(u8, dims[0] * dims[1] * 4) catch return .{};
    const src = px[0 .. sw * sh * 4];
    if (dims[0] == sw and dims[1] == sh) {
        @memcpy(out, src);
    } else if (sw * sh > 4 * 1024 * 1024) {
        // Foto enorme: o filtro melhor custaria caro e a redução já esconde a diferença.
        resize(src, sw, sh, out, dims[0], dims[1]);
    } else {
        @import("../core/resample.zig").bicubic(alloc, src, sw, sh, out, dims[0], dims[1]) catch resize(src, sw, sh, out, dims[0], dims[1]);
    }
    return Pixels.single(out, dims[0], dims[1]);
}

/// Navegadores tratam atraso < 20 ms de GIF como 100 ms; fazemos igual
/// (no WebP também, que quase sempre vem de um GIF).
fn gifDelay(ms: i64) u32 {
    return if (ms < 20) 100 else @intCast(@min(ms, 60_000));
}

/// Quadros de uma animação (GIF, WebP, APNG), já reduzidos e com limite de
/// memória.
const FrameSink = struct {
    max_w: u16,
    max_h: u16,
    stop: *std.atomic.Value(bool),
    deadline_ms: u64,
    frames: std.ArrayList(PixFrame) = .empty,
    w: usize = 0,
    h: usize = 0,
    /// Guarda 1 de cada `step` quadros (sobe quando passa do limite).
    step: usize = 1,
    seen: usize = 0,

    fn bytes(g: *const FrameSink) usize {
        return g.frames.items.len * g.w * g.h * 4;
    }

    /// Junta os quadros dois a dois (somando o tempo) para caber no limite.
    fn halve(g: *FrameSink) void {
        var i: usize = 0;
        var o: usize = 0;
        while (i < g.frames.items.len) : (i += 2) {
            var f = g.frames.items[i];
            if (i + 1 < g.frames.items.len) {
                f.delay_ms +|= g.frames.items[i + 1].delay_ms;
                alloc.free(g.frames.items[i + 1].data);
            }
            g.frames.items[o] = f;
            o += 1;
        }
        g.frames.shrinkRetainingCapacity(o);
        g.step *= 2;
    }

    /// Mais um quadro RGBA sw×sh (todos do mesmo tamanho). false = parar.
    fn add(g: *FrameSink, rgba: []const u8, sw: usize, sh: usize, ms: u32) bool {
        // Mesmo pulando quadros, cada um custa decodificar: aqui é o único ponto
        // comum aos quatro formatos para desistir (e para o app poder fechar).
        if (g.seen >= max_gif_seen or g.stop.load(.acquire) or c.SDL_GetTicks() >= g.deadline_ms) return false;
        defer g.seen += 1;
        if (g.seen % g.step != 0) {
            if (g.frames.items.len > 0) g.frames.items[g.frames.items.len - 1].delay_ms +|= ms;
            return true;
        }
        const dims = fit(sw, sh, g.max_w, g.max_h);
        g.w = dims[0];
        g.h = dims[1];
        const out = alloc.alloc(u8, dims[0] * dims[1] * 4) catch return false;
        const src = rgba[0 .. sw * sh * 4];
        if (dims[0] == sw and dims[1] == sh) @memcpy(out, src) else resize(src, sw, sh, out, dims[0], dims[1]);
        g.frames.append(alloc, .{ .data = out, .delay_ms = ms }) catch {
            alloc.free(out);
            return false;
        };
        if (g.bytes() > gif_limit_bytes.load(.monotonic) or g.frames.items.len > max_gif_frames) g.halve();
        return true;
    }

    fn finish(g: *FrameSink) Pixels {
        if (g.frames.items.len == 0) return .{};
        const frames = g.frames.toOwnedSlice(alloc) catch {
            for (g.frames.items) |f| alloc.free(f.data);
            g.frames.deinit(alloc);
            return .{};
        };
        return .{ .frames = frames, .w = @intCast(g.w), .h = @intCast(g.h) };
    }

    fn gifCb(ud: ?*anyopaque, rgba: [*c]const u8, w: c_int, h: c_int, delay: c_int) callconv(.c) c_int {
        const g: *FrameSink = @ptrCast(@alignCast(ud.?));
        if (w <= 0 or h <= 0 or w > 4096 or h > 4096) return 0;
        const sw: usize = @intCast(w);
        const sh: usize = @intCast(h);
        return @intFromBool(g.add(rgba[0 .. sw * sh * 4], sw, sh, gifDelay(delay)));
    }
};

fn newSink(max_w: u16, max_h: u16, stop: *std.atomic.Value(bool)) FrameSink {
    return .{ .max_w = max_w, .max_h = max_h, .stop = stop, .deadline_ms = c.SDL_GetTicks() + max_decode_ms };
}

fn decodeGif(data: []const u8, max_w: u16, max_h: u16, stop: *std.atomic.Value(bool)) Pixels {
    var sink = newSink(max_w, max_h, stop);
    _ = c.sigma_gif_frames(data.ptr, @intCast(data.len), FrameSink.gifCb, &sink);
    return sink.finish();
}

/// "RIFF", tamanho, "WEBP".
fn isWebp(data: []const u8) bool {
    return data.len >= 12 and std.mem.eql(u8, data[0..4], "RIFF") and std.mem.eql(u8, data[8..12], "WEBP");
}

/// WebP parado vai direto; o animado passa pelo WebPAnimDecoder, que já
/// compõe cada quadro na tela cheia (os tempos dele são acumulados).
fn decodeWebp(data: []const u8, max_w: u16, max_h: u16, stop: *std.atomic.Value(bool)) Pixels {
    var feat: c.WebPBitstreamFeatures = undefined;
    if (c.WebPGetFeatures(data.ptr, data.len, &feat) != c.VP8_STATUS_OK) return .{};
    // O tamanho vem no cabeçalho: recusa antes de alocar (mesmo limite do stb).
    if (feat.width <= 0 or feat.height <= 0 or feat.width > 8192 or feat.height > 8192) return .{};
    if (feat.has_animation == 0) {
        var w: c_int = 0;
        var h: c_int = 0;
        const px = c.WebPDecodeRGBA(data.ptr, data.len, &w, &h) orelse return .{};
        defer c.WebPFree(px);
        return still(px, w, h, max_w, max_h);
    }
    var opts: c.WebPAnimDecoderOptions = undefined;
    if (c.WebPAnimDecoderOptionsInit(&opts) == 0) return .{};
    opts.color_mode = c.MODE_RGBA;
    opts.use_threads = 0;
    const wd: c.WebPData = .{ .bytes = data.ptr, .size = data.len };
    const dec = c.WebPAnimDecoderNew(&wd, &opts) orelse return .{};
    defer c.WebPAnimDecoderDelete(dec);
    var info: c.WebPAnimInfo = undefined;
    if (c.WebPAnimDecoderGetInfo(dec, &info) == 0) return .{};
    if (info.canvas_width == 0 or info.canvas_height == 0 or info.canvas_width > 4096 or info.canvas_height > 4096) return .{};
    const cw: usize = info.canvas_width;
    const ch: usize = info.canvas_height;
    var sink = newSink(max_w, max_h, stop);
    var last: c_int = 0;
    while (c.WebPAnimDecoderHasMoreFrames(dec) != 0) {
        var buf: [*c]u8 = null;
        var ts: c_int = 0;
        if (c.WebPAnimDecoderGetNext(dec, &buf, &ts) == 0 or buf == null) break;
        defer last = ts;
        if (!sink.add(buf[0 .. cw * ch * 4], cw, ch, gifDelay(ts - last))) break;
    }
    return sink.finish();
}

/// Um vídeo curto virando animação (como um GIF): até 30 qps, 60 s e o
/// mesmo limite de memória das outras animações. O tempo de cada quadro é
/// a distância até o próximo.
fn decodeVideo(data: []const u8, max_w: u16, max_h: u16, stop: *std.atomic.Value(bool)) Pixels {
    const a = ffmpeg.get() orelse return .{};
    var rd: ffmpeg.MemReader = .{ .data = data };
    var m = ffmpeg.Media.open(a, rd.io(), false, 1) catch return .{};
    defer m.close();
    var sink = newSink(max_w, max_h, stop);
    var prev: []u8 = &.{};
    defer if (prev.len > 0) alloc.free(prev);
    var dims: [2]usize = .{ 0, 0 };
    var prev_t: i64 = 0;
    var have = false;
    var done = false;
    var eof = false;
    while (!done) {
        if (!eof) switch (m.read()) {
            .video => {
                _ = m.sendVideo(m.pkt.?);
                m.unref(m.pkt.?);
            },
            .eof => {
                _ = m.sendVideo(null);
                eof = true;
            },
            else => continue,
        };
        while (m.receiveVideo() == 0) {
            const t = m.framePtsMs(m.vtb) orelse prev_t + 33;
            if (have and t < prev_t + 30) continue;
            if (t > 60_000) {
                done = true;
                break;
            }
            const src = m.frameSize();
            if (src[0] == 0 or src[1] == 0 or src[0] > 4096 or src[1] > 4096) continue;
            if (!have) {
                dims = fit(src[0], src[1], max_w, max_h);
                prev = alloc.alloc(u8, ffmpeg.rgbaSize(@intCast(dims[0]), @intCast(dims[1]))) catch return sink.finish();
            } else if (!sink.add(prev, dims[0], dims[1], @intCast(@max(t - prev_t, 1)))) {
                done = true;
                break;
            }
            if (!m.toRgba(prev, @intCast(dims[0]), @intCast(dims[1]))) {
                done = true;
                break;
            }
            prev_t = t;
            have = true;
        }
        if (eof) done = true;
    }
    if (have) {
        // O último quadro dura até o fim do vídeo, mas um vídeo cortado em 60 s
        // (ou com a duração errada no arquivo) não pode congelar nele.
        const end = if (m.duration_ms > prev_t) m.duration_ms else prev_t + 33;
        _ = sink.add(prev, dims[0], dims[1], @intCast(std.math.clamp(end - prev_t, 20, 5000)));
    }
    return sink.finish();
}

/// Cada quadro do APNG chega como um PNG avulso, que o stb_image decodifica.
const ApngCtx = struct {
    sink: *FrameSink,

    pub fn decode(_: *ApngCtx, png: []const u8, w: u32, h: u32, out: []u8) bool {
        var iw: c_int = 0;
        var ih: c_int = 0;
        var comp: c_int = 0;
        const px = c.stbi_load_from_memory(png.ptr, @intCast(png.len), &iw, &ih, &comp, 4) orelse return false;
        defer c.stbi_image_free(px);
        if (iw != w or ih != h) return false;
        @memcpy(out, px[0..out.len]);
        return true;
    }

    pub fn emit(x: *ApngCtx, rgba: []const u8, w: u32, h: u32, delay_ms: u32) bool {
        // O tempo do APNG é fracionário (1/60 s existe de verdade): só
        // ≤ 10 ms vira 100 ms, como nos navegadores.
        return x.sink.add(rgba, w, h, if (delay_ms <= 10) 100 else @min(delay_ms, 60_000));
    }
};

fn decodeApng(data: []const u8, max_w: u16, max_h: u16, stop: *std.atomic.Value(bool)) Pixels {
    var sink = newSink(max_w, max_h, stop);
    var ctx: ApngCtx = .{ .sink = &sink };
    _ = apng.play(alloc, data, 4096, &ctx) catch {};
    return sink.finish();
}

/// Redução por média de área (sem serrilhado), com alpha pré-multiplicado
/// para as bordas transparentes não ficarem escuras.
fn resize(src: []const u8, sw: usize, sh: usize, dst: []u8, dw: usize, dh: usize) void {
    for (0..dh) |dy| {
        const y0 = dy * sh / dh;
        const y1 = @max(y0 + 1, (dy + 1) * sh / dh);
        for (0..dw) |dx| {
            const x0 = dx * sw / dw;
            const x1 = @max(x0 + 1, (dx + 1) * sw / dw);
            var acc: [4]u32 = .{ 0, 0, 0, 0 };
            for (y0..y1) |y| {
                const row = src[y * sw * 4 ..];
                for (x0..x1) |x| {
                    const p = row[x * 4 ..][0..4];
                    const a: u32 = p[3];
                    acc[0] += p[0] * a;
                    acc[1] += p[1] * a;
                    acc[2] += p[2] * a;
                    acc[3] += a;
                }
            }
            const n: u32 = @intCast((y1 - y0) * (x1 - x0));
            const o = dst[(dy * dw + dx) * 4 ..][0..4];
            if (acc[3] == 0) {
                o.* = .{ 0, 0, 0, 0 };
            } else {
                o[0] = @intCast(acc[0] / acc[3]);
                o[1] = @intCast(acc[1] / acc[3]);
                o[2] = @intCast(acc[2] / acc[3]);
                o[3] = @intCast(acc[3] / n);
            }
        }
    }
}

// --- Imagens da demonstração (geradas, para não pesar no executável) -----------

fn demo(jb: Job, stop: *std.atomic.Value(bool)) Pixels {
    const spec = jb.url[5..];
    if (std.mem.startsWith(u8, spec, "av:")) return demoAvatar(std.fmt.parseInt(u64, spec[3..], 10) catch 0, jb, false);
    if (std.mem.startsWith(u8, spec, "icon:")) return demoAvatar(std.fmt.parseInt(u64, spec[5..], 10) catch 0, jb, true);
    if (std.mem.eql(u8, spec, "gif")) return demoGif(jb, stop);
    // "emoji:<id>:<0|1>" e "sticker:<id>:<0|1>": a carinha da demonstração.
    if (std.mem.startsWith(u8, spec, "emoji:") or std.mem.startsWith(u8, spec, "sticker:")) return demoEmoji(spec);
    // "GIF em MP4" da demonstração: o vídeo embutido, pelo FFmpeg.
    if (std.mem.eql(u8, spec, "mp4")) {
        c.SDL_WaitSemaphore(decode_slots);
        defer c.SDL_SignalSemaphore(decode_slots);
        return decodeVideo(@import("video.zig").demo_mp4, jb.max_w, jb.max_h, stop);
    }
    const which = std.fmt.parseInt(u8, spec, 10) catch 1;
    const full: [2]f32 = switch (which) {
        2 => .{ 720, 720 },
        3 => .{ 960, 540 },
        else => .{ 900, 560 },
    };
    const scale = @min(1.0, @min(@as(f32, @floatFromInt(jb.max_w)) / full[0], @as(f32, @floatFromInt(jb.max_h)) / full[1]));
    const w: usize = @intFromFloat(@round(full[0] * scale));
    const h: usize = @intFromFloat(@round(full[1] * scale));
    const out = alloc.alloc(u8, w * h * 4) catch return .{};
    for (0..h) |y| for (0..w) |x| {
        const u = @as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(w));
        const v = @as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(h));
        const col = switch (which) {
            2 => synthwave(u, v),
            3 => aurora(u, v, @floatFromInt(x), @floatFromInt(y)),
            else => sunset(u, v),
        };
        const o = out[(y * w + x) * 4 ..][0..4];
        for (0..3) |i| o[i] = @intFromFloat(std.math.clamp(col[i], 0, 1) * 255);
        o[3] = 255;
    };
    return Pixels.single(out, w, h);
}

fn hsv(h: f32, sat: f32, v: f32) [3]f32 {
    const k = [3]f32{ 5, 3, 1 };
    var out: [3]f32 = undefined;
    for (0..3) |i| {
        const t = @mod(k[i] + h * 6, 6);
        out[i] = v - v * sat * std.math.clamp(@min(t, 4 - t), 0, 1);
    }
    return out;
}

fn put(o: []u8, col: [3]f32) void {
    for (0..3) |i| o[i] = @intFromFloat(std.math.clamp(col[i], 0, 1) * 255);
    o[3] = 255;
}

/// Avatar (ou ícone de servidor) da demonstração: degradê com uma forma,
/// diferente para cada semente.
fn demoAvatar(seed: u64, jb: Job, icon: bool) Pixels {
    const size: usize = @min(@min(jb.max_w, jb.max_h), 128);
    const out = alloc.alloc(u8, size * size * 4) catch return .{};
    var prng = std.Random.DefaultPrng.init(seed *% 0x9E3779B97F4A7C15 +% @intFromBool(icon));
    const r = prng.random();
    const h0 = r.float(f32);
    const h1 = h0 + 0.12 + r.float(f32) * 0.25;
    // Ícone de servidor nunca é o rostinho.
    const kind = if (icon) 1 + r.uintLessThan(u8, 2) else r.uintLessThan(u8, 3);
    const fs: f32 = @floatFromInt(size);
    for (0..size) |y| for (0..size) |x| {
        const u = @as(f32, @floatFromInt(x)) / fs;
        const v = @as(f32, @floatFromInt(y)) / fs;
        var col = mix3(hsv(h0, 0.55, 0.95), hsv(h1, 0.75, 0.55), (u + v) / 2);
        const dx = u - 0.5;
        const dy = v - 0.5;
        switch (kind) {
            // Rosto simples: cabeça e ombros.
            0 => {
                const head = (dx * dx + (dy + 0.08) * (dy + 0.08)) < 0.035;
                const body = ((dx * dx) / 0.09 + ((v - 0.95) * (v - 0.95)) / 0.06) < 1;
                if (head or body) col = mix3(col, .{ 1, 1, 1 }, 0.82);
            },
            // Anéis.
            1 => {
                const d = @sqrt(dx * dx + dy * dy);
                if (@mod(d * 9, 1) < 0.35) col = mix3(col, hsv(h1 + 0.4, 0.4, 1), 0.5);
            },
            // Losango.
            else => if (@abs(dx) + @abs(dy) < 0.3) {
                col = mix3(col, .{ 1, 1, 1 }, 0.75);
            },
        }
        put(out[(y * size + x) * 4 ..][0..4], col);
    };
    return Pixels.single(out, size, size);
}

/// Emoji ou figurinha da demonstração: uma carinha de fundo transparente, de
/// cor diferente para cada ID. A animada balança (8 quadros).
fn demoEmoji(spec: []const u8) Pixels {
    var it = std.mem.splitScalar(u8, spec, ':');
    const kind = it.next() orelse "";
    const seed = std.fmt.parseInt(u64, it.next() orelse "0", 10) catch 0;
    const animated = std.mem.eql(u8, it.next() orelse "0", "1");
    const size: usize = if (std.mem.eql(u8, kind, "sticker")) 160 else 64;
    const n: usize = if (animated) 8 else 1;
    var prng = std.Random.DefaultPrng.init(seed *% 0x9E3779B97F4A7C15);
    const hue = prng.random().float(f32);
    const smile = prng.random().boolean();
    const frames = alloc.alloc(PixFrame, n) catch return .{};
    for (0..n) |f| {
        const out = alloc.alloc(u8, size * size * 4) catch {
            for (frames[0..f]) |fr| alloc.free(fr.data);
            alloc.free(frames);
            return .{};
        };
        const wobble = @sin(@as(f32, @floatFromInt(f)) / @as(f32, @floatFromInt(n)) * std.math.tau) * (if (animated) @as(f32, 0.09) else 0);
        const fs: f32 = @floatFromInt(size);
        for (0..size) |y| for (0..size) |x| {
            const dx = (@as(f32, @floatFromInt(x)) + 0.5) / fs - 0.5 - wobble;
            const dy = (@as(f32, @floatFromInt(y)) + 0.5) / fs - 0.5;
            const o = out[(y * size + x) * 4 ..][0..4];
            const r = @sqrt(dx * dx + dy * dy);
            if (r > 0.44) {
                @memset(o, 0);
                continue;
            }
            var col = mix3(hsv(hue, 0.65, 1), hsv(hue + 0.08, 0.8, 0.8), dy + 0.5);
            const eye = @min((dx - 0.15) * (dx - 0.15), (dx + 0.15) * (dx + 0.15)) + (dy + 0.1) * (dy + 0.1) < 0.005;
            const curve = if (smile) dy - 0.08 - (0.09 - dx * dx * 1.1) else dy - 0.2 + (0.05 - dx * dx * 0.9);
            const mouth = @abs(curve) < 0.028 and @abs(dx) < 0.22;
            if (eye or mouth) col = .{ 0.1, 0.08, 0.12 };
            put(o, col);
        };
        frames[f] = .{ .data = out, .delay_ms = 90 };
    }
    return .{ .frames = frames, .w = @intCast(size), .h = @intCast(size) };
}

/// GIF da demonstração: uma bolinha dando a volta, 24 quadros.
fn demoGif(jb: Job, stop: *std.atomic.Value(bool)) Pixels {
    const n = 24;
    const dims = fit(480, 270, jb.max_w, jb.max_h);
    const w = dims[0];
    const h = dims[1];
    const frames = alloc.alloc(PixFrame, n) catch return .{};
    for (0..n) |f| {
        // Fechar o app não espera os quadros que faltam.
        const out = (if (stop.load(.acquire)) null else alloc.alloc(u8, w * h * 4) catch null) orelse {
            for (frames[0..f]) |fr| alloc.free(fr.data);
            alloc.free(frames);
            return .{};
        };
        const t = @as(f32, @floatFromInt(f)) / n * std.math.tau;
        for (0..h) |y| for (0..w) |x| {
            const u = @as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(w));
            const v = @as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(h));
            var col = mix3(.{ 0.12, 0.05, 0.25 }, .{ 0.02, 0.15, 0.3 }, v);
            for (0..5) |i| {
                const ph = t - @as(f32, @floatFromInt(i)) * 0.35;
                const bx = 0.5 + 0.28 * @cos(ph);
                const by = 0.5 + 0.36 * @sin(ph);
                const dx = (u - bx) * 1.78;
                const dy = v - by;
                const glow = @exp(-(dx * dx + dy * dy) * 260) * (1 - @as(f32, @floatFromInt(i)) * 0.18);
                col = mix3(col, hsv(0.78 + 0.05 * @as(f32, @floatFromInt(i)), 0.6, 1), std.math.clamp(glow, 0, 1));
            }
            put(out[(y * w + x) * 4 ..][0..4], col);
        };
        frames[f] = .{ .data = out, .delay_ms = 50 };
    }
    return .{ .frames = frames, .w = @intCast(w), .h = @intCast(h) };
}

fn mix3(a: [3]f32, b: [3]f32, k: f32) [3]f32 {
    return .{ a[0] + (b[0] - a[0]) * k, a[1] + (b[1] - a[1]) * k, a[2] + (b[2] - a[2]) * k };
}

fn hash2(x: f32, y: f32) f32 {
    const s = @sin(x * 12.9898 + y * 78.233) * 43758.5453;
    return s - @floor(s);
}

/// Pôr do sol com montanhas em camadas.
fn sunset(u: f32, v: f32) [3]f32 {
    var col = if (v < 0.6) mix3(.{ 0.28, 0.12, 0.45 }, .{ 1.0, 0.45, 0.35 }, v / 0.6) else mix3(.{ 1.0, 0.45, 0.35 }, .{ 1.0, 0.75, 0.45 }, (v - 0.6) / 0.4);
    const dx = (u - 0.5) * 1.6;
    const dy = v - 0.62;
    const r = @sqrt(dx * dx + dy * dy);
    if (r < 0.13) col = mix3(col, .{ 1.0, 0.93, 0.7 }, 1) else col = mix3(col, .{ 1.0, 0.85, 0.6 }, @max(0, 0.35 - r) * 1.2);
    const layers = [_]struct { base: f32, amp: f32, freq: f32, col: [3]f32 }{
        .{ .base = 0.66, .amp = 0.08, .freq = 7, .col = .{ 0.55, 0.22, 0.45 } },
        .{ .base = 0.74, .amp = 0.07, .freq = 11, .col = .{ 0.36, 0.13, 0.36 } },
        .{ .base = 0.84, .amp = 0.05, .freq = 17, .col = .{ 0.18, 0.06, 0.22 } },
    };
    for (layers) |l| {
        const ridge = l.base - l.amp * (@abs(@sin(u * l.freq)) * 0.7 + @abs(@sin(u * l.freq * 2.3 + 1)) * 0.3);
        if (v > ridge) col = l.col;
    }
    return col;
}

/// Grade synthwave com sol listrado.
fn synthwave(u: f32, v: f32) [3]f32 {
    var col = mix3(.{ 0.08, 0.02, 0.18 }, .{ 0.55, 0.1, 0.55 }, v / 0.55);
    const dx = u - 0.5;
    const dy = v - 0.42;
    if (@sqrt(dx * dx + dy * dy) < 0.24 and v < 0.55) {
        const stripe = @mod(v * 40, 2) < (v - 0.25) * 6;
        if (!stripe) col = mix3(.{ 1.0, 0.85, 0.3 }, .{ 1.0, 0.25, 0.6 }, (v - 0.18) / 0.37);
    }
    if (v >= 0.55) {
        const depth = (v - 0.55) / 0.45;
        col = mix3(.{ 0.1, 0.0, 0.18 }, .{ 0.03, 0.0, 0.08 }, depth);
        const z = 1 / (depth + 0.02);
        const gx = @abs(@mod((u - 0.5) * z * 3, 1) - 0.5);
        const gz = @abs(@mod(z * 0.6, 1) - 0.5);
        const line = @max(@as(f32, @floatCast(@max(0, 0.06 - gx * depth * 0.5))) * 16, @max(0, 0.04 - gz) * 25 * depth);
        col = mix3(col, .{ 1.0, 0.25, 0.85 }, std.math.clamp(line, 0, 1));
    }
    return col;
}

/// Aurora sobre céu estrelado.
fn aurora(u: f32, v: f32, x: f32, y: f32) [3]f32 {
    var col = mix3(.{ 0.01, 0.03, 0.08 }, .{ 0.03, 0.1, 0.18 }, v);
    if (hash2(x, y) > 0.9975) col = .{ 0.9, 0.95, 1 };
    for (0..3) |i| {
        const fi: f32 = @floatFromInt(i);
        const center = 0.35 + 0.12 * fi + 0.08 * @sin(u * (5 + fi * 2) + fi);
        const d = @abs(v - center);
        const band = @exp(-d * d * 160) * (0.6 + 0.4 * @sin(u * 30 + fi * 3));
        const tint: [3]f32 = if (i == 1) .{ 0.55, 0.3, 1.0 } else .{ 0.2, 1.0, 0.6 };
        col = mix3(col, tint, std.math.clamp(band * 0.8, 0, 1));
    }
    if (v > 0.86 - 0.03 * @sin(u * 9)) col = .{ 0.01, 0.02, 0.04 };
    return col;
}
