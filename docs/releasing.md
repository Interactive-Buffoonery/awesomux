# awesoMux release checklist

This document sketches the release process awesoMux needs as part of open
sourcing. Release work should happen in this priority order:

1. Public GitHub Releases with signed, notarized downloadable artifacts.
2. Homebrew cask distribution of the public GitHub Release artifact.
3. Later, we may look at a TestFlight release path for beta testers through
   App Store Connect.

ADR-0019 is the source of truth for macOS distribution, signing, Hardened
Runtime, notarization, and App Sandbox posture. This file is the implementation
checklist. If the policy and this checklist disagree, update this checklist to
match the ADR.

The GitHub Releases path is the primary public distribution path. Homebrew
should consume the GitHub Release artifact rather than build or upload a
separate artifact. TestFlight is not a launch blocker for open sourcing; treat
it as a later App Store Connect-compatible beta path until a sandbox
compatibility spike proves otherwise.

## Current constraints

- awesoMux is a macOS 15+ SwiftPM app with no checked-in Xcode project.
- `Package.swift` remains the canonical build graph.
- `script/build_and_run.sh` stages `dist/awesoMux.app`, copies Ghostty
  resources, and ad-hoc signs for local development only.
- GitHub/Homebrew release builds need real signing, version metadata,
  packaging, notarization, and clean install smoke tests.
- Release signing and entitlement policy is governed by
  [ADR-0019](adr/0019-macos-distribution-signing-and-sandbox-posture.md):
  Developer ID Application signing, Hardened Runtime, notarization, stapling,
  no App Sandbox for direct releases, and no hardened-runtime exception
  entitlements unless a concrete signed-release failure proves they are needed.
- A later TestFlight path needs App Store Connect upload, provisioning, and beta
  review setup.
- `vendor/ghostty` stays a submodule. Do not copy `vendor/ghostty` contents into
  a release commit.
- `vendor/zmx` stays a submodule too. The app bundles the Zig-built `amx`
  persistent-session binary from it (ADR 0011), produced by
  `script/build_amx.sh`, so release builds must build, stage, and sign `amx`
  alongside the app and `awesoMuxAgentHook`.

## Release lanes

| Lane | Audience | Artifact | Signing | Distribution |
| --- | --- | --- | --- | --- |
| GitHub Release | Public stable and public prerelease users | `.dmg` or `.zip` plus checksum | Developer ID Application, hardened runtime, notarized and stapled | GitHub Releases |
| Homebrew cask | Users who install apps from the terminal | Same public GitHub Release `.dmg` or `.zip` | Same Developer ID signed/notarized artifact | org tap first; optional `Homebrew/homebrew-cask` later |
| TestFlight | Internal and external beta testers | App Store Connect macOS build | App Store distribution signing and provisioning profile | TestFlight |

## Common setup checklist

- [ ] Confirm Apple Developer Program team access for release owners.
- [ ] Decide release owner and backup owner.
- [ ] Decide the public release cadence: ad hoc, milestone-based, or calendar.
- [ ] Decide versioning policy:
  - [ ] `CFBundleShortVersionString` uses SemVer, for example `0.1.0`.
  - [ ] `CFBundleVersion` is monotonic per App Store Connect requirements,
        for example a timestamp or CI run number.
  - [ ] Git tags use `vX.Y.Z`, for example `v0.1.0`.
  - [ ] Release candidates use GitHub prereleases, for example `v0.1.0-rc.1`.
- [ ] Add release metadata support to the staged `Info.plist`:
  - [ ] `CFBundleShortVersionString`
  - [ ] `CFBundleVersion`
  - [ ] optional channel/build metadata visible in About UI later
- [ ] Decide bundle IDs:
  - [ ] Public GitHub release bundle ID.
  - [ ] Whether Homebrew installs the same bundle ID as manual GitHub downloads.
- [ ] Decide Homebrew distribution policy:
  - [ ] Start with an org-owned tap, for example
        `Interactive-Buffoonery/homebrew-tap`.
  - [ ] Use `awesomux` as the stable cask token unless it conflicts.
  - [ ] Add `awesomux@beta` only if beta Homebrew installs are useful.
  - [ ] Submit to `Homebrew/homebrew-cask` later only after stable public
        releases have enough public usage and the cask passes audit.
- [ ] Create required certificates and credentials:
  - [ ] Developer ID Application certificate for GitHub releases.
  - [ ] Notary credentials for `xcrun notarytool`.
