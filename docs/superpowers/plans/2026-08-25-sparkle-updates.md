# Sparkle Updates Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add signed, gentle, stable-channel Sparkle updates to the canonical awesoMux release artifact while keeping development, test, local-install, and nightly builds offline from the production feed and marking Homebrew installs as self-updating.

**Architecture:** Sparkle owns checking, presentation, download, installation, and scheduling. One app-owned controller gates initialization to configured production bundles and translates scheduled results into a small sidebar notice. The existing release workflow signs one existing notarized DMG into a stable-release appcast asset.

**Tech Stack:** Swift 6, SwiftUI/AppKit, Swift Package Manager, Sparkle 2.9.6, Bash, GitHub Actions, swift-testing

**Spec:** `docs/superpowers/specs/2026-08-25-sparkle-updates-design.md`

## Global Constraints

- macOS 15+ and the existing non-App-Sandbox distribution posture remain unchanged.
- Only updater-enabled stable release bundles, including the byte-identical Homebrew Cask install, may contact the production update feed; development, test, local-install, and nightly bundles may not.
- Homebrew keeps the same artifact and release-driven Cask update workflow; only its metadata changes to declare `auto_updates true`.
- The canonical archive remains the existing notarized and stapled DMG used by GitHub, Homebrew, and Sparkle.
- `SURequireSignedFeed` and `SUVerifyUpdateBeforeExtraction` are mandatory; system profiling and automatic installation are disabled.
- Scheduled checks use Sparkle's scheduler and gentle-reminder delegate; do not add a timer, channel abstraction, updater protocol, or new preference.
- Sparkle-triggered relaunch must use the existing `applicationShouldTerminate` policy.
- New behavior starts with a failing focused test and ends with the smallest passing change.

---

### Task 1: Add and stage Sparkle

**Files:**
- Modify: `Package.swift`
- Modify: `Package.resolved`
- Modify: `script/build_and_run.sh`
- Modify: `Tests/awesoMuxTests/BuildAndRunScriptTests.swift`
- Modify: `Tests/awesoMuxTests/BuildScriptHelpTests.swift`
- Modify: `Resources/Licenses/README.md`
- Create: `Resources/Licenses/Sparkle/LICENSE`
- Modify: `Resources/THIRD_PARTY_NOTICES.md`
- Modify: `Sources/awesoMux/Views/About/AboutWindowView.swift`
- Modify: `Tests/awesoMuxTests/AboutWindowInfoTests.swift`

**Interfaces:**
- Produces: SwiftPM product `Sparkle` linked only by target `awesoMux`; staged path `dist/awesoMux.app/Contents/Frameworks/Sparkle.framework`.
- Produces: build environment inputs `AWESOMUX_SPARKLE_ENABLED=1` and `SPARKLE_PUBLIC_ED_KEY` that conditionally stamp production updater keys.

- [ ] **Step 1: Add failing source-contract tests**

  Assert that the app target depends on Sparkle 2.9.6, the staging script copies `Sparkle.framework`, removes its `XPCServices` symlink and versioned directory, writes all eight required plist policy keys only under `AWESOMUX_SPARKLE_ENABLED`, and rejects an enabled build with an empty public key. Assert the ordinary help/build path still works without either variable.

- [ ] **Step 2: Run the focused tests and confirm the new assertions fail**

  Run: `./script/swift-test.sh --filter 'BuildAndRunScriptTests|BuildScriptHelpTests|AboutWindowInfoTests'`

- [ ] **Step 3: Add the package and minimum staging logic**

  Add `.package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.6")` and `.product(name: "Sparkle", package: "Sparkle")`. Resolve the package. Copy the binary framework beside the other staged runtime dependencies, trim unused XPC services for the non-sandboxed app, set `@executable_path/../Frameworks` through the existing link/stage mechanism, and stamp these values only for an explicitly enabled build:

  ```text
  SUFeedURL=https://github.com/Interactive-Buffoonery/awesomux/releases/latest/download/appcast.xml
  SUPublicEDKey=<SPARKLE_PUBLIC_ED_KEY>
  SUEnableAutomaticChecks=true
  SUAutomaticallyUpdate=false
  SUAllowsAutomaticUpdates=false
  SUEnableSystemProfiling=false
  SUVerifyUpdateBeforeExtraction=true
  SURequireSignedFeed=true
  ```

  Preserve the existing local ad-hoc signing command. Change it only if the staged launch in Step 5 demonstrates an actual Sparkle loading failure, and then cover the narrow adjustment with a regression test.

