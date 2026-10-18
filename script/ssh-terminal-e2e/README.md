# Manual SSH terminal compatibility verification

Run from the repository root after preparing generated resources:

```sh
generated=$(python3 script/prepare_ghostty_source.py)
python3 script/ssh-terminal-e2e/run.py \
  --integration "$generated/src/shell-integration/zsh" \
  --fish /absolute/path/to/fish \
  --amx "$PWD/.build/amx/amx" \
  --output /private/tmp/awesomux-ssh-terminal-proof
```

Use a new output directory each time. `--fish` and `--amx` are optional.
Build the exact checkout’s backend with `./script/build_amx.sh` before using
`--amx`; an older binary may not support the suite’s reattach command. On macOS the test
may need unrestricted execution because sshd creates its own process sandbox.
It starts a loopback-only OpenSSH server with temporary keys and configuration;
it does not change existing SSH services, user configuration, or remote hosts.
The loopback account is your current user: its login shell/dotfiles still run
on the server side, so a dotfile that overrides TERM can affect the result.
Keep `private-fixture` private and exclude its disposable keys from reviews.

The test catches a missing fallback at the real SSH PTY boundary. A 55-column
zsh PTY loads the full generated startup resources and connects using real
OpenSSH. It verifies the remote terminal, unchanged local terminal, argument
quoting, exit status, user aliases/functions, explicit terminal selection,
bypass behavior, and the existing mouse cleanup sequence. Logs and report.txt
remain in the output directory even when verification fails.

The optional fish lane sources the generated app-owned fish extension in an
interactive `fish -c` and uses real SSH with a forced remote PTY. It checks the
same terminal/status and user-wrapper contracts. It does not exercise fish's
full startup discovery or interactive line editor. The temporary fish 4.9.3
bottle used during development crashed when loading the pinned upstream Ghostty
fish startup script, so that integration remains a separate manual check.

Also run the existing mouse-recovery PTY suite against a disposable SSH target,
including SSH suspend/resume, then `./script/preflight.sh`.

For the original report, open a fresh local pane in the built demo, narrow the
window, run ordinary `ssh sandbox`, confirm `echo "$TERM"` prints
`xterm-256color`, and edit a long command without resizing or pressing Ctrl+C.
This manual check is separate from the transport assertions above.
