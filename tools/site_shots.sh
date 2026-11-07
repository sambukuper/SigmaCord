#!/usr/bin/env bash
# Gera as imagens do site (docs/assets/shots/{en,pt}) sem abrir janela: um print de
# cada tema em claro e escuro e recortes de recursos, em inglês e em português.
# Roda em pastas temporárias: não toca no qa-out/ nem nas suas configurações.
# Precisa de magick e ffmpeg. SIGMACORD_BIN escolhe outro executável.
# O --qa força português e procura os elementos pelos rótulos em português. Para os recortes
# em inglês, use em SIGMACORD_BIN um build com tools/site_shots-en.patch aplicado (git apply, num
# worktree à parte); sem isso eles saem em português.
set -euo pipefail
cd "$(dirname "$0")/.."
# A bateria do QA só existe em builds com -Dqa=true.
[ -n "${SIGMACORD_BIN:-}" ] || zig build -Dqa=true
bin="${SIGMACORD_BIN:-$PWD/zig-out/bin/sigmacord}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

themes=(classico vidro terminal subsolo orbital editorial bolhas zen papel escritorio cupertino)

webp() { magick "$1" -strip -quality "${3:-80}" -define webp:method=6 "$2"; }

# Fundo desfocado do tema vidro, que é transparente (como o compositor faria).
magick -size 1280x800 xc:'#1a0f1f' \
    \( -size 700x700 radial-gradient:'#df68ad'-none -geometry +-120+-160 \) -composite \
    \( -size 800x800 radial-gradient:'#6c5ce7'-none -geometry +700+250 \) -composite \
    \( -size 600x600 radial-gradient:'#d39e69'-none -geometry +380+-260 \) -composite \
    -blur 0x40 "$tmp/vidro-bg.png"

