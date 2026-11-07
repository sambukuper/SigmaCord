#!/usr/bin/env bash
# QA do HTTP dos plugins com TLS de verdade, contra um servidor local (nada sai da
# máquina): com o certificado aprovado a tradução chega; sem ele, o pedido é recusado.
# Fora de tools/qa.sh porque precisa de python3 e openssl. Use depois de tools/qa.sh.
set -uo pipefail
cd "$(dirname "$0")/.."
command -v openssl >/dev/null && command -v python3 >/dev/null || { echo "precisa de openssl e python3"; exit 1; }
bin=./.zig-cache/qa/bin/sigmacord
[ -x "$bin" ] || { echo "rode tools/qa.sh antes"; exit 1; }
dir=$(mktemp -d)
python3 -I tools/qa_http_tls.py "$dir" &
srv=$!
trap 'kill $srv 2>/dev/null; rm -rf "$dir"' EXIT
for _ in $(seq 50); do [ -s "$dir/port" ] && break; sleep 0.1; done
[ -s "$dir/port" ] || { echo "o servidor não subiu"; exit 1; }
base="https://localhost:$(cat "$dir/port")"
fail=0
go() {
    local label="$1"; shift
    local out; out=$(env "$@" QA_SUITE=plugins-tls QA_HTTP_BASE="$base" SDL_VIDEO_DRIVER=offscreen "$bin" --qa 2>&1 | grep -v '^info:')
    local line; line=$(echo "$out" | grep 'passaram')
    printf "%-28s %s\n" "$label" "${line%%(*}"
    if ! echo "$line" | grep -q ' 0 falharam'; then
        fail=1
        echo "$out" | sed -n '/^Falhas:/,$p' | sed 's/^/    /'
    fi
}
go "certificado aprovado" QA_HTTP_CAINFO="$dir/cert.pem"
go "certificado desconhecido" QA_HTTP_BAD_CA=1
# O que chegou no servidor: nada da conta, nenhum cookie.
if grep -qiE '^(authorization|cookie|x-super-properties|x-discord)' "$dir/requests.txt"; then
    echo "o pedido levou um cabeçalho proibido:"; cat "$dir/requests.txt"; fail=1
fi
grep -q 'GET /get?q=' "$dir/requests.txt" || { echo "o pedido não chegou"; fail=1; }
[ "$fail" = 0 ] && echo "tudo passou ✓" || { echo "houve falhas"; exit 1; }
