import GhosttyKit
import Testing
@testable import awesoMux
import AwesoMuxConfig

@Suite("GhosttyConfigManager overlay failure resolution")
struct GhosttyConfigManagerOverlayTests {
    // A generated overlay can fail to apply two ways: the temp file won't write, or
    // libghostty rejects one of our keys (surfaced only as a diagnostic). Both route
    // through `overlayFailureResolution`, so these assertions pin the fail-closed
    // behavior for the security-relevant terminal/appearance overlays.

    @Test("best-effort defaults overlay tolerates failure and keeps building")
    func bestEffortTolerates() {
        #expect(GhosttyConfigManager.overlayFailureResolution(for: .logWarning) == .tolerate)
    }

    @Test("required overlay on init fails the runtime closed")
    func requiredInitFailsClosed() {
        #expect(GhosttyConfigManager.overlayFailureResolution(for: .failRuntime) == .abandonAndFail)
    }

    @Test("required overlay on live re-apply abandons without failing the runtime")
    func requiredReapplyAbandons() {
        #expect(GhosttyConfigManager.overlayFailureResolution(for: .ignore) == .abandon)
    }

    @Test("shell integration overlay preserves non-SSH features and disables SSH helpers")
    func shellIntegrationOverlayDisablesOnlySSHHelpers() {
        let allFeatures = GhosttyConfigManager.ShellIntegrationFeature.allCases.reduce(UInt32(0)) {
            $0 | $1.rawValue
        }

        #expect(GhosttyConfigManager.shellIntegrationConfigContents(
            disablingUnsupportedSSHHelpersFrom: allFeatures
        ) == """
        shell-integration-features = cursor,sudo,title,no-ssh-env,no-ssh-terminfo,path

        """)
    }

    @Test("shell integration overlay preserves disabled non-SSH features")
    func shellIntegrationOverlayPreservesDisabledNonSSHFeatures() {
        let titleOnlyWithSSHHelpers =
            GhosttyConfigManager.ShellIntegrationFeature.title.rawValue
            | GhosttyConfigManager.ShellIntegrationFeature.sshEnv.rawValue
            | GhosttyConfigManager.ShellIntegrationFeature.sshTerminfo.rawValue

        #expect(GhosttyConfigManager.shellIntegrationConfigContents(
            disablingUnsupportedSSHHelpersFrom: titleOnlyWithSSHHelpers
        ) == """
        shell-integration-features = no-cursor,no-sudo,title,no-ssh-env,no-ssh-terminfo,no-path

        """)
    }

    @MainActor
    @Test("shell integration feature bit mapping matches Ghostty")
    func shellIntegrationFeatureBitMappingMatchesGhostty() throws {
        GhosttyRuntime.initializeProcess()
        let manager = GhosttyConfigManager(
            clipboardWritePolicy: .ask,
            confirmClipboardRead: true,
            copyOnSelect: .inherit,
            terminalAppearance: .defaultValue
        )
        let config = try #require(ghostty_config_new())
        defer { ghostty_config_free(config) }

        #expect(manager.loadConfigContents(
            "shell-integration-features = cursor,sudo,title,ssh-env,ssh-terminfo,path\n",
            into: config,
            filePrefix: "test-shell-integration-features",
            failureMode: .failRuntime
        ))

        var rawFeatures: CUnsignedInt = 0
        let key = "shell-integration-features"
        let found = key.withCString { keyPointer in
            ghostty_config_get(config, &rawFeatures, keyPointer, UInt(key.utf8.count))
        }
        let expected = GhosttyConfigManager.ShellIntegrationFeature.allCases.reduce(UInt32(0)) {
            $0 | $1.rawValue
        }

        #expect(found)
        #expect(UInt32(rawFeatures) == expected)
    }

    @MainActor
    @Test("default shell integration config generates the SSH helper override")
    func defaultShellIntegrationConfigGeneratesSSHHelperOverride() throws {
        GhosttyRuntime.initializeProcess()
        let manager = GhosttyConfigManager(
            clipboardWritePolicy: .ask,
            confirmClipboardRead: true,
            copyOnSelect: .inherit,
            terminalAppearance: .defaultValue
        )
        let config = try #require(ghostty_config_new())
        defer { ghostty_config_free(config) }

        #expect(manager.loadConfigContents(
            GhosttyRuntimeDefaults.defaultConfigContents,
            into: config,
            filePrefix: "test-awesomux-defaults",
            failureMode: .failRuntime
        ))
        let rawFeatures = try #require(GhosttyConfigManager.rawShellIntegrationFeatures(from: config))
        let overlay = try #require(
            GhosttyConfigManager.shellIntegrationConfigContentsDisablingUnsupportedSSHHelpers(from: config)
        )

        #expect(overlay == GhosttyConfigManager.shellIntegrationConfigContents(
            disablingUnsupportedSSHHelpersFrom: rawFeatures
        ))
        #expect(overlay.contains("no-ssh-env"))
        #expect(overlay.contains("no-ssh-terminfo"))
    }

    @Test("search highlight overlay maps AwColor attention tokens")
    func searchHighlightOverlayMapsAttentionTokens() {
        #expect(GhosttyConfigManager.searchHighlightConfigContents(for: .dark) == """
        search-foreground = #12121c
        search-background = #cba6f7
        search-selected-foreground = #12121c
        search-selected-background = #fab387

        """)

        #expect(GhosttyConfigManager.searchHighlightConfigContents(for: .light) == """
        search-foreground = #ffffff
        search-background = #8839ef
        search-selected-foreground = #12121c
        search-selected-background = #fe640b

        """)
    }

    @MainActor
    @Test("search highlight keys are accepted by libghostty")
    func searchHighlightKeysAreAcceptedByLibghostty() throws {
        GhosttyRuntime.initializeProcess()
        let manager = GhosttyConfigManager(
            clipboardWritePolicy: .ask,
            confirmClipboardRead: true,
            copyOnSelect: .inherit,
            terminalAppearance: .defaultValue
        )
        let config = try #require(ghostty_config_new())
        defer { ghostty_config_free(config) }

        #expect(manager.loadConfigContents(
            GhosttyConfigManager.searchHighlightConfigContents(for: .dark),
            into: config,
            filePrefix: "test-search-highlight",
            failureMode: .failRuntime
        ))
    }

    @MainActor
    @Test("faint opacity overlay key is accepted by libghostty")
    func faintOpacityOverlayKeyIsAcceptedByLibghostty() throws {
        GhosttyRuntime.initializeProcess()
        let manager = GhosttyConfigManager(
            clipboardWritePolicy: .ask,
            confirmClipboardRead: true,
            copyOnSelect: .inherit,
            terminalAppearance: .defaultValue
        )
        let config = try #require(ghostty_config_new())
        defer { ghostty_config_free(config) }

        #expect(manager.loadConfigContents(
            "faint-opacity = 0.95\n",
            into: config,
            filePrefix: "test-faint-opacity",
            failureMode: .failRuntime
        ))
    }

    // Re-review finding: `confirmClipboardRead` reached `TerminalConfig` in the
    // constructor's default parameters but was never threaded through from
    // `GhosttyConfigManager`'s init, so the live Settings toggle never reached
    // the config-file override (production always got the `true` default).
    // This pins the wiring at the seam `build()` actually reads from.
    @MainActor
    @Test("confirmClipboardRead threads through to the terminal overlay contents")
    func confirmClipboardReadThreadsThroughToOverlayContents() {
        let denyManager = GhosttyConfigManager(
            clipboardWritePolicy: .ask,
            confirmClipboardRead: false,
            copyOnSelect: .inherit,
            terminalAppearance: .defaultValue
        )
        #expect(denyManager.terminalConfig.ghosttyOverrideConfigContents.contains("clipboard-read = deny"))

        let askManager = GhosttyConfigManager(
            clipboardWritePolicy: .ask,
            confirmClipboardRead: true,
            copyOnSelect: .inherit,
            terminalAppearance: .defaultValue
        )
        #expect(askManager.terminalConfig.ghosttyOverrideConfigContents.contains("clipboard-read = ask"))
    }

    // Codex adversarial pass on the fix above: the string-contains test only
    // pins `terminalConfig`, not that `build()` actually uses it — a future
    // edit could stop reading `terminalConfig` in `build()` and that test
    // would keep passing. This exercises the real seam end-to-end through
    // libghostty: build a finalized config and read the resolved
    // `clipboard-read` enum back via `ghostty_config_get`, the same generic
    // getter `window-theme` round-trips through in ghostty's own CApi.zig
    // tests (an enum key reads back as a C string of its case name).
    @MainActor
    @Test("confirmClipboardRead resolves through the real build() into libghostty's finalized config")
    func confirmClipboardReadResolvesThroughRealBuild() throws {
        GhosttyRuntime.initializeProcess()

        for (confirmClipboardRead, expected) in [(true, "ask"), (false, "deny")] {
            let manager = GhosttyConfigManager(
                clipboardWritePolicy: .ask,
                confirmClipboardRead: confirmClipboardRead,
                copyOnSelect: .inherit,
                terminalAppearance: .defaultValue
            )

            guard case let .built(config, _) = manager.build(reportFailures: true) else {
                Issue.record("expected build() to succeed for confirmClipboardRead=\(confirmClipboardRead)")
                continue
            }
            defer { ghostty_config_free(config) }

            var resolved: UnsafePointer<CChar>?
            let key = "clipboard-read"
            let found = key.withCString { keyPointer in
                ghostty_config_get(config, &resolved, keyPointer, UInt(key.utf8.count))
            }
            #expect(found)
            let resolvedValue = resolved.map { String(cString: $0) }
            #expect(resolvedValue == expected)
        }
    }

    // The decision table above is pure; this exercises the actual detect-rejection
    // path end-to-end against libghostty. A key it doesn't recognize appends a
    // diagnostic with no return-code signal, so `loadConfigContents` must read that
    // diagnostic and fail closed for a required overlay — the regression guard the
    // file comments stress (a renamed/removed `clipboard-write` must not silently
    // fall back to libghostty's default).
    @MainActor
    @Test("a required overlay libghostty rejects fails closed; best-effort tolerates")
    func rejectedRequiredOverlayFailsClosed() throws {
        // ghostty_config_new segfaults unless ghostty_init has run; run the
        // process-wide latch directly rather than constructing a whole runtime.
        GhosttyRuntime.initializeProcess()
        let manager = GhosttyConfigManager(
            clipboardWritePolicy: .ask,
            confirmClipboardRead: true,
            copyOnSelect: .inherit,
            terminalAppearance: .defaultValue
        )
        let bogusOverlay = "this-key-does-not-exist = 123\n"

        let requiredConfig = try #require(ghostty_config_new())
        defer { ghostty_config_free(requiredConfig) }
        #expect(!manager.loadConfigContents(
            bogusOverlay,
            into: requiredConfig,
            filePrefix: "test-required",
            failureMode: .failRuntime
        ))

        let bestEffortConfig = try #require(ghostty_config_new())
        defer { ghostty_config_free(bestEffortConfig) }
        #expect(manager.loadConfigContents(
            bogusOverlay,
            into: bestEffortConfig,
            filePrefix: "test-best-effort",
            failureMode: .logWarning
        ))
    }
}
