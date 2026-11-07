#!/usr/bin/env bash
# Mede RAM (PSS e só a parte anônima) e CPU parado de cada tema e falha se passar
# do orçamento. Sempre na demonstração (--demo: nunca conecta na conta) e com a
# configuração isolada numa pasta temporária.
#   tools/membench.sh [orçamento_em_MB]   (padrão: 60)
#   SIGMACORD_BIN=caminho  mede esse executável em vez de compilar
#   THEMES="classico terminal"  só esses temas; REPS=3 rodadas de cada
# A janela flutua com tamanho fixo (1280x800): o que entra na tela muda a RAM, e
# num workspace com outras janelas o tamanho variava de uma rodada para outra.
# No Hyprland ela abre num workspace escondido; em outros ambientes ela aparece
# por alguns segundos. O "CPU parado" conta o GIF que a demonstração deixa na tela
# (~2%); com SIGMACORD_NO_PICS=1 no ambiente dá para ver o app sem nada se mexendo.
set -euo pipefail
cd "$(dirname "$0")/.."
budget="${1:-60}"
if [ -z "${SIGMACORD_BIN:-}" ]; then zig build -Doptimize=ReleaseFast; fi
bin="${SIGMACORD_BIN:-$PWD/zig-out/bin/sigmacord}"
themes="${THEMES:-classico vidro terminal subsolo orbital editorial bolhas zen papel escritorio cupertino}"
reps="${REPS:-1}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cat >"$tmp/run.sh" <<EOF
#!/bin/sh
echo \$\$ >"\$1"; shift
unset SIGMACORD_TOKEN
export XDG_CONFIG_HOME="$tmp/cfg" XDG_CACHE_HOME="\${XDG_CACHE_HOME:-\$HOME/.cache}"
exec "\$@" >/dev/null 2>&1
EOF
chmod +x "$tmp/run.sh"
fail=0
printf "%-10s %10s %10s %12s\n" tema "RAM (PSS)" "anônima" "CPU parado"
for t in $themes; do
    for _ in $(seq 1 "$reps"); do
        rm -f "$tmp/pid"
        if command -v hyprctl >/dev/null && [ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
            hyprctl dispatch exec "[workspace special:sigma silent; float; size 1280 800] $tmp/run.sh $tmp/pid $bin --demo --theme $t --no-live" >/dev/null
        else
            "$tmp/run.sh" "$tmp/pid" "$bin" --demo --theme "$t" --no-live &
        fi
        for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$tmp/pid" ] && break; sleep 0.2; done
        pid=$(cat "$tmp/pid")
        # O "digitando" da demonstração anima nos primeiros 10 s.
        sleep 12
        t1=$(awk '{print $14+$15}' "/proc/$pid/stat"); sleep 5; t2=$(awk '{print $14+$15}' "/proc/$pid/stat")
        kb=$(awk '/^Pss:/{print $2}' "/proc/$pid/smaps_rollup")
        anon=$(awk '/^Pss_Anon:/{print $2}' "/proc/$pid/smaps_rollup")
        kill "$pid"; sleep 0.7; kill -9 "$pid" 2>/dev/null || true
        mb=$(awk -v k="$kb" 'BEGIN{printf "%.1f", k/1024}')
        an=$(awk -v k="$anon" 'BEGIN{printf "%.1f", k/1024}')
        cpu=$(awk -v d=$((t2 - t1)) 'BEGIN{printf "%.2f", d/5}')
        printf "%-10s %7s MB %7s MB %11s%%\n" "$t" "$mb" "$an" "$cpu"
        if awk -v m="$mb" -v b="$budget" 'BEGIN{exit !(m > b)}'; then fail=1; fi
    done
done
[ "$fail" = 0 ] || { echo "passou do orçamento de ${budget} MB"; exit 1; }