- [ ] Decide where secrets live:
  - [ ] GitHub Actions environment secrets for automated GitHub releases.
  - [ ] Local maintainer keychain for manual first releases.
- [ ] Protect release workflows so signing secrets only run on trusted refs.
- [ ] Add release notes/changelog convention.
- [ ] Add a rollback policy for bad releases.

## Pre-release freeze checklist

- [ ] Confirm the release branch is based on the intended public branch.
- [ ] Confirm the worktree is clean.
- [ ] Confirm submodules are initialized and at the intended pins.
- [ ] Confirm no release-blocking GitHub issues remain.
- [ ] Confirm bundled license and notice material is current:
  - [ ] Ghostty
  - [ ] zmx (bundled `amx` binary; upstream `neurosnap/zmx`, MIT)
  - [ ] Hack Nerd Font
  - [ ] swift-toml
  - [ ] swift-markdown (Apache-2.0 — include its NOTICE)
  - [ ] swift-cmark (transitive via swift-markdown)
- [ ] Run local verification:
  - [ ] `./script/swift-test.sh`
  - [ ] `./script/preflight.sh`
  - [ ] `./script/build_and_run.sh --verify`
- [ ] Run manual smoke in the app:
  - [ ] fresh launch
  - [ ] create session
  - [ ] split pane
  - [ ] close pane/session
  - [ ] quit/relaunch restore
  - [ ] `amx` persistent-session reattach across relaunch, when enabled
  - [ ] notification permission behavior
  - [ ] agent hook event file behavior
  - [ ] bundled Ghostty resources and fonts load
- [ ] Draft release notes:
  - [ ] highlights
  - [ ] fixes
  - [ ] known issues
  - [ ] upgrade notes
  - [ ] verification summary

## GitHub Releases path

Goal: publish a public artifact that macOS opens without unidentified-developer
warnings and that users can verify.

### One-time implementation checklist

Developer ID signing and notarization implementation is tracked by
the GitHub issue tracking Developer ID signing for distribution.
Keep release policy in ADR-0019 and use this section as the build checklist.

- [x] Add a dedicated release build script: script/build_release.sh
- [x] Keep `script/build_and_run.sh` local-dev focused; do not overload it with
      release signing. (the release path only adds `--stage-release`, which stops before launch; release signing lives in `script/build_release.sh`)
- [x] Teach the release script to accept:
  - [x] version
  - [x] build number (default: `git rev-list --count HEAD`)
  - [x] signing identity
  - [x] output directory
  - [x] notarization keychain profile (`--notary-profile`)
- [ ] Build from a clean checkout:
  - [ ] `git submodule update --init --recursive`
  - [ ] `./script/ensure_ghostty_artifacts.sh`
  - [ ] `./script/build_amx.sh`
  - [ ] `swift build -c release`
- [ ] Stage `awesoMux.app` exactly like the local script does:
  - [ ] app executable
  - [ ] `awesoMuxAgentHook`
  - [ ] `amx` session-backend binary
  - [ ] Ghostty `share` resources
  - [ ] agent integrations
  - [ ] app icon
  - [ ] bundled fonts
  - [ ] license resources
- [ ] Sign with Developer ID Application:
  - [ ] app binary
  - [ ] bundled helper executables (`awesoMuxAgentHook`, `amx`)
  - [ ] nested code, if any
  - [ ] final app bundle with hardened runtime
  - [ ] entitlements match ADR-0019
- [ ] Verify signing:
  - [ ] `codesign --verify --deep --strict --verbose=2 dist/awesoMux.app`
  - [ ] inspect entitlements
- [ ] Package the app:
  - [ ] choose `.dmg` or `.zip` for the initial release
  - [ ] preserve the signed bundle exactly
  - [ ] remove `com.apple.quarantine` from release inputs
- [ ] Notarize packaged artifact with `xcrun notarytool`.
- [ ] Staple the notarization ticket.
- [ ] Verify Gatekeeper assessment:
  - [ ] `spctl --assess --type execute --verbose dist/awesoMux.app`
  - [ ] `stapler validate <artifact>`
- [ ] Generate checksums:
  - [ ] SHA-256 for every downloadable artifact
  - [ ] optional signed checksum file later
