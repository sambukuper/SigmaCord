#!/usr/bin/env bash
# Bandeja e instância única com processos de verdade: janela X11 num Xvfb, D-Bus
# particular e um painel falso (tools/qa_bandeja.py). Nada aparece na tela de
# quem roda, nada conecta em lugar nenhum (--demo). Antes, as baterias de QA que
# terminam com o app saindo: fechar sem bandeja e Sair no menu, os dois com a
# thread de voz de pé, e o pedido de reinício.
#   tools/qa_bandeja.sh [--slow]   (--slow: inclui o painel morrendo, ~3 min)
set -uo pipefail
cd "$(dirname "$0")/.."
zig build -Doptimize=debug -p .zig-cache/qa || exit 1
bin=$PWD/.zig-cache/qa/bin/sigmacord
fail=0
mkdir -p qa-out
for suite in bandeja-sair bandeja-menu bandeja-reinicio; do
    start=$(date +%s%N)
    out=$(QA_SUITE=$suite timeout 60 "$bin" --qa --theme classico 2>&1)
    code=$?
    ms=$(( ($(date +%s%N) - start) / 1000000 ))
    if echo "$out" | grep -q 'encerramento demorou'; then
        echo "$suite: FALHOU (só saiu pelo vigia de 3 s)"; fail=1
    elif echo "$out" | grep -q '✗'; then
        echo "$suite: FALHOU"; echo "$out" | grep '✗'; fail=1
    elif [ "$code" != 0 ]; then
        echo "$suite: FALHOU (código $code)"; echo "$out" | tail -5; fail=1
    else
        echo "$suite: ok (saiu com código 0 em $ms ms no total)"
    fi
done
# Nenhuma bateria deixa um app de verdade para trás: ele entraria na conta de quem roda.
if left=$(pgrep -f "^$bin( --restarted|\$)"); then
    echo "FALHOU: o QA deixou um app aberto: $left"; kill $left; fail=1
fi
# XDG_CURRENT_DESKTOP e o WAYLAND_DISPLAY de quem roda não entram.
env -u WAYLAND_DISPLAY -u XDG_CURRENT_DESKTOP -u DBUS_SESSION_BUS_ADDRESS -u SIGMACORD_TOKEN \
    xvfb-run -a -s "-screen 0 1280x800x24" \
    dbus-run-session -- python3 tools/qa_bandeja.py "$bin" "$@" || fail=1
[ "$fail" = 0 ] && echo "bandeja: tudo passou" || { echo "bandeja: houve falhas"; exit 1; }
