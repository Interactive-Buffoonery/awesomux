import AwesoMuxCore
import Foundation
import Testing
@testable import awesoMux

@Suite("Sidebar hover integration")
struct SidebarHoverIntegrationTests {
    @Test("proximity uses overlay while explicit show uses persistent split")
    func routesPresentationKinds() {
        #expect(
            SidebarPresentationRouting.command(userWantsHidden: true, proximity: .revealed)
                == .showOverlay)
        #expect(
            SidebarPresentationRouting.command(userWantsHidden: true, proximity: .cue)
                == .hideOverlay)
        #expect(
            SidebarPresentationRouting.command(userWantsHidden: false, proximity: .dormant)
                == .showPersistent)
    }

    @Test("hidden width toggle changes selection without visibility")
    func hiddenWidthToggle() {
        let result = SidebarHiddenWidthTogglePolicy.resolve(
            currentWidth: 300,
            lastNonCollapsedWidth: 300,
            persistentlyHidden: true
        )
        #expect(result.targetWidth == SidebarWidthPolicy.collapsedWidth)
        #expect(!result.shouldReveal)
    }

    @Test("hidden collapsed width toggle restores remembered full width")
    func hiddenCollapsedWidthToggle() {
        let result = SidebarHiddenWidthTogglePolicy.resolve(
            currentWidth: SidebarWidthPolicy.collapsedWidth,
            lastNonCollapsedWidth: 300,
            persistentlyHidden: true
        )
        #expect(result.targetWidth == 300)
        #expect(!result.shouldReveal)
    }

    @Test("temporarily revealed width toggle uses the live rendered width")
    func temporaryRevealUsesLiveWidth() {
        let currentWidth = SidebarHiddenWidthTogglePolicy.currentWidth(
            committedWidth: 300,
            liveWidth: SidebarWidthPolicy.collapsedWidth,
            isTemporarilyRevealed: true
        )
        let result = SidebarHiddenWidthTogglePolicy.resolve(
            currentWidth: currentWidth,
            lastNonCollapsedWidth: 300,
            persistentlyHidden: true
        )
        #expect(result.targetWidth == 300)
        #expect(!result.shouldReveal)
    }

    @Test("focus request persists host before delivering focus to SidebarView")
    func focusDeliveryIsSerializedAfterPersistentHandoff() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let root = testFile.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/awesoMux/Views/ContentView.swift"),
            encoding: .utf8)
        let handler = try #require(source.range(of: ".onChange(of: sidebarFocusRequestID)"))
        let tail = source[handler.lowerBound...]
        let nextHandler = tail.range(of: ".onChange(of: sidebarPresentation.proximityState)")
        let body = nextHandler.map { tail[..<$0.lowerBound] } ?? tail[...]
        let persistent = try #require(body.range(of: "splitProxy.setPersistentVisible?(true)"))
        let delivered = try #require(body.range(of: "deliveredSidebarFocusRequestID = requestID"))

        #expect(persistent.lowerBound < delivered.lowerBound)
        #expect(source.contains("focusRequestID: deliveredSidebarFocusRequestID"))
        #expect(!source.contains("focusRequestID: sidebarFocusRequestID,"))
    }

}
