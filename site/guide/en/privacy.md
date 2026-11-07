# Privacy and security

> [!WARNING]
> **Third-party clients break Discord's Terms of Service, and your account can be banned.** Nothing on this page changes that. The sections below describe how the app treats your data, not whether Discord will accept it.

## Your token

- It's never in the code, logs or error messages.
- It's wiped from memory when the app exits.
- It's stored in the system keyring when possible. Without one, it goes in a file with `chmod 600`, and the app warns you if the file is readable by others.
- With "Remember" on, it's only saved after Discord accepts it.
- `SIGMACORD_VOICE_DEBUG` and `SIGMACORD_DEBUG_MEDIA` never print tokens or keys.

It's only sent to Discord.

## Read confirmations

Like the official client, the app tells Discord what you've read, at most once per channel every 3 seconds. It sends nothing on its own while the window is unfocused. Marking something as read or unread yourself always goes through, and your status doesn't change any of this.

## What stays on your computer

| What | Where | Control |
|---|---|---|
| Message cache | `~/.cache/sigmacord/messages`, folders 700, files 600 | 200 messages per channel, 50 MB cap. Turn it off and erase it in Settings → Privacy |
| Drafts | `drafts.kdl`, `chmod 600` | Sending a message clears its draft |
| Saved messages and notes | `saved-<account>.json` | Up to 500. Nothing goes to Discord |
| Alert words, filters, ignored people | `settings.kdl` | Nobody is told |
| Message log | Local, on screen | Off by default |

The complete list is in [Settings and files](page:settings).

## What goes over the network

The only request that isn't to Discord or its CDNs is the update check: when the app opens (if "Check when opening" is on) or when you press the button, it asks `api.github.com` for the latest version, and sends no account data. Downloads come from GitHub and are checked against a signed list.

- **Discord**: gateway, REST and media.
- **External media, only when you ask for it**: animated Tenor and Giphy GIFs are off by default because those sites see your IP. When off, you get a still preview through Discord's proxy.
- Links open in your browser.

Media downloads only go to allowed hosts, redirects are checked, images are limited to 8192 pixels per side, and downloads stop at 32 MB for images and 64 MB for video.

There's no telemetry or analytics in the app.

## Proxy

Settings → Privacy → Network accepts `http`, `https`, `socks5` and `socks5h`. For Tor, use `socks5h://127.0.0.1:9050`.

By default, the proxy applies to media from outside Discord. **Use the proxy for everything** also routes the API, images, videos and the gateway through it (the gateway from the next connection on).

## Plugins

Plugins run with your account, so only use files you've read and understand. The sandbox limits what they can do:

- A plugin never sees your token or your email.
- No file, process or socket access. `io`, `os.execute`, `os.remove`, `os.getenv`, `require`, `package`, `debug`, `coroutine`, `load`, `loadfile`, `dofile`, `collectgarbage` and `string.dump` don't exist.
- About 5 million instructions per call and 8 MB of memory per plugin, on a thread of their own.
- `sigma.send` only works directly from a gesture on that plugin (its command, keybind, button or menu entry), because automatic replies would turn your account into a self-bot.
- The only network is `sigma.http`: HTTPS only, to hosts the plugin declares and you approve one by one in Settings → Plugins, with no cookies, token or Discord headers. Nothing goes out until you approve. A plugin with the `links` capability can also open an address in your browser, when you click something of its own, and its card says so.
- A plugin's data stays in `~/.config/sigmacord/plugin-data/`, separate per plugin and account, readable only by you. The plugins that come with the app don't keep the text of messages after they're deleted.

The details are in [Lua plugins](page:plugins).

## Streamer mode

Hides your email and username in settings. It doesn't hide anything else on screen.

## Reporting a problem

Open an issue on [GitHub](https://github.com/sambukuper/SigmaCord/issues). If it involves leaking a token or anything sensitive, don't include real tokens in the report.

## If Discord locks your account

Discord disables accounts or forces a password reset when it thinks an account is a spam bot or was compromised. It can happen on any client, but third-party clients tend to trigger it more often. It already happened to this project's developer, after a day of testing. **Use a secondary account.**

These are the usual triggers people report, so do them in the official client:

- joining or leaving servers, the most common one
- disconnecting and reconnecting often, which includes restarting the app over and over
- opening DMs with new people
- changing your friends list
- editing your profile while connected here

If it happens, reset your password from discord.com. If the account stays locked, [appeal here](https://support.discord.com/hc/en-us/requests/new?ticket_form_id=360000029731). Discord doesn't publish these rules, so this list comes from the experience of people who make third-party clients.

## If your antivirus complains

The Windows build isn't signed, so SmartScreen warns about it. A scanner may also call it a Discord token stealer, likely because a Discord client is full of the same words a stealer has, such as "token" and "Authorization". One sandbox scored version 0.5.0 that way from a pattern rule, while its behavior report showed no credential access and, in demo mode, no network at all.

The token only goes to Discord, and it stays in the system keyring or, without one, in a private file. The code is public, so you can read it or build it yourself. Only download SigmaCord from this repository.
