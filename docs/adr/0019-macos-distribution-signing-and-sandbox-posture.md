# 0019 - macOS distribution, signing, and sandbox posture

## Status

Accepted (INT-18).

## Date

2026-07-07

## Deciders

Sarah, eD

## Context

awesoMux is a macOS 15+ terminal app assembled from SwiftPM targets by
`script/build_and_run.sh`. Local development currently stages `dist/awesoMux.app`
and ad-hoc signs it so macOS frameworks that require a bundle identity, such as
notifications, behave during development.

That local-development signature is not a release posture. Public distribution
needs a stable Developer ID signature, Hardened Runtime, notarization, stapling,
and verification. The app bundle also contains multiple executables:

- `awesoMux`
- `awesoMuxAgentHook`
- `amx`

All release executables need valid signatures. Shared libraries, static archives,
and in-process code inherit from the host executable rather than carrying their
own entitlement policy.

awesoMux is also a terminal. Its core value depends on creating PTYs, launching
login shells, running arbitrary user tools, reading and writing project files,
using Homebrew-installed CLIs, driving agent hooks, and optionally using the
`amx` command bridge. Those behaviors do not fit a near-term App Sandbox posture.
The Mac App Store and TestFlight lanes require separate compatibility work rather
than quietly changing the direct-download app's threat model.

Upstream Ghostty is useful reference material because awesoMux embeds libghostty,
but Ghostty's macOS entitlements are not awesoMux's policy. Ghostty carries broad
protected-resource entitlements for its own app surface and history. Copying that
set would widen awesoMux's security and privacy surface without evidence that the
permissions are required.

## Decision

Direct macOS distribution is the primary release lane:

1. Publish signed, notarized GitHub Release artifacts first.
2. Publish a Homebrew cask that installs the same GitHub Release artifact.
3. Treat TestFlight or Mac App Store distribution as a later compatibility lane.

For direct distribution, release builds use:

- Developer ID Application signing.
- Hardened Runtime.
- Notarization through Apple's notary service.
- Stapling before publication.
- No App Sandbox entitlement.

Release signing must cover the app and bundled helper executables. In practice,
the release flow signs `awesoMux`, `awesoMuxAgentHook`, `amx`, any nested code,
and then the final `.app` bundle.

Hardened Runtime exception entitlements start empty. Do not add
`com.apple.security.cs.allow-jit`,
`com.apple.security.cs.disable-library-validation`,
`com.apple.security.cs.allow-dyld-environment-variables`,
`com.apple.security.automation.apple-events`, camera, audio, contacts, calendars,
location, photos, or other protected-resource entitlements just because Ghostty
or another terminal uses them. Add an entitlement only when all of the following
are true:

1. A real signed release build fails without it.
2. The failure is captured with concrete local output, notarization output, or
   runtime behavior.
3. The entitlement is the smallest permission that explains and fixes the
   failure.
4. The ADR or a follow-up ADR is updated with the evidence and resulting policy.

GitHub issues, PR bodies, and release checklists track work, but they do not own
the signing, sandbox, or entitlement decision. This ADR is the source of truth
until superseded.

## Consequences

`script/build_and_run.sh` remains the local development path and keeps ad-hoc
signing. Release signing belongs in a dedicated release flow, not in the normal
build/run loop.

Homebrew work is blocked on a signed, notarized, stapled GitHub Release artifact.
The cask should install that artifact directly rather than rebuilding or
repackaging awesoMux.

The direct-release app keeps terminal behavior intact: shell spawning, project
file access, user CLIs, `awesoMuxAgentHook`, and `amx` remain designed for an
unsandboxed Developer ID app.

A future TestFlight or Mac App Store lane must start with a sandbox
compatibility spike. At minimum, that spike must prove PTY creation, login shell
launch, user-selected project access, common CLI execution, SSH and networking,
local dev-server behavior, bundled helper execution, agent hook behavior, session
persistence, notification behavior, and any expected sandbox limitations.

Because entitlements widen the signed process's capabilities, release failures
should be debugged before granting exceptions. This keeps Hardened Runtime useful
instead of turning the entitlement file into a copied allowlist.

## References

- [Apple: Hardened Runtime](https://developer.apple.com/documentation/security/hardened-runtime)
- [Apple: Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Apple: App Sandbox entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.app-sandbox)
- [Apple: Disable Library Validation entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.disable-library-validation)
- [Apple: Apple Events entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.automation.apple-events)
- [awesoMux release checklist](../releasing.md)
