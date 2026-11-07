#!/usr/bin/env bash
# QA completo: a bateria geral no tema classico, a tela de login e a bateria
# por tema em todos os temas, no escuro e no claro. Não abre janela. Prints em qa-out/.
set -uo pipefail
cd "$(dirname "$0")/.."
# Debug (com as checagens de segurança), instalado à parte para não trocar
# o executável de zig-out/ (que é ReleaseFast).
zig build -Doptimize=debug -p .zig-cache/qa || exit 1
rm -rf qa-out && mkdir -p qa-out
bin=./.zig-cache/qa/bin/sigmacord
total_fail=0
run() {
    local label="$1"; shift
    # Cada bateria começa sem o cache de mensagens da anterior.
    rm -rf qa-out/cache
    local out; out=$("$@" 2>&1 | grep -v '^info:')
    local line; line=$(echo "$out" | grep 'passaram')
    printf "%-24s %s\n" "$label" "${line%%(*}"
    if ! echo "$line" | grep -q ' 0 falharam'; then
        total_fail=1
        echo "$out" | sed -n '/^Falhas:/,$p' | sed 's/^/    /'
    fi
}
run "geral (classico)" $bin --qa --theme classico
QA_SUITE=extras SIGMACORD_NO_FFMPEG=1 run "extras" $bin --qa --theme classico
# Plugins: o que fica gravado ao fechar continua lá ao abrir de novo (outro processo).
QA_SUITE=plugins-a run "plugins (antes)" $bin --qa
sleep 2.5
QA_SUITE=plugins-b run "plugins (depois)" $bin --qa
for m in escuro claro; do
    QA_SUITE=login QA_PREFIX="$m-" run "login ($m)" $bin --qa --mode "$m"
done
for t in classico vidro terminal subsolo orbital editorial bolhas zen papel escritorio cupertino; do
    for m in escuro claro; do
        QA_SUITE=tema QA_PREFIX="$t-$m-" run "$t ($m)" $bin --qa --theme "$t" --mode "$m"
    done
done
[ "$total_fail" = 0 ] && echo "tudo passou ✓" || { echo "houve falhas"; exit 1; }