- [ ] Add a tag-triggered GitHub Actions workflow:
  - [ ] only runs on protected `v*` tags or manual maintainer dispatch
  - [ ] checks out submodules
  - [ ] imports signing cert into a temporary keychain
  - [ ] builds and signs
  - [ ] notarizes and staples
  - [ ] uploads artifacts/checksums to a draft GitHub Release
  - [ ] never runs signing steps for `pull_request` from forks
- [x] Add an unsigned local dry-run mode (`--unsigned`; needs full Xcode + Zig, but no signing credentials)
- [ ] Document maintainer-only release prerequisites.

### Per-release checklist

- [ ] Create release branch or use the protected release commit.
- [ ] Confirm version and build number.
- [ ] Run pre-release freeze checklist.
- [ ] Create annotated tag, for example:
  - [ ] `git tag -a v0.1.0 -m "v0.1.0"`
  - [ ] `git push origin v0.1.0`
- [ ] Wait for release workflow to produce draft GitHub Release.
- [ ] Download the draft artifact on a clean Mac.
- [ ] Install/open from the downloaded artifact.
- [ ] Confirm Gatekeeper accepts the app.
- [ ] Confirm the app shows the expected version/build.
- [ ] Confirm session smoke still works from the installed app.
- [ ] Review generated checksums.
- [ ] Review release notes.
- [ ] Publish GitHub Release.
- [ ] Announce release in the chosen channels.
- [ ] Watch early feedback/crashes/issues.
- [ ] If broken:
  - [ ] mark the release as withdrawn or prerelease as appropriate
  - [ ] publish a known issue
  - [ ] cut a patch tag

## Homebrew cask path

Goal: let users install the public release with:

```sh
brew tap interactive-buffoonery/tap
brew install --cask awesomux
```

Longer term, if the project meets Homebrew's public acceptance expectations, the
same cask can be submitted to `Homebrew/homebrew-cask` so users can run:

```sh
brew install --cask awesomux
```

Use a cask, not a formula. awesoMux ships a native `.app` bundle and bundled
helper executables; Homebrew formulae are for source-built packages, while casks
install precompiled, upstream-signed app artifacts.

Homebrew is blocked on the signed, notarized, stapled GitHub Release artifact
from the GitHub Releases path. When release Phase 6 starts, split a dedicated
GitHub issue for the Homebrew cask rather than keeping cask implementation work
only inside the general release plan.

### One-time implementation checklist

- [ ] Create the org tap repository:
  - [ ] repository name: `Interactive-Buffoonery/homebrew-tap`
  - [ ] user-facing tap name: `interactive-buffoonery/tap`
  - [ ] public visibility once the main repo is public
- [ ] Generate the tap structure:
  - [ ] `brew tap-new interactive-buffoonery/homebrew-tap`
  - [ ] push the generated tap to GitHub
- [ ] Add `Casks/a/awesomux.rb`.
- [ ] Prefer generating the initial cask from the release URL:
      `brew create --cask <release-url> --tap interactive-buffoonery/homebrew-tap --set-name awesomux`
- [ ] Point the cask at the GitHub Release artifact, not at CI artifacts,
      TestFlight builds, or unversioned downloads.
- [ ] Keep the cask URL filename stable and versioned, for example:
      `awesoMux-0.1.0.dmg`.
- [ ] Confirm the GitHub artifact is Developer ID signed, notarized, stapled,
      and Gatekeeper-accepted before updating the cask.
- [ ] Confirm the release artifact SHA-256 matches the cask `sha256`.
- [ ] Add a `livecheck` block that tracks stable GitHub releases.
- [ ] Add macOS and architecture requirements:
  - [ ] `depends_on macos: ">= :sequoia"` for macOS 15+
  - [ ] `depends_on arch: :arm64` while the app is Apple Silicon-only
- [ ] Decide whether to include `zap` paths for user data:
  - [ ] session restore JSON
  - [ ] preferences
  - [ ] saved application state
  - [ ] agent runtime event files, if stored outside the session state path
- [ ] Test local cask install and uninstall:
  - [ ] `HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_FROM_API=1 brew install --cask awesomux`
  - [ ] launch installed app from `/Applications`
  - [ ] `brew uninstall --cask awesomux`
  - [ ] optional `brew zap --cask awesomux`
- [ ] Run cask hygiene checks:
  - [ ] `HOMEBREW_NO_INSTALL_FROM_API=1 brew audit --cask --new awesomux`
  - [ ] `brew style --fix awesomux`
