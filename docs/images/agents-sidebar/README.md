# Agents panel screenshots

These unedited native screenshots use simulated agent data. They do not show live provider activity or permission decisions.

- `panel-before.png`: an AppKit-hosted SwiftUI component fixture of the previous capped panel layout from commit `d904ee79`, rendered with current Core and DesignSystem modules.
- `panel-after.png`: the integrated development app after the layout refinement. It shows a wrapped custom title, project provenance without the repeated title, a compact reason/mark-seen row, the continuous sidebar divider, and footer-only mode switching. The terminal explicitly labels its simulated event.

- `panel-rails.png`: the integrated development app with outline borders instead of leading status dots, full-width wrapped titles, and a small Thinking spinner beside the status. Two labeled simulated agents occupy separate panes in a real split. Captured after the native focus-section correction.

The images have different framing; the earlier component fixture is not a full-app before screenshot. Split navigation was exercised separately with simulated pane events. Live-provider delivery and VoiceOver speech remain separate acceptance checks.
