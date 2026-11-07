# Getting started

SigmaCord is a native Discord client for Linux and Windows, written in Zig. You can run it without an account: `--demo` starts **demo mode**, with fake servers and fake people, and it doesn't connect to anything. With no token configured, the app opens the sign-in screen, which also offers the demo.

> [!WARNING]
> **Third-party clients break Discord's Terms of Service**, and your account can be banned. Use a real account at your own risk, ideally a secondary one. This project has no affiliation with Discord Inc.

## What you need

| | |
|---|---|
| Operating system | Linux (tested daily on Arch with Hyprland) or Windows 10/11 |
| Compiler | Zig 0.17 |
| Libraries | SDL3, FreeType, fontconfig, libcurl (with WebSocket support, 7.86 or newer), zlib, libwebp, Opus, OpenSSL |
| Recommended fonts | Inter, JetBrains Mono and Noto Color Emoji. fontconfig picks substitutes if one is missing |
| Optional | FFmpeg 7, 8 or 9 (libavformat 61–63) to play video inside the app. Any other version is ignored and videos open in the browser |

## Install

**Download:** [Linux](https://github.com/sambukuper/SigmaCord/releases/latest/download/sigmacord-linux-x86_64) · [Windows](https://github.com/sambukuper/SigmaCord/releases/latest/download/sigmacord-windows-x86_64.zip) · [all versions](https://github.com/sambukuper/SigmaCord/releases). On Linux, `chmod +x` the file and run it. On Windows, unzip it and open `sigmacord.exe`; it isn't code-signed yet, so Windows may warn you the first time.

The Linux build runs on distros from about 2022 onward (glibc 2.34 or newer). SDL3, libcurl and OpenSSL come inside it. FreeType, fontconfig, libwebp, Opus and zlib come from the system, and a desktop distro usually has them already. Before each release it's opened in Ubuntu 22.04 and 24.04, Debian 12 and 13, Fedora, openSUSE and Arch containers, in demo mode with no GPU.

GitHub Actions builds that file from this repository's code. With the GitHub CLI you can check it: `gh attestation verify sigmacord-linux-x86_64 --repo sambukuper/SigmaCord`.

Or use a script:

On Linux (into `~/.local`, no sudo):

```bash
curl -fsSL https://raw.githubusercontent.com/sambukuper/SigmaCord/main/install.sh | sh
```

On Windows, in PowerShell (for your user, no administrator):

```powershell
irm https://raw.githubusercontent.com/sambukuper/SigmaCord/main/install.ps1 | iex
```

Both check the download against `SHA256SUMS`. On Linux the script lists any system library that's missing. After that the app updates itself from Settings → Updates.

The table above matters if you build from source, below.

## Build and run

```bash
# Arch Linux
sudo pacman -S zig sdl3 freetype2 fontconfig curl zlib libwebp opus openssl \
    inter-font ttf-jetbrains-mono noto-fonts-emoji

git clone https://github.com/sambukuper/SigmaCord
cd SigmaCord

zig build -Doptimize=ReleaseFast
./zig-out/bin/sigmacord --demo
```

Everything else is already in the repository: Dear ImGui, Lua, stb_image, libdave, MLSpp and nlohmann/json are copied into `third_party/`, so the build downloads nothing.

## Your first five minutes

1. Press `F2` a few times. Every press swaps the whole theme file.
2. Press `Ctrl+K` and type `theme`, or a channel name. That's the command palette, and almost everything is in it.
3. Press `Ctrl+,` to open settings. Look at Appearance, where each theme has its own options.
4. Right-click a message, a user, a channel and a server. Everything has a menu.
5. Copy a theme and edit it while the app is open:

```bash
mkdir -p ~/.config/sigmacord/themes
cp themes/orbital.kdl ~/.config/sigmacord/themes/mine.kdl
$EDITOR ~/.config/sigmacord/themes/mine.kdl
```

Change the `theme "orbital"` line to `theme "mine"`, pick it with `F2` or in the palette, and every save reloads the window. If you make a mistake, a notice shows `file:line:column` and the previous version stays on screen. [Writing themes](page:themes) has the whole language.

## Next steps

- [Connect your account](page:account), if you accept the risk.
- [Feature tour](page:features), to see what's in there.
- [Shortcuts and CLI](page:shortcuts), for every key and flag.
