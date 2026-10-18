import AppKit
import AwesoMuxConfig
import AwesoMuxCore
import Testing
@testable import awesoMux

@MainActor
@Suite("GhosttyRuntime config build")
struct GhosttyRuntimeConfigBuildTests {
    @Test("in-place configuration reload preserves cached panes and refreshes background")
    func inPlaceConfigurationReloadPreservesPane() throws {
        var color = "#abcdef"
        let runtime = GhosttyRuntime(terminalAppearanceProvider: { Self.customBackground(color) })
        defer { runtime.discardAllSurfaces() }
        let pane = TerminalPane(title: "reload", workingDirectory: "/tmp", executionPlan: .local)
        let session = TerminalSession(title: "reload", workingDirectory: "/tmp", layout: .pane(pane), activePaneID: pane.id)
        let store = SessionStore(groups: [SessionGroup(name: "test", sessions: [session])], selectedSessionID: session.id)
        let view = runtime.surfaceView(
            sessionStore: store, session: session, pane: pane,
            enabledAgentRuntimeFileDropSources: [], grokIconEnabled: false
        )
        let revision = runtime.surfaceCacheRevision
        color = "#003366"
        guard case .applied = runtime.reloadGhosttyConfiguration() else {
            Issue.record("Expected an applied in-place configuration reload")
            return
        }
        #expect(runtime.isReady)
        #expect(runtime.cachedSurfaceView(for: pane.id) === view)
        #expect(runtime.surfaceCacheRevision == revision)
        #expect(store.selectedSession?.activePaneID == pane.id)
        Self.expectBackground(runtime.terminalBackgroundColor, approximately: (r: 0, g: 0x33, b: 0x66))
    }

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

}
