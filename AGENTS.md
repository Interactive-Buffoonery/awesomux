# Agent instructions - awesoMux

Shared rules for Claude Code and Codex (`CLAUDE.md` imports this file).

## Project

**awesoMux** is a SwiftPM macOS 15+ terminal built on libghostty, with vertical sidebar tabs and first-class agent UX. It is maintained under the `Interactive-Buffoonery` organization.

The product direction is a native single-window sidebar/session shell, not a multi-window manager or tmux replacement. Claude Code and Codex are the first intended agent integrations, with the surface designed so other agents can follow. The repo is MIT and maintains a strict GPL/source-read firewall.

## Where to look

Read the docs for the area you are changing before editing.

- Orientation / glossary: [`CONTEXT.md`](CONTEXT.md)
- Checkout-local notes (if present): [`.agents/AGENTS.md`](.agents/AGENTS.md)
- Targets, products, dependencies, platforms, and test targets: [`Package.swift`](Package.swift)
- Architecture, product model, persistence, and runtime composition: [`docs/architecture.md`](docs/architecture.md) and [`docs/adr/`](docs/adr/)
- Ghostty sourcing, build, link, runtime resources, and terminal identity: [`docs/ghostty-integration.md`](docs/ghostty-integration.md), [`.gitmodules`](.gitmodules), and the scripts under [`script/`](script/)
- Build, run, test, and local preflight: [`README.md`](README.md), [`script/preflight.sh`](script/preflight.sh), [`script/swift-test.sh`](script/swift-test.sh), [`script/build_and_run.sh`](script/build_and_run.sh)
- macOS distribution / signing / notarization / sandbox posture: [ADR-0019](docs/adr/0019-macos-distribution-signing-and-sandbox-posture.md) (not GitHub issues or PR bodies)
- CI: [`.github/workflows/cheap-guards.yml`](.github/workflows/cheap-guards.yml), [`.github/workflows/tint-contrast.yml`](.github/workflows/tint-contrast.yml), OpenCode review in [`docs/code-review.md`](docs/code-review.md)
- Scripted pane automation (`amx` send/history, `AWESOMUX_AMX`, `$ZMX_SESSION`): [`docs/amx-automation.md`](docs/amx-automation.md)
- UI tokens and SwiftUI/AppKit patterns: [`Sources/DesignSystem/`](Sources/DesignSystem/)
- Bundled fonts, icons, templates, and third-party licenses: [`Resources/`](Resources/) (tracked in-repo; no Git LFS or private asset fetch)
- Decisions not yet in code, docs, or ADRs: [GitHub Issues](https://github.com/Interactive-Buffoonery/awesomux/issues)

## Non-negotiable rules

- Never copy code from a GPL-3.0 source into this repo.
- When another product informs awesoMux behavior, rely on public product
  descriptions, documentation, screenshots, or user descriptions. Do not read
  its GPL-licensed source while implementing analogous behavior.
- Never commit `vendor/ghostty` contents directly. It is a submodule.
- Never push to `main` directly without explicit user approval.
- In public PRs, commits, and comments, use neutral wording such as "review",
  "specialist review", or "code review findings". Do not name internal
  reviewer personas.
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

Plan in GitHub Issues; ship and review in pull requests.
Link a PR to its issue when one exists.

Only the issue assignee should push to the branch and update the PR.
Everyone else reviews on GitHub — don’t push competing commits unless
ownership is handed off. Reply to specific review comments, not the
whole review in general.

### Public roadmap and Linear

Some GitHub Issues sync with Linear. Treat everything on those issues as public.

- Do not publish internal notes, private links, credentials, or private tracker refs.
- Do not create, merge, re-parent, or restructure synchronized roadmap issues
  without maintainer approval.
- Roadmap issues describe user-facing outcomes; implementation detail belongs in
  implementation issues or PRs.
- Draft new roadmap issues for maintainer review before publishing.
- Preserve existing labels when editing issue metadata.

Before opening a PR, ask the contributor the AI assistance level for the PR
template (`none`, `light`, `moderate`, or `substantial`). Do not infer it from
tool usage.

## Stack & decisions (open)

Unresolved choices until they land in code or an ADR.
[`docs/architecture.md`](docs/architecture.md) indexes this section.

| Topic | Status / direction |
| --- | --- |
| **Ghostty XCFramework prebuilds** | Fresh clones build locally via `./script/build_ghostty_xcframework.sh`. No published/cached macOS Ghostty XCFramework yet. |
| **Remote SSH workspaces** | Declared remote panes use local `amx` persistence around an SSH child. `PaneExecutionPlan` owns remote identity; host profiles, remote zmx management, and target-side installers are not current prerequisites ([ADR 0023](docs/adr/0023-remote-workspace-architecture.md)). |
| **Richer agent adapters** | Opt-in / deeper per-agent setup beyond the shipped Claude Code, Codex, and Grok plugins remains follow-up (see agent-state notes in [`docs/architecture.md`](docs/architecture.md)). |

## Build and verification

- Run the app with `./script/build_and_run.sh`.
- Run tests with `./script/swift-test.sh`.
- Before opening a non-docs PR, run `./script/preflight.sh`.
- First Ghostty builds need the `vendor/ghostty` submodule and a compatible Zig
  toolchain. Let the Ghostty scripts own how that build is staged.
- Local builds stay ad-hoc signed. Public macOS distribution follows ADR-0019
  (Developer ID, Hardened Runtime, notarization, stapling, no App Sandbox for
  the direct-release terminal app). Do not copy Ghostty’s entitlement set
  without evidence from a failing signed release build.

Do not bypass local commit/PR hooks. If a pre-merge review hook runs, address
the findings or explain why they do not apply.

## Codex approvals and sandboxing

Prefer least privilege. Don’t download packages or hit the network without a
reason, and don’t weaken environment or file protections casually.

## Code style

For targeted changes, never run a repository-wide formatter. Use
`script/format.sh` only with the Swift files you intentionally changed, and
inspect the resulting diff before continuing. Use `script/format.sh --lint` for
the non-mutating repository check. Follow `docs/toolchain.md` when updating the
pinned Swift or `swift-format` versions.

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
