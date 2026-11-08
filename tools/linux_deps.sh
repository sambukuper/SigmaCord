#!/usr/bin/env bash
# Compila o que a versão portátil para Linux leva dentro do binário, em .deps/linux
# (versões e hashes fixos; hash errado para tudo). Roda no CI, num Ubuntu antigo: é
# a glibc de lá que decide em quais distros o binário abre.
#   tools/linux_deps.sh && PKG_CONFIG_PATH=$PWD/.deps/linux/lib/pkgconfig zig build -Dportable=true
#
# SDL3: várias distros ainda não têm o pacote. Ela abre X11, Wayland e o áudio só ao
# rodar, então nada disso vira dependência do binário.
# curl: muitas distros trazem uma versão sem WebSocket.
# OpenSSL: vem dos pacotes do Ubuntu e entra estático (zig build -Dportable=true), porque
# as distros já estão trocando a versão da libssl. Os certificados continuam os da
# distro de quem usa (sys.curlTls).
set -euo pipefail
cd "$(dirname "$0")/.."
out=$PWD/.deps/linux
dl=$out/dl
mkdir -p "$dl"
get() { # url sha256
    local f="$dl/$(basename "$1")"
    if [ ! -f "$f" ]; then
        if ! curl -fsSL --retry 3 --connect-timeout 20 -o "$f" "$1"; then
            # O site de origem pode estar fora (504, tempo de conexão): tenta
            # os caminhos de trás, e o sha256 abaixo garante que é o arquivo.
            case "$1" in
                https://github.com/*)
                    local repo tag asset
                    # github.com/<dono>/<repo>/releases/download/<tag>/<arquivo>
                    repo=$(echo "$1" | cut -d/ -f4-5)
                    tag=$(echo "$1" | cut -d/ -f8)
                    asset=$(echo "$1" | cut -d/ -f9-)
                    # Com gh autenticado (no CI tem GH_TOKEN): API sem o limite
                    # anônimo, que nos corredores compartilhados nem sempre abre.
                    if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
                        gh release download "$tag" --repo "$repo" --pattern "$asset" --output "$f" --clobber || true
                    fi
                    if [ ! -s "$f" ]; then
                        local id
                        id=$(curl -fsSL --connect-timeout 20 "https://api.github.com/repos/$repo/releases/tags/$tag"                             | grep -B4 "\"name\": \"$asset\"" | grep -o "\"id\": [0-9]*" | head -1 | tr -dc "0-9" || true)
                        if [ -n "$id" ]; then
                            curl -fsSL --connect-timeout 20 -H "Accept: application/octet-stream" -o "$f"                                 "https://api.github.com/repos/$repo/releases/assets/$id" || true
                        fi
                    fi
                    ;;
                https://repo.msys2.org/*)
                    curl -fsSL --retry 3 --connect-timeout 20 -o "$f" "https://mirror.msys2.org/mingw/ucrt64/$(basename "$1")" || true
                    ;;
                https://download.savannah.gnu.org/*)
                    curl -fsSL --retry 3 --connect-timeout 20 -o "$f"                         "https://mirror.netcologne.de/savannah/${1#https://download.savannah.gnu.org/releases/}" || true
                    ;;
            esac
        fi
    fi
    echo "$2  $f" | sha256sum -c --quiet -
    echo "$f"
}

f=$(get https://github.com/libsdl-org/SDL/releases/download/release-3.4.20/SDL3-3.4.20.tar.gz f3bb06f55bed9557227a700af2ea62e49497ebdf58037732a731a5fb3ef8581f)
t=$(mktemp -d)
tar -xf "$f" -C "$t"
cmake -S "$t"/SDL3-* -B "$t/build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$out" \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DSDL_SHARED=OFF -DSDL_STATIC=ON \
    -DSDL_DEPS_SHARED=ON \
    -DSDL_TESTS=OFF -DSDL_TEST_LIBRARY=OFF -DSDL_EXAMPLES=OFF
cmake --build "$t/build"
cmake --install "$t/build"
rm -rf "$t"

f=$(get https://curl.se/download/curl-8.23.0.tar.xz 8dadd7d2536a314f982ad05a651b713f426bf7d02cc2c76cffb9796f2218e6c5)
t=$(mktemp -d)
tar -xf "$f" -C "$t"
(
    cd "$t"/curl-*
    ./configure --prefix="$out" --libdir="$out/lib" \
        --disable-shared --enable-static --with-pic \
        --with-openssl --enable-websockets \
        --without-ca-bundle --without-ca-path --with-ca-fallback \
        --without-libpsl --without-brotli --without-zstd --without-nghttp2 --without-libidn2 --without-librtmp \
        --disable-ldap --disable-ldaps --disable-rtsp --disable-dict --disable-telnet --disable-tftp \
        --disable-pop3 --disable-imap --disable-smtp --disable-gopher --disable-mqtt --disable-smb \
        --disable-manual --disable-docs
    make -j"$(nproc)"
    make install
)
rm -rf "$t"
rm -rf "$out/bin" "$out/share"
echo "pronto: $out"
