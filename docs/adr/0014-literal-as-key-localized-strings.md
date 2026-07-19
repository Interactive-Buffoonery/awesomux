# 0014 - Localized strings use literal-as-key

## Status

Accepted (INT-450).

## Context

The INT-22 review surfaced two coexisting `String(localized:)` styles in
alert dialogs. The quit-risk alert used keyed strings
(`String(localized: "quit.alert.title", defaultValue: "Quit awesoMux?")`)
while the close-confirm alert — and roughly 95 of the ~104 localized call
sites across `Sources/` — used the literal-as-key style
(`String(localized: "Close \(displayTitle)?", comment: "…")`).

Mixed styles make translators switch mental models between adjacent
dialogs and leave future PRs without a default to follow. The repo has no
`.xcstrings` catalog at the time, so no shipped translations constrained the choice.

## Decision

Localized strings use literal-as-key with a `comment:`:

```swift
String(
    localized: "Quit awesoMux?",
    comment: "Title of the quit confirmation dialog."
)
```

Do not introduce keyed strings with `defaultValue:`. Rationale:

- Literal-as-key is the modern Apple convention: Xcode's String Catalog
  auto-extracts the English source as the key at build time.
- It was already the de facto repo style; migrating the nine keyed quit
  alert strings was the smallest possible change.
- Less ceremony per call site; the `comment:` carries translator context.

Count-dependent strings still go through `Localizable.stringsdict` plural
entries per the existing AGENTS.md rule — this ADR governs key style, not
pluralization.

## Consequences

- Rewording English copy changes the key and invalidates any existing
  translation of that string. Acceptable pre-1.0 and pre-localization.
- Identical English text appearing in two contexts shares one catalog
  entry; if two contexts ever need different translations, disambiguate
  the English source text rather than reintroducing keys. Catalog
  extraction also merges their `comment:` values into one entry, so only
  one comment survives for shared strings like "Cancel".
- INT-612 added an app-owned `Localizable.xcstrings`. The staging script compiles
  it into the macOS app's resources, so SwiftUI, Core, and DesignSystem all resolve
  through `Bundle.main`. Do not move the catalog into one target's `Bundle.module`
  without updating every other target's lookup path.
- `AGENTS.md` documents the convention under Swift code style so agents
  and humans default to it.
- Tests assert the developer-language (English) value of localized strings
  directly; suites run under an English locale. Pinning such assertions to
  an explicit locale is deliberately avoided — label constants carry no
  bundle/locale plumbing, and review findings asking for it are dismissed
  as out of convention.
