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
        let expectedWorkgroupBoundary: CGFloat
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
            TitlebarCase(
                position: .left, titlebarWidth: 500, sidebarWidth: 60, translation: -60, expectedVisibleWidth: 0,
                expectedWorkgroupBoundary: 104),
            TitlebarCase(
                position: .left, titlebarWidth: 500, sidebarWidth: 60, translation: -30, expectedVisibleWidth: 30,
                expectedWorkgroupBoundary: 104),
            TitlebarCase(
                position: .left, titlebarWidth: 500, sidebarWidth: 60, translation: 0, expectedVisibleWidth: 60,
                expectedWorkgroupBoundary: 104),
            TitlebarCase(
                position: .left, titlebarWidth: 1_200, sidebarWidth: 300, translation: -180, expectedVisibleWidth: 120,
                expectedWorkgroupBoundary: 136),
            TitlebarCase(
                position: .left, titlebarWidth: 1_200, sidebarWidth: 300, translation: 0, expectedVisibleWidth: 300,
                expectedWorkgroupBoundary: 316),
            TitlebarCase(
                position: .left, titlebarWidth: 500, sidebarWidth: 300, translation: -150, expectedVisibleWidth: 150,
                expectedWorkgroupBoundary: 166),
            TitlebarCase(
                position: .left, titlebarWidth: 500, sidebarWidth: 300, translation: 0, expectedVisibleWidth: 300,
                expectedWorkgroupBoundary: 316),
            TitlebarCase(
                position: .left, titlebarWidth: 1_200, sidebarWidth: 60, translation: -30, expectedVisibleWidth: 30,
                expectedWorkgroupBoundary: 104),
            TitlebarCase(
                position: .left, titlebarWidth: 1_200, sidebarWidth: 60, translation: 0, expectedVisibleWidth: 60,
                expectedWorkgroupBoundary: 104),
            TitlebarCase(
                position: .right, titlebarWidth: 500, sidebarWidth: 60, translation: 60, expectedVisibleWidth: 0,
                expectedWorkgroupBoundary: 484),
            TitlebarCase(
                position: .right, titlebarWidth: 500, sidebarWidth: 60, translation: 30, expectedVisibleWidth: 30,
                expectedWorkgroupBoundary: 454),
            TitlebarCase(
                position: .right, titlebarWidth: 500, sidebarWidth: 60, translation: 0, expectedVisibleWidth: 60,
                expectedWorkgroupBoundary: 424),
            TitlebarCase(
                position: .right, titlebarWidth: 1_200, sidebarWidth: 300, translation: 180, expectedVisibleWidth: 120,
                expectedWorkgroupBoundary: 1_064),
            TitlebarCase(
                position: .right, titlebarWidth: 1_200, sidebarWidth: 300, translation: 0, expectedVisibleWidth: 300,
                expectedWorkgroupBoundary: 884),
            TitlebarCase(
                position: .right, titlebarWidth: 500, sidebarWidth: 300, translation: 150, expectedVisibleWidth: 150,
                expectedWorkgroupBoundary: 334),
            TitlebarCase(
                position: .right, titlebarWidth: 500, sidebarWidth: 300, translation: 0, expectedVisibleWidth: 300,
                expectedWorkgroupBoundary: 184),
            TitlebarCase(
                position: .right, titlebarWidth: 1_200, sidebarWidth: 60, translation: 30, expectedVisibleWidth: 30,
                expectedWorkgroupBoundary: 1_154),
            TitlebarCase(
                position: .right, titlebarWidth: 1_200, sidebarWidth: 60, translation: 0, expectedVisibleWidth: 60,
                expectedWorkgroupBoundary: 1_124),
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
        let geometry = SidebarPresentationLayoutPolicy(position: testCase.position).titlebarGeometry(
            titlebarWidth: testCase.titlebarWidth,
            visibleSidebarWidth: visibleWidth
        )
        #expect(geometry.sidebarReservationWidth == testCase.expectedVisibleWidth)
        #expect(geometry.workgroupBoundary == testCase.expectedWorkgroupBoundary)
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
        #expect(overlay.contains("visibleSidebarWidth: visibleWidth"))
        #expect(overlay.contains("titlebarColumns(geometry: geometry)"))
        #expect(overlay.contains(".offset(x: translation)"))
        #expect(overlay.components(separatedBy: "currentTitlebarTranslationX").count == 2)
    }

    @Test("reveal then partial-hide reversal updates the boundary on both sides")
    func revealThenPartialHideReversal() {
        for position in [AppearanceConfig.SidebarPosition.left, .right] {
            let state = SidebarHostPresentationState(mode: .hidden)
            var translation: CGFloat = position == .left ? -300 : 300
            state.overlayPresentationTranslation = { translation }
            state.beginOverlayTransition(presented: true, width: 300, position: position)

            translation = 0
            #expect(state.currentTitlebarVisibleWidth(position: position) == 300)

            state.beginOverlayTransition(presented: false, width: 300, position: position)
            translation = position == .left ? -120 : 120
            let visibleWidth = state.currentTitlebarVisibleWidth(position: position)
            let geometry = SidebarPresentationLayoutPolicy(position: position).titlebarGeometry(
                titlebarWidth: 500,
                visibleSidebarWidth: visibleWidth
            )

            #expect(visibleWidth == 180)
            #expect(geometry.workgroupBoundary == (position == .left ? 196 : 304))
        }
    }

    @Test("hidden sidebar restores the original workgroup position on both sides")
    func hiddenSidebarRestoresWorkgroupPosition() {
        let left = SidebarPresentationLayoutPolicy(position: .left).titlebarGeometry(
            titlebarWidth: 500,
            visibleSidebarWidth: 0
        )
        let right = SidebarPresentationLayoutPolicy(position: .right).titlebarGeometry(
            titlebarWidth: 500,
            visibleSidebarWidth: 0
        )

        #expect(left.sidebarReservationWidth == 0)
        #expect(left.workgroupBoundary == 104)
        #expect(right.sidebarReservationWidth == 0)
        #expect(right.workgroupBoundary == 484)
    }
}