for lang in en pt; do
    out="$PWD/docs/assets/shots/$lang"
    w="$tmp/$lang"
    mkdir -p "$out" "$w/cfg" "$w/cache" "$w/home" "$w/rosa/.cache/wal" "$w/run" "$w/rec"
    # Tudo isolado: dados de demonstração, sem a paleta nem as configurações de quem roda.
    base=(env XDG_CONFIG_HOME="$w/cfg" XDG_CACHE_HOME="$w/cache" HOME="$w/home" SDL_VIDEO_DRIVER=offscreen)

    for t in "${themes[@]}"; do
        "${base[@]}" timeout 40 "$bin" --lang "$lang" --theme "$t" --mode escuro --shot "$w/$t.png" >/dev/null 2>&1
        "${base[@]}" timeout 40 "$bin" --lang "$lang" --theme "$t" --mode claro --shot "$w/$t-claro.png" >/dev/null 2>&1
    done
    for f in vidro vidro-claro; do magick "$tmp/vidro-bg.png" -blur 0x18 "$w/$f.png" -composite "$w/$f.png"; done
    for t in "${themes[@]}"; do
        webp "$w/$t.png" "$out/$t.webp"
        webp "$w/$t-claro.png" "$out/$t-claro.webp"
    done

    # Cenas: a call com o mixer e as configurações.
    "${base[@]}" SIGMACORD_SCENE=voice timeout 40 "$bin" --lang "$lang" --theme orbital --mode escuro --shot "$w/voz.png" >/dev/null 2>&1
    magick "$w/voz.png" -crop 820x470+0+330 +repage -strip -quality 84 "$out/f-voz.webp"
    "${base[@]}" timeout 40 "$bin" --lang "$lang" --theme classico --mode escuro --settings --shot "$w/config.png" >/dev/null 2>&1
    webp "$w/config.png" "$out/f-config.webp" 82

    # A bateria geral do QA passa por todas as telas e deixa prints (com uma paleta
    # neon de pywal, a do tema padrão do site). Os recortes mostram o recurso em
    # tamanho real e deixam de fora os avisos de teste.
    printf '%s\n' '#0A050F' '#EF4444' '#22C55E' '#F59E0B' '#D946EF' '#9333EA' '#06B6D4' '#E5E7EB' \
        '#6B7280' '#F87171' '#4ADE80' '#FBBF24' '#E879F9' '#A855F7' '#22D3EE' '#E5E7EB' >"$w/rosa/.cache/wal/colors"
    qa_env=(env QA_LANG="$lang" XDG_CONFIG_HOME="$w/cfg" XDG_CACHE_HOME="$w/cache" HOME="$w/rosa" SDL_VIDEO_DRIVER=offscreen)
    # Em inglês alguns testes falham (comparam textos em português), mas a bateria vai até o fim.
    # Um recorte que faltar fica com a versão anterior.
    (cd "$w/run" && "${qa_env[@]}" timeout 420 "$bin" --qa --lang "$lang" --theme classico >"$w/qa.log" 2>&1) || true
    (cd "$w/run" && "${qa_env[@]}" QA_SUITE=voz timeout 120 "$bin" --qa --lang "$lang" --theme classico >"$w/qa-voz.log" 2>&1) || true
    # Os plugins funcionando: as notas de CVE e do GitHub são respostas de verdade desses serviços.
    (cd "$w/run" && "${qa_env[@]}" QA_SUITE=vitrine timeout 60 "$bin" --qa --lang "$lang" --theme classico >"$w/qa-vitrine.log" 2>&1) || true
    crop() { [ -f "$w/run/qa-out/$1" ] || { echo "$lang: sem $1, $3 fica como estava"; return 0; }; magick "$w/run/qa-out/$1" -crop "$2" +repage -strip -quality 84 -define webp:method=6 "$out/$3"; }
    crop 01-inicio.png 1280x800+0+0 sigma.webp
    crop 35-tela-dividida.png 1280x740+0+60 f-mosaico.webp
    crop 40-caixa-de-entrada.png 540x760+742+20 f-caixa.webp
    crop 49-busca.png 1020x640+260+40 f-busca.webp
    crop 41-bloco-codigo.png 760x420+310+370 f-codigo.webp
    crop 42-paleta-acoes.png 660x470+320+120 f-paleta.webp
    crop 35-video.png 860x660+310+60 f-video.webp
    crop 07c-perfil-grande.png 990x720+145+40 f-perfil.webp
    crop 44-salvas-anotacao.png 560x360+700+62 f-salvas.webp
    crop 05-menu.png 760x560+310+230 f-menu.webp
    crop 43-alertas-pagina.png 800x725+400+55 f-alertas.webp
    crop 35-plugins.png 800x800+400+0 f-plugins.webp
    crop vitrine.png 1280x800+0+0 f-vitrine.webp
    crop 62-thread-aberta.png 920x790+0+10 f-threads.webp
    crop 70-forum.png 1000x730+160+60 f-forum.webp
    crop 63-emoji-seletor.png 760x560+420+230 f-emoji.webp
    crop 67-autocompletar-pessoas.png 880x330+310+460 f-autocompletar.webp
    crop 54-fixadas.png 900x440+370+60 f-fixadas.webp
    crop voz-pagina.png 800x800+400+0 f-vozcfg.webp

    # A tela de login animada (o app grava os quadros sozinho).
    "${base[@]}" SIGMACORD_RECORD="$w/rec" SIGMACORD_RECORD_FRAMES=150 timeout 60 "$bin" --lang "$lang" --login --mode escuro >/dev/null 2>&1 || true
    ffmpeg -y -loglevel error -framerate 30 -i "$w/rec/%04d.png" -c:v libx264 -crf 27 -preset slow \
        -pix_fmt yuv420p -movflags +faststart -an "$out/login.mp4"
    webp "$w/rec/0149.png" "$out/login-poster.webp"
    tail -1 "$w/qa.log" | cut -c1-80
done

# Ícones.
for s in 32 64 180; do magick -background none -density 300 assets/icon.svg -resize "${s}x${s}" "docs/assets/icon-$s.png"; done
du -sh docs/assets/shots
