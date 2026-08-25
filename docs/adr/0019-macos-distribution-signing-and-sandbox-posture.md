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
- Sparkle's `Autoupdate` helper and `Updater.app`

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
the release flow signs the app helpers, Sparkle's `Autoupdate`, `Updater.app`,
and `Sparkle.framework` inside-out with Hardened Runtime before signing the
final `.app` bundle. The non-sandboxed bundle omits Sparkle's unused XPC
services. Signing must never use `codesign --deep`; deep verification of the
finished bundle remains required. Every nested executable and framework is
covered by the same Developer ID authority, Hardened Runtime, and empty-
entitlements checks as the outer app. No Sparkle entitlement exceptions are
added.

Stable, updater-enabled bundles are an explicit release configuration. They
embed `SURequireSignedFeed`, `SUVerifyUpdateBeforeExtraction`,
`SUSignedFeedFailureExpirationInterval = 0`, and the public EdDSA key. Disabling
Sparkle's signed-feed recovery interval keeps rejection strict instead of
falling back to same-team Developer ID verification after prolonged feed
failures. Scheduled nightly builds do not receive that configuration and do
not contact the stable feed. The workflow generates a signed `appcast.xml`
only when it will create a stable draft release, using the exact notarized and
stapled versioned DMG already published to GitHub and consumed by Homebrew.
Delta generation is disabled; no second archive or feed hosting lane exists.

The Sparkle public key is the protected `release` environment variable
`SPARKLE_PUBLIC_ED_KEY`. Its private counterpart is the environment secret
`SPARKLE_PRIVATE_ED_KEY`, exposed only to the stable appcast generation step
and piped to Sparkle through standard input. The private key is never written
to disk or passed in process arguments.

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
repackaging awesoMux, and declares `auto_updates true` because the installed app
uses Sparkle rather than relying on `brew upgrade` for updates.

Sparkle key custody is release continuity. Losing the private key means existing
updater-enabled installs cannot accept a newly signed feed. Replacing either key
without a planned transition likewise strands those installs; recovery requires
a manually installed bootstrap release carrying a new public key. Rotation must
therefore be validated across releases before retiring the old key.

The first updater-enabled stable release is only a bootstrap: older builds do
not contain Sparkle and cannot exercise an update into it. Issue #17 remains
open until the following stable release passes a real notarized N-to-N+1 smoke
test. That smoke must cover discovery, the gentle reminder, explicit install,
quit cancellation for at-risk terminal work through the existing
`AppDelegate.applicationShouldTerminate` sheet, successful relaunch, preserved
sessions, and a Homebrew Cask install that remains self-updating.

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
