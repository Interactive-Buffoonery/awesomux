# Agents panel screenshots

These unedited native screenshots distinguish component fixtures, simulated events and a real Codex question. None shows a permission approval transaction.

- `panel-before.png`: an AppKit-hosted SwiftUI component fixture of the previous capped panel layout from commit `d904ee79`, rendered with current Core and DesignSystem modules.
- `panel-after.png`: the integrated development app after the layout refinement. It shows a wrapped custom title, project provenance without the repeated title, a compact reason/mark-seen row, the continuous sidebar divider, and footer-only mode switching. The terminal explicitly labels its simulated event.

- `panel-rails.png`: the integrated development app with outline borders instead of leading status dots, full-width wrapped titles, and a small Thinking spinner beside the status. Two labeled simulated agents occupy separate panes in a real split. Captured after the native focus-section correction.

- `panel-codex-question.png`: the current native app with the shared search/New Workspace header and solid Agent outlines. The selected idle left agent uses its group accent; the unselected right agent has a solid orange outline and attention reason for its real Codex request_user_input question. The off-pane navigator points to that question, which remains unanswered. Both saved conversations were resumed on Codex 0.167.0 after rebuilding. Selection switching and solid outlines were checked on this build. The group color and automatic reset were checked on the preceding source-identical tint implementation; only dash removal changed the final render. Earlier lifecycle checks separately covered notes, cursor navigation, cancellation, submission and off-pane navigation; the initial failure was on Codex 0.166.0.

The images have different framing; the earlier component fixture is not a full-app before screenshot. Split navigation was exercised separately with simulated pane events. Other live-provider delivery paths, real permission transactions and VoiceOver speech remain separate acceptance checks.

## Information layout and collapsible Agents sections

- `panel-information-before.png`: integrated development app on merged PR #914, before this follow-up. Plain section labels have no disclosure control, the provider/location line is always visible, and the footer still says 2 agents while in Agents mode.
- `panel-information-layout.png`: the rebuilt development app after the follow-up, with Workgroup-styled Agents disclosure headers, project context above the task title, distinct workspace provenance and a Workgroups return label. The existing real Codex question remains unanswered; neither navigation nor section collapse approves it. The original manual title is preserved.

Both captures are unedited native app images. Individual collapse, search/mode return, footer retarget and keyboard checks are documented separately from the screenshot; no VoiceOver speech or new remote/provider delivery proof is implied. Activity age and Git/PR fields are omitted because the current store has no reliable substantive-activity timestamp or exact-pane sidebar Git cache.
