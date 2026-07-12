# 0016 - Agent icon family and provider glyphs

## Status

Accepted.

## Context

Each supported agent provider gets a distinct glyph in the sidebar and peek
surfaces. The glyphs are drawn programmatically as SwiftUI shapes in
`Sources/DesignSystem/Atoms/AgentTile.swift`, not shipped as asset-catalog
images, and each is tinted with a single Catppuccin token from
`Sources/DesignSystem/Tokens/AwColor.swift`. There was no recorded convention
for how a glyph's shape or tint is chosen.

The Codex glyph prompted this: it began as three overlapping rings in a
triangle, which read as a hazard/biohazard symbol, then became a cloud. The
cloud was generic and visually soft beside the rest of the family. Codex now
uses an organic open spiral tinted `lavender`: a house mark that suggests
iteration while staying distinct at the smallest tile size.

## Decision

- Provider glyphs are code-drawn shapes in `AgentTile.swift`. No per-provider
  asset images.
- A glyph's silhouette must not read as a real-world sign (the retired Codex
  rings read as a hazard symbol).
- Prefer a shape that connects to the provider's identity. When the literal
  metaphor is weak, a distinct and legible house mark may be the better fit.
  Current glyphs:

  | Provider | Glyph | Tint |
  |---|---|---|
  | Claude | radiating burst | `peach` |
  | Codex | organic open spiral | `lavender` |
  | OpenCode | open brackets | `sky` |
  | Pi | `π` | `mauve` |
  | Grok | three overlapping rings | `green` |
  | Shell | `>_` prompt | `text` |

  Grok's rings are the shape this ADR retired from Codex. Reviving them for a
  different provider, in a different tint, is a deliberate exception — see
  [ADR 0017](0017-grok-icon-only-agent-and-revived-rings-glyph.md) for why the
  hazard-reading concern does not carry over.

- Where two providers share a tint, the glyph shapes must carry the distinction
  on their own. Every provider currently holds a unique tint (Codex moved from
  `sky` to `lavender` so it no longer collides with OpenCode); if a future
  provider must reuse a token, pair it with a clearly-distinct shape.

## Consequences

- New providers add a case in `AgentTile.swift` with a distinct shape, and
  claim a tint that either is unused or pairs with a clearly-distinct shape.
- Codex (`lavender`) and Pi (`mauve`) are both in the purple family. They are
  distinct tokens with clearly different hues and distinct shapes (spiral vs
  `π`); watch that they don't read as one family if rendered adjacent.