- [ ] Decide update automation:
  - [ ] manually update the tap for the first release
  - [ ] later, have the GitHub release workflow open or push a tap PR
  - [ ] if accepted upstream, use Homebrew's current bump command, for example
        `brew bump --open-pr --version <version> awesomux`

### Draft cask shape

```ruby
cask "awesomux" do
  version "0.1.0"
  sha256 "<sha256-of-release-artifact>"

  url "https://github.com/Interactive-Buffoonery/awesomux/releases/download/v#{version}/awesoMux-#{version}.dmg",
      verified: "github.com/Interactive-Buffoonery/awesomux/"
  name "awesoMux"
  desc "Native macOS terminal built on libghostty with agent-aware sessions"
  homepage "https://github.com/Interactive-Buffoonery/awesomux"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sequoia"
  depends_on arch: :arm64

  app "awesoMux.app"

  # Decide exact zap paths after confirming runtime storage locations.
  zap trash: [
    "~/Library/Application Support/awesoMux",
    "~/Library/Preferences/com.interactivebuffoonery.awesomux.plist",
    "~/Library/Saved Application State/com.interactivebuffoonery.awesomux.savedState",
  ]
end
```

### Per-Homebrew-release checklist

- [ ] Publish or draft the GitHub Release artifact first.
- [ ] Download the exact artifact URL that the cask will use.
- [ ] Compute SHA-256:
  - [ ] `shasum -a 256 awesoMux-<version>.dmg`
- [ ] Update the cask:
  - [ ] `version`
  - [ ] `sha256`
  - [ ] `url` if the artifact naming changed
  - [ ] `depends_on` if macOS/architecture support changed
- [ ] Install from the local tap:
  - [ ] `brew install --cask awesomux`
- [ ] Confirm install location and launch behavior:
  - [ ] `/Applications/awesoMux.app` exists
  - [ ] app launches from Finder/open
  - [ ] app shows the expected version/build
  - [ ] app can create a terminal session
- [ ] Confirm upgrade behavior from the previous cask version.
- [ ] Confirm uninstall leaves expected user data in place.
- [ ] Confirm `brew zap --cask awesomux` removes only intended user data.
- [ ] Run `brew audit --cask awesomux`.
- [ ] Run `brew style awesomux`.
- [ ] Merge/push the tap update.
- [ ] Add Homebrew install instructions to the GitHub Release notes:

```sh
brew tap interactive-buffoonery/tap
brew install --cask awesomux
```

### Official Homebrew cask checklist

- [ ] Wait until awesoMux has a stable public release, public homepage, and
      enough public usage to satisfy Homebrew review.
- [ ] Confirm the app runs with Gatekeeper enabled on Homebrew-supported macOS
      versions and platforms.
- [ ] Confirm the app is not a beta-only, nightly-only, vendorless, or
      login-walled download.
- [ ] Confirm the release artifact is built and signed by the awesoMux project.
- [ ] Confirm the cask is not just a discoverability mechanism; users can verify
      the app from the homepage/repo/release page.
- [ ] Check for existing open or closed Homebrew cask PRs for `awesomux`.
- [ ] Submit the cask to `Homebrew/homebrew-cask`.
- [ ] For later updates, use:

```sh
brew bump --open-pr --version <version> awesomux
```

## TestFlight path

Goal: upload beta builds to App Store Connect so testers can install through
TestFlight and send feedback.

Treat this as a separate compatibility lane. TestFlight uses App Store Connect,
so the app must satisfy App Store Connect upload, signing, profile, metadata,
and beta review constraints.

### One-time feasibility checklist

- [ ] Decide TestFlight bundle ID:
  - [ ] same as public GitHub app if TestFlight is a pre-release of the same
        installed app
  - [ ] separate `.beta` bundle ID if TestFlight should install side-by-side
        with GitHub releases
- [ ] Decide displayed app name:
  - [ ] `awesoMux`
  - [ ] `awesoMux Beta`
- [ ] Create App Store Connect app record.
- [ ] Create App ID and provisioning profile.
- [ ] Create App Store distribution certificate/identity.
- [ ] Create App Store Connect API key or other upload credentials.
- [ ] Decide whether TestFlight is only beta for GitHub releases or a future Mac
      App Store submission path.
