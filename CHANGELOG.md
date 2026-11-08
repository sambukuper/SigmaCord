# What changed in each version

## 0.7.0

**SigmaCord**
- This is the first release under the SigmaCord name. Everything was renamed: the window, the tray, the installer, the binary (`sigmacord`), the config folder (`~/.config/sigmacord`, was `~/.config/larpercord`), the environment variables (`SIGMACORD_TOKEN`, was `LARPER_TOKEN`) and the plugin API (`sigma.notify`, `sigma.send` and so on, was `larper.*`). Move your old `~/.config/larpercord` folder to `~/.config/sigmacord` to keep your settings, themes and plugins.

**Keybinds**
- Configurable keybinds: Settings → Keybinds lists every action with its key, click it and press a new combination to change it, and the × next to it goes back to the default. Assigning a key another action already uses moves it off that action.
- The microphone mute and the deafen toggles finally have keys, `Ctrl+Shift+M` and `Ctrl+Shift+D`, and both are rebindable like everything else.
- Every bind can be turned off by itself (the little square next to the key), and there is one switch to make all of them work outside the window too: on Windows (RegisterHotKey) and on Linux with X11 (XGrabKey) the keys then work in any program; on Wayland they stay window-focused, since the compositor decides about global keys. Off by default: a global key is taken away from every other program.
- The command palette, search, settings, fullscreen, next theme, inbox, saved messages and the tab actions are all in the same list. The fixed extras (Ctrl+Shift+P, interface zoom, Alt+1…9, Alt+Enter) stay as they were.
- The rule is the same one plugins already had: letters and digits need Ctrl, Alt or Super, and F1–F24 can go alone.

**Builds**
- Both release binaries now come from GitHub Actions: Linux portable and Windows cross-compiled, each with a build attestation. Nothing is built locally anymore; the release script only downloads, checks and signs.

## 0.6.1

**More languages and screens**
- The interface is available in Japanese, from nakayama900. Text with no translation yet appears in English.
- Japanese, Korean and Chinese text now shows up. The fonts only load the first time a letter needs them, and the interface language picks the letter forms.
- The interface follows the display scale on Windows and X11, from Davyd Khanin. It no longer comes out tiny at 125% or 150%.
- Settings → Appearance has an interface size from 75 to 200%, and Ctrl + , Ctrl - and Ctrl 0 change it from anywhere.
- F11 and Alt+Enter turn fullscreen on and off.
- Channel and user names in stylized letters (𝗠𝗲𝗺𝗲𝘀, ʀᴇɢʀᴀs) show as normal letters when no font has them, instead of `??????`. Settings → Advanced lists any writing systems that still have no font.

**Sharper**
- Small text is sharp. Sizes like 13.5 were generated at 14 and then shrunk like an image, which blurred almost all gray text.
- Text also lines up with screen pixels at sizes like 125%.
- Secondary text has a minimum contrast in every theme, including community themes.
- Settings → Advanced → Text changes the weight of the text and how letters fit the pixel grid, live.
- Avatars, icons and images are stored at the size they appear and reduced with a better filter. Before, a 128 px photo was shrunk by the graphics card without filtering, which made it jagged. It also uses less memory.
- Images no longer come out stretched or cropped in messages, embeds and the full-screen viewer, including after resizing the window.

**Calls**
- Fixed the bursts of loud noise, from Davyd Khanin. Some voice packets carry padding, and the app sent those to the decoder still encrypted.
- The start of a sentence after a pause no longer comes out louder than it should. Silence frames now go through the decoder, and it starts fresh after a pause or a large gap.
- Settings → Advanced has a debug log: turn it on, make the problem happen and send the file, with no terminal. It also records volume jumps and how many packets had padding.

**New**
- Search has a side panel with filters, sort order and pages. It searches this computer as you type, and Discord when you press Enter.
- Forward a message to another channel.
- Join a server from a link or code, and create and edit invites from the server and channel menus.
- GIF picker next to the emoji button: trending, search and your favorites from Discord. A GIF plays when you hover it.
- Copy an image from the full-screen viewer, and zoom in it with the mouse wheel. Ctrl+V pastes PNG, BMP, JPEG, GIF and WebP.
- Leave a server from its menu, with a confirmation.
- The pinned messages panel shows images, videos and link previews.
- Settings → Chat can download FFmpeg on Windows so videos play inside the app, with a warning first and a checked SHA-256.
- Settings → Performance has limits for images, each GIF and messages in memory.