- [ ] **Step 4: Add dependency attribution**

  Copy Sparkle's upstream license verbatim into `Resources/Licenses/Sparkle/LICENSE`, add Sparkle to the license manifest/About credits and third-party notices, and keep `required_license_files` as the single bundle manifest.

- [ ] **Step 5: Run focused tests and inspect a staged bundle**

  Run the focused test command again, then `./script/build_and_run.sh --stage-release`. Confirm `otool -L dist/awesoMux.app/Contents/MacOS/awesoMux` resolves Sparkle through `@rpath`, the framework exists without XPC services, and `plutil -p dist/awesoMux.app/Contents/Info.plist` has no `SUFeedURL` or `SUPublicEDKey` by default.

- [ ] **Step 6: Commit**

  ```bash
  git add Package.swift Package.resolved script/build_and_run.sh Tests/awesoMuxTests/BuildAndRunScriptTests.swift Tests/awesoMuxTests/BuildScriptHelpTests.swift Resources/Licenses Resources/THIRD_PARTY_NOTICES.md Sources/awesoMux/Views/About/AboutWindowView.swift Tests/awesoMuxTests/AboutWindowInfoTests.swift
  git commit -m "build(updates): stage Sparkle in macOS bundles"
  ```

### Task 2: Add the production-gated updater and commands

**Files:**
- Create: `Sources/awesoMux/Services/UpdateController.swift`
- Create: `Tests/awesoMuxTests/UpdateControllerTests.swift`
- Modify: `Sources/awesoMux/App/AwesoMuxApp.swift`

**Interfaces:**
- Produces: `@MainActor @Observable final class UpdateController` with `isEnabled: Bool`, `availableVersion: String?`, `canCheckForUpdates: Bool`, `checkForUpdates()`, and `skipAvailableUpdate()`; the test initializer accepts one optional `checkForUpdatesAction: (() -> Void)?` spy closure instead of an updater protocol.
- Consumes: `AppRuntimeProfile` and the bundle's `SUFeedURL`/`SUPublicEDKey` values.

- [ ] **Step 1: Write failing controller tests**

  Cover development/test/unknown profiles, a production bundle missing either required key, a fully configured production bundle, scheduled update receipt, clearing at session finish, skip-for-now, and explicit check forwarding. Inject one optional `checkForUpdatesAction` closure for the forwarding assertion; production uses a closure that calls Sparkle. Do not create an updater protocol or construct a network-capable updater in tests.

- [ ] **Step 2: Run the controller tests and confirm they fail**

  Run: `./script/swift-test.sh --filter UpdateControllerTests`

- [ ] **Step 3: Implement the controller and Sparkle delegate**

  Construct `SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)` only after the two-part gate passes. Return `true` from `supportsGentleScheduledUpdateReminders`; return `false` from `standardUserDriverShouldHandleShowingScheduledUpdate`; record `update.displayVersionString` when Sparkle delegates scheduled presentation; clear state when the update session finishes. Forward explicit checks to `checkForUpdates(nil)`.

- [ ] **Step 4: Add the app command**

  Own one controller in `AwesoMuxApp`, add `CommandGroup(after: .appInfo)` with localized literal-key **Check for Updates…**, forward to the controller, and disable it unless Sparkle reports it can check. Do not add a parallel keyboard shortcut catalog entry.

- [ ] **Step 5: Run focused tests and format only touched Swift files**

  Run: `./script/swift-test.sh --filter 'UpdateControllerTests|AppRuntimeProfileTests'` and `./script/format.sh Sources/awesoMux/Services/UpdateController.swift Sources/awesoMux/App/AwesoMuxApp.swift Tests/awesoMuxTests/UpdateControllerTests.swift`.

- [ ] **Step 6: Commit**

  ```bash
  git add Sources/awesoMux/Services/UpdateController.swift Sources/awesoMux/App/AwesoMuxApp.swift Tests/awesoMuxTests/UpdateControllerTests.swift
  git commit -m "feat(updates): add production Sparkle controller"
  ```

### Task 3: Surface the unobtrusive update indicator

**Files:**
- Create: `Sources/awesoMux/Views/UpdateAvailableIndicator.swift`
- Create: `Tests/awesoMuxTests/UpdateAvailableIndicatorTests.swift`
- Modify: `Sources/awesoMux/Views/ContentView.swift`
- Modify: `Sources/awesoMux/Views/SidebarView.swift`