- [ ] Decide whether TestFlight can install side-by-side with GitHub builds.
- [ ] Determine required entitlements:
  - [ ] app sandbox
  - [ ] file access
  - [ ] outgoing network, if needed
  - [ ] notification behavior
  - [ ] helper executable inheritance, if needed
  - [ ] temporary exceptions, if any
- [ ] Run a sandbox compatibility spike:
  - [ ] login shell starts
  - [ ] user shell config loads as expected
  - [ ] cwd inheritance works
  - [ ] Terminal panes can read/write expected user paths
  - [ ] Ghostty resources load from the bundle
  - [ ] `awesoMuxAgentHook` can write runtime event JSONL
  - [ ] Claude Code/Codex integration can function under the sandbox
  - [ ] notifications register
  - [ ] session persistence works
- [ ] Decide whether sandbox limitations are acceptable for TestFlight.
- [ ] If command-line upload is not accepted, decide whether to add a thin Xcode
      wrapper while keeping SwiftPM as the source of truth.
- [ ] Confirm the upload path:
  - [ ] Xcode Organizer
  - [ ] Transporter app
  - [ ] Transporter command line with App Store Connect API key
  - [ ] `xcrun altool` only if still acceptable for build upload
- [ ] Add TestFlight packaging script, for example
      `script/build_testflight.sh`.
- [ ] Teach the script to:
  - [ ] set version/build
  - [ ] use App Store signing identity
  - [ ] embed provisioning profile
  - [ ] sign app and helper with the correct entitlements
  - [ ] package for App Store Connect upload
  - [ ] strip/check `com.apple.quarantine`
  - [ ] validate before upload
- [ ] Add App Store Connect metadata:
  - [ ] beta app description
  - [ ] feedback email
  - [ ] contact information
  - [ ] export compliance answers
  - [ ] privacy/app data answers
  - [ ] screenshots if external beta review needs them
- [ ] Create tester groups:
  - [ ] internal maintainers
  - [ ] trusted external beta testers
  - [ ] optional public-link external group
- [ ] Decide external tester limit for public links.
- [ ] Decide how TestFlight feedback becomes GitHub issues.

### Per-TestFlight-build checklist

- [ ] Confirm target version and monotonic build number.
- [ ] Run pre-release freeze checklist or scoped beta verification.
- [ ] Build and sign TestFlight package.
- [ ] Validate the package locally.
- [ ] Upload to App Store Connect.
- [ ] Wait for processing.
- [ ] Confirm the build appears under the correct macOS version/build.
- [ ] Add the build to internal testing.
- [ ] Fill in "What to Test".
- [ ] Install from TestFlight internally.
- [ ] Smoke test the installed TestFlight build:
  - [ ] launch
  - [ ] terminal spawn
  - [ ] session restore
  - [ ] agent hook behavior
  - [ ] notification permission behavior
  - [ ] expected sandbox limitations
- [ ] For external testing:
  - [ ] add build to external group
  - [ ] fill in beta review notes
  - [ ] submit for beta review when required
  - [ ] wait for approval
  - [ ] notify testers or enable automatic notification
- [ ] Monitor TestFlight:
  - [ ] crash reports
  - [ ] feedback submissions
  - [ ] sessions/installs
  - [ ] build expiration date
- [ ] Expire old builds when they should no longer be tested.

## Automation plan

Break this into small PRs. The first automation step should be a GitHub Actions
workflow file that creates the release shape without taking on every signing and
distribution concern at once.

### Phase 1: GitHub release workflow skeleton

- [ ] Add `.github/workflows/release-github.yml`.
- [ ] Trigger only from trusted refs:
  - [ ] `workflow_dispatch`
  - [ ] protected `v*` tags once the dry run is proven
- [ ] Start with least-privilege permissions, for example `contents: read`.
- [ ] Check out submodules.
- [ ] Run release-adjacent validation first:
  - [ ] `./script/swift-test.sh`
  - [ ] `./script/build_and_run.sh --verify`
- [ ] Produce an unsigned or ad-hoc-signed dry-run artifact initially.
- [ ] Upload the artifact and checksum as workflow artifacts.
- [ ] Do not import signing certificates yet.
- [ ] Do not publish a GitHub Release yet.
- [ ] Document the exact artifact naming convention the later cask will consume.

### Phase 2: Release metadata and local signing

- [ ] Add release metadata support.
- [ ] Add Developer ID signing/notarization script for local maintainer runs.
- [ ] Add checksum generation and local Gatekeeper verification.
- [ ] Run the first real GitHub release locally.
- [ ] Document command outputs and failure modes.

