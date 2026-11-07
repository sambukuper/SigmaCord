#!/usr/bin/env bash
# Publica uma versão sem compilar nada aqui: os dois binários já saíram do CI
# (workflow release-builds). Este script confere os atestados dos dois, monta o
# zip do Windows, assina o SHA256SUMS e cria a release no GitHub com o trecho
# do CHANGELOG.md. Rode do main, sem nada pendente, depois que o release-builds
# passar neste commit.
#   tools/release.sh            (a versão vem de src/core/version.zig)
# A chave fica em ~/.config/sigmacord-release/ed25519.seed, fora do repositório.
set -euo pipefail
cd "$(dirname "$0")/.."
ver=$(sed -n 's/^pub const number = "\(.*\)";/\1/p' src/core/version.zig)
key="${SIGMACORD_RELEASE_KEY:-$HOME/.config/sigmacord-release/ed25519.seed}"
[ -f "$key" ] || { echo "sem a chave em $key"; exit 1; }
command -v zip >/dev/null || { echo "falta o zip"; exit 1; }
command -v zig >/dev/null || { echo "falta o zig (só para assinar: zig run tools/release_sign.zig)"; exit 1; }
[ -z "$(git status --porcelain --untracked-files=no)" ] || { echo "há mudanças sem commit"; exit 1; }
[ "$(git rev-parse --abbrev-ref HEAD)" = main ] || { echo "rode do main"; exit 1; }
grep -q "^## $ver\$" CHANGELOG.md || { echo "CHANGELOG.md sem a seção $ver"; exit 1; }
if gh release view "v$ver" >/dev/null 2>&1; then echo "v$ver já existe"; exit 1; fi

# A pasta temporária não é um repositório: o gh precisa ouvir qual é, e de que commit.
repo=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
commit=$(git rev-parse HEAD)
run=$(gh run list --repo "$repo" --workflow release-builds --commit "$commit" --status success --limit 1 --json databaseId --jq '.[0].databaseId // empty')
[ -n "$run" ] || { echo "o release-builds ainda não passou em $commit"; exit 1; }

out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
# Linux e Windows vêm dos artefatos do CI, com o atestado de cada um.
gh run download "$run" --repo "$repo" --name sigmacord-linux-x86_64 --dir "$out/linux"
gh run download "$run" --repo "$repo" --name sigmacord-windows-x86_64 --dir "$out/win-bin"
gh attestation verify "$out/linux/sigmacord" --repo "$repo" --source-ref refs/heads/main --source-digest "$commit"
gh attestation verify "$out/win-bin/sigmacord.exe" --repo "$repo" --source-ref refs/heads/main --source-digest "$commit"
install -m 755 "$out/linux/sigmacord" "$out/sigmacord-linux-x86_64"
install -m 755 "$out/win-bin/sigmacord.exe" "$out/sigmacord-windows-x86_64.exe"
cp "$out"/win-bin/*.dll "$out/"
# O .exe não abre sem as DLLs: quem baixa pelo site recebe tudo junto.
mkdir "$out/SigmaCord"
cp "$out/sigmacord-windows-x86_64.exe" "$out"/win-bin/*.dll "$out/SigmaCord/"
(cd "$out" && zip -qr sigmacord-windows-x86_64.zip SigmaCord)
assets=(sigmacord-linux-x86_64 sigmacord-windows-x86_64.zip sigmacord-windows-x86_64.exe SDL3.dll libcurl-x64.dll libcrypto-3-x64.dll)
(cd "$out" && sha256sum "${assets[@]}" > SHA256SUMS)
zig run tools/release_sign.zig -- sign "$key" "$out/SHA256SUMS"
awk -v v="## $ver" '$0==v{on=1;next} /^## /{on=0} on' CHANGELOG.md > "$out/notes.md"
cd "$out"
gh release create "v$ver" --repo "$repo" --target "$commit" --title "SigmaCord $ver" --notes-file notes.md "${assets[@]}" SHA256SUMS SHA256SUMS.sig
