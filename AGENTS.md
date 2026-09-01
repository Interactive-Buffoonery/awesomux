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
- CI policy and commands: [`docs/ci.md`](docs/ci.md); workflows live under [`.github/workflows/`](.github/workflows/), with OpenCode review details in [`docs/code-review.md`](docs/code-review.md)
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

## Submodules

`vendor/ghostty` and `vendor/zmx` are pinned submodules; the build scripts sync
them (see [`docs/ghostty-integration.md`](docs/ghostty-integration.md)).

- If `git status` shows a submodule as modified after a pull, run
  `git submodule update --init --recursive`. It refuses to discard local
  modifications rather than overwriting them.
- Never commit a submodule gitlink change (e.g. staging the `M vendor/ghostty`
  entry) or bump a pin without an explicit user request. Pin updates are
  deliberate PRs ("Updating The Pin" in
  [`docs/ghostty-integration.md`](docs/ghostty-integration.md)).
- Do not park uncommitted changes inside `vendor/`.

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

### Pull request body

CI fails the PR if the body does not match the template, so read the whole
template before you write one. Read the file in full — most sections carry
their instructions in an HTML comment that the headings alone do not show:

```sh
cat .github/pull_request_template.md
```

To check a draft against the required sections, list them with line numbers:

```sh
grep -n '^## ' .github/pull_request_template.md
```

Never read the template with `head` or `sed -n '1,40p'`. The last three sections
start at line 42, so a 40-line read hides `Risk Notes`, `Review Notes`, and
`Follow-ups` and still looks complete.

Rules the validator applies:

- Code PRs need seven `##` sections, spelled exactly: `Why`, `What's Included`,
  `UI / UX`, `Validation`, `AI Assistance`, `Risk Notes`, `Follow-ups`.
- Docs-only PRs need five. They drop `UI / UX` and `Risk Notes`. Docs-only means
  every changed file ends in `.md`, `.txt`, or `.rst`, sits under `docs/`, or is
  LICENSE, NOTICE, AUTHORS, or CODE_OF_CONDUCT.md.
- `Review Notes` is in the template, but the validator ignores it.
- Each required section must have visible text after HTML comments, bullet
  marks, and table rules are removed.
- Delete the template placeholder comments. The validator matches their text, so
  editing around one still fails.
- `Validation` needs real evidence: a checked `- [x]` box, a backticked command
  with a pass or run word, the word "manually", "tested", or "verified", or an
  explicit statement that a check was not run and why.
- `AI Assistance` must contain the literal string
  `Assistance level: none|light|moderate|substantial`.
- The `Validation` and `AI Assistance` content rules apply whenever those
  sections are present, docs-only PRs included.

The validator runs from the default branch, not from the PR branch. A PR that
changes `.github/scripts/validate-pr-body.mjs` must still satisfy the copy on
`main`.

## Stack & decisions (open)

Unresolved choices until they land in code or an ADR.
[`docs/architecture.md`](docs/architecture.md) indexes this section.

| Topic | Status / direction |
| --- | --- |
| **Ghostty XCFramework prebuilds** | Fresh clones build locally via `./script/build_ghostty_xcframework.sh`. No published/cached macOS Ghostty XCFramework yet. |
| **Remote SSH workspaces** | Declared remote panes default to local `amx` persistence around an SSH child, and may opt into remote-owned zmx persistence per pane (session name only — the attach resolves `amx`/`zmx` on the far host itself) instead. `PaneExecutionPlan` owns remote identity; host profiles and target-side installers remain non-prerequisites ([ADR 0023](docs/adr/0023-remote-workspace-architecture.md) and its amendment). Linux destinations use a manually installed static helper ([`docs/remote-linux-helper.md`](docs/remote-linux-helper.md)). |
| **Richer agent adapters** | Opt-in / deeper per-agent setup beyond the shipped Claude Code, Codex, and Grok plugins remains follow-up (see agent-state notes in [`docs/architecture.md`](docs/architecture.md)). |

## Build and verification

- Run the app with `./script/build_and_run.sh`.
- Run the complete test suite with `./script/test.sh all`. Use
  `./script/swift-test.sh --filter ...` only for focused selections.
- Before opening a non-docs PR, run `./script/preflight.sh`. Run it directly and
  read its own exit code — never `preflight.sh | tail` or a trailing `echo`,
  which report the last command's status instead and turn a red preflight green.
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