**Fixes**
- While invisible you no longer appear online for a moment when the app opens. Your status now goes out with the first connection.
- Reconnecting is calmer: a connection only counts as good after a minute. A server that accepts and then drops the connection no longer means a new login attempt every few seconds.
- Holding Shift+J or Shift+K in Vim mode no longer sweeps through channels.
- Dragging the message scrollbar no longer gets stuck when the mouse drifts off it or older messages load.
- A GIF that declares a huge size is refused before decoding, from svindler, so a small file can't use up your memory.
- Themes with no user panel, like Zen, have a settings button in the header.
- Installed through a package manager, the app tells you to update through it.

**Project**
- SigmaCord is now licensed under GPL-3.0.

## 0.6.0

**Plugins**
- Translate has options now: target and source language on its card in Settings → Plugins, and "Translate to…" on the right-click menu for one message. A 🌐 on the message toolbar, and `/tr es hello` puts a translation in the message box.
- Scam guard marks in red the classic Discord scams in other people's messages: addresses that imitate Discord or Steam, fake free Nitro with a link, shortened links with bait. It runs on your computer, with no network, and official addresses are never marked.
- CVE radar finds `CVE-2021-44228` in messages and shows the severity, the CVSS score and a summary under it, from the official record. Each number is asked once, and only after you approve the host.
- GitHub cards put the title, the state and the stars under `owner/repo#123` and GitHub links.
- What did I miss sums up the unread messages in a channel: how many from each person, mentions of you, unanswered questions, links and files, with a click to each one.
- Also new: Clean links removes tracking from the links you send, and Links and files lists what was shared in the channel.
- Reminders understand times and dates (`/remind tomorrow 9am`, `/remind every day 8:30`), have a second list on the right-click menu, and what already fired can come back in 10 minutes.
- Highlights shows how many you haven't seen, can mute a channel, follows edits, and can use desktop notifications.
- Bookmarks, the word filter, snippets, timestamps, stats and the demo plugins no longer come with the app: the first two became built-in features. If you have them they keep working, and a button archives them to `plugins/antigos/`. Nothing is deleted.
- A bundled plugin with a newer version shows an update button on its card, and keeps your file as `.bak`.
- New for plugin authors: options on the card (`sigma.settings`, `select`, `toggle`), second lists and toolbar buttons on menus, suggestions in the message box (`sigma.completions`), rules for what you send (`sigma.rewrite`), `sigma.copy`, `sigma.open`, a number on the panel tab, red notes, the `edit`, `dismiss` and `hosts` events, a `contains` filter that keeps messages away from Lua, and attachments, replies, mentions and the read position in `sigma.messages`.
- A plugin that falls behind loses messages instead of holding up the others, and its card says so. Each plugin has its own limit of desktop notifications, so a noisy one doesn't eat a reminder's.
- The card warns about a plugin that reads messages and can also send something out.
- Closing a translation with its × no longer makes the next "Translate" do nothing.

**Messages**
- `<t:…>` times appear as a date or "in 2 hours", in your time zone, instead of the raw code.
- Over a link, the mouse cursor turns into a hand. Text selection was overriding it.
- Dragging the message scrollbar no longer selects text, and the resize handle no longer covers the scrollbar.
- Mark as read and mark as unread always reach Discord now. While invisible they stayed on your computer only and came back the next time you connected. Your status no longer stops read confirmations; an unfocused window still doesn't confirm on its own.

**Lighter**
- A frame that comes out the same as the last one isn't drawn again, so network events that change nothing on screen cost less.
- Moving the mouse with no button pressed asks for fewer frames.
- After a minute in the tray or minimized, images leave memory, except small ones that were on screen.
- Settings → Performance shows where the memory goes: images, messages, people, servers, fonts, driver and libraries.

