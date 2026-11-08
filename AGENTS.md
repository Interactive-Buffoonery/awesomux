# Agent instructions — awesoMux

Shared rules for Codex and Claude (`CLAUDE.md` imports this file).
awesoMux is a SwiftPM macOS 15+ terminal built on libghostty, with a native
single-window sidebar/session shell.

## Context

Read the docs relevant to your change:

- [CONTEXT.md](CONTEXT.md), [architecture](docs/architecture.md), and [ADRs](docs/adr/).
- [README](README.md), [contributing](CONTRIBUTING.md), and [CI](docs/ci.md).
- [Ghostty integration](docs/ghostty-integration.md), [pane automation](docs/amx-automation.md),
  [signing](docs/adr/0019-macos-distribution-signing-and-sandbox-posture.md),
  [targets](Package.swift), and [UI tokens](Sources/DesignSystem/), as applicable.

The maintained shared roadmap is optional context. Use
[read-awesomux-plan](.agents/skills/read-awesomux-plan/SKILL.md) when explicitly
requested or when available planning context would help. Routine issue work
proceeds without planning access or setup. When consulting the plan, reconcile
it with current code, ADRs, and GitHub; flag conflicts.

## Guardrails

- Preserve unrelated changes. Do not push to `main` without explicit approval.
- Get direct human approval of the action and content before publishing issues,
  pushing commits, opening PRs, or posting comments/replies.
- External contributors need issue assignment or an ownership handoff before
  pushing/updating its PR; maintainers `serabi` and `edequalsawesome` are exempt.
- GitHub and synced Linear issues are public. Synced issue keys are fine;
  private notes, links, credentials, and unpublished tracker content are not.
  Draft roadmap issues for review; preserve labels and get approval before
  restructuring synced issues. Linear workspace: `interactive-buffoonery`, team `INT`.
- Use neutral public review wording; omit internal reviewer personas.
- Never copy or read GPL-3.0 source for implementation references. Use public
  product docs instead. Ghostty, Ghostling, and zmx are MIT; attribute copied patterns.
- `vendor/ghostty` and `vendor/zmx` are pinned submodules. Keep local work out;
  change pins only when explicitly requested. After pulling, reconcile unexpected
  submodule changes with `git submodule update --init --recursive`; preserve local edits.
- App/window/workspace commands belong to awesoMux menus, palette, and
  `KeyboardShortcutCatalog`, not Ghostty app-action bindings ([ADR-0020](docs/adr/0020-ghostty-app-actions-are-not-an-awesomux-command-surface.md)).
- Local builds are ad-hoc signed. Follow ADR-0019 for distribution; add entitlements
  only with evidence from a failing signed release build.

## Changes

- Keep changes narrow; avoid compatibility shims for nonexistent code paths.
- Format only changed Swift files: `./script/format.sh path/to/File.swift`.
  Inspect the diff; `./script/format.sh --lint` is non-mutating.
- Use literal-as-key `String(localized:)`, never keyed `defaultValue:` calls.
  Use `Localizable.stringsdict` for plurals ([ADR-0014](docs/adr/0014-literal-as-key-localized-strings.md)).
- Comments explain non-obvious reasons. Commits use Conventional Commits,
  imperative lowercase subjects, no trailing period, and at most 72 characters.

## Verification and PRs

- Prefer E2E verification with a repeatable artifact. Do not grow the unit suite
  or write unit tests after production code. If isolation testing is necessary,
  document failure modes and write Swift Testing tests first. Preserve existing
  tests unless changing them or performing a focused cull.
- Choose proportional checks and report actual results. Keep E2E, automated
  tests, preflight, native UI, and accessibility evidence separate.
- Use repository scripts for Ghostty/Zig setup. Never bypass commit or PR hooks.
- `./script/build_and_run.sh` builds/runs the app; `./script/test.sh all` runs
  zmx and existing Swift tests. Filters match identifiers: require a non-zero count.
- Rerun one failing test with `./script/swift-test.sh --filter <Suite>/<test>`.
  Commit once it passes, not once per attempt.
- Before a non-docs PR, run `./script/preflight.sh` directly and preserve its exit
  status. Docs-only changes can use `git diff --check`.
- After preflight, run [merge-risk](.agents/skills/merge-risk/SKILL.md) and add its
  one-line result under Notes in the PR.
- Link the issue and follow the exact [PR template](.github/pull_request_template.md)
  headings. Remove placeholders. Write PR text and merge risk updates in simple
  English or ASD-STE100 (Simplified Technical English).
- List the models that worked on the change after `Models:` in the PR, or `None`.
