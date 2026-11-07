const std = @import("std");

/// Temas embutidos (usados também pelo passo `snapshots`).
/// Lua 5.4 dos plugins (third_party/lua). Sem io, package, debug e
/// coroutine: o sandbox não abre essas bibliotecas (ver src/plugins/engine.zig).
const lua_sources = [_][]const u8{
    "lapi.c",     "lcode.c",   "lctype.c",  "ldebug.c",   "ldo.c",      "ldump.c",   "lfunc.c",
    "lgc.c",      "llex.c",    "lmem.c",    "lobject.c",  "lopcodes.c", "lparser.c", "lstate.c",
    "lstring.c",  "ltable.c",  "ltm.c",     "lundump.c",  "lvm.c",      "lzio.c",    "lauxlib.c",
    "lbaselib.c", "lstrlib.c", "ltablib.c", "lmathlib.c", "lutf8lib.c", "loslib.c",
};

fn addLua(b: *std.Build, m: *std.Build.Module) void {
    const windows = m.resolved_target.?.result.os.tag == .windows;
    m.addCSourceFiles(.{
        .root = b.path("third_party/lua"),
        .files = &lua_sources,
        // Sem o sanitizador de UB do Zig: o Lua conta com aritmética de C
        // que ele marcaria (e o QA roda em debug).
        // No Windows o longjmp desenrola a pilha pelas tabelas do SEH e morre ao
        // passar por um quadro em Zig (o gancho que para plugin em laço infinito).
        // Com o quadro nulo no _setjmp ele só restaura os registradores.
        .flags = if (windows) &.{ "-std=gnu99", "-O2", "-fno-sanitize=undefined", "-DLUAI_THROW(L,c)=longjmp((c)->b,1)", "-DLUAI_TRY(L,c,a)=if(_setjmp((c)->b,0)==0){a}", "-Dluai_jmpbuf=jmp_buf" } else &.{ "-std=gnu99", "-O2", "-DLUA_USE_POSIX", "-fno-sanitize=undefined" },
    });
}

/// RNNoise, a supressão de ruído da voz (third_party/rnnoise; src/core/ruido.zig).
/// C puro, sem detecção de CPU em tempo de execução. -O2 também no debug do QA,
/// que escuta o microfone em tempo real; -Wno-cpp cala o aviso dele sobre AVX2.
fn addRnnoise(b: *std.Build, m: *std.Build.Module) void {
    const cpu = m.resolved_target.?.result.cpu;
    const rtcd = cpu.arch == .x86_64 and !cpu.has(.x86, .avx2);
    m.addIncludePath(b.path("third_party/rnnoise/include"));
    m.addIncludePath(b.path("third_party/rnnoise/compat"));
    m.addCSourceFiles(.{
        .root = b.path("third_party/rnnoise/src"),
        .files = &.{
            "celt_lpc.c",    "denoise.c", "kiss_fft.c",             "nnet.c",        "nnet_default.c",
            "parse_lpcnet_weights.c", "pitch.c",   "rnn.c", "rnnoise_data.c", "rnnoise_tables.c",
        },
        .flags = if (rtcd) &.{ "-std=gnu99", "-O2", "-fno-sanitize=undefined", "-Wno-cpp", "-DRNN_ENABLE_X86_RTCD", "-DCPU_INFO_BY_ASM" } else &.{ "-std=gnu99", "-O2", "-fno-sanitize=undefined", "-Wno-cpp" },
    });
    if (!rtcd) return;
    // Compilado para o mínimo comum (a release): a rede neural escolhe AVX2 ao rodar.
    m.addIncludePath(b.path("third_party/rnnoise/src"));
    m.addCSourceFile(.{ .file = b.path("third_party/rnnoise/compat/x86/select_arch.c"), .flags = &.{ "-std=gnu99", "-O2", "-fno-sanitize=undefined" } });
    // Um objeto por caminho: um -mavx2 nas opções do arquivo não vale, o alvo manda.
    const X = std.Target.x86.Feature;
    for ([_]struct { name: []const u8, file: []const u8, add: []const X }{
        .{ .name = "rnnoise-avx", .file = "nnet_avx.c", .add = &.{.avx} },
        .{ .name = "rnnoise-avx2", .file = "nnet_avx2.c", .add = &.{ .avx2, .fma } },
    }) |path| {
        var query = m.resolved_target.?.query;
        query.cpu_features_add = std.Target.x86.featureSet(path.add);
        const vec = b.createModule(.{ .target = b.resolveTargetQuery(query), .optimize = .ReleaseFast, .link_libc = true });
        vec.addIncludePath(b.path("third_party/rnnoise/include"));
        vec.addIncludePath(b.path("third_party/rnnoise/compat"));
        vec.addIncludePath(b.path("third_party/rnnoise/src"));
        vec.addCSourceFile(.{ .file = b.path(b.fmt("third_party/rnnoise/compat/x86/{s}", .{path.file})), .flags = &.{ "-std=gnu99", "-O2", "-fno-sanitize=undefined", "-Wno-cpp", "-DRNN_ENABLE_X86_RTCD" } });
        m.addObject(b.addObject(.{ .name = path.name, .root_module = vec }));
    }
}

