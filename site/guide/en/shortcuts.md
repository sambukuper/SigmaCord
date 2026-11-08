# Shortcuts and CLI

## Keyboard

| Action | Keys |
|---|---|
| Mute / unmute the microphone | `Ctrl+Shift+M` |
| Deafen / undeafen | `Ctrl+Shift+D` |
| Command palette | `Ctrl+K` |
| Palette, actions first | `Ctrl+Shift+P` |
| Search messages | `Ctrl+F` |
| Settings | `Ctrl+,` |
| Next theme | `F2` |
| Previous theme | `Shift+F2` |
| Next tab | `Ctrl+Tab` |
| Previous tab | `Ctrl+Shift+Tab` |
| Go to tab N | `Alt+1…9` |
| Close tab | `Ctrl+W` |
| Inbox | `Ctrl+I` |
| Saved messages | `Ctrl+Shift+S` |
| Open channel in a new tab | `Ctrl+Click` |
| Close tab with the mouse | Middle click |
| Edit your last message | `↑` in an empty box |
| Cancel a reply or edit | `Esc` |
| Copy the selected text | `Ctrl+C` |
| New line in the composer | `Shift+Enter` |
| Autocomplete in the composer | `@`, `#`, `:ab` or `/`, then the arrows and `Tab` or `Enter` |
| Push to talk | The key or mouse button you pick in Settings → Voice |

Everything from "Mute / unmute the microphone" down to "Close tab" is a bind: change it in Settings → Keybinds (click the key, press a new combination; the × next to it restores the default, the little square turns the bind on and off, and letters and digits need Ctrl, Alt or Super). One switch makes all of them work outside the window too — on Windows and on Linux with X11 they then work in any program (on Wayland they stay window-focused); off by default, because a global key is taken away from every other program. The rest of the table is fixed.

Right-click works on messages, users, channels and servers.

## Vim navigation

It's off by default. Turn it on in Settings → Keybinds. The keys work while the text box doesn't have focus.

| Action | Keys |
|---|---|
| Scroll down / up | `j` / `k` |
| Top / bottom of the conversation | `gg` / `G` |
| Half page down / up | `Ctrl+d` / `Ctrl+u` |
| Next / previous channel | `J` / `K` |
| Back to the text box | `i` or `Enter` |
| Leave the text box, keeping the text | `Esc` |
| Search (palette) | `/` |

## Command line

```bash
sigmacord [options]
```

| Option | What it does |
|---|---|
| `--theme NAME` | starts with this theme |
| `--list-themes` | lists the built-in themes and exits |
| `--mode MODE` | `claro` (or `light`) or `escuro`, ignoring your settings |
| `--lang LANG` | `pt` or `en`, ignoring your settings |
| `--demo` | uses the demo data even with a token |
| `--login` | shows the sign-in screen, ignoring the saved token |
| `--settings` | opens straight into settings |
| `--no-live` | turns off the demo mode's automatic messages |
| `--shot FILE.png` | saves a screenshot once the screen settles, then exits |
| `--stats` | shows the time to first frame |
| `--qa` | runs the automatic UI test, with screenshots in `qa-out/` |
| `--voice-test GUILD CHANNEL` | joins a voice channel for 25 s, always muted (needs `SIGMACORD_TOKEN`) |
| `--help` | shows the usage text |

## Environment variables

| Variable | What it does |
|---|---|
| `SIGMACORD_TOKEN` | the account token (see [Connect your account](page:account)) |
| `SIGMACORD_RENDERER` | picks the SDL render backend: `opengl`, `vulkan`, `gpu` or `software` |
| `SIGMACORD_HIDDEN` | opens with a hidden window. The app draws nothing while hidden, so memory reads much lower than with a real window |
| `SIGMACORD_BENCH` | redraws nonstop, to measure the cost of a frame |
| `SIGMACORD_VOICE_DEBUG` | prints what happens in a call (opcodes, close codes, DAVE). It never prints tokens or keys |
| `SIGMACORD_DEBUG_MEDIA` | logs why an image failed to load |
| `SIGMACORD_NO_FFMPEG` | pretends FFmpeg isn't installed |
| `SIGMACORD_EGL_ALL` | turns off the trick that skips unneeded EGL drivers |
| `SIGMACORD_SCENE` | sets up a scene for documentation screenshots |
| `SIGMACORD_RECORD`, `SIGMACORD_RECORD_FRAMES` | records the sign-in screen as frames in a folder |
| `SIGMACORD_FLOOD` | sends N presence changes per second in demo mode (load test) |

`XDG_CONFIG_HOME` and `XDG_CACHE_HOME` are respected, and they're handy for running with a clean configuration.
