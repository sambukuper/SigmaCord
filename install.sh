#!/bin/sh
# Installs SigmaCord into ~/.local (no sudo) from the latest published version.
#   curl -fsSL https://raw.githubusercontent.com/sambukuper/SigmaCord/main/install.sh | sh
#   sh install.sh --uninstall
set -eu
repo="sambukuper/SigmaCord"
bin_dir="${HOME}/.local/bin"
app_dir="${HOME}/.local/share/applications"
icon_dir="${HOME}/.local/share/icons/hicolor/128x128/apps"

if [ "${1:-}" = "--uninstall" ]; then
    rm -f "$bin_dir/sigmacord" "$bin_dir/sigmacord.old" "$app_dir/dev.sigmacord.desktop" "$app_dir/sigmacord.desktop" "$icon_dir/sigmacord.png"
    echo "SigmaCord removed. Your settings are still in ~/.config/sigmacord."
    exit 0
fi

[ "$(uname -s)" = "Linux" ] || { echo "This script is for Linux. On Windows, use install.ps1."; exit 1; }
[ "$(uname -m)" = "x86_64" ] || { echo "Only x86_64 builds are published. On other architectures, build from source (see the README)."; exit 1; }
for tool in curl sha256sum; do
    command -v "$tool" >/dev/null || { echo "Missing command: $tool"; exit 1; }
done

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
base="https://github.com/$repo/releases/latest/download"
echo "Downloading the latest version..."
curl -fsSL --proto '=https' -o "$tmp/sigmacord-linux-x86_64" "$base/sigmacord-linux-x86_64"
curl -fsSL --proto '=https' -o "$tmp/SHA256SUMS" "$base/SHA256SUMS"
(cd "$tmp" && grep ' sigmacord-linux-x86_64$' SHA256SUMS | sha256sum -c --quiet -) || { echo "The download does not match SHA256SUMS. Nothing was installed."; exit 1; }

mkdir -p "$bin_dir" "$app_dir" "$icon_dir"
install -m 755 "$tmp/sigmacord-linux-x86_64" "$bin_dir/sigmacord"
curl -fsSL --proto '=https' -o "$icon_dir/sigmacord.png" "https://raw.githubusercontent.com/$repo/main/docs/assets/icon-180.png" || true
# Taskbars find the icon through the window's app ID, so the file carries that name.
rm -f "$app_dir/sigmacord.desktop"
cat > "$app_dir/dev.sigmacord.desktop" <<DESK
[Desktop Entry]
Type=Application
Name=SigmaCord
Comment=Native Discord client
Exec=$bin_dir/sigmacord
Icon=sigmacord
Terminal=false
Categories=Network;InstantMessaging;
StartupWMClass=dev.sigmacord
DESK

# SDL3, curl and OpenSSL come inside the binary. The rest comes from the system:
# report what is missing and how to get it.
missing="$(ldd "$bin_dir/sigmacord" 2>/dev/null | grep 'not found' || true)"
glibc="$(ldd "$bin_dir/sigmacord" 2>&1 | grep 'GLIBC_' || true)"
"$bin_dir/sigmacord" --help >/dev/null 2>"$tmp/err" || glibc="$(cat "$tmp/err")"
if [ -n "$missing" ]; then
    echo "Missing system libraries:"
    echo "$missing"
    cmd=""
    if command -v pacman >/dev/null; then cmd="sudo pacman -S --needed freetype2 fontconfig libwebp opus"
    elif command -v dnf >/dev/null; then cmd="sudo dnf install freetype fontconfig libwebp opus"
    elif command -v apt-get >/dev/null; then cmd="sudo apt-get install libfreetype6 libfontconfig1 libwebp7 libwebpdemux2 libopus0"
    elif command -v zypper >/dev/null; then cmd="sudo zypper install libfreetype6 fontconfig libwebp7 libwebpdemux2 libopus0"
    fi
    if [ -n "$cmd" ]; then
        echo "To install them: $cmd"
        if [ -t 0 ]; then
            printf "Run it now? [y/N] "
            read -r answer
            case "$answer" in y|Y) $cmd ;; esac
        fi
    fi
elif [ -n "$glibc" ]; then
    echo "The published build does not run on this system:"
    echo "$glibc" | head -3
    echo "Build from source: https://github.com/$repo#building"
    exit 1
fi

case ":$PATH:" in
    *":$bin_dir:"*) ;;
    *) echo "Add $bin_dir to PATH to run it from a terminal." ;;
esac
echo "Done. Open it from your app menu or with: sigmacord"
