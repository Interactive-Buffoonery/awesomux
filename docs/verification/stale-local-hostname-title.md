# Stale local hostname title (#698)

## Backend diagnostic

`script/verify-stale-hostname-title.py` compiles the checkout's real Core sources
and `ProcessLivenessProbe` in a disposable SwiftPM executable. It drives a real
interactive zsh on a PTY, a local command, and an actual OpenSSH client using a
local sleep ProxyCommand. No SSH server, credentials, DNS lookup, or remote
write is required. Temporary packages go to Trash; the fixture cleans up its
own processes before returning.

This is backend integration evidence, **not native UI E2E proof**. The `codex`
title is injected while a local `sleep` process owns the PTY; the diagnostic
does not start Codex or exercise libghostty's title callback/throttle.

The production title commit passes `localShellOwnsTerminal` to
`SessionStore.updatePane`; the diagnostic passes the same probe result. Run:

```sh
python3 script/verify-stale-hostname-title.py --output /tmp/issue-698-after.log
```

Every assertion must pass with exit 0. On a pre-fix checkout, add `--baseline`
and drop the `localShellOwnsTerminal:` argument from the proof's `report`; exit 1
with stale-title assertions failing is the expected baseline. A build failure,
failed PTY/SSH precondition, or timeout is not a reproduction. The artifact
records commit, source digest, observations, and the PTY transcript. A dirty
checkout is identified by its source digest; record `git diff` separately.
The log contains local paths and hostnames, so keep it out of the repository.

## Coordinator-owned native verification

Run the entire build, launch, interaction, capture, and cleanup workflow while
holding one `build_slot.py` invocation. If native automation needs multiple tool
calls, the coordinator must hold that slot until cleanup completes. Never start
a GUI workflow outside that ownership. Use this worktree's development bundle,
profile, and amx namespace; refuse to launch if its exact executable is already
running. Do not terminate or relaunch another app instance.

1. Record `git rev-parse HEAD`, the worktree path, and the staged executable's
   hash. Build/stage using the repository entrypoint and identify the exact
   worktree-specific bundle ID and runtime profile (see `runtime-profile.sh`).
   Launch only that bundle and record its executable path and PID.
2. In a fresh local terminal, record `pwd`, `hostname`, and the pane's
   `ZMX_SESSION`. Use a stale test hostname absent from the current hostname.
   Install a local zsh `precmd` function that emits the same title at every
   prompt, to model a long-lived shell's cached hostname:

   ```sh
   function issue698_title() { printf '\033]2;example@syn-172-100-12-34:~\007'; }
   precmd_functions+=(issue698_title)
   ```

3. Let the prompt repeat several times. Capture the sidebar/footer and verify
   they show the local working directory, never the test hostname. Start the
   installed Codex CLI in that pane without submitting work. After its title
   becomes indeterminate, capture the same surfaces again. Exit only this
   fixture's CLI and verify the repeating prompt remains local.
4. Verify an ordinary hand-opened SSH session to an independently authorized
   fixture host still shows its foreign prompt hostname and remains remote
   while an agent changes its title. Terminal titles grant no remote file
   access. If there is no authorized SSH fixture, record this case as unrun;
   do not contact a guessed host. The backend diagnostic separately covers
   foreground OpenSSH and the identical stale hostname without a network.
5. Return to the local prompt and verify the local directory returns. Repeat
   rapid local command launches and a shell wrapper around SSH to cover title
   throttling and foreground-process races.
6. Capture screenshots and an interaction log tied to the exact commit and
   bundle. Remove the fixture's `precmd` function, close its panes/daemons,
   and terminate only the process created by this run. Verify those processes
   exited before releasing the slot. Keep screenshots, logs, and incomplete
   cases with the coordinator's report.

Native rendering, VoiceOver, the existing Swift suites, and full preflight are
separate results. Do not infer one from another.
