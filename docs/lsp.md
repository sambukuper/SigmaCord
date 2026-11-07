# Code diagnostics (LSP)

While you type a fenced code block in the message box, SigmaCord can show the errors a
[language server](https://microsoft.github.io/language-server-protocol/) finds in it. Nothing
is built into the app and nothing is downloaded: the server is a program of yours, and it only
runs for a language you turned on. With everything off (the default) there is no thread, no
child process and no extra memory in use.

## Turning it on

Settings → **Code diagnostics**. Each language has a command and a switch:

| Block tag | Row |
| --- | --- |
| `zig` | Zig |
| `python`, `py`, `py3` | Python |
| `rust`, `rs` | Rust |
| `c`, `h`, `cpp`, `c++`, `cc`, `cxx`, `hpp` | C / C++ |
| `go`, `golang` | Go |
| `typescript`, `ts`, `tsx`, `javascript`, `js`, `jsx` | TypeScript / JavaScript |
| `lua` | Lua |

The server has to speak LSP over stdin and stdout, so the command is usually something like
`zls`, `ruff server`, `pyright-langserver --stdio`, `rust-analyzer`, `clangd`, `gopls`,
`typescript-language-server --stdio` or `lua-language-server`.

- **The command is not run by a shell.** It is split on spaces, with `"…"` or `'…'` for
  arguments that contain spaces. `;`, `|`, `$HOME` and `~` are plain text.
- A program name without a path is looked up on `PATH`.

The page also searches your `PATH` for those well-known names and offers what it finds. It only
checks that the file exists and is executable; it does not run it. Clicking **Use … and turn
on** stores the full path as the command, which is what you are agreeing to run.

## While typing

Put the cursor inside a block:

````
```zig
const a: u32 = "text";
```
````

About 300 ms after you stop typing, the block goes to the server. Up to three problems show up
above the message box (line, severity, message), and they are underlined in the text. If the
text has grown enough to scroll inside the box, only the list is shown. Line numbers count from
the start of the message, not from the start of the block.

- Only the block under the cursor is checked, and only after a newline following the tag.
- The server starts on the first such block. After a minute without typing it stops; the next
  keystroke starts it again.
- A server that crashes is retried after 1, 4 and 15 seconds. After that the error shows in the
  box and in Settings, with a **Try again** button, until you change the configuration.

## What the server gets

The app holds your Discord token, so a server runs with as little as possible:

- **Text:** only what you are typing in your own message box, only the block under the cursor.
  Never other people's messages, and never anything else from the app.
- **Environment:** only `PATH` and `HOME` (on Windows also `SystemRoot`, `SystemDrive`,
  `USERPROFILE`, `APPDATA`, `LOCALAPPDATA`, `TEMP`, `TMP`, `PATHEXT`). `SIGMACORD_TOKEN` and the
  rest of your environment do not reach it.
- **Folder:** it runs in a scratch folder (`~/.cache/sigmacord/lsp-scratch`). Whatever a server
  left there is removed before the next start, except subfolders that aren't empty: the app does
  not walk into them, so a link left there can't make it delete anything else. `rootUri` and `workspaceFolders` are `null`, and the document is a virtual
  `file://<that scratch folder>/sigmacord-composer.<ext>` that never exists on disk (servers such as clangd only accept `file:`). Nothing you type is written to disk, and your projects
  are not involved. This also means a server that wants a project (imports, a build file) only
  sees one isolated file, so its errors are about that snippet alone.
- **Open files:** on Linux the app's sockets and files are closed in the child.
- **Limits:** a message over 1 MiB, malformed framing, more than 32 MiB of output per minute, or
  not reading its input for 10 seconds all stop the server. Its stderr is discarded.

This is not a sandbox. A language server is a normal program running as you, and it could read
your files, including where the app stores its token. Only turn on servers you trust.

## From a plugin

A Lua plugin can propose a server, for example for a language the app doesn't list:

```lua
sigma.lsp("haskell", {"haskell-language-server-wrapper", "--lsp"})
```

The proposal shows up on the same Settings page with its full command, off. It only runs after
you turn it on, and that decision is tied to that plugin, language and exact command: if the
plugin changes the command, it goes back to off. See [plugins.md](plugins.md#sigmalsplang-argv).

If a language has both, your own command wins.

## Limits worth knowing

- Stopping a server kills that process, not whatever it started. A wrapper command that spawns
  the real server (`npx …`) may leave that one behind.
- If the app is killed outright (`kill -9`, power loss), a server only notices when its input
  closes. Well-behaved servers exit then.
