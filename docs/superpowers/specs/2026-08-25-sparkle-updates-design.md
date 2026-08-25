# Sparkle Updates Design

## Outcome

Stable release builds of awesoMux check for signed updates with Sparkle 2.9.6. A manual **Check for Updates…** command is always explicit. Scheduled checks use Sparkle's default daily scheduler and surface a quiet sidebar notice instead of interrupting launch or terminal work. Development, test, local-install, and nightly builds never start the production updater. Homebrew installs use the same self-updating stable artifact and declare that behavior in the Cask.

## Product behavior

- Stable direct-download builds enable scheduled checks by default without a second-launch permission dialog.
- Scheduled checks never show Sparkle's update window immediately. They set one subtle in-app **Update Available** indicator in the sidebar, matching Rogue Amoeba's public unobtrusive-notification behavior.
- Activating the indicator reveals the normal Sparkle update path and **Skip for Now**. Choosing the update path opens Sparkle's standard flow; the app-menu command remains a direct, explicit check.
- **Skip for Now** is not permanently visible beside the indicator and does not skip the release. It hides the visual only until Sparkle's next timed check, when the same available release may be surfaced again.
- Sparkle may download an update only as part of its normal user-facing flow. Silent automatic installation is disabled and not offered.
- Sparkle's normal relaunch request goes through `NSApplication` termination. The existing `AppDelegate.applicationShouldTerminate` quit-risk flow remains the sole authority for preserving or warning about terminal work.
- No beta/nightly channels, delta updates, system profiling, custom polling, update preferences, or unattended background installation are added.

## Runtime boundary

`UpdateController` is the single app-owned integration point. It creates `SPUStandardUpdaterController` only when both conditions hold:

1. `AppRuntimeProfile.current == .production`.
2. The bundle contains the stable release's `SUFeedURL` and `SUPublicEDKey` values.

That double gate prevents source builds, tests, `--install`, and nightly artifacts from contacting the stable feed even though they may use the production bundle identifier. The menu command is disabled when no updater exists.

The controller implements `SPUStandardUserDriverDelegate` directly. It opts into gentle scheduled reminders, declines Sparkle's scheduled presentation, records the available display version, clears the notice when the update session ends, and forwards explicit checks to Sparkle. It does not introduce a protocol or alternate update engine.

`UpdateAvailableIndicator` is a small pill-style SwiftUI control above the existing equatable activity section. Its compact choice UI exposes the update path and **Skip for Now** only after activation. The app injects the controller through SwiftUI's typed environment and re-injects it at the existing AppKit `NSHostingController` boundary, matching `AppSettingsStore`.

## Build and release boundary

- SwiftPM pins Sparkle from `2.9.6` and links its `Sparkle` product only to the macOS app target.
- `build_and_run.sh` copies `Sparkle.framework` into `Contents/Frameworks`, removes its unused XPC services for this non-sandboxed app, and stamps updater keys only when explicitly enabled by `build_release.sh`.
- The existing local ad-hoc signing posture stays unchanged unless a staged launch proves Sparkle requires a narrowly scoped adjustment. The Developer ID release path signs Sparkle inside-out before signing the app and must not use `codesign --deep` for signing.
- Stable release builds require a public EdDSA key. Nightly and ordinary local builds omit all production update keys.
- The non-nightly release workflow explicitly enables the update capability and generates a signed `appcast.xml` from the exact notarized/stapled DMG with `.build/artifacts/sparkle/Sparkle/bin/generate_appcast`, reading the private EdDSA key from standard input. It disables deltas.
- The stable appcast is uploaded to the draft GitHub release before publication. `SUFeedURL` uses `https://github.com/Interactive-Buffoonery/awesomux/releases/latest/download/appcast.xml`; the appcast enclosure points to the versioned release's existing DMG.
- Homebrew and Sparkle therefore install the same notarized DMG. The generated Cask includes `auto_updates true`, so Homebrew does not manage the app as if it were updater-free. Publishing the already-complete draft atomically moves GitHub's latest stable release redirect to its feed; prereleases do not replace that target.

## Security and privacy

Stable bundles set `SUVerifyUpdateBeforeExtraction`, `SURequireSignedFeed`, and `SUEnableAutomaticChecks` to true; `SUAutomaticallyUpdate`, `SUAllowsAutomaticUpdates`, and `SUEnableSystemProfiling` to false. The public key is embedded; the private key exists only as a GitHub environment secret and is piped to the signing tool, never placed in arguments, logs, or the repository.

The release verifier checks the framework and every nested executable's Developer ID signature, Hardened Runtime, notarization, and staple. The existing no-App-Sandbox posture remains unchanged.

## Release bootstrap and validation

The first updater-enabled stable release is a bootstrap release: it cannot prove an update from an older non-Sparkle build. Before publishing it, validate the signed feed, bundle configuration, archive signature, and an unsigned/local update fixture. Issue #17 remains open after the bootstrap implementation. The next stable release must perform a real notarized N-to-N+1 smoke test covering discovery, gentle notice, explicit install, quit cancellation with at-risk terminal work, successful relaunch, preserved sessions, and a Homebrew-Cask install that remains correctly marked self-updating.

Maintainer setup required before the first updater-enabled stable release:

- Generate the EdDSA key with Sparkle's `generate_keys`.
- Store the public key as the release environment variable `SPARKLE_PUBLIC_ED_KEY`.
- Store the private key as the release environment secret `SPARKLE_PRIVATE_ED_KEY`.

No key is generated or stored by this implementation.

## Documentation

Amend ADR-0019 and `docs/releasing.md` rather than adding a new ADR: Sparkle implements the distribution posture already decided there. Add Sparkle's license and attribution to the existing About/license manifests.

## Acceptance checks

- Unit tests cover the two-part runtime gate, gentle reminder state, skip behavior, and explicit check forwarding.
- Source-contract tests cover release-only plist keys, framework staging, inside-out signing and empty entitlements, an explicit non-nightly workflow gate, stable-only appcast generation, stdin key handling, no deltas, unchanged nightly behavior, and Homebrew `auto_updates true`.
- About/license tests cover the new dependency.
- A staged local bundle verifies the framework layout and absence of production feed keys by default.
- `./script/test.sh all` and `./script/preflight.sh` pass.
