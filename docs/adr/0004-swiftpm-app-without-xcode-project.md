# 0004 — SwiftPM app without a checked-in Xcode project

- **Status:** Accepted
- **Date:** 2026-05-08
- **Deciders:** eD, Sarah

## Context

macOS apps are often maintained as `.xcodeproj` / `.xcworkspace` trees with SwiftPM only for dependencies. That path gives Interface Builder, scheme sharing, and one-click Archive in Xcode—but it also duplicates build truth between the project file and any Package manifests, and it complicates headless CI unless the project is carefully kept reproducible.

awesoMux targets **Swift 6 + SwiftPM** with an **executable** app target (`awesoMux`) plus library targets (`AwesoMuxCore`, `DesignSystem`, `GhosttyKit`, `GhosttyKitLinker`). The shipping `.app` bundle is **assembled by** [`script/build_and_run.sh`](../../script/build_and_run.sh) (staging `dist/awesoMux.app`, copying resources, codesigning)—not by an Xcode archive pipeline checked into the repo.

## Decision

The **canonical build description** for the app is **`Package.swift`**. There is **no committed Xcode project** as a source of truth. Contributors and CI run `swift build`, `swift test`, and the build/run script; Xcode remains usable by opening the package (e.g. `Package.swift`) for editing and local debugging when desired.

## Consequences

- **Single build graph** — targets, dependencies, and linker settings live in one place (`Package.swift`), including the Ghostty integration’s explicit archive linking via `GhosttyKitLinker`.
- **CI simplicity** — GitHub Actions can invoke SwiftPM and shell scripts without resolving an `.xcodeproj` UUID graph.
- **Onboarding** — new contributors must understand the script stage path for a runnable `.app`, not only ⌘B in Xcode. [`AGENTS.md`](../../AGENTS.md) documents `./script/build_and_run.sh` as the primary dev loop.
- **Future** — if we later need Xcode-only capabilities (e.g. a complex App Extensions story), we can add a **thin** workspace that references the same SwiftPM package without moving build truth out of the manifest—or we supersede this ADR if we deliberately migrate to a project-first model.

## Alternatives considered

- **Xcode project as primary** — rejected for v0 to avoid dual maintenance and to keep CI aligned with SwiftPM.
- **SwiftPM + committed `.xcodeproj` wrapper** — deferred; no current requirement that isn’t met by opening the package in Xcode.
