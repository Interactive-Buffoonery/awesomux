import Foundation
import Testing

@Suite("Sidebar hover architecture")
struct SidebarHoverArchitectureTests {
    @Test("hover presentation contains no divider animation API")
    func noDividerHoverAnimation() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let controller = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/awesoMux/Views/SidebarSplitController.swift"),
            encoding: .utf8
        )
        for forbidden in [
            "SidebarWidthAnimation", "animateSidebarVisibility",
            "isHoverAnimating", "setSidebarVisible(",
        ] {
            #expect(!controller.contains(forbidden), "remove real-divider hover path: \(forbidden)")
        }
        let support = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/awesoMux/Views/SidebarSplitSupport.swift"),
            encoding: .utf8
        )
        #expect(!support.contains("setVisibility:"))
    }

    @Test("persistent visibility is runtime-only and never driven by hover")
    func persistentVisibilityOwnership() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let content = try String(
            contentsOf: root.appendingPathComponent("Sources/awesoMux/Views/ContentView.swift"),
            encoding: .utf8
        )
        let explicit = try #require(
            content.split(
                separator: ".onChange(of: sidebarPresentationCommandMailbox.pending",
                maxSplits: 1
            ).last?.split(
                separator: ".onChange(of: splitProxy.commandHostGeneration",
                maxSplits: 1
            ).first
        )
        #expect(explicit.contains("deliverPendingSidebarPresentationCommand()"))
        let delivery = try #require(
            content.split(
                separator: "private func deliverPendingSidebarPresentationCommand",
                maxSplits: 1
            ).last?.split(
                separator: "private func clearInitialEmptyFocusIfEligible",
                maxSplits: 1
            ).first
        )
        #expect(content.contains("splitProxy.setPersistentVisible?"))
        #expect(delivery.contains("applyPersistentHidden"))
        #expect(delivery.contains("peekModel.hideAll()"))
        let proximity = try #require(
            content.split(separator: ".onChange(of: sidebarPresentation.proximityState)", maxSplits: 1)
                .last?.split(
                    separator: ".onChange(of: appSettingsStore.appearance.value.sidebarPosition)",
                    maxSplits: 1
                ).first
        )
        #expect(proximity.contains("reconcileSidebarOverlay()"))
        #expect(!proximity.contains("setPersistentVisible"))
        let reconciliation = try #require(
            content.split(separator: "private func reconcileSidebarOverlay", maxSplits: 1)
                .last?.split(separator: "private func wirePeekSelection", maxSplits: 1).first
        )
        #expect(reconciliation.contains("setOverlayVisible"))
    }

    @Test("edge tab is fixed directional and noninteractive")
    func edgeTabRenderingContract() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let content = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/awesoMux/Views/SessionDetailView.swift"),
            encoding: .utf8
        )
        let tabBody = try #require(
            content.split(separator: "private struct SidebarEdgeTab", maxSplits: 1).last
        )
        #expect(tabBody.contains("Image(systemName: \"chevron.right\")"))
        #expect(tabBody.contains("Image(systemName: \"chevron.left\")"))
        #expect(tabBody.contains(".frame(width: 7)"))
        #expect(tabBody.contains(".frame(width: 28, height: 52)"))
        #expect(tabBody.contains(".frame(width: 28, alignment: position == .left ? .leading : .trailing)"))
        #expect(tabBody.contains("position == .left ? -10 : 10"))
        #expect(tabBody.contains(".offset(x: style == nil && !reduceMotion ? hiddenOffset : 0)"))
        #expect(tabBody.contains("SidebarEdgeTabTransitionPolicy.shouldAnimate"))
        #expect(tabBody.contains(".allowsHitTesting(false)"))
        #expect(tabBody.contains(".accessibilityHidden(true)"))
        #expect(tabBody.contains(".opacity(style == nil ? 0 : 1)"))
        #expect(tabBody.contains("let terminalBackground: Color"))
        #expect(tabBody.contains("terminalBackground: terminalBackground"))
        #expect(!tabBody.contains("terminalBackground: Color.aw.surface.window"))
        #expect(!tabBody.contains("TimelineView(.animation)"))
        #expect(!tabBody.contains("currentOverlayVisibleFraction"))
        #expect(!tabBody.contains("SidebarEdgeTabPolicy.opacity("))
        for forbidden in [
            "SidebarProximityCue", "cueIntensity", "visualStrength", ".shadow(",
        ] {
            #expect(!content.contains(forbidden), "remove proximity glow API: \(forbidden)")
        }
    }
}
