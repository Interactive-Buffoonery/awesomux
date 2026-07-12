# Agent instructions - awesoMux

Read this before doing any work in this repo. This file is the shared source of truth for Claude Code and Codex; `CLAUDE.md` imports it.

## Read first

- Start with [`CONTEXT.md`](CONTEXT.md), [`docs/architecture.md`](docs/architecture.md), [`docs/ghostty-integration.md`](docs/ghostty-integration.md), and relevant ADRs in [`docs/adr/`](docs/adr/).
- For UI/design work, follow the existing SwiftUI/AppKit patterns and the tokens under [`Sources/DesignSystem/`](Sources/DesignSystem/).

## Project

**awesoMux** is a SwiftPM macOS 15+ terminal built on libghostty, with vertical sidebar tabs and first-class agent UX. It is maintained under the `Interactive-Buffoonery` organization.

The product direction is a native single-window sidebar/session shell, not a multi-window manager or tmux replacement. Claude Code and Codex are the first intended agent integrations, with the surface designed so other agents can follow. The repo is MIT and maintains a strict GPL/source-read firewall.

## Source-of-truth map

- Targets, products, dependencies, platforms, and test targets: [`Package.swift`](Package.swift).
- Architecture, product model, persistence, and runtime composition: [`docs/architecture.md`](docs/architecture.md) and [`docs/adr/`](docs/adr/).
- Ghostty sourcing, build, link, runtime resources, and terminal identity: [`docs/ghostty-integration.md`](docs/ghostty-integration.md), [`.gitmodules`](.gitmodules), and the scripts under [`script/`](script/).
- Build, run, test, and local preflight commands: [`README.md`](README.md), [`script/preflight.sh`](script/preflight.sh), [`script/swift-test.sh`](script/swift-test.sh), and [`script/build_and_run.sh`](script/build_and_run.sh).
- macOS distribution, signing, Hardened Runtime, notarization, and App Sandbox posture: [ADR-0019](docs/adr/0019-macos-distribution-signing-and-sandbox-posture.md). Keep the ADR as the source of truth; GitHub issues and PR bodies track work but do not decide this policy.
- CI behavior: [`.github/workflows/swift.yml`](.github/workflows/swift.yml).
- Scripted pane automation (`amx` send/history, `AWESOMUX_AMX`, `$ZMX_SESSION` addressing): [`docs/amx-automation.md`](docs/amx-automation.md).
- UI tokens and atoms: [`Sources/DesignSystem/`](Sources/DesignSystem/).
- Bundled fonts, app-icon sources, integration templates, and third-party license files are tracked directly under [`Resources/`](Resources/); fresh clones must not depend on Git LFS or a private asset fetch.
- Product and implementation decisions not already recorded in code, docs, or ADRs: [GitHub Issues](https://github.com/Interactive-Buffoonery/awesomux/issues).

## Non-negotiable rules

- Never copy code from a GPL-3.0 source into this repo.
- When another product informs awesoMux behavior, rely on public product
  descriptions, documentation, screenshots, or user descriptions. Do not read
  its GPL-licensed source while implementing analogous behavior.
- Never commit `vendor/ghostty` contents directly. It is a submodule.
- Never push to `main` directly without explicit user approval.
- Public artifacts use neutral wording such as "review", "specialist review", or "code review findings". Do not mention internal reviewer/persona names in PR titles, PR bodies, commits, issue comments, or other public surfaces.
- awesoMux owns app/window/workspace command routing through SwiftUI/AppKit
  menus, the command palette, and `KeyboardShortcutCatalog`. Do not route
  Ghostty app-action keybindings into awesoMux commands or document them as a
  parallel command surface unless a new decision explicitly changes
  [ADR-0020](docs/adr/0020-ghostty-app-actions-are-not-an-awesomux-command-surface.md).

## Reference repositories

- `ghostty-org/ghostty` (MIT) is the canonical libghostty source and macOS Swift integration reference. Quote small copied patterns with attribution.
- `ghostty-org/ghostling` (MIT) is the minimum viable C terminal reference for libghostty embedding.
- `neurosnap/zmx` (MIT) is the upstream of `Interactive-Buffoonery/zmx`, our public fork vendored at `vendor/zmx` that adds the AMX out-of-band protocol (ADR 0011). General fixes go upstream when practical; the fork rebases onto upstream `main` on pin-bumps.

## Collaboration workflow

Use GitHub Issues as the public handoff contract and GitHub PRs as the implementation and review artifact.

One agent owns branch writes at a time:

- The issue assignee is the current implementation owner.
- The implementation owner may edit files, push commits, and update the PR.
- The reviewing agent stays read-only on that branch unless ownership is explicitly transferred.
- Review output lands as GitHub review comments or follow-up GitHub issues.
- The implementing agent responds only to concrete review comments or explicit issue follow-ups.

GitHub issue and PR state carry the public lifecycle. Link each implementation PR to its issue when one exists.

### Public roadmap and Linear synchronization

GitHub Issues are the public planning and discussion surface for awesoMux.
Internal implementation planning may be maintained separately in Linear.

Some GitHub Issues are synchronized with Linear. Treat all titles,
descriptions, comments, labels, statuses, and relationships on synchronized
issues as public information, regardless of which system you edit them from.

- Do not publish internal implementation notes, private links, credentials,
  security-sensitive details, or private tracker references.
- Do not create, merge, re-parent, or restructure synchronized roadmap issues
  without explicit maintainer approval.
- Public roadmap issues describe user-facing outcomes. Implementation details
  belong in implementation issues or pull requests intended for public view.
- Draft new roadmap issues for maintainer review before publishing them.
- Preserve existing labels when editing issue metadata.
- GitHub Issues and pull requests remain the public handoff and review
  artifacts for contributors.

Before opening a PR, agents must ask the contributor what AI assistance level to put in the PR template (`none`, `light`, `moderate`, or `substantial`). Do not infer this from tool usage. The contributor may have reviewed, rewritten, or shaped the work enough that the right disclosure level differs from the agent's raw contribution.

## Build and verification

- Run the app locally with `./script/build_and_run.sh`.
- Run tests with `./script/swift-test.sh`.
- Before opening any PR that is more than docs/Markdown changes, run `./script/preflight.sh`.
- First Ghostty builds require the `vendor/ghostty` submodule and a compatible Zig toolchain. Let the Ghostty scripts own exact artifact, worktree, and optimize-mode behavior.
- Local development builds stay ad-hoc signed. Public macOS distribution must follow ADR-0019: Developer ID Application signing, Hardened Runtime, notarization, stapling, no App Sandbox for the direct-release terminal app, and no copied Ghostty entitlement set without evidence from a failing signed release build.

Do not bypass local commit/PR hooks. If a pre-merge review hook runs, address concrete findings or explain why they do not apply.

## Codex approvals and sandboxing

Use least privilege for the task, avoid unnecessary package downloads or arbitrary external fetches, and do not weaken environment or file protections without a specific reason.

## Code style

### Swift

- Follow the Swift API Design Guidelines.
- Prefer `struct` and value types. Use `class` only when reference semantics or Cocoa/AppKit requires it.
- Keep one type per file unless the types are trivially small and clearly related.
- Use `// MARK: -` for top-level sections in long files.
- Write tests for non-trivial logic. UI smoke is fine; pure logic gets unit coverage.
- New tests use swift-testing (`@Suite` / `@Test` / `#expect`). Existing XCTest tests stay until touched.
- User-facing count-dependent strings must use `Localizable.stringsdict` plural entries via `String(localized:)`; do not add `count == 1 ? ... : ...` singular/plural switches for UI, notification, or accessibility copy.
- Localized strings use literal-as-key: `String(localized: "Quit awesoMux?", comment: "…")`. Do not introduce keyed strings with `defaultValue:` (see [ADR 0014](docs/adr/0014-literal-as-key-localized-strings.md)).

### General

- Conventional Commits: `<type>(<scope>): <lowercase imperative>`. Subject <=72 chars, no period. Types: `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `chore`, `build`, `ci`, `revert`. Breaking change: `!` before `:`.
- `main` is protected. Feature work goes on branches and lands via PR.
- Don't add backwards-compatibility shims for code paths that don't exist yet. We're pre-1.0.
- Don't write code comments that just narrate what the code does. Comments earn their place by explaining *why* something non-obvious is the case.
