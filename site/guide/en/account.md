# Connect your account

> [!WARNING]
> **Using a user account outside the official client breaks Discord's Terms of Service, and the account can be banned.** Use it at your own risk, ideally with a secondary account. Nothing in this project makes that risk go away.

## How the app finds your token

The token is never stored in the code, and it never goes into logs or error messages. It's also wiped from memory when the app exits. The app looks in this order:

1. **The system keyring** (recommended):
   ```bash
   secret-tool store --label='SigmaCord' service sigmacord   # paste the token when asked
   ```
2. The `SIGMACORD_TOKEN` environment variable.
3. The file `~/.config/sigmacord/token`, which must have `chmod 600`. If other users can read it, the app warns you.

## The sign-in screen

Without a token, the app opens the sign-in screen (`--login` forces it). You can paste a token or choose **Explore the demo**, and the screen has its own help link. With **Remember on this computer** on, the token is only saved after Discord accepts it.

## Multiple accounts

Click your own name to open the account menu. It lists saved accounts with name and avatar, and switching takes effect right away. **Add account** goes back to the sign-in screen without forgetting the others.

The sign-in screen lists saved accounts too, so you can get into another one if a session ends. When Discord refuses a token, the app forgets it instead of trying it again every time it opens.

| What | Where |
|---|---|
| Each remembered token | Its own keyring entry (`service sigmacord-account account <ID>`). Without a keyring: `~/.config/sigmacord/tokens/<ID>` with `chmod 600` |
| The list of accounts (ID, name and avatar only) | `~/.config/sigmacord/accounts` |

The keyring entry from the first section still works for the account that was already in it.

## Sign out

Settings → **Log Out**. To force demo mode even with a token saved, run `sigmacord --demo`.

## What goes over the network

With a token, the app talks to Discord's gateway and REST API, and to Discord's media servers for images. See [Privacy and security](page:privacy) for the details, including the optional proxy.