**Accounts**
- The sign-in screen lists every saved account as a button, however you got there, with a warning to use a secondary account before you paste a token.
- When Discord refuses a token, the app forgets it instead of trying it again every time it opens. If the session ends with the app open, it goes back to the sign-in screen.

**Install**
- The Linux download runs on distros from about 2022 onward (glibc 2.34), and no longer needs a very recent one. SDL3, libcurl and OpenSSL now come inside it, so the file went from about 7 MB to about 15 MB.
- GitHub Actions builds the Linux file, opens it on Ubuntu, Debian, Fedora, openSUSE and Arch, and publishes an attestation you can check with `gh attestation verify`.
- The Linux installer names its shortcut after the window's app ID, so taskbars that look up the icon that way can find it. Running it again replaces the old shortcut.

## 0.5.0

**Windows**
- SigmaCord now runs on Windows 10 and 11, built from the same code.
- Tokens stay in Windows Credential Manager.

**Updates**
- Checks for a new version when opening or from Settings → Updates.
- One button downloads, installs and restarts. Updates are signed, and a version without the right signature isn't installed.
- Restart button in Settings, and this page.

**Voice**
- Microphone noise suppression with RNNoise, on by default and switchable mid-call. It doesn't run with the push-to-talk key released.
- Less stutter and no more clicks when packets are lost or arrive out of order; the audio buffer grows when the network hiccups.
- When the network stalls, the voice fades out instead of cutting off mid-word, and comes back without a pop.
- A pause from someone's noise gate is no longer treated as a bad network, which kept the audio delay low.
- Noise suppression uses less CPU in the published builds: it picks the faster path for your processor when it runs.
- People no longer cut out for a moment when someone joins or leaves the call.

**Tray**
- Closing and reopening no longer stacks up tray icons. On Linux the icon lives in a small separate process that only exists while the window is hidden, so GTK stays out of the app.

**Layout**
- Drag the edge of the channel list, the member list or the panes of a split view to resize them. A double-click goes back to the theme's width, and your choice is saved and follows you between themes.
- A narrow conversation keeps working: the search box steps aside before the buttons do.

**Messages**
- A BOT tag next to the name of bots and webhooks, with a check mark for verified bots, in messages, the member list, DMs and profiles.
- Webhook messages keep the name and picture each one was sent with.
- Bot messages in the newer component format, which used to appear blank. Forwarded messages and polls appear as cards.
- Text in embeds can be selected and copied.
- Discord markdown: headings, small text, quotes, lists and `[text](url)` links. Line numbers in code blocks.
- Selecting text inside a code block is visible now.
- Esc cancels editing a message.
- Right-clicking or middle-clicking a button no longer also triggers its normal click. In the message toolbar, for example, it used to add the reaction.
- Optional code diagnostics while typing a code block, from a language server you choose.

**Servers and groups**
- Edit a server (name, description, icon, banner) or a group DM (name, icon).
- Delete threads.
- Server banners at the top of the channel list and on invite cards.
- Click a server banner to see it in full, and the same for a profile banner. Server and user menus can open the icon or picture too.
- Friends, group and pin icons redrawn.

**Plugins**
- Plugins now run on a thread of their own: a slow or stuck one can't make the interface stutter, and it's stopped with the error on its card. With no plugin on, the thread doesn't exist and no Lua is loaded.
- New plugins that come with the app: bookmarks, reminders, highlights, local filter, snippets, translate and channel stats. Settings → Plugins installs them, without touching your files.
- Settings → Plugins shows a card for each plugin, from a manifest at the top of the file: name, description, version, what it asks for, errors and a way to open its panel, even when it's off.
- What plugins can do now: panels in a side panel you dock on either side, right-click entries on messages and people, badges, notes and collapsing with "show" under messages, their own storage, timers, desktop notifications, loaded messages, jumping to a message and inserting text in the message box.
- Optional HTTPS for plugins, only to hosts you approve one by one, with no cookies, token or Discord headers.
- Files in the plugin folder from before keep working, and the examples that came with the old versions aren't removed.

**Lighter**
- Smaller executable, faster opening and less memory.

## 0.4.0

First public version: real Discord connection, voice with end-to-end encryption, threads and forums, read state, search, Lua plugins and 11 themes.
