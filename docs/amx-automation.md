# Automating awesoMux panes with `amx`

Every daemon-backed awesoMux pane is an `amx` session (the vendored zmx behind
the command bridge, [ADR-0011](adr/0011-persistent-session-daemon-command-bridge.md)).
That makes the bundled `amx` CLI a ready-made automation surface: a process
inside a pane — or a second terminal — can inject keystrokes into a pane and
read its scrollback without any GUI scripting.

This document covers the blessed subset and its exact semantics. Everything
here is verified against `vendor/zmx` and awesoMux source, plus live
transcripts where noted; commands or flags not listed are unsupported for
automation and may change with the vendored pin.

## The binary: `$AWESOMUX_AMX`

`amx` ships beside the app's main executable
(`awesoMux.app/Contents/MacOS/amx`) and is **not on `PATH`** inside panes —
the same trap `AWESOMUX_AGENT_HOOK` exists to solve. awesoMux advertises the
absolute path in `AWESOMUX_AMX` in every pane's environment. When the bundled
binary is missing or not executable the variable is **unset** rather than
pointing at a dead path, so guard on it. This guard is a **script prologue**
— pasted into an interactive prompt, the `|| exit 0` kills your login shell:

```sh
[ -n "$AWESOMUX_AMX" ] && [ -x "$AWESOMUX_AMX" ] || exit 0
```

**Staleness caveat:** a pane's shell lives in the daemon, and the daemon only
inherits the environment of the attach that *spawned* it. Restored panes
(every pane after an app relaunch) keep their spawn-time snapshot of all
`AWESOMUX_*` variables until their daemon dies — so after an app update or
relocation, `AWESOMUX_AMX` can point at a path that no longer exists. The `-x`
check above is the guard. `AWESOMUX_AMX` is deliberately **not** part of the
runtime health check (`healthCheckRequiredKeys`): local-shell fallback panes
legitimately lack a daemon and must still pass.

## Addressing: which session is my pane?

The amx session name is awesoMux's per-**pane** `TerminalSessionID` — an
independently generated lowercase UUID. Use `$ZMX_SESSION`: the zmx daemon
`putenv`s it into every daemon-backed shell before exec
(`vendor/zmx/src/main.zig:727-733`), so it is always present in bridged panes
and — unlike the `AWESOMUX_*` snapshot — immune to reattach staleness (the
session name never changes for the life of the daemon).

Do **not** use `AWESOMUX_SESSION_ID` (per-tab UI UUID) or `AWESOMUX_PANE_ID`
(pane UI UUID) as amx names. They are different identifiers entirely, not a
case variation. Observed in a real pane:

```
ZMX_SESSION=efed3c35-b9e3-4edc-8f43-4dc07b00b767   <- amx session name
AWESOMUX_PANE_ID=F66098EB-24C3-4C38-8539-2875B588B8A7  <- UI UUID, NOT an amx name
ZMX_DIR=/var/folders/zm/.../T/amx                  <- socket dir, inherited
```

`ZMX_DIR` is likewise inherited by the pane's shell, so in-pane invocations of
`"$AWESOMUX_AMX"` already talk to the right socket directory with no extra
setup.

**`ZMX_SESSION_PREFIX` warning:** zmx prepends `$ZMX_SESSION_PREFIX` to
**every** session argument — including an explicit `"$ZMX_SESSION"`
(`vendor/zmx/src/socket.zig:12-17`). A stray `export ZMX_SESSION_PREFIX=…` in
a user rc silently re-addresses every snippet in this doc (and `send` still
exits 0). The snippets below run through `env -u ZMX_SESSION_PREFIX` wherever
a session argument is passed to defuse this.

