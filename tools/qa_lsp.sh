#!/usr/bin/env bash
# QA dos erros de código (LSP), com o servidor de mentira embutido no binário:
# a bateria do cliente e, para cada modo, fechar o app com o servidor de pé e
# conferir de fora que ele morreu e que o app saiu sem precisar do vigia.
set -uo pipefail
cd "$(dirname "$0")/.."
zig build -Doptimize=debug -p .zig-cache/qa || exit 1
mkdir -p qa-out
bin=./.zig-cache/qa/bin/sigmacord
fail=0
out=$(QA_SUITE=lsp "$bin" --qa 2>&1 | grep -v '^info:')
echo "$out" | grep 'passaram'
if ! echo "$out" | grep -q ' 0 falharam'; then
    fail=1
    echo "$out" | sed -n '/^Falhas:/,$p' | sed 's/^/    /'
fi
for mode in normal stubborn hang noread; do
    rm -f qa-out/lsp-quit.pid
    start=$(date +%s%N)
    out=$(QA_SUITE=lsp-quit QA_LSP_MODE=$mode "$bin" --qa 2>&1)
    code=$?
    ms=$(( ($(date +%s%N) - start) / 1000000 ))
    pid=$(cat qa-out/lsp-quit.pid 2>/dev/null || echo "")
    if [ -z "$pid" ]; then
        echo "fechar com $mode: FALHOU (o servidor não subiu)"; fail=1; continue
    fi
    if kill -0 "$pid" 2>/dev/null; then
        echo "fechar com $mode: FALHOU (filho $pid continua vivo)"; kill -9 "$pid"; fail=1
    elif echo "$out" | grep -q 'encerramento demorou'; then
        echo "fechar com $mode: FALHOU (só saiu pelo vigia de 3 s)"; fail=1
    elif ! echo "$out" | grep -q ' 0 falharam'; then
        echo "fechar com $mode: FALHOU (bateria)"; echo "$out" | sed -n '/^Falhas:/,$p'; fail=1
    else
        echo "fechar com $mode: ok (filho $pid morto, app saiu com código $code em $ms ms no total)"
    fi
done
[ "$fail" = 0 ] && echo "lsp: tudo passou" || { echo "lsp: houve falhas"; exit 1; }