**Interfaces:**
- Consumes: the Task 2 `UpdateController` instance.
- Produces: one subtle **Update Available** indicator in expanded and collapsed sidebars; activating it exposes the update path and **Skip for Now** without an automatic window.

- [ ] **Step 1: Write failing indicator tests**

  Verify no view when `availableVersion` is nil; one readable, subtle indicator when available; a usable collapsed-rail form; no always-visible skip control; activation exposes both the standard update path and **Skip for Now**; both choices' callbacks; and accessibility labels containing the available version.

- [ ] **Step 2: Run the focused tests and confirm failure**

  Run: `./script/swift-test.sh --filter UpdateAvailableIndicatorTests`

- [ ] **Step 3: Implement and route the indicator**

  Read the controller from SwiftUI's typed environment. Re-inject it beside `AppSettingsStore` where `ContentView` creates the AppKit-hosted sidebar. Render `UpdateAvailableIndicator` above `SidebarActivitySection`, outside that section's `.equatable()` boundary. Use a single pill-style control with existing design tokens, literal-key localization, minimum target sizes, and VoiceOver labels. Activation reveals a compact native choice UI; **Update…** calls `checkForUpdates()` and **Skip for Now** calls `skipAvailableUpdate()`. Do not show a second permanent button or copy Rogue Amoeba's proprietary visuals/code.

- [ ] **Step 4: Run focused tests and format touched files**

  Run the Step 2 command, then format only the five changed/created Swift source and test files.

- [ ] **Step 5: Commit**

  ```bash
  git add Sources/awesoMux/Views/ContentView.swift Sources/awesoMux/Views/SidebarView.swift Sources/awesoMux/Views/UpdateAvailableIndicator.swift Tests/awesoMuxTests/UpdateAvailableIndicatorTests.swift
  git commit -m "feat(updates): show gentle update reminder"
  ```

### Task 4: Sign and publish the stable appcast

**Files:**
- Modify: `script/build_release.sh`
- Modify: `script/update_homebrew_cask.sh`
- Modify: `.github/workflows/release.yml`
- Modify: `.github/scripts/test/release-workflow.test.mjs`
- Modify: `.github/scripts/test/update-homebrew-cask.test.mjs`
- Modify: `Tests/awesoMuxTests/BuildScriptHelpTests.swift`
- Modify: `docs/adr/0019-macos-distribution-signing-and-sandbox-posture.md`
- Modify: `docs/releasing.md`

**Interfaces:**
- Produces: `script/build_release.sh --enable-sparkle`, requiring `SPARKLE_PUBLIC_ED_KEY` and forwarding release-only staging configuration.
- Consumes: GitHub environment variable `SPARKLE_PUBLIC_ED_KEY` and secret `SPARKLE_PRIVATE_ED_KEY`.
- Produces: stable draft asset `appcast.xml`; nightly artifacts remain unchanged.

- [ ] **Step 1: Add failing build/workflow contract tests**

  Assert that enabled release builds reject a missing public key, sign `Autoupdate`, `Updater.app`, and `Sparkle.framework` inside-out with Hardened Runtime before the app, include them in the ADR-0019 empty-entitlements checks, and do not use `codesign --deep` for signing. Extend the existing release workflow test to assert that the shared build step passes `--enable-sparkle` and exposes the public key only when `github.event_name != 'schedule'`; stable release validates both keys, invokes `.build/artifacts/sparkle/Sparkle/bin/generate_appcast` with `--maximum-deltas 0`, reads the private key through `--ed-key-file -`, produces the versioned DMG enclosure URL, uploads `appcast.xml` before draft creation/publish, and never adds it to nightly. Extend the Cask helper test to require `auto_updates true` exactly once.

- [ ] **Step 2: Run the focused tests and confirm failure**

  Run: `./script/swift-test.sh --filter BuildScriptHelpTests && node --test .github/scripts/test/release-workflow.test.mjs .github/scripts/test/update-homebrew-cask.test.mjs`

- [ ] **Step 3: Add release build configuration and signing**

  Parse `--enable-sparkle`; require the public key only in that mode; export the exact `AWESOMUX_SPARKLE_ENABLED=1` and `SPARKLE_PUBLIC_ED_KEY` inputs from Task 1 before staging. Sign Sparkle's `Autoupdate`, `Updater.app`, and framework in that order using Developer ID and Hardened Runtime; then sign the app. Extend verification and the ADR-0019 empty-entitlements loop to cover every nested executable and assert the absence of unused XPC services.

