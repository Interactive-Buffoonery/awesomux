# Remote Markdown confirmation handoff

This is running-app verification of confirmation submission, the approved SSH
read, and the rendered result. It is separate from the isolated authorization
and queued-admission proofs. It is not an automated app-level test.

## Repeat the read and cancellation checks

1. On a reachable SSH config alias, create `start.md` with a unique marker and
   a relative link to `next.md`. Give `next.md` a different marker.
2. In a local awesoMux workspace, run SSH to that alias and decline managed
   workspace conversion. Choose Open Markdown.
3. Enter the SSH alias, `start.md`, and the fixture's absolute remote directory.
   Confirm that the preview names the intended host and full path.
4. Cancel. Verify that no document opens. Open the dialog again and choose
   Read File. Verify that the remote marker appears in a read-only document.
5. Follow the relative document link. Cancel its new confirmation and verify
   the current document remains. Retry and confirm; verify the second marker.
6. Change the second file remotely. Choose Refresh and cancel its confirmation;
   verify the old marker remains. Retry and confirm; verify the new marker.
7. Repeat the initial read with spaces around the remote base directory. Verify
   that the preview and actual read use the same trimmed directory.

## Recorded results

On October 6, 2026, the development app at `ca2b59fd` completed steps 2–6
against real files through SSH alias `pinguchy`. Cancelling created no document
or refresh, confirming rendered the expected remote markers, and document
navigation and Refresh each required fresh consent. Return and Escape worked.
The managed SSH opening flow also rendered the expected remote file.

The review fixes at `98eb2589` completed the relative-path read in step 7,
using `start.md` and a padded `/tmp/awesomux-pr732-ui-sJKlop` base directory.
The preview resolved to that directory's `start.md`, and Read File rendered
`PR732 UI proof` and `REMOTE-CONTENT-ONE`.

After rebuilding at `49041935`, the contributor confirmed that VoiceOver
reached the confirmation dialog and that a new confirmation could open after
closing its parent window. These are contributor-reported manual checks.

Local records are `.build/verification/pr732-ui-report.md`,
`.build/verification/pr732-review-fixes.md`, and
`.build/verification/pr732-final-feedback.md`.

## Destination precedence regression check

With a confirmed document for host A selected and an active managed SSH pane
for a different target B in the same workspace, choose Open Markdown. The
typed-path dialog must name B and use B's configured destination. When the
active pane and selected document name the same target, the confirmed document
must retain its per-read confirmation flow.

The existing context-selection suite covers the different-target rule. The
application entry point now checks that resolved context before choosing the
confirmed-document flow. A running-app check of this mixed-target scenario
remains outstanding.
