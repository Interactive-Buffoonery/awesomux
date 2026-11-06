# Agents panel screenshots

These unedited native screenshots use simulated agent data. They do not show live provider activity or permission decisions.

- `panel-before.png`: an AppKit-hosted SwiftUI component fixture of the previous capped panel layout from commit `d904ee79`, rendered with current Core and DesignSystem modules.
- `panel-after.png`: the integrated development app after the layout refinement. It shows a wrapped custom title, project provenance without the repeated title, a compact reason/mark-seen row, the continuous sidebar divider, and footer-only mode switching. The terminal explicitly labels its simulated event.

The images have different framing; the earlier component fixture is not a full-app before screenshot. Split navigation was exercised separately with simulated pane events. Live-provider delivery and VoiceOver speech remain separate acceptance checks.