- [ ] **Step 4: Generate and attach the signed appcast**

  In the shared build step, conditionally pass `--enable-sparkle` and `SPARKLE_PUBLIC_ED_KEY` only when `github.event_name != 'schedule'`; scheduled nightlies must execute the unconfigured path. In stable publication only, require the private key, verify the resolved tool exists at `.build/artifacts/sparkle/Sparkle/bin/generate_appcast`, pipe the private key to it, disable deltas, set the versioned GitHub release download prefix, and upload `appcast.xml` with the existing DMG before the draft release is created. Preserve the current rule that compilation finishes before signing secrets are exposed.

- [ ] **Step 5: Document key custody and two-release smoke testing**

  Amend ADR-0019 and `docs/releasing.md` with the stable-only gate, exact secret/variable names, key rotation/loss implications, one-DMG feed contract, bootstrap limitation, and the required notarized N-to-N+1 manual validation. Explicitly state that the existing quit-risk sheet governs updater relaunch cancellation, the Cask must carry `auto_updates true`, and issue #17 stays open until the two-release smoke passes.

- [ ] **Step 6: Preserve Homebrew's self-update contract**

  Teach `script/update_homebrew_cask.sh` to add `auto_updates true` exactly once while updating the version/checksum. Add it to the documented Cask shape and verify a Cask-installed app can self-update without `brew upgrade` replacing it with an older stable artifact.

- [ ] **Step 7: Run focused checks and an unsigned configured package build**

  Run the Step 2 command. With a temporary fixture public key, run `./script/build_release.sh --version 0.0.0 --build-number 1 --unsigned --enable-sparkle`, inspect the staged plist/framework, then trash the generated artifacts through the repository's existing clean target or an explicit validated path.

- [ ] **Step 8: Commit**

  ```bash
  git add script/build_release.sh script/update_homebrew_cask.sh .github/workflows/release.yml .github/scripts/test/release-workflow.test.mjs .github/scripts/test/update-homebrew-cask.test.mjs Tests/awesoMuxTests/BuildScriptHelpTests.swift docs/adr/0019-macos-distribution-signing-and-sandbox-posture.md docs/releasing.md
  git commit -m "ci(updates): publish signed stable appcast"
  ```

### Task 5: Integrate and verify

**Files:**
- Modify only files required by failures found in this task.

**Interfaces:**
- Consumes: Tasks 1-4 as one stable update path.
- Produces: review-ready, verified branch with no production network activity from local/nightly builds.

- [ ] **Step 1: Run all tests and lint**

  Run `./script/test.sh all` and `./script/format.sh --lint`. Fix only regressions introduced by this branch and rerun the failing command.

- [ ] **Step 2: Run local UI smoke tests**

  Launch the checkout-scoped development app, verify its identity, and confirm no update command/banner or production feed access. Build a configured local fixture, inject scheduled-update state through the test seam, and verify expanded/collapsed notice layout, VoiceOver labels, Update action, and Skip for Now. Refresh accessibility element IDs after UI transitions.

- [ ] **Step 3: Verify the existing termination funnel**

  In the configured fixture, begin the update flow with at-risk terminal work, request relaunch, confirm the existing quit warning can cancel termination, and confirm no updater-specific code bypasses `applicationShouldTerminate`. Record this as fixture evidence only; issue #17 and any completion claim remain blocked until two notarized stable releases prove the real N-to-N+1 path.

- [ ] **Step 4: Run complete preflight**

  Run `./script/preflight.sh`. Save the fresh command/output evidence in `STATE.md` and the session rollup.

- [ ] **Step 5: Run required reviews before pushing**

  Run the repository's full multi-reviewer review, CodeRabbit CLI trace review, and Claude adversarial diff review in parallel where safe. Resolve every blocking finding, record judgment calls, rerun focused and full checks affected by fixes, and repeat reviews until clean.

- [ ] **Step 6: Commit review fixes**

  ```bash
  git add <only files changed by review fixes>
  git commit -m "fix(updates): address pre-merge review findings"
  ```

- [ ] **Step 7: Push and open the pull request after the required user input**

  Confirm eD's PR-template AI assistance level (`none`, `light`, `moderate`, or `substantial`), push `issue/17-sparkle-updates`, and open a PR that references—but does not close—issue #17 with neutral public review wording. Do not change the issue assignee or roadmap metadata.
