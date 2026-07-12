# Remote Markdown over SSH

Linear: INT-760

## Goal

When a terminal pane is inside an SSH session, clicking a Markdown file path
should open the remote file in awesoMux's Markdown viewer instead of trying to
resolve the path on the Mac.

## Existing shape

- `RemoteSessionDetector` marks a pane remote from the terminal title, using the
  detected host as the safe signal for hiding local-only affordances.
- `GhosttyRuntime` receives `GHOSTTY_ACTION_OPEN_URL` for clicked links and bare
  paths from libghostty.
- `MarkdownLinkIntercept` already limits local document-pane opens to Markdown
  extensions and rejects unsafe invisible/control path characters.
- `DocumentPane` is a tab inside `DocumentGroup`, with reducer support for
  same-file dedupe, close/reopen, and session restore.

## Implementation approach

INT-760 keeps the first version read-only:

1. Only handle remote Markdown when the source `TerminalPane` already has
   `remoteHost`.
2. Build an SSH target from the detected host. If the live title still matches
   `user@host`, reuse that user.
3. Resolve absolute paths directly. Resolve relative paths only when the live
   title includes a remote prompt directory such as `user@host:~/repo`.
4. Fetch the file with non-interactive `ssh`, an output-size cap, and shell
   quoting for the remote path.
5. Store the fetched bytes as a local cache file and open that cache file as a
   `DocumentPane`.
6. Mark the pane with `remoteSnapshotOrigin` so the UI can show that it is a
   read-only snapshot and avoid local file-browser or comment-edit actions.

## Follow-ups

- Add refresh controls for remote snapshots.
- Decide whether remote Markdown-to-Markdown links should fetch through SSH too.
- Decide whether remote edit/writeback is in scope. The first version avoids it
  on purpose so opening a file cannot accidentally mutate a remote machine.
