# Lua plugins

**English** · [Português](plugins.pt-BR.md)

Plugins are small scripts that add features to the app with no recompiling: panels, right-click
entries, commands, reminders, notes under messages. Every `.lua` file in

```
~/.config/sigmacord/plugins/          ($XDG_CONFIG_HOME/sigmacord/plugins, if set)
```

is a plugin. Open **Settings → Plugins** (`Ctrl+,`) to see what each one is, what it asks for and
any error it hit, turn it on or off (the choice is kept in `~/.config/sigmacord/plugins.kdl`),
approve the hosts it wants to talk to, open its panel and **Reload** after editing a file.

## The plugins that come with the app

**Settings → Plugins → Install bundled plugins** copies the missing ones to your folder. It never
overwrites a file you've edited and never removes anything.

| Plugin | What it does |
|---|---|
| [`translate.lua`](plugins/translate.lua) | Right-click a message, or the 🌐 on its toolbar, to see the translation under it. "Translate to…" picks another language for one message, its card sets the default target and source, and `/tr es hello` puts a translation in the message box. Off until you approve the host: see [HTTP](#sigmahttp) |
| [`reminders.lua`](plugins/reminders.lua) | `/remind 10m call back`, `/remind tomorrow 9am pay the bill`, `/remind every day 8:30 standup`, or "Remind me" on a message. Notifies you at the right time, also after a restart. What already fired can come back in 10 minutes |
| [`highlights.lua`](plugins/highlights.lua) | Words to watch across all channels: a notification, a number on the panel for what you haven't seen, and a history that takes you to the message. You can mute a channel |
| [`scamguard.lua`](plugins/scamguard.lua) | Marks in red the classic Discord scams in other people's messages: addresses that imitate Discord or Steam (swapped letters, another alphabet, a disguised subdomain), fake free Nitro and gifts with a link, shortened links with bait, links that show one address and open another. Official addresses and talk with no link are never marked. "Not a scam" on a message keeps that address on a list for your account. `/scam` opens the panel with the latest ones. No network |
| [`cve.lua`](plugins/cve.lua) | Finds `CVE-2021-44228` and the like in messages and shows the severity, the CVSS score and a short summary under them, from the official CVE record. `/cve CVE-2021-44228` looks one up by hand, and the panel lists what was seen, worst first. Only the number goes out, once you approve the host; each answer is kept for days |
| [`github.lua`](plugins/github.lua) | `owner/repo#123` and links to GitHub issues, pull requests and repositories get a note with the title, the state and the stars. Public repositories only, with no login: GitHub allows few requests per hour without one, so answers are kept for a while and at the limit the notes just wait. Off until you approve the host |
| [`catchup.lua`](plugins/catchup.lua) | `/missed` or the panel sums up the unread messages in the open channel, or the last ones: how many from each person, mentions of you, questions left unanswered, links and files, each with a click to the message. It only looks when you ask |
| [`cleanlinks.lua`](plugins/cleanlinks.lua) | Removes tracking from the links you send (`utm_*`, `fbclid`, YouTube's and Spotify's `si`…). The app applies the rules when you send: the plugin doesn't see what you write |
| [`links.lua`](plugins/links.lua) | Every link and file in the messages loaded in the open channel: search, open, copy, go to the message. It only looks while its panel is open and keeps nothing on disk |

None of them keeps the text of a message after it's deleted or edited: the plugin hears about it and
drops the old text. Highlights never writes other people's text to disk.

**New version of a bundled plugin:** when the app brings a newer `@version` of a file you have, its
card shows **Update to vX**. It only changes on that click, and your file stays next to it as
`name.lua.bak` (then `.bak2`, and so on): nothing is overwritten.

**No longer bundled:** bookmarks and the word filter became the app's own Saved messages and Alerts
and filters; snippets, timestamps, stats and some demos (calc, shrug, dice…) left. If you have them
they keep working, and **Archive to antigos/** moves them to `plugins/antigos/`, which isn't loaded.
Nothing is deleted. The app still shows `<t:…>` times as dates, with or without a plugin.

## How plugins run

Plugin code runs on a thread of its own, never on the interface thread, so a slow or stuck plugin
can't make the app stutter. The interface and that thread only talk through two queues.

- Each plugin has its own Lua 5.4 state: one can't see another.
- **With no plugin on, the thread doesn't exist** and no Lua state is created. With plugins on and
  nothing happening, the thread is asleep: no polling, no timers, no frames. A plugin with a pending
  timer wakes it when that's due (and once a minute if the timer is far away, because a computer can
  sleep in the meantime).
- Plugins start when you're logged in, and start again when you switch accounts: each account has
  its own data.
- Everything a plugin sends to the screen is data (a tree, a rule, a note, a list of suggestions).
  The app draws and applies it on its own, without calling Lua per message, per frame or per key.
- There's no event for presence, typing or voice: they fire so often that listening to them would be
  a steady cost even with the plugin doing nothing.
- If the queue falls behind, a plugin that takes too long on each message loses messages instead of
  holding up the others. Its card says how many.

## An example

```lua
-- @name Shrug
-- @name:pt Dar de ombros
-- @description /shrug sends a shrug.
-- @description:pt /shrug manda um dar de ombros.
-- @version 1.0.0
-- @capabilities send

sigma.command("/shrug", function(args)
  local text = "¯\\_(ツ)_/¯"
  if args ~= "" then text = args .. " " .. text end
  sigma.send(sigma.channel(), text)
end)
```

Type `/shrug no idea` in the message box and the channel receives `no idea ¯\_(ツ)_/¯`. The
`/shrug` itself never goes to Discord.

## The manifest

The comments at the top of the file say what the plugin is. The app reads them without running
anything, so the settings page shows them even for a plugin that's off.

| Line | What it's for |
|---|---|
| `-- @name Bookmarks` | The name (and `-- @name:pt Favoritos` in Portuguese) |
| `-- @description …` | One or two sentences (and `-- @description:pt …`) |
| `-- @version 1.0.0` | Shown next to the name |
| `-- @capabilities menu, panel, storage` | What it asks for. Shown on its card, and the only things it can use |
| `-- @hosts api.example.com` | The hosts for [`sigma.http`](#sigmahttp), just the name. No IP address, port or Discord domain |

| Capability | Gives access to |
|---|---|
| `messages` | `sigma.on("message")`, `sigma.on("edit")`, `sigma.on("delete")`, `sigma.messages` |
| `send` | `sigma.send` |
| `notify` | `sigma.notify` |
| `storage` | `sigma.storage` |
| `timers` | `sigma.after`, `sigma.every` |
| `panel` | `sigma.panel` |
| `menu` | `sigma.menu` |
| `decorate` | `sigma.decorate`, `sigma.undecorate`, `sigma.rules`, `sigma.on("dismiss")` |
| `composer` | `sigma.insert` |
| `http` | `sigma.http` (needs `@hosts`) |
| `lsp` | `sigma.lsp` |
| `settings` | `sigma.settings` |
| `completions` | `sigma.completions` |
| `rewrite` | `sigma.rewrite` (its card says "Changes what you send") |
| `links` | `sigma.open` (its card says "Opens links") |

Commands, keybinds, `sigma.channel`, `sigma.guild`, `sigma.jump`, `sigma.copy`, `sigma.tr` and
`sigma.json` don't need any capability. Calling something the manifest doesn't ask for raises an error that says
what to add.

**Files with no manifest** keep working: they are "old API" plugins, with `messages`, `send`,
`notify` and `lsp`. To use anything newer, add a manifest. A manifest with a mistake (an unknown
capability, a bad host) stops the plugin from starting, and the card says why. A plugin that reads
messages and can also send something out (`messages` with `http` or `links`) gets a warning line on
its card, on top of the labels.

## Limits

These are what make it safe to run other people's scripts next to your account.

- **A plugin never sees your token or your email.**
- **Sending a message only works directly from a gesture on that plugin**: its command, keybind,
  panel button (or Enter in one of its inputs) or menu entry. Not at load time, in an event, in a
  timer or in the answer to an HTTP request. Replying on its own would turn the account into a
  *self-bot*, which Discord forbids and usually punishes with a ban. There are no auto-replies,
  auto-reactions or anything else that writes to the account in the background.
- `sigma.insert`, `sigma.jump`, `sigma.copy`, `sigma.open` and `sigma.panel.open` also need a
  gesture: a background plugin can't type into your message box or move you around. The one
  exception: the answer to an HTTP request made in a gesture can call `sigma.insert`. It still can't
  send.
- **No files, programs or raw sockets.** Only `string`, `table`, `math`, `utf8` and the basic
  functions, plus `os.time`, `os.date`, `os.clock` and `os.difftime`. There is no `io`,
  `os.execute`/`os.remove`/`os.getenv`, `require`, `package`, `debug`, `coroutine`, `load`,
  `loadfile`, `dofile`, `collectgarbage` or `string.dump`.
- **Instructions**: each call (loading the file, an event, a command…) can run up to ~5 million
  instructions. Go past that and the plugin is **stopped**, with the error on its card. `pcall` can't
  catch this error.
- **Memory**: up to 8 MB per plugin; going over is a regular `not enough memory` error.
- **Errors** don't bring the app down: they become a red notice and are written on the plugin's card,
  with `file:line`. An error while loading the file, or 10 errors later on, stops the plugin. Fix the
  file and click **Reload** (or turn it off and on).
- Files over 256 KB aren't loaded; at most 64 plugins. If events arrive faster than a plugin handles
  them, the excess messages are dropped; what you do on it never is.

Plugins run with your account: only use files you've read and understand.

## API

Everything lives in the global table `sigma`. Discord IDs are strings (`"1234567890"`).

### `sigma.on(event, function)`

| event | when | argument |
|---|---|---|
| `"message"` | a new message arrives in any channel (including your own) | `msg` |
| `"edit"` | someone edited a message | `msg`, with the new text |
| `"delete"` | a message was deleted | `{ id, channel }` (IDs) |
| `"dismiss"` | you closed this plugin's note with its × | `{ id }` |
| `"ready"` | the app connected (or the plugin started while the app was already connected) | none |
| `"channel"` | you opened another channel | `{ id, name }`, or `nil` |
| `"lang"` | the app's language changed: draw your panel again | none |
| `"panel"` | your panel opened or closed on the screen | `true` or `false` |
| `"hosts"` | you approved or removed a host on the plugin's card | none |

`msg` has:

| field | example |
|---|---|
| `msg.content` | `"good morning"` |
| `msg.author` | `{ id = "1001", name = "ana" }` |
| `msg.channel` | `{ id = "5000", name = "general" }` |
| `msg.guild` | `{ id = "500", name = "Server" }`, or `nil` in direct messages |
| `msg.mine` | `true` if you sent it |
| `msg.ignored` | `true` if you ignore whoever wrote it |
| `msg.id` | `"1350000000000000000"` |
| `msg.time` | seconds since 1970 |
| `msg.attachments` | how many |
| `msg.files` | only from `sigma.messages({ files = true })`: a list of `{ name, url, size }` |
| `msg.reply_to` | the ID of the message it replies to, if any |
| `msg.mentions_me` | only from `sigma.messages`: `true` if it calls you (a mention, one of your roles, `@everyone`) |

`"message"` and `"edit"` take a third argument, `{ contains = { "cve-", "://" } }` (up to 16 pieces of
text, ignoring case): your function only runs for messages with one of them, and the others don't even
reach Lua. Use it whenever you can, so a plugin that cares about few messages costs nothing on the rest.

The history loaded when you open a channel doesn't fire `"message"`, only what arrives live.
System messages (someone joined, pinned…) don't either. A plugin never gets what was deleted, or a
message's text from before it was edited, not even with the message log turned on.

```lua
sigma.on("message", function(msg)
  if not msg.mine and msg.content:lower():find("pizza", 1, true) then
    sigma.notify(msg.author.name .. " talked about pizza in #" .. msg.channel.name)
  end
end)
```

### `sigma.command("/name", function(args))`

A local command: when you send a message that starts with `/name`, the function runs with the
rest of the text (`args`, trimmed at both ends, `""` if there's nothing) and **nothing goes to
Discord**. The name is `/` followed by letters, numbers, `_` or `-` (up to 32). If two plugins
register the same name, the first one in file name order wins. A `/something` that no enabled
plugin knows is sent as normal text.

### `sigma.keybind("ctrl+shift+x", function)`

A keyboard shortcut. Modifiers: `ctrl`, `shift`, `alt`, `super`; keys: `a`–`z`, `0`–`9`,
`f1`–`f24`, `enter`, `space`, `tab`, `backspace`, `delete`, `insert`, `home`, `end`, `pageup`,
`pagedown`, `up`, `down`, `left`, `right`, `,` `.` `/` `;` `-` `=`. Letters and numbers need
`ctrl`, `alt` or `super` (otherwise they'd fire while you type); F keys can go alone.
The shortcut works outside settings and the command palette, including with the text box focused.
The app's own shortcuts (`Ctrl+K`, `Ctrl+W`…) keep working alongside it: pick another combination.

### `sigma.notify(text, [options])`

Shows a notice at the top of the window. With the window unfocused (and "Desktop notifications"
on), a system notification goes out too, except in focus mode. With `{ desktop = true }` the system
notification goes out even with the window focused or in focus mode, for something the person
explicitly asked for, like a reminder. At most 20 per 10 seconds and 6 system notifications a minute
per plugin (20 a minute across all of them); the rest are dropped silently.

### `sigma.send(channel, text)`

Sends a real message, as if you had typed it. `channel` can be `nil` (the open channel), a table
with an `id` (like `sigma.channel()` or `msg.channel`) or the ID as a string.
`text` is 1 to 2000 bytes. At most 5 per gesture. See [Limits](#limits).

### `sigma.channel()` and `sigma.guild()`

The open channel (`{ id, name }`) and its server (`{ id, name }`). `nil` when no channel is open
(friends screen) or, for `guild()`, in a direct message.

### `sigma.messages([options], function(list))`

The messages loaded in the open channel, oldest first, as a copy. Options: `channel` (an ID), `limit`
(200 by default, up to 500) and `files` (`true` also brings `msg.files`, so only who asks pays for
it). `contains` works as in `sigma.on`. The list also has `list.last_read`: the ID of the last message
already read before you opened this channel, when there are unread ones. The answer arrives in
`function`, later. It returns `false`, and never calls the function, if you ask again within half a second.

### `sigma.jump(channel, message)`

Opens the channel and goes to the message, fetching it if needed. Needs a gesture.

### `sigma.insert(text)`

Puts text in the message box. It never sends. Needs a gesture, or the answer to an HTTP request made
in one.

### `sigma.copy(text)` and `sigma.open(url)`

`sigma.copy` puts text on the clipboard. `sigma.open` opens an `http://` or `https://` address in the
browser, and needs the `links` capability: an address can carry data, so the card warns when the
plugin also reads messages. Both need a gesture.

### `sigma.completions(trigger, list)`

Suggestions in the message box while someone types the trigger at the start of a word:

```lua
sigma.completions(";", { { name = "hi", text = "Hello, how are you?", hint = "greeting" } })
```

Typing `;h` shows the list, and picking one puts `text` in the box, instead of `;h`. It never sends.
The list stays with the app, so the search runs on every key without calling your plugin; call this
again when it changes. The trigger is one of `;` `!` `$` `%` `&` `+` `=` `?` `^`. Up to 256 suggestions
and 256 KB per plugin.

### `sigma.rewrite(list)`

Fixed rules for the text the person sends:

```lua
sigma.rewrite({
  { strip_params = { "utm_*", "fbclid" } },                 -- in links, anywhere
  { strip_params = { "si" }, host = "youtu.be" },           -- only there and on its subdomains
  { replace_host = "old.example.com", with = "new.example.com" },
  { word = "btw", with = "by the way" },                    -- whole words, ignoring case; no mention or link
})
```

The app applies them when sending, after mentions are resolved. Your plugin doesn't see what was
written and nothing runs while typing. Code blocks, mentions and emoji stay as they are. If the result
wouldn't fit in a message, the text goes as written. Each call replaces the plugin's rules; up to 256,
counting each parameter. It doesn't touch what `sigma.send` sends, or edits.

### `sigma.lang()` and `sigma.tr(pt, en)`

`sigma.lang()` is `"pt"` or `"en"`, and `sigma.tr("olá", "hello")` is the text in the interface's
language. Plugins should use it for all their text, and draw again on `sigma.on("lang", …)`.

### `sigma.after(seconds, function)`, `sigma.every(seconds, function)`, `sigma.cancel(id)`

Timers that run while the plugin is on, and die with it. Both return an ID for `sigma.cancel`.
`every` has a minimum of 1 second. A plugin can have up to 64. To survive a restart, keep the time in
`sigma.storage` and start the timer again when the plugin loads, as `reminders.lua` does.

### `sigma.storage`

Data that stays between restarts, separate for each plugin and account, on this computer
(`~/.config/sigmacord/plugin-data/`). Up to 1 MB per plugin.

| Function | What it does |
|---|---|
| `sigma.storage.get(key)` | The value, or `nil`. It's a copy: changing it doesn't save |
| `sigma.storage.set(key, value)` | Saves a string, number, boolean or table (a list, or with string keys). `nil` deletes. Raises an error if it doesn't fit, leaving the old value there |
| `sigma.storage.delete(key)` | Deletes |
| `sigma.storage.keys()` | The list of keys |
| `sigma.storage.clear()` | Deletes everything |

It goes to disk shortly after the change, off the interface thread, and when the plugin stops. A file
that can't be read is kept next to it as `.bad`, and the plugin starts empty with the error on its card.

### `sigma.panel`

A panel the app draws in a side panel the person can dock on either side and resize. Reach it with the
button in the channel header, the command palette (`Panel: name`) or **Open panel** on the plugin's
card. You describe it as data; publish again whenever something changes.

```lua
local function draw()
  sigma.panel.set({
    title = sigma.tr("Meu painel", "My panel"),
    { type = "heading", text = "Heading" },
    { type = "text", text = "Text that wraps", style = "muted" },
    { type = "input", key = "search", placeholder = "Search", value = query,
      on_change = function(v) query = v; draw() end,
      on_submit = function(v) end },
    { type = "row",
      { type = "button", label = "Save", style = "accent", on_click = function() end },
      { type = "button", label = "Delete", style = "danger", on_click = function() end },
    },
    { type = "bar", label = "ana", value = 12, max = 30, text = "12" },
    { type = "select", key = "kind", label = "Show", value = kind,
      options = { { value = "all", label = "Everything" }, { value = "new", label = "New" } },
      on_change = function(v) kind = v; draw() end },
    { type = "toggle", key = "sound", label = "Sound", hint = "Optional text below", value = sound,
      on_change = function(on) sound = on end },
    { type = "separator" },
    { type = "list", empty = "Nothing here yet.", items = {
      { title = "Title", subtitle = "Up to 4 lines", meta = "12:30",
        on_click = function() end,
        actions = { { label = "Remove", style = "danger", on_click = function() end } } },
    } },
  })
end
```

| Type | Fields |
|---|---|
| `text` | `text`, `style` (`muted`, `accent`, `danger`) |
| `heading` | `text` |
| `separator` | none |
| `row` | buttons in its list part, wrapping when they don't fit |
| `button` | `label`, `style`, `on_click` |
| `input` | `key` (required), `placeholder`, `value`, `on_change(text)`, `on_submit(text)` (Enter), `clear` (empties on Enter) |
| `bar` | `label`, `value`, `max`, `text`, `style` |
| `select` | `key` (required), `label`, `value`, `options` (`{ value, label }`), `on_change(value)` |
| `toggle` | `key` (required), `label`, `hint`, `value`, `on_change(true or false)` |
| `list` | `items`, `empty` (the text when there are none) |
| list item | `title`, `subtitle`, `meta`, `on_click`, `actions` (buttons) |

Any of them takes a `key`. While someone is typing in an input, publishing doesn't overwrite what's
there; with the focus elsewhere, `value` wins. `sigma.panel.open()` (needs a gesture) and
`sigma.panel.close()` show and hide it. Up to 4000 items and 1 MB of text. A click on an option or a
toggle counts as a gesture. A `badge` next to `title` (a short text, like `"3"`) shows on the panel's
tab and as a dot on the channel header button, which then opens that panel first. Publish without it to
clear.

### `sigma.settings.set(list)`

Options on the plugin's card in **Settings → Plugins**, with the same types as a panel, usually `select`
and `toggle`. They show while the plugin is on. Your plugin keeps the value, with `sigma.storage`, and
publishes again on `"lang"`:

```lua
-- @capabilities settings, storage
local target = sigma.storage.get("target") or "auto"
local function options()
  sigma.settings.set({
    { type = "select", key = "target", label = sigma.tr("Traduzir para", "Translate to"), value = target,
      options = { { value = "auto", label = "App language" }, { value = "es", label = "Spanish" } },
      on_change = function(v) target = v; sigma.storage.set("target", v) end },
  })
end
sigma.on("lang", options)
options()
```

### `sigma.menu(where, label, function, [options])`

An entry on the right-click menu. `where` is `"message"` (the function receives `msg`, as in
`sigma.on`, for the message you clicked) or `"user"` (it receives `{ id, name }`). `label` is a string
or `{ pt = "…", en = "…" }`. Up to 4 per plugin. Options:

| Option | What it does |
|---|---|
| `choices` | A second list, up to 16 `{ value, pt, en }`. Clicking the entry opens it, and the `value` picked is the function's second argument |
| `toolbar` | An emoji: the entry also becomes a button on the toolbar of the hovered message, with the label as a tooltip. Only for `"message"`, and at most 3 across all plugins |

```lua
sigma.menu("message", { pt = "Traduzir para…", en = "Translate to…" }, function(msg, lang)
  translate(msg, lang)
end, { choices = { { value = "es", pt = "Espanhol", en = "Spanish" } } })
```

### `sigma.decorate(message, options)` and `sigma.undecorate(message)`

Marks a message, only on your screen. `message` is an ID or a `msg`.

| Option | What it does |
|---|---|
| `badge` | A small label under the message |
| `note` | A line of text under the message, up to 2000 bytes, with an × to dismiss |
| `collapse` | `true` collapses it to one line, with "show" |
| `label` | The text of that line |
| `style` | `"danger"` shows it in red, for a warning |

Up to 4096 per plugin. When a message is deleted, what was on it goes too. When the person closes a
note with its ×, `sigma.on("dismiss")` tells you.

### `sigma.rules(list)`

The same thing as rules the app applies on its own, including to messages that arrive later, without
calling your plugin:

```lua
sigma.rules({
  { word = "spoiler", collapse = true, label = "Collapsed by my filter" },
  { user = "1234567890", badge = "!" },
})
```

`word` matches whole words, ignoring case. Each call replaces the plugin's rules. Up to 256. Your own
messages are never affected.

### `sigma.http`

Requests to the outside world, off the interface thread. This is the only network a plugin has.

```lua
-- @capabilities http
-- @hosts api.example.com
sigma.http.get("https://api.example.com/x?q=" .. sigma.urlencode(text), function(res)
  if res.ok then local data = sigma.json.decode(res.body) end
end)
```

`sigma.http.get(url, [options], function)` and `sigma.http.post(url, options, function)`. Options:
`body` (up to 64 KB) and `headers`. The function receives `{ ok, status, body, error }`. `error` is
`"not_approved"`, `"rate_limited"`, `"too_big"` or `"network"`.

- **HTTPS only**, and only to a host in `@hosts` that **you approved on the plugin's card**, separately
  for each plugin and host. Until then nothing goes out, and the plugin gets `not_approved`.
  `sigma.http.allowed(host)` says whether it's approved.
- A URL with a user, a port or characters that aren't encoded raises an error. So does a host that's
  not in `@hosts`. Discord's own domains can't be declared at all.
- Redirects aren't followed: the 3xx comes back to the plugin, so it can't lead to a host you didn't approve.
- The app sends no cookies, no token and no Discord headers. A plugin can only set `Accept`,
  `Accept-Language` and `Content-Type`; anything else is dropped.
- Limits: answers up to 1 MB, 20 seconds per request, 3 at a time and 30 a minute per plugin.
- It respects your proxy, if you have one.

### `sigma.json.encode(value)`, `sigma.json.decode(text)` and `sigma.urlencode(text)`

`decode` returns the value, or `nil` and an error message. `encode` takes what `sigma.storage.set`
takes.

### `sigma.lsp(lang, argv)`

Proposes a language server for code blocks in the message box
([code diagnostics](lsp.md)): `lang` is the block tag or a language key from that page (`"zig"`,
`"python"`, `"haskell"`), and `argv` is the program and its arguments, with no shell involved.

```lua
sigma.lsp("haskell", {"haskell-language-server-wrapper", "--lsp"})
```

This does not run anything. The proposal appears under Settings → Code diagnostics, off, with the
full command. It only runs after you turn it on, for that plugin, language and exact command;
changing the command turns it off again. The plugin never sees what you type or what the server
answers. A plugin can propose up to 8 servers; calling this again for the same language replaces
the proposal.

### `print(...)`

Goes to the app's log (`[name.lua] …` in the terminal), not to the interface.