If `$ZMX_SESSION` is unset, you are not in a daemon-backed pane (see
[Shadow paths](#shadow-paths)) — skip amx automation.

## Blessed surface

| Command | Session argument | Purpose |
| --- | --- | --- |
| `amx send <name>` | **required** | Send text to the pane's PTY (include your own trailing `\r`) — payloads failing the daemon's user-input gate are silently dropped, see below |
| `amx history <name> [--vt\|--html]` | optional — defaults to `$ZMX_SESSION` | Dump the pane's scrollback |
| `amx list [--short]` | n/a | List sessions in `$ZMX_DIR` |
| `amx cwd <name>` | **required** | Print the active terminal job's cwd, falling back to the session root shell |
| `amx wait <name>` | **required** | Block until an `amx run -d` **task** completes — see below |

For `cwd`, the active terminal job is the foreground process group — the
shell while it owns the prompt, or an interactive program such as Pi, Claude
Code, or an editor while that program controls the terminal. `amx` reads the
group leader's directory while the leader is alive, falls back to a surviving
group member when the leader has exited (bash pipelines routinely leave the
job running under a dead leader), and only then to the durable root shell.
An agent's background tool subprocesses never take the terminal, so they are
not followed; a foreground child that does take it is reported while it holds
the terminal. This keeps every consumer on the same out-of-band cwd oracle.

Session-argument precision (`vendor/zmx/src/main.zig`): only `history` falls
back to `$ZMX_SESSION` when the argument is omitted (line 136-137); `send`
(line 245) and `cwd` (line 145) error with `SessionNameRequired` without an
explicit name. Don't rely on the default even for `history` — passing
`"$ZMX_SESSION"` explicitly keeps all four calls uniform.

**`wait` is task tracking only.** It waits for a command started with
`amx run -d <name> <cmd>` to finish (verified: `run -d sleep 3` then `wait`
returned after ~3 s with `exit_code=0`). It is **not** a pane-idle or
agent-completion detector — it cannot tell you when an interactive foreground
process (a shell at prompt, a running Claude session) is done; that use was
evaluated and rejected in [ADR-0011](adr/0011-persistent-session-daemon-command-bridge.md).

## `send` byte semantics

`send` never transforms bytes and appends **no carriage return** — but it does
not deliver everything. A `send` client is not the attached leader, so the
daemon runs the payload through a user-input gate before forwarding
(`vendor/zmx/src/main.zig:3081` → `handleInput` `main.zig:1013-1036` →
`util.isUserInput` `util.zig:558-588`; examples below verified against zmx's
own `isUserInput` tests, `util.zig:1389-1503`). The gate is **order-dependent
and all-or-nothing**: the payload is scanned front to back, and the first
decisive byte sequence decides the *entire* payload.

First, one whole-payload pre-check: a payload consisting **entirely** of mouse
reports is dropped by a stale-report gate when the inner app's mouse tracking
is off (`handleInput`, `main.zig:1013-1032`). Everything else reaches the
scan, where the first decisive action wins:

- **Forwards the whole payload** — a printable character (space included);
  CR / LF / Tab / Backspace; a keyboard CSI sequence with final `u` or `~`
  (kitty-protocol keys, `\x1b[3~` Delete, `\x1b[5~`/`\x1b[6~` PgUp/PgDn,
  bracketed-paste markers `\x1b[200~`/`\x1b[201~`); a CSI `A`–`D` arrow with
  **more than one parameter** (modified arrows like `\x1b[1;5A`). SS3
  application-mode arrows (`\x1bOA`) also pass — the letter after `\x1bO`
  parses as a printable.
- **Rejects the whole payload** — a mouse CSI (final `M` or `<`,
  `util.zig:573-575`) or a focus event (`\x1b[I`/`\x1b[O`,
  `util.zig:576-578`) hit *before* any accepted sequence.
- **Nothing decisive found** → dropped: a lone Ctrl-C (`\x03`), a bare ESC,
  *unmodified* CSI arrows (`\x1b[A` — zero or one parameter), cursor reports
  (`\x1b[6n`).

Because the first decision covers the whole payload, mixed payloads behave
non-intuitively: `text + mouse report` forwards the mouse bytes along with the
text, while `mouse report + text` (with tracking on) is rejected before the
text is ever reached. All drops and rejections are **silent, exit 0**. Net:
text plus `\r` and keyboard-shaped escapes work; you cannot deliver a lone
Ctrl-C via `send` today, and it fails silently; don't prepend focus/mouse
sequences to otherwise-deliverable payloads.

Text arguments are joined with single spaces
(`vendor/zmx/src/main.zig:2490-2494`). With no text arguments, `send` reads
stdin and strips **one** trailing newline from piped input
(`main.zig:2508-2513`) — a bare `echo cmd | amx send ...` therefore leaves the
command sitting unexecuted at the prompt. Include the `\r` yourself:

```sh
printf 'git status\r' | env -u ZMX_SESSION_PREFIX "$AWESOMUX_AMX" send "$ZMX_SESSION"
```

Verified live: `printf 'echo marker-CR-$((40+2))\r' | amx send <name>`
executed (history shows `marker-CR-42`); the same command piped with only a
trailing `\n` sat at the prompt unexecuted.

Failure caveat (source-derived, `main.zig:2522-2535`): `send` to a missing or
unresponsive session prints a diagnostic and still **exits 0**. Confirm the
session exists (`amx list --short`) or check `history` output rather than
trusting `send`'s exit code.

## Reading a pane

```sh
env -u ZMX_SESSION_PREFIX "$AWESOMUX_AMX" history "$ZMX_SESSION" | tail -50  # plain text
env -u ZMX_SESSION_PREFIX "$AWESOMUX_AMX" history "$ZMX_SESSION" --vt        # with VT escapes
env -u ZMX_SESSION_PREFIX "$AWESOMUX_AMX" history "$ZMX_SESSION" --html      # styled HTML dump
```

Plain output preserves `\r\n` line endings; pipe through `tr -d '\r'` if that
matters to your consumer. `history` against a nonexistent name exits 1 with
`error: session "<name>" does not exist` — and that is the **only** nonzero
exit: a present-but-unresponsive daemon, and the internal 5 s response
timeout, both exit 0 with **empty stdout** (`main.zig:2029-2050`). Since
`history` is this doc's recommended verification channel for `send`, verify
by content, not exit code.

## From a second terminal

Outside a pane there is no inherited `ZMX_DIR`, and `amx list`/`kill` are
scoped to whatever `ZMX_DIR` resolves to — so pair the socket dir with the app
profile explicitly. awesoMux keeps its daemons in a dedicated per-user dir
under `$TMPDIR` (`AppRuntimeProfile.amxSocketDirectoryPath`):

| App | Socket dir |
| --- | --- |
| Production (`com.interactivebuffoonery.awesomux`) | `$TMPDIR/amx` |
| Primary dev bundle (`…awesomux.dev`, `swift run`, test runners) | `$TMPDIR/amx-dev` |
| Linked-worktree dev bundle (`…awesomux.dev.<id>`) | `$TMPDIR/<stable-7-character-namespace>` |

```sh
export ZMX_DIR="${TMPDIR:?}amx"  # or ${TMPDIR:?}amx-dev for a dev build
export ZMX_DIR_MODE=700          # every amx run mkdirs $ZMX_DIR, default 0750
                                 # (vendor/zmx/src/main.zig:495-553); the app's
                                 # own 700 pin hits PathAlreadyExists and can't
                                 # tighten a dir your invocation created first
AMX=/Applications/awesoMux.app/Contents/MacOS/amx   # wherever the .app lives
"$AMX" list                      # one UUID-named session per live pane
env -u ZMX_SESSION_PREFIX "$AMX" history <pane-session-uuid> | tail -50
```

Empty `list` output means no daemons are running **or** the app has never run
yet / you're pointed at the wrong `ZMX_DIR` — the cases are
indistinguishable, so check the dir pairing before concluding "no sessions".

Inside an awesoMux pane, `AWESOMUX_PROFILE` carries the exact active profile and
`script/amx-reap.sh` uses it automatically. Outside a pane, use `--prod`,
`--dev` for the primary dev profile, or
`--profile development:<worktree-id>` for a linked worktree.

Verified live: `ZMX_DIR="${TMPDIR}amx" amx list` from a shell listed every
production pane daemon (UUID names, pids, `start_dir`), and `history <uuid>`
read another pane's scrollback. Mind the profile pairing: a dev-profile `amx`
invocation cannot see (or touch) the production app's daemons and vice versa —
that isolation is the GC ownership boundary, not a bug.

Note `$TMPDIR` ends with a slash on macOS and is per-user; both sides of the
pairing must be the same user.

## Trust boundary

All panes of one user + app profile are a single security domain: the sockets
in `$ZMX_DIR` carry no per-pane authorization, so any same-UID process —
including a prompt-injected agent running in one pane — can `send` input to
and read `history` from every other pane of that profile. Agents should treat
sibling panes as untrusted input and must not exfiltrate scrollback from
workloads they don't own.

## Shadow paths

- **Local-shell fallback pane** — bridge disabled, or `amx` missing at spawn:
  the pane runs a plain login shell, `ZMX_SESSION` is unset, and there is no
  daemon to address. `AWESOMUX_AMX` may still be set (the binary can exist
  while the bridge is off), so gate on `$ZMX_SESSION`, not on `$AWESOMUX_AMX`,
  when deciding whether the *current pane* is automatable.
- **Reattached shells** — hold spawn-time snapshots of every `AWESOMUX_*`
  variable (see the staleness caveat above). `ZMX_SESSION` and `ZMX_DIR` remain
  valid because they describe the daemon, not the attach client.
- **Session-name length** — awesoMux pins its own ids at 46 UTF-8 bytes
  (`TerminalSessionID.maxAmxSessionNameUTF8Bytes`,
  `Sources/AwesoMuxCore/Models/TerminalSessionID.swift:11` — sized for the
  dev-dir worst case). zmx's actual limit is the **total socket path**:
  `$ZMX_DIR` + `/` + name must fit `sockaddr_un` (~103 usable bytes;
  `vendor/zmx/src/socket.zig:77-94,115-120`), so the name budget shrinks as
  `ZMX_DIR` grows. Bare UUIDs (36 bytes) always fit awesoMux's dirs — keep
  custom socket dirs short.
