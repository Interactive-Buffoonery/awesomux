# Unmanaged SSH Markdown file links

## Scope and evidence

This change lets a local pane use an explicit, runtime-only SSH alias and fixed
remote directory for Markdown filenames printed by tools such as Claude Code.
Setting the context does not connect or authorize a read. Each open uses the
existing unmanaged confirmation and read-only snapshot path.

Native UI acceptance is **not complete**. On 2026-10-06 the build host had no
accessible awesoMux windows (`cgWindowNotFound`); the contributor's active Mac
was a different machine. No screenshot, terminal click, interactive Claude TUI,
VoiceOver, or mixed-host UI result is claimed here.

Completed checks on the implementation worktree:

- `./script/preflight.sh`: exit 0, including the existing Swift/Zmx suites,
  formatting/localization guards, license checks, and release build verification.

- `./script/build_and_run.sh`: exit 0; development bundle built, staged, and
  launched. This establishes build/launch evidence, not visible UI behavior.
- `./script/swift-test.sh --filter PaneChangeClassificationTests`: exit 0,
  6 existing tests passed. An initial preflight exposed the missing durable
  pane-change comparison for file context; the comparison was corrected.
- `python3 script/verify_remote_markdown_authorization.py --output
  .build/verification/remote-markdown-authorization.log`: exit 0, 10 existing
  authorization checks passed. Focused production-method proof, not UI E2E.
- `python3 script/verify-remote-markdown-transport.py --host <SSH-alias>
  --report .build/verification/remote-markdown-transport.json`: exit 0,
  `passed: true`, 13 lexical checks, real SSH content checks and fixture cleanup.
  The remote shell was Bash; Zsh coverage was unavailable. This exercises the
  existing transport, not the new context editor or native terminal hit testing.
- A remote `claude -p --tools "" --no-session-persistence` invocation printed
  `I saved the scratchpad at journeys-memory-plan.md.` exactly. This establishes
  the bare filename output shape only.
- Independent parallel code review and a targeted recheck found no remaining
  verified code findings. This does not establish native gesture behavior.

Local logs live in `.build/verification/`, including `preflight-final.log`,
`pane-classification.log`, `remote-markdown-authorization.log`, and
`remote-markdown-transport.json`. Re-run the commands to produce fresh artifacts.

## Repeatable native acceptance

Use an unlocked Mac running the development bundle from this branch. Create a
remote directory containing `journeys-memory-plan.md`, `next.md`, and a
`journeys-memory-plan.md.bak` file. Put distinct marker text in both Markdown
files and a relative `[Next](next.md)` link in the first.

1. Open a local pane and type `ssh devbox` manually. Run Claude Code there.
   Use File > Set Remote File Context… (also available in the command palette)
   to select `devbox` and the fixture directory. Confirm that setting context
   performs no SSH read and the path bar displays the target and directory.
2. Print prose containing `journeys-memory-plan.md`, `./next.md`, and a filename
   followed by sentence punctuation. Plain-click and Command-click each.
   Confirm exactly one per-read confirmation names the selected alias and
   resolved remote path, then opens the matching read-only remote marker.
3. Cancel a confirmation: no snapshot should open. Open again: confirmation
   must recur. Follow the relative Markdown link and refresh the snapshot;
   confirm each operation remains independently authorized.
4. Check wrapped filenames, Unicode before the filename, wide characters,
   combining characters, resized panes, and scrollback. Ambiguous viewport
   boundaries should fail closed. Record the renderer and font configuration.
5. Print HTTPS links ending in `.md`, email-like text, `.md.bak`, and non-Markdown
   names. Verify bare-word handling does not claim them. Preserve explicit
   terminal hyperlinks, ordinary selection, drag selection, and double-click
   word selection. Bare filenames have no new hover underline.
6. Switch focus during the delayed click, edit/clear context, close the pane,
   reset the shell, and reconnect or submit another SSH command. Verify stale
   clicks cannot open using replacement context or fall back to Mac paths.
   Clear and re-set the same values to exercise identity replacement.
7. Restart the app and split/duplicate the pane: context must not be restored or
   inherited. A generic shell `cd` is not tracked; update the fixed directory
   explicitly after changing it. Undetectable nested SSH also needs an explicit
   context update.
8. With another managed host and a remote snapshot present, exercise file open,
   refresh, and relative links. Verify each action keeps its originating target
   and read policy rather than borrowing the focused pane's authority.
9. Use keyboard-only navigation and VoiceOver in the editor and path bar.
   Verify initial focus, validation announcements, target/base labels,
   Edit/Clear actions, Escape, and Return. Capture screenshots or a recording
   and a result log with the tested build revision.

Leave the PR in draft until the native acceptance artifact is available.
