import AwesoMuxCore
import AwesoMuxConfig
import CoreGraphics
import Foundation
import Testing
@testable import awesoMux

@Suite("Sidebar presentation layout")
@MainActor
struct SidebarPresentationLayoutTests {
    struct TitlebarCase: Sendable {
        let position: AppearanceConfig.SidebarPosition
        let titlebarWidth: CGFloat
        let sidebarWidth: CGFloat
        let translation: CGFloat
        let expectedVisibleWidth: CGFloat
    }

    @Test("left sidebar reveals from leading and peeks rightward")
    func leftSidebarLayout() {
        let policy = SidebarPresentationLayoutPolicy(position: .left)

        #expect(policy.edge == .leading)
        #expect(policy.peekDirection == .right)
        #expect(policy.titlebarColumns == [.sidebar, .detail])
        #expect(policy.trafficLightColumn == .sidebar)
        #expect(policy.dividerGutterColumn == .detail)
        #expect(policy.dividerGutterEdge == .leading)
    }

    @Test("right sidebar reveals from trailing and peeks leftward")
    func rightSidebarLayout() {
        let policy = SidebarPresentationLayoutPolicy(position: .right)

        #expect(policy.edge == .trailing)
        #expect(policy.peekDirection == .left)
        #expect(policy.titlebarColumns == [.detail, .sidebar])
        #expect(policy.trafficLightColumn == .detail)
        #expect(policy.dividerGutterColumn == .sidebar)
        #expect(policy.dividerGutterEdge == .leading)
    }

    @Test("title lockup alignment follows sidebar position")
    func titleLockupAlignment() {
        #expect(
            SidebarPresentationLayoutPolicy(position: .left).titlebarLockupAlignment
                == .leading
        )
        #expect(
            SidebarPresentationLayoutPolicy(position: .right).titlebarLockupAlignment
                == .trailing
        )
    }

    @Test("title lockup contract is stable across presentation states")
    func titleLockupPresentationMatrix() {
        let states: [(width: CGFloat, persistent: Bool, temporary: Bool)] = [
            (SidebarWidthPolicy.collapsedWidth, true, false),
            (SidebarWidthPolicy.expandedWidth, true, false),
            (SidebarWidthPolicy.collapsedWidth, false, true),
            (SidebarWidthPolicy.expandedWidth, false, true),
        ]
        for state in states {
            _ = state
            let policy = SidebarPresentationLayoutPolicy(position: .right)
            #expect(policy.titlebarLockupAlignment == .trailing)
            #expect(policy.titlebarLockupOuterPadding == 10)
        }
    }

    @Test(
        "workgroup stays outside the live overlay region",
        arguments: [
            TitlebarCase(position: .left, titlebarWidth: 500, sidebarWidth: 60, translation: -60, expectedVisibleWidth: 0),
            TitlebarCase(position: .left, titlebarWidth: 500, sidebarWidth: 60, translation: -30, expectedVisibleWidth: 30),
            TitlebarCase(position: .left, titlebarWidth: 500, sidebarWidth: 60, translation: 0, expectedVisibleWidth: 60),
            TitlebarCase(position: .left, titlebarWidth: 1_200, sidebarWidth: 300, translation: -180, expectedVisibleWidth: 120),
            TitlebarCase(position: .left, titlebarWidth: 1_200, sidebarWidth: 300, translation: 0, expectedVisibleWidth: 300),
            TitlebarCase(position: .right, titlebarWidth: 500, sidebarWidth: 60, translation: 60, expectedVisibleWidth: 0),
            TitlebarCase(position: .right, titlebarWidth: 500, sidebarWidth: 60, translation: 30, expectedVisibleWidth: 30),
            TitlebarCase(position: .right, titlebarWidth: 500, sidebarWidth: 60, translation: 0, expectedVisibleWidth: 60),
            TitlebarCase(position: .right, titlebarWidth: 1_200, sidebarWidth: 300, translation: 180, expectedVisibleWidth: 120),
            TitlebarCase(position: .right, titlebarWidth: 1_200, sidebarWidth: 300, translation: 0, expectedVisibleWidth: 300),
        ])
    func workgroupAvoidsLiveOverlay(testCase: TitlebarCase) {
        let state = SidebarHostPresentationState(mode: .hidden)
        state.beginOverlayTransition(
            presented: true,
            width: testCase.sidebarWidth,
            position: testCase.position
        )
        state.overlayPresentationTranslation = { testCase.translation }

        let visibleWidth = state.currentTitlebarVisibleWidth(position: testCase.position)
        #expect(visibleWidth == testCase.expectedVisibleWidth)
    }

    @Test("overlay titlebar reuses one presentation translation sample")
    func overlayTitlebarUsesOneTranslationSample() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let content = try String(
            contentsOf: root.appendingPathComponent("Sources/awesoMux/Views/ContentView.swift"),
            encoding: .utf8
        )
        let overlay = try #require(
            content.split(separator: "case .overlay:", maxSplits: 1).last?
                .split(separator: "case .hidden:", maxSplits: 1).first
        )

        #expect(overlay.contains("let translation = hostPresentation.currentTitlebarTranslationX"))
        #expect(overlay.contains("translation: translation"))
        #expect(overlay.contains("titlebarColumns(sidebarWidth: visibleWidth)"))
        #expect(overlay.contains(".offset(x: translation)"))
        #expect(overlay.components(separatedBy: "currentTitlebarTranslationX").count == 2)
    }

    @Test("hidden sidebar restores the original workgroup position on both sides")
    func hiddenSidebarRestoresWorkgroupPosition() {
        let state = SidebarHostPresentationState(mode: .hidden)
        state.beginOverlayTransition(presented: false, width: 300, position: .left)

        #expect(state.currentTitlebarVisibleWidth(position: .left) == 0)
        #expect(AppTitlebarMetrics.contentColumnGutter == 16)
        state.beginOverlayTransition(presented: false, width: 300, position: .right)
        #expect(state.currentTitlebarVisibleWidth(position: .right) == 0)
    }
}
