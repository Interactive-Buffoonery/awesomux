import Foundation
import Testing
@testable import awesoMux

@Suite("Sidebar edge tab policy")
struct SidebarAttentionCuePolicyTests {
    @Test("Durable acknowledgement and unread notifications both count as attention")
    func durableAttentionSources() {
        #expect(
            SidebarEdgeTabPolicy.hasAttention(
                needsAcknowledgement: true,
                unreadNotificationCount: 0
            ))
        #expect(
            SidebarEdgeTabPolicy.hasAttention(
                needsAcknowledgement: false,
                unreadNotificationCount: 1
            ))
        #expect(
            !SidebarEdgeTabPolicy.hasAttention(
                needsAcknowledgement: false,
                unreadNotificationCount: 0
            ))
    }

    @Test("attention scanning runs only for a dormant persistently hidden sidebar")
    func attentionScanGate() {
        #expect(
            SidebarEdgeTabPolicy.shouldScanAttention(
                isPersistentlyHidden: true, proximity: .dormant))
        #expect(
            !SidebarEdgeTabPolicy.shouldScanAttention(
                isPersistentlyHidden: false, proximity: .dormant))
        #expect(
            !SidebarEdgeTabPolicy.shouldScanAttention(
                isPersistentlyHidden: true, proximity: .cue))
        #expect(
            !SidebarEdgeTabPolicy.shouldScanAttention(
                isPersistentlyHidden: true, proximity: .revealed))
    }

    @Test("inactive control suppresses scanning and presentation without clearing attention")
    func inactiveControlSuppressesAttentionPresentation() {
        let hasAttention = SidebarEdgeTabPolicy.hasAttention(
            needsAcknowledgement: true,
            unreadNotificationCount: 0
        )

        #expect(
            !SidebarEdgeTabPolicy.shouldScanAttention(
                isPersistentlyHidden: true,
                proximity: .dormant,
                isControlActive: false
            ))
        #expect(
            SidebarEdgeTabPolicy.resolve(
                isPersistentlyHidden: true,
                proximity: .dormant,
                hasAttention: hasAttention,
                isControlActive: false
            ) == nil)

        #expect(
            SidebarEdgeTabPolicy.shouldScanAttention(
                isPersistentlyHidden: true,
                proximity: .dormant,
                isControlActive: true
            ))
        #expect(
            SidebarEdgeTabPolicy.resolve(
                isPersistentlyHidden: true,
                proximity: .dormant,
                hasAttention: hasAttention,
                isControlActive: true
            ) == .attention)
    }

    @Test("edge tab slides away while revealed and returns for the cue")
    func edgeTabRevealTransition() {
        #expect(
            SidebarEdgeTabPolicy.resolve(
                isPersistentlyHidden: true, proximity: .cue, hasAttention: false) == .cue)
        #expect(
            SidebarEdgeTabPolicy.resolve(
                isPersistentlyHidden: true, proximity: .revealed, hasAttention: false) == nil)
        #expect(
            SidebarEdgeTabPolicy.resolve(
                isPersistentlyHidden: true, proximity: .cue, hasAttention: false) == .cue)
    }

    @Test("attention appears only while the hidden sidebar is dormant")
    func edgeTabAttentionStyle() {
        #expect(
            SidebarEdgeTabPolicy.resolve(
                isPersistentlyHidden: true, proximity: .dormant, hasAttention: true) == .attention)
        #expect(
            SidebarEdgeTabPolicy.resolve(
                isPersistentlyHidden: true, proximity: .revealed, hasAttention: true) == nil)
        #expect(
            SidebarEdgeTabPolicy.resolve(
                isPersistentlyHidden: true, proximity: .dormant, hasAttention: false) == nil)
        #expect(
            SidebarEdgeTabPolicy.resolve(
                isPersistentlyHidden: false, proximity: .cue, hasAttention: true) == nil)
    }

    @Test("edge tab belongs to terminal and empty content and uses adaptive chevron contrast")
    func edgeTabSourceContract() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let contentSource = try String(
            contentsOf: root.appendingPathComponent("Sources/awesoMux/Views/ContentView.swift"),
            encoding: .utf8
        )
        let detailSource = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/awesoMux/Views/SessionDetailView.swift"),
            encoding: .utf8
        )
        let normalizedDetailSource = detailSource.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        let terminalRegion = try #require(
            detailSource.split(separator: "TerminalPaneView(", maxSplits: 1).last?
                .split(separator: "TerminalPathBarView(", maxSplits: 1).first
        )
        let emptyRegion = try #require(
            detailSource.split(separator: "EmptyWorkspaceView(", maxSplits: 1).last?
                .split(separator: "private enum EmptyWorkspaceMode", maxSplits: 1).first
        )
        let normalizedTerminalRegion = terminalRegion.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )

        #expect(contentSource.contains("edgeTabStyle: edgeTabStyle"))
        #expect(contentSource.contains("sidebarPosition: sidebarPosition"))
        #expect(contentSource.contains("@Environment(\\.controlActiveState)"))
        #expect(contentSource.contains("isControlActive: controlActiveState != .inactive"))
        let attentionGate = try #require(
            contentSource.range(of: "SidebarEdgeTabPolicy.shouldScanAttention"))
        let attentionScan = try #require(
            contentSource.range(of: "sessionStore.groups.contains", range: attentionGate.lowerBound..<contentSource.endIndex))
        #expect(attentionGate.lowerBound < attentionScan.lowerBound)
        #expect(contentSource.contains("onFooterHeightChange: onTerminalFooterHeightChange"))
        #expect(!contentSource.contains("@State private var terminalFooterHeight"))
        #expect(!contentSource.contains(".padding(.bottom, terminalFooterHeight)"))
        #expect(terminalRegion.contains("SidebarEdgeTab("))
        #expect(
            terminalRegion.contains(
                ".overlay(alignment: sidebarPosition == .left ? .leading : .trailing)"))
        #expect(emptyRegion.contains("SidebarEdgeTab("))
        #expect(
            normalizedTerminalRegion.contains(
                "terminalBackground: Color( nsColor: ghosttyRuntime.terminalBackgroundColor"))
        #expect(emptyRegion.contains("terminalBackground: Color.aw.surface.terminal"))
        #expect(detailSource.contains("onFooterHeightChange(height)"))
        #expect(detailSource.contains("private struct SidebarEdgeTab"))
        #expect(
            normalizedDetailSource.contains(
                "Color.aw.contrastTuned( Color.aw.status.needs, terminalBackground: terminalBackground"))
        #expect(
            detailSource.contains(
                "Color.aw.backgroundIsDark(color) ? Color.white : Color.black"
            )
        )
    }

    @Test("Visibility title describes the next action")
    func visibilityTitleDescribesNextAction() {
        #expect(SidebarVisibilityActionTitle.resolve(isHidden: false) == "Hide Sidebar")
        #expect(SidebarVisibilityActionTitle.resolve(isHidden: true) == "Show Sidebar")
    }

    @Test("visibility titles use literal localization keys present in the catalog")
    func visibilityTitlesAreLocalized() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/awesoMux/Views/SidebarPresentationModel.swift"),
            encoding: .utf8
        )
        let normalizedSource = source.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        #expect(normalizedSource.contains("localized: \"Show Sidebar\", comment:"))
        #expect(normalizedSource.contains("localized: \"Hide Sidebar\", comment:"))

        let catalogData = try Data(
            contentsOf: root.appendingPathComponent("Resources/Localizable.xcstrings"))
        let catalog = try #require(
            JSONSerialization.jsonObject(with: catalogData) as? [String: Any])
        let strings = try #require(catalog["strings"] as? [String: Any])
        #expect(strings["Show Sidebar"] != nil)
        #expect(strings["Hide Sidebar"] != nil)
    }
}
