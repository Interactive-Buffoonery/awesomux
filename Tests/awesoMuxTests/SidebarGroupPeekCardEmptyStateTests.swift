import AppKit
import AwesoMuxCore
import SwiftUI
import Testing

@testable import awesoMux

/// Covers the empty-group peek card's create action (#279). The debounce here
/// is a copy of `NewWorkspaceSplitButton`'s, which is covered by
/// `NewWorkspaceSplitButtonHitTargetTests` — this is the same coverage for the
/// second copy, since a guard that silently stops guarding looks identical to
/// one that works.
///
/// `singleClickCreatesExactlyOneWorkspace` is a positive control, not padding:
/// it shares `createRowPoint` with the debounce test, so if that point ever
/// stops landing on the button (a spacing change, a font metric shift), the
/// control fails loudly instead of the debounce test passing because nothing
/// was ever clicked.
@Suite(.serialized)
@MainActor
struct SidebarGroupPeekCardEmptyStateTests {
    @Test("a single click on the empty-state row creates exactly one workspace")
    func singleClickCreatesExactlyOneWorkspace() {
        let counter = CreateCounter()
        let window = Self.makeWindow(onNewWorkspace: counter.increment)
        defer { window.close() }

        SidebarHostedTestHarness.sendClick(to: window, at: Self.createRowPoint)
        #expect(SidebarHostedTestHarness.pumpMainRunLoop(until: { counter.count >= 1 }))
        SidebarHostedTestHarness.settleMainRunLoop()

        #expect(counter.count == 1)
    }

    @Test("two rapid clicks on the empty-state row create only one workspace")
    func rapidDoubleClickIsDebouncedToOne() {
        let counter = CreateCounter()
        let window = Self.makeWindow(onNewWorkspace: counter.increment)
        defer { window.close() }

        // Back to back, well inside the 400ms guard. The card stays hittable
        // through its removal transition after the first click hides it, so
        // without the guard the second click reaches the button too.
        SidebarHostedTestHarness.sendClick(to: window, at: Self.createRowPoint)
        SidebarHostedTestHarness.sendClick(to: window, at: Self.createRowPoint)
        #expect(SidebarHostedTestHarness.pumpMainRunLoop(until: { counter.count >= 1 }))
        SidebarHostedTestHarness.settleMainRunLoop()

        #expect(counter.count == 1)
    }

    @Test("a group whose workspaces are all pinned out offers no create action")
    func allPinnedGroupHasNoCreateAction() {
        let counter = CreateCounter()
        // Non-empty roster with an empty pin-filtered projection — the "All
        // pinned" state. It must render no button, so the same click that
        // creates a workspace above must do nothing here.
        let window = Self.makeWindow(
            onNewWorkspace: counter.increment,
            groupSessions: [
                TerminalSession(title: "pinned", workingDirectory: "~")
            ]
        )
        defer { window.close() }

        SidebarHostedTestHarness.sendClick(to: window, at: Self.createRowPoint)
        SidebarHostedTestHarness.settleMainRunLoop()

        #expect(counter.count == 0)
    }

    /// The create row is the last element in the card's `VStack`, and the card
    /// carries `.padding(12)`. In AppKit's bottom-left window space that puts
    /// the row's 24pt band between y=12 and y=36, so y=24 is its vertical
    /// centre. The window is sized to the card's fitting height so there is no
    /// slack for SwiftUI to redistribute — same approach as
    /// `NewWorkspaceSplitButtonHitTargetTests.primarySegmentPoint`.
    private static let createRowPoint = CGPoint(x: SidebarPeekMetrics.cardWidth / 2, y: 24)

    private static func makeWindow(
        onNewWorkspace: @escaping () -> Void,
        groupSessions: [TerminalSession] = []
    ) -> NSWindow {
        let group = SessionGroup(name: "Empty group", sessions: groupSessions)
        let card = SidebarGroupPeekCard(
            group: group,
            tint: ProjectTint(groupName: group.name, color: .teal, index: 0),
            items: [],
            onSelectSession: { _ in },
            onNewWorkspace: onNewWorkspace,
            onHoverChanged: { _ in }
        )
        .frame(width: SidebarPeekMetrics.cardWidth)

        // Measure, then rebuild at the measured height: the card sizes itself
        // from its content, and guessing the height would move the create row
        // out from under `createRowPoint`.
        let probe = SidebarHostedTestHarness.makeWindow(
            rootView: card,
            frame: NSRect(x: 0, y: 0, width: SidebarPeekMetrics.cardWidth, height: 400)
        )
        let fittingHeight = probe.hostingView.fittingSize.height
        probe.window.close()

        let hosted = SidebarHostedTestHarness.makeWindow(
            rootView: card,
            frame: NSRect(
                x: 0,
                y: 0,
                width: SidebarPeekMetrics.cardWidth,
                height: fittingHeight
            )
        )
        return hosted.window
    }
}

private final class CreateCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}
