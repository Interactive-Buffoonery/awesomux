import AppKit
import SwiftUI
import Testing
@testable import awesoMux

@MainActor
@Suite(.serialized)
struct ScrollbackDumpSheetTests {
    @Test("unchanged dumps keep selection and new dumps replace the displayed snapshot")
    func snapshotIdentityControlsTextInstallation() throws {
        let state = SurfaceSearchState()
        let request = try #require(state.beginScrollbackDump())
        state.finishScrollbackDump(.loaded(text: "first history"), request: request)
        func sheet() -> ScrollbackDumpSheet {
            ScrollbackDumpSheet(
                presentation: state.scrollbackDump ?? .loading,
                revision: state.scrollbackDumpRevision,
                onDismiss: {}
            )
        }
        let host = NSHostingView(rootView: sheet())
        host.frame = NSRect(x: 0, y: 0, width: 720, height: 600)
        host.layoutSubtreeIfNeeded()
        let first = try #require(SidebarHostedTestHarness.firstDescendant(of: NSTextView.self, in: host))
        #expect(first.string == "first history")
        first.setSelectedRange(NSRange(location: 2, length: 3))

        host.rootView = sheet()
        host.layoutSubtreeIfNeeded()
        let unchanged = try #require(SidebarHostedTestHarness.firstDescendant(of: NSTextView.self, in: host))
        #expect(unchanged === first)
        #expect(unchanged.selectedRange() == NSRange(location: 2, length: 3))

        state.dismissScrollbackDump()
        let nextRequest = try #require(state.beginScrollbackDump())
        state.finishScrollbackDump(.loaded(text: "second history"), request: nextRequest)
        host.rootView = sheet()
        host.layoutSubtreeIfNeeded()
        let replacement = try #require(SidebarHostedTestHarness.firstDescendant(of: NSTextView.self, in: host))
        #expect(replacement !== first)
        #expect(replacement.string == "second history")
    }
}
