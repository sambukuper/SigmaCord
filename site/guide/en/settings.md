# Settings and files

Open settings with `Ctrl+,`. Changes apply right away and are saved in `~/.config/sigmacord/settings.kdl`.

## The pages

| Page | What's there |
|---|---|
| **My Account** | Account details and log out |
| **Privacy** | Typing indicator, Tenor and Giphy animation, streamer mode, message log, keep messages on disk, clear cache, and the network proxy |
| **Alerts & Filters** | Alert words, word filter, ignored people and focus mode |
| **Appearance** | Mode (dark, light, follow the system), theme with thumbnails and its options, font scale, compact mode, avatars, 24-hour clock, status ring, accent color, corners, custom theme colors, member list, status bar and resetting panel sizes |
| **Accessibility** | Reduce motion, role colors, underline links |
| **Chat** | Autoplay GIFs, images from links, data saver, always show spoilers, markdown preview, open at the first unread |
| **Voice** | Microphone and output, volumes, voice activity or push-to-talk, microphone test, filters and call sounds. See [Voice calls](page:voice) |
| **Notifications** | Desktop notifications and taskbar flashing |
| **Keybinds** | The shortcut list and vim navigation |
| **Language** | Follow the system, Português (Brasil) or English (US) |
| **Advanced** | Developer mode (message IDs, "Copy ID") and reload themes on save |
| **Performance** | RAM, CPU per frame, idle CPU and messages per channel |
| **Plugins** | A card for each plugin (what it is and what it asks for), on/off, errors, host approvals, its panel, Reload and Install bundled plugins |
| **About** | Version and what it's built with |

## Privacy choices worth knowing

| Option | Default | Effect |
|---|---|---|
| Send typing indicator | on | Others see "typing…" while you write |
| Animate Tenor and Giphy GIFs | off | Downloads from their site, which sees your IP. When off, you get a still preview through Discord |
| Streamer mode | off | Hides your email and username in settings |
| Message log | off | Deleted messages stay visible, marked, and edits keep the original. Local only |
| Keep messages on disk | on | Chats open instantly and `Ctrl+F` works offline. Only your user can read the files |

## Files on disk

`$XDG_CONFIG_HOME` and `$XDG_CACHE_HOME` replace `~/.config` and `~/.cache` when set.

| Path | What it is |
|---|---|
| `~/.config/sigmacord/settings.kdl` | Settings, including per-theme options and colors |
| `~/.config/sigmacord/themes/*.kdl` | Your themes |
| `~/.config/sigmacord/plugins/*.lua` | Your plugins |
| `~/.config/sigmacord/plugins.kdl` | Which plugins are off, the hosts you approved, and the side panel |
| `~/.config/sigmacord/plugin-data/` | What each plugin stores, per account |
| `~/.config/sigmacord/drafts.kdl` | Unsent drafts per channel (`chmod 600`) |
| `~/.config/sigmacord/saved-<account>.json` | Saved messages and notes |
| `~/.config/sigmacord/accounts` | Saved accounts: ID, name and avatar only |
| `~/.config/sigmacord/tokens/<ID>` | Remembered tokens when there's no keyring (`chmod 600`) |
| `~/.config/sigmacord/token` | Optional token file (`chmod 600`) |
| `~/.cache/sigmacord/messages` | Message cache: folders 700, files 600, 200 messages per channel, 50 MB cap |
| `~/.cache/wal/colors` | Read only: pywal's palette, for themes that use it |

To go back to defaults, close the app and delete `~/.config/sigmacord/settings.kdl`.
