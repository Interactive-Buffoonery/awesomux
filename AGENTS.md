# Agent instructions — awesoMux

Shared rules for Claude Code and Codex (`CLAUDE.md` imports this file).

awesoMux is a SwiftPM macOS 15+ terminal built on libghostty. Its product shape
is a native, single-window sidebar/session shell with first-class agent UX—not a
multi-window manager or tmux replacement.

## Start here

Read the documentation for the area you will change before editing:

- Orientation and glossary: [`CONTEXT.md`](CONTEXT.md)
- Checkout-local notes, when present: `.agents/AGENTS.md`
- Architecture and decisions: [`docs/architecture.md`](docs/architecture.md) and
  [`docs/adr/`](docs/adr/)
- Build, test, and contribution workflow: [`README.md`](README.md),
  [`docs/ci.md`](docs/ci.md), and [`CONTRIBUTING.md`](CONTRIBUTING.md)
- Ghostty integration and submodule updates:
  [`docs/ghostty-integration.md`](docs/ghostty-integration.md)
- Pane automation (`amx`, `AWESOMUX_AMX`, `$ZMX_SESSION`):
  [`docs/amx-automation.md`](docs/amx-automation.md)
- Distribution, signing, and sandbox posture: [ADR-0019](docs/adr/0019-macos-distribution-signing-and-sandbox-posture.md)
- Targets and dependencies: [`Package.swift`](Package.swift); UI tokens and
  patterns: [`Sources/DesignSystem/`](Sources/DesignSystem/)

Use current code, ADRs, and docs as the source of truth. Use GitHub Issues for
decisions not recorded there; do not treat old issue or PR prose as current
architecture without checking.

## Hard guardrails

### Licensing and dependencies

- Never copy code from GPL-3.0 sources. When another product informs analogous
  behavior, do not read its GPL source; use public product documentation,
  screenshots, or user descriptions instead.
- `ghostty-org/ghostty`, `ghostty-org/ghostling`, and `neurosnap/zmx` are MIT
  references. Attribute any small copied pattern.
- `vendor/ghostty` and `vendor/zmx` are pinned submodules. Do not park
  uncommitted work inside them, commit their contents, or change a gitlink/pin
  unless the task explicitly asks for a pin update. Follow the integration docs
  for temporary local diagnostics.
- If a submodule appears modified after pulling, run
  `git submodule update --init --recursive`. The update refuses to overwrite
  local submodule changes.

### Product and command ownership

- Keep the app aligned with the native single-window product direction.
- awesoMux owns app, window, and workspace commands through SwiftUI/AppKit
  menus, the command palette, and `KeyboardShortcutCatalog`. Ghostty app-action
  keybindings are not a parallel awesoMux command surface; see [ADR-0020](docs/adr/0020-ghostty-app-actions-are-not-an-awesomux-command-surface.md).
- Local builds are ad-hoc signed. Follow ADR-0019 for distribution; do not copy
  Ghostty's entitlements without evidence from a failing signed release build.

### Repository and public workflow

- Preserve unrelated local changes. Never push directly to `main` without
  explicit user approval.
- Do not publish issues, open PRs, push commits, or post review comments or
  replies without direct human approval of that action and its content.
- Only the issue assignee pushes to its branch or updates its PR unless
  ownership is handed off. Other contributors review on GitHub and reply to the
  specific review thread.
- Treat GitHub issues synchronized with Linear as public. Do not expose internal
  notes, private links, credentials, or private tracker references. Draft new
  roadmap issues for maintainer review; do not restructure synchronized roadmap
  issues without approval, and preserve labels.
- In public text, use neutral terms such as “review” or “code review findings”;
  do not name internal reviewer personas.

## Making changes

- Prefer narrow changes that use existing seams. Do not add compatibility shims
  for code paths that do not exist yet.
- Format only Swift files you intentionally changed:
  `./script/format.sh path/to/File.swift`, then inspect the diff. Use
  `./script/format.sh --lint` for a non-mutating check.
- New tests use Swift Testing (`@Suite`, `@Test`, `#expect`). Keep existing
  XCTest tests unless you are already changing them. Give non-trivial logic unit
  coverage; do not substitute UI smoke for pure-logic tests.
- Localized strings use literal-as-key `String(localized:)`, never keyed
  `defaultValue:` calls. Count-dependent user-facing text uses
  `Localizable.stringsdict`, not hand-written singular/plural branches. See
  [ADR-0014](docs/adr/0014-literal-as-key-localized-strings.md).
- Comments should explain a non-obvious reason, not narrate the code.
- Commit subjects follow Conventional Commits, use an imperative lowercase
  description, have no trailing period, and stay at or below 72 characters.

## Verification

Choose checks proportional to the change and report exactly what ran:

```sh
./script/build_and_run.sh                     # build and run the app
./script/swift-test.sh --filter SomeTests     # focused Swift tests
./script/test.sh all                          # zmx and full Swift suite
./script/preflight.sh                         # full non-docs PR gate
```

- A Swift test filter matches identifiers, not display names. Confirm the output
  reports a non-zero test count; a filter that matches nothing can exit 0.
- Run `./script/preflight.sh` directly and use its own exit status. Do not pipe
  it or append a command that masks failure.
- Let repository scripts prepare Ghostty and the compatible Zig toolchain.
- Do not bypass commit or PR hooks. Address findings or document why they do not
  apply. Keep automated tests, full preflight, and manual macOS/UI/accessibility
  checks as separate evidence; one does not imply another passed.

## Pull requests

- Plan in an issue when appropriate and link the PR to it.
- Before opening a PR, ask the contributor to choose the AI assistance level:
  `none`, `light`, `moderate`, or `substantial`. Never infer it from tool usage.
- Read [`.github/pull_request_template.md`](.github/pull_request_template.md) in
  full and preserve its exact required headings. Remove placeholder comments,
  include real validation results, and explicitly name checks not run and why.
- Before a non-docs PR, run `./script/preflight.sh`. If it was not run, say so
  in the PR.
