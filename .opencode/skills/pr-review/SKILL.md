---
name: pr-review
description: |
  Project-specific pull request review for awesoMux. Covers Swift/macOS API design,
  Swift 6 concurrency, SwiftUI correctness, accessibility, clean code, security,
  and libghostty boundary checks. Use for all PR reviews on this repository.
---

# PR Review — awesoMux

Post a concise structured code review as a PR comment. Do not push commits or modify files.
Write the entire PR comment in English, regardless of model locale, runner
locale, PR author locale, or source language in the diff.
The structured code review is the final public answer. Do not add a preamble,
postscript, or separate completion summary after it; the GitHub action posts
the final assistant message as the PR comment.

## Scope

Fetch the entire diff in **one** call using the exact immutable base/head range
supplied in the workflow prompt: `git diff <exact-base-head-range>`. Never use a
floating `HEAD` substitute or chunk the fetch per-file or per-file-group across
separate turns — that starves the budget before you draft. Read surrounding
context (direct callers/callees) only after you have the full diff in hand.
Focus on the diff — flag pre-existing issues only if they interact with the
change.

Large-diff budget rule: prioritize drafting the `## Code Review` over exhaustive
reading. If you are running short on budget, draft the review from the diff you
already have rather than continuing to investigate. A complete `## Code Review`
from a partial read beats narration with no review.

## Review checklist

### Swift API design

- Names follow the Swift API Design Guidelines. Side-effecting names are
  verb phrases; non-mutating names read as noun phrases.
- Optional handling is explicit. Force unwraps and force casts are justified
  or removed.
- Public APIs have documentation when behaviour is non-obvious.
- Parameters are labelled for clarity at the call site.

### Value types and reference types

- `struct` by default. `class` only when reference semantics, Cocoa/AppKit
  interop, or identity semantics require it.
- Value types do not capture `self` in escaping closures that mutate shared
  state.
- Copy-on-write is used correctly for large value types with value semantics.

### Swift 6 concurrency

- Actor isolation is explicit and consistent, especially `@MainActor` on
  UI-facing state.
- `Sendable` boundaries are safe. Non-Sendable objects do not cross task
  boundaries unsafely.
- Async APIs use structured concurrency. Detached tasks are justified.
- Cancellation and error paths are handled, not swallowed.
- UI updates occur on the main actor without ad-hoc dispatching.

### SwiftUI correctness

- Views remain declarative and reasonably small. Complex behaviour moves to
  helpers or models.
- Bindings do not create feedback loops or ambiguous sources of truth.
- `List`, `ForEach`, and animations use stable identity.
- Long-running work is not started repeatedly by `body` recomputation.
- `@State` is local to the view. `@StateObject` owns the lifecycle.
  `@ObservedObject` is injected. `@EnvironmentObject` is for shared
  dependencies.

### Memory ownership

- No retain cycles in escaping closures, tasks, delegates, or callbacks.
- `weak` / `unowned` references are used correctly when breaking cycles.
- C callback context pointers respect lifetime and ownership rules.

### AppKit interop

- AppKit objects stay on the main thread. Thread affinity violations are
  flagged.
- Delegate and notification observers are unregistered on teardown.
- Cocoa bridging (`NSColor` / `Color`, `NSImage` / `Image`) is correct.

### Accessibility

- All interactive elements have meaningful accessibility labels and traits.
- `VoiceOver` users can reach and operate every control via keyboard.
- Focus management is correct: modals trap focus, tab order is logical,
  focus returns to trigger element on dismiss.
- Dynamic Type is supported. Layout does not clip or overlap at large sizes.
- `@Environment(\.accessibilityReduceMotion)` and
  `@Environment(\.accessibilityReduceTransparency)` adapt visuals for
  accessibility settings.
- Color is not the sole indicator of state. At minimum a second channel
  (icon, label, pattern) communicates the same information.
- Dynamic content changes are announced via `AccessibilityNotification`.
- Touch targets meet 44×44 pt minimum.

### Clean code

- No dead code or unused imports in the diff.
- Error paths are handled, not silently swallowed. `try?` is justified.
- Input validation exists for new code paths that accept external data.
- Missing test coverage for changed behaviour is flagged.
- Consistent style across similar code paths (naming, error handling,
  logging patterns).
- No placeholder implementations, `// TODO` without a tracking issue,
  or debug print statements left in production code.

### Security

- No secrets, tokens, or credentials in the diff.
- Entitlements and sandboxing are correct for new capabilities.
- Keychain access follows best practices (access control, item deletion).
- XPC boundaries validate incoming data and check caller entitlements.
- User input is sanitised before use in queries, paths, or shell arguments.
- Network calls use HTTPS and validate certificates where appropriate.

### libghostty boundaries

- No code copied from GPL-3.0 sources, including cmux source.
- No reading of cmux source while writing code for this repo.
- `vendor/ghostty` contents are never committed directly — it is a submodule.
- Ghostty integration follows patterns documented in
  `docs/ghostty-integration.md`.

### Project norms

- Conventional Commits: `<type>(<scope>): <lowercase imperative>`.
- Tests use swift-testing (`@Suite` / `@Test` / `#expect`) for new tests.
- Public review output is always written in English, regardless of model
  locale, runner locale, PR author locale, or source language in the diff.
- Review comments use neutral wording: "review", "code review findings",
  "specialist review". No internal persona or reviewer names in public
  comments, PR titles, commit messages, or Linear comments.

## Output format

The public PR comment must be short and directly actionable.

- Your final message **must** begin with `## Code Review`, with no preamble. This
  is unconditional: if analysis could not be completed, still emit the block with
  whatever findings exist (or the "No blocking or should-fix findings" form
  below). Never end on process narration — narration is discarded and posted as
  an empty review.
- Start with `## Code Review`.
- Include only sections that contain findings; omit empty sections instead of
  writing `None`.
- Omit `Verified` and `Not verified` sections unless the user explicitly asks
  for an audit trail.
- Cap findings at 5 total, with at most 2 nits.
- Each finding must use `file:line — problem; fix` and be no more than two
  short sentences.
- If there are no blockers or should-fix items, output only:

```markdown
## Code Review

No blocking or should-fix findings.
```

When findings exist, use this shape:

````markdown
## Code Review

**Blockers:** <count> | **Should fix:** <count> | **Nits:** <count>

### Blockers
- `file:line` — Issue; suggested fix.

### Should fix
- `file:line` — Issue; suggested fix.

### Nits
- `file:line` — Issue. Suggested fix.
````

## Constraints

- Read-only. Do not modify source files.
- Focus on the diff. Flag pre-existing issues only when they interact with
  the change.
- Give concrete replacement code only when a short inline fix would be clearer
  than prose.
- Separate blockers from nits. Do not inflate style preferences into
  correctness issues.
- Prefer minimal fixes fitting the existing architecture over broad rewrites.
- If no diff is available, review the working tree against HEAD.
