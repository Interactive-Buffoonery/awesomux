# Open remote web links on your Mac

A program running over SSH can ask awesoMux to open a web link in your Mac's
default browser. This uses your browser's existing sign-in. It does not install
a browser on the remote server.

## Set it up

1. Connect using **Connect via SSH** or **Make This Workspace Managed**.
2. Leave **Remote session name** empty.
3. Approve installing or updating the remote helper when offered.
4. Leave **Settings → Workspaces → Managed SSH → Open remote web links on
   your Mac** enabled.

The remote helper supports Linux x86_64/aarch64 and Apple Silicon macOS 15+.
Ordinary `ssh` commands and named remote `amx`/`zmx` sessions do not get browser
forwarding in this version. Declining helper setup keeps SSH usable.

After checking the helper's browser capability and its executable wrapper,
awesoMux sets `BROWSER` for the new remote shell. Programs that honor `BROWSER`
can use it; programs that directly invoke another browser command may not.
This replaces an inherited `BROWSER` value for that session. Shell startup files
can override it. No remote shell configuration files are edited.

## Choose what happens

The confirmation shows the configured SSH destination, the website, and its
full URL. **Open Link** hands the URL to your Mac's default browser. **Cancel**
opens nothing. **Copy Link** copies the URL to your Mac's clipboard without
opening it. Return and Escape cancel rather than approving an unexpected request.

The unchecked **Always allow** option remembers one SSH destination and one
exact website origin: scheme, hostname, and effective port. Subdomains,
HTTP versus HTTPS, and different ports need separate permission. Suspicious
URLs still require confirmation and cannot create a remembered permission.
Only HTTP and HTTPS are accepted; local files and custom app links are refused.

Remove remembered permissions under **Websites allowed without asking**.
Turning forwarding off blocks new requests in existing sessions. Reconnect
after turning it on so a new shell receives `BROWSER`.

## Limits and failures

- Browser requests and agent status use independent authenticated connection
  slots on the same SSH channel. Status updates cannot replace a waiting
  browser request. A second concurrent browser caller gets a busy result.
- Only one browser confirmation is shown across the app. A shared limit of
  three requests per ten seconds also applies to remembered permissions.
- Requests expire after at most two minutes. Closing the pane, losing the
  browser connection, or replacing the SSH attachment cancels pending work.
  Reconnecting does not replay a request.
- The helper returns success only when macOS accepts the browser handoff. It
  does not claim that the page loaded or that sign-in succeeded. Other outcomes
  return a nonzero status and leave a copyable URL in the remote command's
  error output.
- `localhost` in a URL refers to the Mac when opened there. Remote development
  servers and sign-in callbacks can require separate port forwarding; this
  feature does not create those tunnels.
- Nested SSH, containers, and `sudo` do not automatically receive the helper's
  environment or connection. SSH forwarding restrictions can also prevent
  the underlying managed channel from being available.

## Real SSH end-to-end check

Run the opt-in integration journey from the repository root:

```sh
./script/test-remote-browser-e2e.sh
```

The script creates a user-owned `sshd` on a free loopback high port. It uses
fresh host and client keys, a private `AuthorizedKeysFile`, a private
`known_hosts`, and an isolated OpenSSH client configuration under `.build`.
It never reads or changes `~/.ssh/config`, `~/.ssh/authorized_keys`, the system
SSH service, or an external server. The script validates the daemon PID and
configuration before signaling it, moves the temporary fixture to the Trash,
and prints the retained artifact directory on exit.

The app's saved SSH destination model intentionally contains only a user and
host. It does not accept a port or an alternate OpenSSH configuration path.
The integration test therefore uses `ssh -F` only to establish the isolated
fixture edge. Everything after that edge is production code: the built remote
helper, Unix-socket reverse forward, bridge actor and supervisor, browser
coordinator, settings store, AppKit sheet, pasteboard, and `NSWorkspace` open.

The journey verifies:

- non-web URL rejection;
- the global off switch;
- prompt Cancel, Copy Link, and Open Link results;
- one browser lane at a time while ordinary status frames still flow;
- an exact HTTP request reaching a loopback browser receiver;
- remembered-origin lookup and revocation through `AppSettingsStore`;
- request expiry, connection loss, and a fresh request after reconnect.

The artifact directory contains `browser-e2e-report.txt`,
`helper-results.log`, `browser-hit.txt`, `browser-prompt.png`, SSH logs, and
the isolated TOML settings file. The PNG is an `NSView` bitmap of the real
sheet. It confirms the prompt content and layout, but AppKit does not render
the button labels into this offscreen bitmap; the integration test locates and
presses the live buttons by their actual titles.

This automated journey does not verify VoiceOver speech, physical keyboard
Return/Escape behavior, or saving the **Always allow** checkbox through a
manual click. It writes the equivalent grant through the real settings store,
then verifies production lookup and revocation. Check those three interactions
separately in a running app when preparing a release that changes the prompt.
