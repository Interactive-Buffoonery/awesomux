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
        let reservationWidth: CGFloat
        let expectedReservation: CGFloat
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

    // MARK: - Static titlebar geometry (#77)

    @Test(
        "titlebar geometry is a pure function of width and reservation",
        arguments: [
            // Left, lockup reservation (hidden/overlay): boundary is the static
            // 188pt workspace-title anchor.
            TitlebarCase(
                position: .left, titlebarWidth: 500,
                reservationWidth: AppTitlebarMetrics.brandWithTextMinimumWidth,
                expectedReservation: 172, expectedWorkgroupBoundary: 188),
            TitlebarCase(
                position: .left, titlebarWidth: 1_200,
                reservationWidth: AppTitlebarMetrics.brandWithTextMinimumWidth,
                expectedReservation: 172, expectedWorkgroupBoundary: 188),
            // Left, persistent widths: boundary tracks the divider.
            TitlebarCase(
                position: .left, titlebarWidth: 1_200, reservationWidth: 300,
                expectedReservation: 300, expectedWorkgroupBoundary: 316),
            TitlebarCase(
                position: .left, titlebarWidth: 500, reservationWidth: 60,
                expectedReservation: 60, expectedWorkgroupBoundary: 104),
            TitlebarCase(
                position: .left, titlebarWidth: 500, reservationWidth: 0,
                expectedReservation: 0, expectedWorkgroupBoundary: 104),
            // Right: boundary is the trailing reservation edge.
            TitlebarCase(
                position: .right, titlebarWidth: 500,
                reservationWidth: AppTitlebarMetrics.brandWithTextMinimumWidth,
                expectedReservation: 172, expectedWorkgroupBoundary: 312),
            TitlebarCase(
                position: .right, titlebarWidth: 1_200, reservationWidth: 300,
                expectedReservation: 300, expectedWorkgroupBoundary: 884),
            TitlebarCase(
                position: .right, titlebarWidth: 500, reservationWidth: 0,
                expectedReservation: 0, expectedWorkgroupBoundary: 484),
        ])
    func titlebarGeometryIsPure(testCase: TitlebarCase) {
        let geometry = SidebarPresentationLayoutPolicy(position: testCase.position)
            .titlebarGeometry(
                titlebarWidth: testCase.titlebarWidth,
                visibleSidebarWidth: testCase.reservationWidth
            )

        #expect(geometry.sidebarReservationWidth == testCase.expectedReservation)
        #expect(abs(geometry.workgroupBoundary - testCase.expectedWorkgroupBoundary) < 0.001)
    }

    @Test("hidden and overlay reservations are identical, so reveal moves nothing")
    func hiddenAndOverlayShareOneReservation() {
        let hidden = SidebarHostPresentationState(mode: .hidden)

        let overlay = SidebarHostPresentationState(mode: .hidden)
        overlay.settle(mode: .overlay(width: 300), effectiveVisibleWidth: 300)

        #expect(
            hidden.titlebarReservationWidth
                == AppTitlebarMetrics.brandWithTextMinimumWidth
        )
        #expect(overlay.titlebarReservationWidth == hidden.titlebarReservationWidth)

        // The shared reservation lands the workspace-title anchor at the same
        // boundary in both states — the static-titlebar invariant (#77).
        let policy = SidebarPresentationLayoutPolicy(position: .left)
        let hiddenGeometry = policy.titlebarGeometry(
            titlebarWidth: 1_200,
            visibleSidebarWidth: hidden.titlebarReservationWidth
        )
        let overlayGeometry = policy.titlebarGeometry(
            titlebarWidth: 1_200,
            visibleSidebarWidth: overlay.titlebarReservationWidth
        )
        #expect(hiddenGeometry == overlayGeometry)
        #expect(hiddenGeometry.workgroupBoundary == 188)
    }

    @Test("persistent reservation mirrors the live column across settles")
    func persistentReservationTracksDivider() {
        let state = SidebarHostPresentationState(mode: .persistent(width: 300))
        #expect(state.titlebarReservationWidth == 300)

        state.settle(mode: .persistent(width: 240), effectiveVisibleWidth: 240)
        #expect(state.titlebarReservationWidth == 240)

        state.settle(mode: .hidden, effectiveVisibleWidth: 0)
        #expect(
            state.titlebarReservationWidth
                == AppTitlebarMetrics.brandWithTextMinimumWidth
        )

        state.settle(mode: .persistent(width: 300), effectiveVisibleWidth: 300)
        #expect(state.titlebarReservationWidth == 300)
    }

    @Test("narrow windows clamp the reservation and boundary")
    func narrowWindowClampsGeometry() {
        let geometry = SidebarPresentationLayoutPolicy(position: .left).titlebarGeometry(
            titlebarWidth: 150,
            visibleSidebarWidth: AppTitlebarMetrics.brandWithTextMinimumWidth
        )

        #expect(geometry.sidebarReservationWidth == 150)
        #expect(geometry.workgroupBoundary == 150)
    }

    @Test("degenerate geometry inputs clamp to zero")
    func degenerateInputsClamp() {
        let policy = SidebarPresentationLayoutPolicy(position: .left)
        let nanWidth = policy.titlebarGeometry(
            titlebarWidth: .nan,
            visibleSidebarWidth: 172
        )
        let nanReservation = policy.titlebarGeometry(
            titlebarWidth: 500,
            visibleSidebarWidth: .nan
        )

        #expect(nanWidth.titlebarWidth == 0)
        #expect(nanWidth.sidebarReservationWidth == 0)
        #expect(nanReservation.sidebarReservationWidth == 0)
        #expect(nanReservation.workgroupBoundary == 104)
    }

    @Test("titlebar content fills its reader and stays vertically centered")
    func titlebarContentCentersInReader() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let content = try String(
            contentsOf: root.appendingPathComponent("Sources/awesoMux/Views/ContentView.swift"),
            encoding: .utf8
        )
        let titlebarBody = try #require(
            content.split(separator: "GeometryReader { proxy in", maxSplits: 1).last?
                .split(separator: "// Titlebar height stays fixed", maxSplits: 1).first
        )

        #expect(titlebarBody.contains(".frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)"))
    }

    @Test("titlebar renders no per-frame sampling or translation mirroring")
    func titlebarHasNoLockstepMachinery() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let content = try String(
            contentsOf: root.appendingPathComponent("Sources/awesoMux/Views/ContentView.swift"),
            encoding: .utf8
        )

        #expect(!content.contains("TimelineView(.animation)"))
        #expect(!content.contains("overlayTitlebar"))
        #expect(!content.contains("titlebarTranslationX"))
        #expect(!content.contains("overlayVisibleFraction"))
    }

    @Test("permanent titlebar branding stays exposed to accessibility")
    func permanentTitlebarBrandingAccessibilityContract() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let contentView = try String(
            contentsOf: root.appendingPathComponent("Sources/awesoMux/Views/ContentView.swift"),
            encoding: .utf8)
        let brandmark = try String(
            contentsOf: root.appendingPathComponent("Sources/awesoMux/Views/Brandmark.swift"),
            encoding: .utf8)

        // The lockup is permanent titlebar chrome (#77): exactly one render
        // path, never hidden from assistive tech, labeled by Brandmark itself.
        let titlebar = try #require(
            contentView.split(separator: "private func titlebarContent", maxSplits: 1).last?
                .split(separator: "private func workspaceCluster", maxSplits: 1).first)
        #expect(!titlebar.contains(".accessibilityHidden"))
        #expect(brandmark.contains(".accessibilityLabel(\"awesoMux\")"))
    }
}
