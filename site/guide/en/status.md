# Status and roadmap

SigmaCord is a young project: version 0.6.0, with its first commit on November 2, 2026. It's usable, but it isn't complete.

## What works today

| Area | State | Detail |
|---|---|---|
| Messages, DMs, reactions, replies | **works** | Send, edit, delete, history, mentions |
| Images | **works** | Avatars and attachments, with a fixed-size cache |
| Video in chat | **works** | Attachments and direct links. Needs the system's FFmpeg |
| Inbox, saved messages, offline search | **works** | All local, can be turned off and erased |
| Multiple accounts, proxy, Lua plugins | **works** | |
| Threads and forums | **works** | Nested threads, forum post lists, creating threads and posts, archived ones |
| Custom emoji, stickers, autocomplete | **works** | Animated too. The picker warns when an emoji needs Nitro |
| Read state, pins, Discord links | **works** | Synced with your other devices |
| Themes | **works** | 11 built-in, each light and dark, reload on save |
| Voice | partial | E2EE (DAVE), mixer, mute, device picker, push-to-talk, high-pass filter, noise gate and RNNoise noise suppression work. Push-to-talk needs the window focused, and no automated test covers a real call |
| Permissions | partial | Channels without access get a padlock, voice without permission is blocked, and threads and forums check whether you can post. Those channels still appear, and the composer in regular channels, reactions and the member list don't check permissions |
| System tray, updates | **works** | Closing keeps it in the tray; signed updates from Settings. On Linux the tray needs a StatusNotifier panel |
| Windows | partial | Windows 10/11 from the same code. Newer than Linux and less used |
| Notifications | partial | Through `notify-send` on Linux and the tray on Windows. Clicking doesn't open the channel |
| Accessibility | partial | Font scale, reduced motion, palette and vim navigation. No visible focus and no high contrast |
| First run | partial | Sign-in screen and demo mode, no introduction to the app |
| Platforms | partial | Linux and Windows. The Linux build needs glibc 2.34 or newer. It's used daily on Arch with Hyprland, and opened in Ubuntu, Debian, Fedora, openSUSE and Arch containers, in demo mode, before each release. The Windows build has only been run in CI and in a sandbox, in demo mode |
| Joining a server by invite | missing | Invites show as a card and open in the browser |
| Screen sharing and camera | missing | |

## Roadmap

**Done**

- [x] Real gateway (WebSocket, heartbeat, reconnects) and REST respecting rate limits
- [x] Session RESUME and zlib-stream
- [x] Presences, members and server and channel events
- [x] Images: avatars, attachments and custom emoji with a fixed-size cache
- [x] Voice: voice gateway, UDP, Opus and DAVE/MLS
- [x] Voice settings: device picker, push-to-talk, filters and call sounds
- [x] Threads and forums
- [x] Stickers, the full emoji picker and autocomplete
- [x] Read state synced with Discord, pinned messages, Discord links in the app
- [x] Theme engine: gradients, patterns, grain, vignette, display typography, shapes and rules, procedural backgrounds

**Next**

- [ ] Open from the saved servers, channels and messages, then sync when Discord answers
- [ ] Rich Presence: show the game you're playing, off by default
- [ ] Moderation: kick, ban, timeout, and server mute and deafen
- [ ] A texture atlas for avatars and emoji
- [ ] Server and role settings
- [ ] A better theme editor
- [ ] More versatile and more powerful plugins
- [ ] Windows as a single `.exe`

**To make the app complete**

- [ ] Real permissions: hide what you can't see, disable composer and reactions, filter members
- [ ] Join a server by invite
- [ ] Native D-Bus notifications with "open conversation"
- [ ] Voice: a global push-to-talk and an automated call test
- [ ] Accessibility and first run: visible focus, high contrast, a welcome screen

**Themes**

- [ ] Engine: overlay and z-order, fonts and images bundled with a theme
- [ ] Gallery and editor: real thumbnails, import and export `.kdl`, a component inspector
- [ ] Theme components written in Lua (sandboxed)

**Later**

- [ ] A software backend (`wl_shm`, no GPU), to get to about 15–20 MB
