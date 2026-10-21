# Agent disclosure interaction check

Run `bash script/agent-disclosure-e2e/run.sh` from an unlocked macOS desktop.
The script acquires `heavy-gate`, builds an isolated SwiftPM fixture using the
production disclosure row and DesignSystem sources, and opens a temporary native
window. It presses the actual disclosure button through AppKit accessibility and
edits the SwiftUI text field through its native field editor. No integration
settings or user files are changed. The process closes its window on completion.

The check covers initial and later attention, clearing attention while editing
(including draft and focus preservation), and manual expansion/collapse across
subsequent attention changes. Failures exit nonzero; successful scenarios print
`PASS` lines. Build artifacts stay under `.build/agent-disclosure-e2e`.

This is a component interaction check. It does not validate provider probes,
installation, or the complete Settings pane, and requires no Accessibility grant
because it uses the fixture's own in-process accessibility objects.