### Phase 3: Protected signed GitHub release workflow

- [ ] Add GitHub Environment protection for release jobs.
- [ ] Store certs and notary credentials in release-only secrets.
- [ ] Import signing certs into a temporary keychain.
- [ ] Build, sign, package, notarize, staple, and verify.
- [ ] Raise workflow permissions to `contents: write` only when creating a
      draft GitHub Release.
- [ ] Create draft GitHub Releases only.
- [ ] Keep publication manual.
- [ ] Ensure every public artifact is built from the tagged commit.

### Phase 4: Homebrew tap workflow

- [ ] Add or update the org tap repository.
- [ ] Decide whether the main release workflow opens a tap PR or pushes a tap
      commit directly after the GitHub Release is published.
- [ ] Update cask version, URL, and SHA-256 from the published artifact.
- [ ] Run cask install/uninstall/audit checks in CI where possible.
- [ ] Keep official `Homebrew/homebrew-cask` updates manual until the project is
      accepted there and the bump process is boring.

### Later: TestFlight workflow

- [ ] Decide whether TestFlight upload should stay local or move to CI.
- [ ] If moved to CI, gate it behind `workflow_dispatch` and a protected
      environment.
- [ ] Store App Store Connect API credentials in release-only secrets.
- [ ] Upload only from trusted branches/tags.
- [ ] Never run TestFlight signing/upload on external PR code.

## Security checklist

- [ ] Signing secrets never run on `pull_request` from forks.
- [ ] Release workflows use protected environments.
- [ ] Release workflows check out trusted refs only.
- [ ] Any artifact uploaded to GitHub is built from the tagged commit.
- [ ] Generated artifacts include checksums.
- [ ] Release scripts do not read or print private signing credentials.
- [ ] Temporary keychains are deleted after CI signing.
- [ ] App Store Connect API keys are scoped as narrowly as practical.
- [ ] Homebrew cask updates point only to signed, notarized public release
      artifacts.
- [ ] Homebrew cask `sha256` matches the exact published artifact.
- [ ] Homebrew tap automation cannot be triggered from untrusted PR code.
- [ ] Notarization logs are reviewed when notarization fails.
- [ ] Public release notes avoid internal reviewer/persona names.

## Follow-up issue checklist

- [ ] Implement release metadata stamping.
- [ ] Create Developer ID release script.
- [ ] Create notarized GitHub release workflow.
- [ ] Add checksum generation and verification docs.
- [ ] Decide GitHub artifact format: `.dmg` vs `.zip`.
- [ ] Create a dedicated GitHub issue for the Homebrew cask when release Phase 6 starts.
- [ ] Create `Interactive-Buffoonery/homebrew-tap`.
- [ ] Add initial `awesomux` cask.
- [ ] Add Homebrew cask release/update workflow.
- [ ] Decide if/when to submit `awesomux` to `Homebrew/homebrew-cask`.
- [ ] Create TestFlight App Store Connect app record.
- [ ] Run TestFlight sandbox/signing feasibility spike.
- [ ] Create TestFlight packaging/upload script.
- [ ] Add TestFlight tester group and feedback routing docs.
- [ ] Decide whether a thin Xcode wrapper is needed for TestFlight.
- [ ] Add release notes template.
- [ ] Add rollback/withdrawal playbook.

## External references

- [Distributing software on macOS](https://developer.apple.com/macos/distribution/)
- [Signing Mac Software with Developer ID](https://developer.apple.com/developer-id/)
- [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Upload builds to App Store Connect](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/)
- [TestFlight overview](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/)
- [Invite external testers](https://developer.apple.com/help/app-store-connect/test-a-beta-version/invite-external-testers/)
- [Upcoming requirements](https://developer.apple.com/news/upcoming-requirements/)
- [Homebrew: How to Create and Maintain a Tap](https://docs.brew.sh/How-to-Create-and-Maintain-a-Tap)
- [Homebrew: Cask Cookbook](https://docs.brew.sh/Cask-Cookbook)
- [Homebrew: Adding Software to Homebrew](https://docs.brew.sh/Adding-Software-to-Homebrew)
- [Homebrew: Acceptable Casks](https://docs.brew.sh/Acceptable-Casks)
- [Homebrew: How to Open a Pull Request](https://docs.brew.sh/How-To-Open-a-Homebrew-Pull-Request)
