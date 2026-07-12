import AppKit
import AwesoMuxConfig
import Testing
@testable import awesoMux

/// Characterization tests for the config-build seam, pinned through the
/// coordinator surface that survives the `GhosttyConfigManager` extraction:
/// `init`, `applyTerminalAppearance`, `reload`, and the `terminalBackgroundColor`
/// / `readiness` read-backs. These exercise the full
/// input → generate-overlay → libghostty-load → finalize → read-back pipeline
/// on a live runtime (it reaches `.ready` headlessly), so they fail if the
/// extraction perturbs any link in that chain. Written before the extraction so
/// they can move green across it unchanged.
@MainActor
@Suite("GhosttyRuntime config build")
struct GhosttyRuntimeConfigBuildTests {
    /// Allow a 1/255 rounding gap per channel: the hex round-trips through
    /// libghostty's 8-bit color struct and back into an sRGB `NSColor`.
    private static func expectBackground(
        _ color: NSColor,
        approximately hex: (r: Int, g: Int, b: Int),
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let srgb = color.usingColorSpace(.sRGB)
        let actual = (
            r: Int((srgb?.redComponent ?? 0) * 255 + 0.5),
            g: Int((srgb?.greenComponent ?? 0) * 255 + 0.5),
            b: Int((srgb?.blueComponent ?? 0) * 255 + 0.5)
        )
        #expect(actual.r == hex.r, sourceLocation: sourceLocation)
        #expect(actual.g == hex.g, sourceLocation: sourceLocation)
        #expect(actual.b == hex.b, sourceLocation: sourceLocation)
    }

    private static func customBackground(_ hex: String) -> TerminalAppearancePreferences {
        TerminalAppearancePreferences(
            terminalBackgroundMode: .custom,
            terminalBackgroundColor: hex
        )
    }

    @Test("runtime reaches ready after headless construction")
    func constructsReady() {
        let runtime = GhosttyRuntime()
        #expect(runtime.isReady)
        #expect(runtime.readiness == .ready)
        #expect(runtime.errorMessage == nil)
    }

    // The load-bearing one: feed an explicit background hex through the
    // construction-time provider and assert the value read back out of the
    // finalized config matches the input. Input-sensitive, so it fails if the
    // first config build stops threading appearance → config → read-back —
    // unlike asserting the default theme color, which a no-op pipeline would
    // still satisfy.
    @Test("construction provider resolves through the first config build and reads back")
    func constructionProviderResolvesFromInput() {
        var providerCalls = 0
        let runtime = GhosttyRuntime(terminalAppearanceProvider: {
            providerCalls += 1
            return Self.customBackground("#abcdef")
        })
        Self.expectBackground(
            runtime.terminalBackgroundColor,
            approximately: (r: 0xab, g: 0xcd, b: 0xef)
        )
        #expect(providerCalls > 0)
    }

    @Test("a different background hex resolves to a different color")
    func differentBackgroundHexResolvesDistinctly() {
        let runtime = GhosttyRuntime(terminalAppearanceProvider: {
            Self.customBackground("#102030")
        })
        Self.expectBackground(
            runtime.terminalBackgroundColor,
            approximately: (r: 0x10, g: 0x20, b: 0x30)
        )
    }

    @Test("applyTerminalAppearance re-resolves the background on a live app")
    func applyAppearanceRebuildsBackground() {
        let runtime = GhosttyRuntime(terminalAppearanceProvider: {
            Self.customBackground("#abcdef")
        })
        runtime.applyTerminalAppearance(Self.customBackground("#003366"))
        Self.expectBackground(
            runtime.terminalBackgroundColor,
            approximately: (r: 0x00, g: 0x33, b: 0x66)
        )
    }

    @Test("reload rebuilds the runtime and reapplies the configured background")
    func reloadRebuildsToReadyWithBackground() {
        let runtime = GhosttyRuntime(terminalAppearanceProvider: {
            Self.customBackground("#445566")
        })
        runtime.reload()
        #expect(runtime.isReady)
        Self.expectBackground(
            runtime.terminalBackgroundColor,
            approximately: (r: 0x44, g: 0x55, b: 0x66)
        )
    }

    // `.ghostty` mode emits no awesoMux `background` override, so the build runs
    // its no-awesoMux-color branch. This pins that the branch still produces a
    // finalized, ready runtime. It does NOT exercise the in-runtime nil-key
    // no-clobber guard (`if let backgroundColor`): libghostty resolves its own
    // default `background` even with no override, so the read-back is non-nil and
    // the prior value is overwritten, not preserved. That guard only fires if the
    // finalized config truly lacks the key, which isn't reachable through this
    // input — hence no assertion on the prior color here.
    @Test("ghostty-owned background mode still builds a ready runtime")
    func ghosttyOwnedModeBuildsReady() {
        let runtime = GhosttyRuntime(terminalAppearanceProvider: {
            Self.customBackground("#7788aa")
        })
        Self.expectBackground(
            runtime.terminalBackgroundColor,
            approximately: (r: 0x77, g: 0x88, b: 0xaa)
        )

        runtime.applyTerminalAppearance(
            TerminalAppearancePreferences(terminalBackgroundMode: .ghostty)
        )
        #expect(runtime.isReady)
    }
}
