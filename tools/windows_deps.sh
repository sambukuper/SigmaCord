#!/usr/bin/env bash
# Baixa as bibliotecas do build para Windows em .deps/windows (versões e hashes
# fixos; hash errado para tudo). Compila a partir do Linux:
#   tools/windows_deps.sh && zig build -Dtarget=x86_64-windows-gnu
set -euo pipefail
cd "$(dirname "$0")/.."
out=.deps/windows
dl=$out/dl
mkdir -p "$dl" "$out/include" "$out/lib" "$out/bin" "$out/src"
msys=https://repo.msys2.org/mingw/ucrt64
get() { # url sha256
    local f="$dl/$(basename "$1")"
    if [ ! -f "$f" ]; then
        curl -fsSL --retry 3 --connect-timeout 20 -o "$f" "$1" || {
            # Repositório fora ou lento no momento: tenta o caminho de trás.
            case "$1" in
                # A página de download do GitHub pode dar 504: o mesmo arquivo
                # vai pela API, que serve o conteúdo com outro cabeçalho.
                https://github.com/*)
                    local repo tag asset id
                    repo=$(echo "$1" | cut -d/ -f4-5)
                    tag=$(echo "$1" | cut -d/ -f7)
                    asset=$(echo "$1" | cut -d/ -f8-)
                    id=$(curl -fsSL --connect-timeout 20 "https://api.github.com/repos/$repo/releases/tags/$tag"                         | grep -B4 "\"name\": \"$asset\"" | grep -o "\"id\": [0-9]*" | head -1 | tr -dc "0-9")
                    [ -n "$id" ] && curl -fsSL --connect-timeout 20 -H "Accept: application/octet-stream" -o "$f"                         "https://api.github.com/repos/$repo/releases/assets/$id"
                    ;;
                # O msys2 tem espelho próprio com a mesma árvore de arquivos.
                https://repo.msys2.org/*)
                    curl -fsSL --retry 3 --connect-timeout 20 -o "$f" "https://mirror.msys2.org/mingw/ucrt64/$(basename "$1")"
                    ;;
            esac
        }
    fi
    echo "$2  $f" | sha256sum -c --quiet -
    echo "$f"
}
pkg() { # nome-do-pacote sha256: um pacote MSYS2, só headers e bibliotecas.
    local f t
    f=$(get "$msys/$1" "$2")
    t=$(mktemp -d)
    tar --zstd -xf "$f" -C "$t" ucrt64/include ucrt64/lib ucrt64/bin 2>/dev/null || tar --zstd -xf "$f" -C "$t"
    cp -r "$t"/ucrt64/include/. "$out/include/" 2>/dev/null || true
    find "$t/ucrt64/lib" -maxdepth 1 -name '*.a' -exec cp {} "$out/lib/" \;
    find "$t/ucrt64/bin" -maxdepth 1 -name '*.dll' -exec cp {} "$out/bin/" \; 2>/dev/null || true
    rm -rf "$t"
}
pkg mingw-w64-ucrt-x86_64-opus-1.6.1-2-any.pkg.tar.zst bb114bcf26225f50f874497ebfd6b8224fff2a20bda3f8ee45cd07ce5f02657b
pkg mingw-w64-ucrt-x86_64-zlib-1.3.2-3-any.pkg.tar.zst 130e6ef04c654fc2150a177600aa5ed0035087665a893479d2c85ba7485d5704
pkg mingw-w64-ucrt-x86_64-libwebp-1.6.0-1-any.pkg.tar.zst 34ff8396c403d484c8777ad49ad0fc06dfb94fadf6f14bcf84d50c45bc6fd17e
pkg mingw-w64-ucrt-x86_64-openssl-3.6.5-1-any.pkg.tar.zst 773e021ebad83f14b5c103db467411e8ff064663e1c7e7f730e2be72f4117064

# SDL3: o pacote oficial para MinGW.
f=$(get https://github.com/libsdl-org/SDL/releases/download/release-3.4.20/SDL3-devel-3.4.20-mingw.tar.gz d2d3bf3fb97a90b22e908a306d7362631ef1bab229d988fe6669595dc29cd9ed)
t=$(mktemp -d); tar -xf "$f" -C "$t"
cp -r "$t"/SDL3-*/x86_64-w64-mingw32/include/. "$out/include/"
cp "$t"/SDL3-*/x86_64-w64-mingw32/lib/libSDL3.dll.a "$out/lib/"
cp "$t"/SDL3-*/x86_64-w64-mingw32/bin/SDL3.dll "$out/bin/"
rm -rf "$t"

# libcurl: o build oficial, num DLL só e sem dependências além do Windows.
f=$(get https://curl.se/windows/dl-8.23.0_8/curl-8.23.0_8-win64-mingw.zip ca5b0fd6e7a6dbde210281f545c73a89784f2e88104a2cdfe0b73ea3dfed5b3a)
t=$(mktemp -d); unzip -q "$f" -d "$t"
cp -r "$t"/curl-*/include/curl "$out/include/"
cp "$t"/curl-*/lib/libcurl.dll.a "$out/lib/"
cp "$t"/curl-*/bin/libcurl-x64.dll "$out/bin/"
rm -rf "$t"

# FreeType: compilado junto com o app (o pacote pronto arrastaria harfbuzz e glib).
f=$(get https://download.savannah.gnu.org/releases/freetype/freetype-2.15.0.tar.xz 93cd47eb719c325107f2d3cf087d06299e944c3b48a40b55537302304dea1dd5)
rm -rf "$out/src/freetype"; mkdir -p "$out/src/freetype"
tar -xf "$f" -C "$out/src/freetype" --strip-components=1

# Só o que o app carrega de verdade vai ao lado do executável.
find "$out/bin" -name '*.dll' ! -name 'SDL3.dll' ! -name 'libcurl-x64.dll' ! -name 'libcrypto-3-x64.dll' -delete
rm -f "$out"/lib/libssl* "$out"/lib/libcurl.a
echo "pronto: $out"