/// Windows: FreeType compilado junto (o baixado por tools/windows_deps.sh).
const freetype_sources = [_][]const u8{
    "base/ftsystem.c", "base/ftinit.c",    "base/ftdebug.c",     "base/ftbase.c",  "base/ftbbox.c",  "base/ftbitmap.c",
    "base/ftglyph.c",  "base/ftsynth.c",   "base/ftmm.c",        "base/ftgasp.c",  "sfnt/sfnt.c",    "truetype/truetype.c",
    "cff/cff.c",       "psaux/psaux.c",    "pshinter/pshinter.c", "psnames/psnames.c", "smooth/smooth.c", "raster/raster.c",
    "autofit/autofit.c", "gzip/ftgzip.c",  "lzw/ftlzw.c",
};

const theme_names = [_][]const u8{ "classico", "vidro", "terminal", "subsolo", "orbital", "editorial", "bolhas", "zen", "papel", "escritorio", "cupertino" };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // Padrão: ReleaseFast (o de debug desenha cada quadro ~4x mais devagar).
    // O QA usa -Doptimize=debug, com as checagens de segurança.
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "debug, safe, fast ou small (padrão: fast)") orelse .fast;
    const strip = b.option(bool, "strip", "Remove símbolos de debug do executável") orelse (optimize != .debug);
    const release = optimize != .debug;
    // Binário das releases: SDL3, curl e OpenSSL dentro dele (ver tools/linux_deps.sh).
    const portable = b.option(bool, "portable", "Liga SDL3, curl e OpenSSL estáticos") orelse false;
    // O robô de QA (--qa) e suas marcações só entram onde são usados.
    const qa = b.option(bool, "qa", "Inclui o robô de QA (--qa); padrão: só no debug") orelse !release;
    const build_options = b.addOptions();
    build_options.addOption(bool, "qa", qa);
    // -Dversion: só para testar a atualização a partir de uma versão velha.
    build_options.addOption([]const u8, "version", b.option([]const u8, "version", "Versão gravada no executável") orelse @import("src/core/version.zig").number);

    const imgui_dir = b.path("third_party/imgui");
    const dcimgui_dir = b.path("third_party/dcimgui");

    const builtin_themes = b.createModule(.{ .root_source_file = b.path("themes/builtin.zig") });
    const plugin_examples = b.createModule(.{ .root_source_file = b.path("docs/plugins/exemplos.zig") });

    // Headers C (SDL3, Dear ImGui, fontconfig, libc) traduzidos num módulo Zig.
    const translate = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    });
    translate.addIncludePath(imgui_dir);
    translate.addIncludePath(dcimgui_dir);
    translate.addIncludePath(dcimgui_dir.path(b, "backends"));
    translate.addIncludePath(b.path("third_party/stb"));
    translate.addIncludePath(b.path("third_party/libdave/includes"));
    translate.defineCMacro("IMGUI_USE_WCHAR32", "1");
    // Só o enum de teclas do ImGui: os atalhos (ui/bind_keys.zig) e os testes
    // puros deles não podem depender do SDL nem das outras bibliotecas.
    const imgui_keys = b.addTranslateC(.{
        .root_source_file = b.path("src/bind_keys_c.h"),
        .target = target,
        .optimize = optimize,
    });
    imgui_keys.addIncludePath(imgui_dir);
    imgui_keys.addIncludePath(dcimgui_dir);
    imgui_keys.defineCMacro("IMGUI_USE_WCHAR32", "1");
    const windows = target.result.os.tag == .windows;
    // Sem pkg-config: as bibliotecas vêm de tools/windows_deps.sh.
    const win_deps = b.path(".deps/windows");
    if (windows) {
        translate.addIncludePath(win_deps.path(b, "include"));
    } else {
        translate.linkSystemLibrary("sdl3", .{});
        translate.linkSystemLibrary("fontconfig", .{});
        translate.linkSystemLibrary("libcurl", .{});
        translate.linkSystemLibrary("zlib", .{});
        translate.linkSystemLibrary("libwebp", .{});
        translate.linkSystemLibrary("libwebpdemux", .{});
        translate.linkSystemLibrary("opus", .{});
    }

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
        .strip = strip,
        // Só o C++ da voz usa exceções, e ele gera as tabelas que precisa.
        .unwind_tables = if (release and target.result.os.tag != .windows) .none else null,
    });
    mod.addOptions("build_options", build_options);
    mod.addAnonymousImport("changelog_en", .{ .root_source_file = b.path("CHANGELOG.md") });
    mod.addAnonymousImport("changelog_pt", .{ .root_source_file = b.path("CHANGELOG.pt-BR.md") });
    mod.addImport("c", translate.createModule());
    mod.addImport("imgui_c", imgui_keys.createModule());
    mod.addImport("builtin_themes", builtin_themes);
    mod.addImport("plugin_examples", plugin_examples);
    // Ícones da janela e da bandeja (tools/gen_icons.py).
    mod.addAnonymousImport("icon_64", .{ .root_source_file = b.path("assets/icon-64.png") });
    mod.addAnonymousImport("icon_32", .{ .root_source_file = b.path("assets/icon-32.png") });

    mod.addIncludePath(imgui_dir);
    mod.addIncludePath(imgui_dir.path(b, "backends"));
    mod.addIncludePath(dcimgui_dir);
    mod.addIncludePath(dcimgui_dir.path(b, "backends"));
    mod.addIncludePath(b.path("third_party/libdave/includes"));
    mod.addIncludePath(b.path("third_party/mlspp/include"));
    mod.addIncludePath(b.path("third_party/mlspp/lib/bytes/include"));
    mod.addIncludePath(b.path("third_party/mlspp/lib/hpke/include"));
    mod.addIncludePath(b.path("third_party/mlspp/lib/tls_syntax/include"));
    mod.addIncludePath(b.path("third_party/mlspp/third_party"));
    mod.addIncludePath(b.path("third_party"));
    mod.addIncludePath(b.path("third_party/libdave/src"));
    mod.addCMacro("IMGUI_ENABLE_FREETYPE", "1");
    mod.addCMacro("IMGUI_USE_WCHAR32", "1"); // emojis fora do plano básico (😂, 🌸...)
    // Janela de métricas e log de depuração: ninguém abre (dcimgui ainda cita
    // duas funções deles, então só onde o ligador joga fora o que não é usado).
    if (release and !windows) mod.addCMacro("IMGUI_DISABLE_DEBUG_TOOLS", "1");
    mod.addCMacro("WITH_OPENSSL3", "1");
    mod.addCMacro("DISABLE_GREASE", "1");
    mod.addCSourceFiles(.{
        .root = b.path("third_party"),
        .files = &.{
            "imgui/imgui.cpp",
            "imgui/imgui_draw.cpp",
            "imgui/imgui_tables.cpp",
            "imgui/imgui_widgets.cpp",
            "imgui/misc/freetype/imgui_freetype.cpp",
            "imgui/backends/imgui_impl_sdl3.cpp",
            "imgui/backends/imgui_impl_sdlrenderer3.cpp",
            "dcimgui/dcimgui.cpp",
            "dcimgui/backends/dcimgui_impl_sdl3.cpp",
            "dcimgui/backends/dcimgui_impl_sdlrenderer3.cpp",
        },
        .flags = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti" },
    });
    // Só os stubs: as bindings citam ShowDemoWindow, mas o app nunca abre a demo.
    mod.addCSourceFile(.{ .file = b.path("third_party/imgui/imgui_demo.cpp"), .flags = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti", "-DIMGUI_DISABLE_DEMO_WINDOWS" } });

    mod.addCSourceFile(.{ .file = b.path("src/ui/font_metrics.cpp"), .flags = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti" } });

    // Decodificador de imagens (PNG/JPEG/GIF) dos anexos; WebP vem da libwebp.
    mod.addIncludePath(b.path("third_party/stb"));
    mod.addCSourceFile(.{ .file = b.path("third_party/stb/stb_image.c"), .flags = &.{"-O2"} });

    // Voz: DAVE (E2EE) + MLS. Compilado junto porque só é usado quando
    // alguém entra numa chamada; parado, não custa CPU.
    mod.addCSourceFiles(.{
        .root = b.path("third_party"),
        .files = &.{
            "libdave/src/bindings_capi.cpp",
            "libdave/src/codec_utils.cpp",
            "libdave/src/cryptor.cpp",
            "libdave/src/cryptor_manager.cpp",
            "libdave/src/decryptor.cpp",
            "libdave/src/encryptor.cpp",
            "libdave/src/frame_processors.cpp",
            "libdave/src/logger.cpp",
            "libdave/src/mls_key_ratchet.cpp",
            "libdave/src/mls/key_serialization.cpp",
            "libdave/src/mls/parameters.cpp",
            "libdave/src/mls/persisted_key_pair_null.cpp",
            "libdave/src/mls/session.cpp",
            "libdave/src/mls/user_credential.cpp",
            "libdave/src/mls/util.cpp",
            "libdave/src/openssl_cryptor.cpp",
            "libdave/src/utils/leb128.cpp",
            "libdave/src/version.cpp",
            "mlspp/src/common.cpp",
            "mlspp/src/core_types.cpp",
            "mlspp/src/credential.cpp",
            "mlspp/src/crypto.cpp",
            "mlspp/src/grease.cpp",
            "mlspp/src/key_schedule.cpp",
            "mlspp/src/messages.cpp",
            "mlspp/src/session.cpp",
            "mlspp/src/state.cpp",
            "mlspp/src/treekem.cpp",
            "mlspp/src/tree_math.cpp",
            "mlspp/lib/bytes/src/bytes.cpp",
            "mlspp/lib/hpke/src/aead_cipher.cpp",
            "mlspp/lib/hpke/src/base64.cpp",
            "mlspp/lib/hpke/src/certificate.cpp",
            "mlspp/lib/hpke/src/common.cpp",
            "mlspp/lib/hpke/src/dhkem.cpp",
            "mlspp/lib/hpke/src/digest.cpp",
            "mlspp/lib/hpke/src/group.cpp",
            "mlspp/lib/hpke/src/hkdf.cpp",
            "mlspp/lib/hpke/src/hpke.cpp",
            "mlspp/lib/hpke/src/hybrid_kem.cpp",
            "mlspp/lib/hpke/src/mlkem.cpp",
            "mlspp/lib/hpke/src/openssl_common.cpp",
            "mlspp/lib/hpke/src/random.cpp",
            "mlspp/lib/hpke/src/rsa.cpp",
            "mlspp/lib/hpke/src/signature.cpp",
            "mlspp/lib/hpke/src/userinfo_vc.cpp",
            "mlspp/lib/tls_syntax/src/tls_syntax.cpp",
        },
        // Frio: a cifra de cada quadro é da OpenSSL; aqui passa pouco e raramente.
        .flags = if (release) &.{ "-std=c++17", "-fno-strict-aliasing", "-Os" } else &.{ "-std=c++17", "-fno-strict-aliasing" },
    });
    addLua(b, mod);
    addRnnoise(b, mod);
    if (windows) {
        const ft = win_deps.path(b, "src/freetype");
        mod.addIncludePath(ft.path(b, "include"));
        translate.addIncludePath(ft.path(b, "include"));
        mod.addIncludePath(win_deps.path(b, "include"));
        mod.addCSourceFiles(.{ .root = ft.path(b, "src"), .files = &freetype_sources, .flags = &.{ "-DFT2_BUILD_LIBRARY", "-DFT_CONFIG_MODULES_H=\"ftmodule.h\"", "-O2", "-fno-sanitize=undefined" } });
        mod.addIncludePath(b.path("src/platform/win"));
        mod.addLibraryPath(win_deps.path(b, "lib"));
        for ([_][]const u8{ "SDL3.dll", "curl.dll", "crypto.dll" }) |l| mod.linkSystemLibrary(l, .{ .use_pkg_config = .no });
        for ([_][]const u8{ "opus", "z", "webp", "webpdemux", "sharpyuv" }) |l| mod.linkSystemLibrary(l, .{ .use_pkg_config = .no, .preferred_link_mode = .static });
        for ([_][]const u8{ "ws2_32", "advapi32", "crypt32", "shell32", "ole32", "bcrypt", "user32" }) |l| mod.linkSystemLibrary(l, .{ .use_pkg_config = .no });
        for ([_][]const u8{ "SDL3.dll", "libcurl-x64.dll", "libcrypto-3-x64.dll" }) |dll| b.getInstallStep().dependOn(&b.addInstallBinFile(win_deps.path(b, b.pathJoin(&.{ "bin", dll })), dll).step);
    } else {
        mod.linkSystemLibrary("sdl3", .{});
        mod.linkSystemLibrary("freetype2", .{});
        mod.linkSystemLibrary("fontconfig", .{});
        mod.linkSystemLibrary("libcurl", .{});
        mod.linkSystemLibrary("zlib", .{});
        mod.linkSystemLibrary("libwebp", .{});
        mod.linkSystemLibrary("libwebpdemux", .{});
        mod.linkSystemLibrary("opus", .{});
        mod.linkSystemLibrary("crypto", .{ .preferred_link_mode = if (portable) .static else .dynamic });
        if (portable) mod.linkSystemLibrary("ssl", .{ .preferred_link_mode = .static });
    }

    const exe = b.addExecutable(.{ .name = "sigmacord", .root_module = mod });
    // Com uma seção por função, o ligador joga fora o que ninguém chama.
    exe.link_function_sections = release;
    exe.link_data_sections = release;
    exe.link_gc_sections = release;
    if (windows) {
        exe.win32_manifest = b.path("assets/sigmacord.manifest");
        mod.addWin32ResourceFile(.{ .file = b.path("assets/sigmacord.rc") });
        // Sem janela de console no build final.
        if (release) exe.subsystem = .windows;
    }
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    b.step("run", "Roda o SigmaCord").dependOn(&run.step);

    // Testes das partes puras (sem janela nem GPU): rodam em qualquer CI.
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_mod.addImport("builtin_themes", builtin_themes);
    test_mod.addImport("plugin_examples", plugin_examples);
    test_mod.addImport("imgui_c", imgui_keys.createModule());
    test_mod.addAnonymousImport("changelog_en", .{ .root_source_file = b.path("CHANGELOG.md") });
    test_mod.addAnonymousImport("changelog_pt", .{ .root_source_file = b.path("CHANGELOG.pt-BR.md") });
    addLua(b, test_mod);
    addRnnoise(b, test_mod);
    const tests = b.addTest(.{ .root_module = test_mod });
    b.step("test", "Roda os testes").dependOn(&b.addRunArtifact(tests).step);

    // Custo do supressor de ruído por quadro (sempre otimizado: é o que se mede).
    const custo_mod = b.createModule(.{
        .root_source_file = b.path("src/core/ruido_custo.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });
    addRnnoise(b, custo_mod);
    const custo = b.addExecutable(.{ .name = "ruido-custo", .root_module = custo_mod });
    b.step("ruido-custo", "Mede o custo do supressor de ruído").dependOn(&b.addRunArtifact(custo).step);

    // Rede ruim simulada na recepção de voz (Opus de verdade, sem rede nem conta).
    const rede_mod = b.createModule(.{
        .root_source_file = b.path("src/core/voz_rede.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });
    addRnnoise(b, rede_mod);
    rede_mod.linkSystemLibrary("opus", .{});
    const rede = b.addExecutable(.{ .name = "voz-rede", .root_module = rede_mod });
    b.step("voz-rede", "Simula rede ruim na recepção de voz").dependOn(&b.addRunArtifact(rede).step);

    // Um print de cada tema em docs/themes/ (usado no README).
    const snaps = b.step("snapshots", "Gera docs/themes/<tema>.png para cada tema embutido");
    for (theme_names) |name| {
        const shot = b.addRunArtifact(exe);
        shot.addArgs(&.{ "--theme", name, "--shot" });
        shot.addArg(b.fmt("docs/themes/{s}.png", .{name}));
        shot.setEnvironmentVariable("SDL_VIDEO_DRIVER", "offscreen"); // não abre janela
        shot.has_side_effects = true;
        snaps.dependOn(&shot.step);
    }
}
