#!/usr/bin/env bash
# Gera os prints de docs/ (sem abrir janela) e compõe o tema "vidro" sobre um
# fundo colorido desfocado, simulando o blur do compositor.
set -euo pipefail
cd "$(dirname "$0")/.."
zig build -Doptimize=ReleaseFast
mkdir -p docs/themes
export SDL_VIDEO_DRIVER=offscreen
for t in classico vidro terminal subsolo orbital editorial bolhas zen papel escritorio cupertino; do
    ./zig-out/bin/sigmacord --theme "$t" --mode escuro --shot "docs/themes/$t.png"
    ./zig-out/bin/sigmacord --theme "$t" --mode claro --shot "docs/themes/$t-claro.png"
done
./zig-out/bin/sigmacord --theme classico --settings --shot docs/settings.png

if command -v magick >/dev/null; then
    magick -size 1280x800 xc:'#1a0f1f' \
        \( -size 700x700 radial-gradient:'#df68ad'-none -geometry +-120+-160 \) -composite \
        \( -size 800x800 radial-gradient:'#6c5ce7'-none -geometry +700+250 \) -composite \
        \( -size 600x600 radial-gradient:'#d39e69'-none -geometry +380+-260 \) -composite \
        -blur 0x40 docs/themes/vidro-bg.png
    for f in vidro vidro-claro; do magick docs/themes/vidro-bg.png -blur 0x18 docs/themes/$f.png -composite docs/themes/$f.png; done
    rm docs/themes/vidro-bg.png
    # Grade com todos os temas para o topo do README.
    magick montage docs/themes/{classico,vidro,terminal,subsolo,orbital,editorial,bolhas,zen,papel,escritorio,cupertino,cupertino-claro}.png -tile 4x3 -geometry 384x240+6+6 -background none docs/themes.png
    magick montage docs/themes/{terminal,terminal-claro,papel,papel-claro}.png -tile 2x2 -geometry 640x400+6+6 -background none docs/modes.png
fi
echo "prints em docs/"
