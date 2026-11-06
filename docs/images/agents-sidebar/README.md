# Agents panel screenshots

These unedited native screenshots distinguish component fixtures, simulated events and a real Codex question. None shows a permission approval transaction.

- `panel-before.png`: an AppKit-hosted SwiftUI component fixture of the previous capped panel layout from commit `d904ee79`, rendered with current Core and DesignSystem modules.
- `panel-after.png`: the integrated development app after the layout refinement. It shows a wrapped custom title, project provenance without the repeated title, a compact reason/mark-seen row, the continuous sidebar divider, and footer-only mode switching. The terminal explicitly labels its simulated event.

- `panel-rails.png`: the integrated development app with outline borders instead of leading status dots, full-width wrapped titles, and a small Thinking spinner beside the status. Two labeled simulated agents occupy separate panes in a real split. Captured after the native focus-section correction.

- `panel-codex-question.png`: a real Codex request_user_input dialog in the right split, with its selected Agent row outlined orange, the idle sibling quiet, and no redundant banner for the active pane. The reported failure was captured on Codex 0.166.0; both saved testing conversations were resumed after rebuilding on the installed Codex 0.167.0. Notes editing, cursor navigation, cancellation and submission were checked separately. Selecting the sibling retains off-pane navigation to the question.

The images have different framing; the earlier component fixture is not a full-app before screenshot. Split navigation was exercised separately with simulated pane events. Other live-provider delivery paths, real permission transactions and VoiceOver speech remain separate acceptance checks.
