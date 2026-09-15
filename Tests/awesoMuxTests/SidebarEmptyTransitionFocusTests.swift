import AppKit
import AwesoMuxConfig
import AwesoMuxCore
import SwiftUI
import Testing
@testable import awesoMux

@Suite("Sidebar empty transition focus", .serialized)
@MainActor
struct SidebarEmptyTransitionFocusTests {
    @Test("removing the last group focuses the expanded New Workspace action")
    func lastGroupRemovalFocusesExpandedNewWorkspaceAction() async throws {
        try await assertLastGroupRemovalFocus(width: 320)
    }

    @Test("removing the last group focuses the collapsed New Workspace action")
    func lastGroupRemovalFocusesCollapsedNewWorkspaceAction() async throws {
        try await assertLastGroupRemovalFocus(width: SidebarWidthPolicy.collapsedWidth)
    }

    @Test("Space activates once and ignores repeats, modifiers, and retired targets")
    func spaceActivationGuards() throws {
        let frame = NSRect(x: 0, y: 0, width: 40, height: 40)
        let (window, _) = SidebarHostedTestHarness.makeWindow(rootView: EmptyView(), frame: frame)
        defer { window.close() }
        let target = SidebarNewWorkspaceFocusButton()
        target.frame = frame
        window.contentView?.addSubview(target)
        var activations = 0
        target.update(focusRequestID: 0, focusIsActive: true, onActivate: { activations += 1 })
        #expect(window.makeFirstResponder(target))

        try sendSpaceDirectly(to: target, in: window, isRepeat: true)
        #expect(activations == 0)
        SidebarHostedTestHarness.sendKey(
            to: window,
            keyCode: 49,
            characters: " ",
            isRepeat: true
        )
        #expect(activations == 0)
        for modifier in [NSEvent.ModifierFlags.command, .control, .option, .shift] {
            try sendSpaceDirectly(to: target, in: window, modifiers: modifier)
            #expect(activations == 0)
            SidebarHostedTestHarness.sendKey(
                to: window,
                keyCode: 49,
                characters: " ",
                modifiers: modifier
            )
            #expect(activations == 0)
        }

        SidebarHostedTestHarness.sendKey(to: window, keyCode: 49, characters: " ")
        #expect(activations == 1)
        #expect(window.firstResponder !== target)

        target.dismantle()
        target.onActivate = { activations += 1 }
        #expect(window.makeFirstResponder(target))
        SidebarHostedTestHarness.sendKey(to: window, keyCode: 49, characters: " ")
        #expect(activations == 1)
    }

    private func sendSpaceDirectly(
        to responder: NSResponder,
        in window: NSWindow,
        modifiers: NSEvent.ModifierFlags = [],
        isRepeat: Bool = false
    ) throws {
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: " ",
                charactersIgnoringModifiers: " ",
                isARepeat: isRepeat,
                keyCode: 49
            )
        )
        responder.keyDown(with: event)
    }

    @Test("a cancelled request cannot focus a retiring target")
    func cancelledRequestDoesNotFocusTarget() async {
        let frame = NSRect(x: 0, y: 0, width: 40, height: 40)
        let (window, _) = SidebarHostedTestHarness.makeWindow(
            rootView: EmptyView(),
            frame: frame
        )
        defer { window.close() }
        let target = SidebarNewWorkspaceFocusButton()
        target.frame = frame
        window.contentView?.addSubview(target)

        target.update(focusRequestID: 1, focusIsActive: true, onActivate: {})
        target.update(focusRequestID: 1, focusIsActive: false, onActivate: {})
        for _ in 0..<2 {
            await SidebarHostedTestHarness.drainMainQueue()
        }

        #expect(window.firstResponder !== target)
        #expect(!target.isAccessibilityFocused())

        target.update(focusRequestID: 2, focusIsActive: true, onActivate: {})
        for _ in 0..<2 {
            await SidebarHostedTestHarness.drainMainQueue()
        }
        #expect(window.firstResponder === target)

        target.update(focusRequestID: 2, focusIsActive: false, onActivate: {})
        #expect(window.firstResponder === window)
        #expect(!target.isAccessibilityFocused())

        target.update(focusRequestID: 3, focusIsActive: true, onActivate: {})
        for _ in 0..<2 {
            await SidebarHostedTestHarness.drainMainQueue()
        }
        #expect(window.firstResponder === target)

        target.dismantle()
        #expect(window.firstResponder === window)
        #expect(!target.isAccessibilityFocused())
    }

    private func assertLastGroupRemovalFocus(width: CGFloat) async throws {
        let group = SessionGroup(name: "Project", sessions: [])
        let fixture = SidebarEmptyTransitionFocusFixture(groups: [group], width: width)
        defer { fixture.close() }

        #expect(fixture.store.removeGroup(id: group.id))
        #expect(fixture.store.groups.isEmpty)

        let target = try #require(await fixture.focusedNewWorkspaceButton())
        #expect(target.accessibilityRole() == .button)
        #expect(target.accessibilityLabel() == "New Workspace")
        #expect(target.isAccessibilityFocused())
        let expectedSize: CGFloat = width == SidebarWidthPolicy.collapsedWidth ? 40 : 30
        #expect(abs(target.bounds.width - expectedSize) < 0.5)
        #expect(abs(target.bounds.height - expectedSize) < 0.5)

        fixture.pressSpace()
        #expect(SidebarHostedTestHarness.pumpMainRunLoop(until: { fixture.store.groups.count == 1 }))
        for _ in 0..<2 {
            await SidebarHostedTestHarness.drainMainQueue()
        }
        #expect(!fixture.isFirstResponder(target))
        #expect(!target.isAccessibilityFocused())
    }
}

@MainActor
private struct SidebarEmptyTransitionFocusFixture {
    let store: SessionStore
    private let window: NSWindow

    init(groups: [SessionGroup], width: CGFloat) {
        store = SessionStore(groups: groups, selectedSessionID: nil, pinnedSessionIDs: [])
        let runtime = GhosttyRuntime()
        let settings = AppSettingsStore(legacySnapshotProvider: { nil })
        let liveWidth = SidebarLiveWidth(value: width)

        let sidebarRoot = SidebarView(
            sessionStore: store,
            ghosttyRuntime: runtime,
            workspacesWithBackgroundedFloatingWork: [],
            promotedSessionID: nil,
            promotionPulseSessionID: nil,
            onCloseWorkspace: { _ in },
            onClearWorkspace: { _ in },
            onCloseWorkspaceGroup: { _ in },
            onRenameWorkspace: { _ in },
            onRenameWorkspaceGroup: { _ in },
            onNewWorkspaceGroup: {},
            onConnectViaSSH: { _ in },
            canMakeWorkspaceManaged: { _ in false },
            onMakeWorkspaceManaged: { _ in },
            onOpenQuickSettings: {},
            onShowWelcomeTour: {},
            onToggleCommandPalette: {},
            onFocusPane: { _, _ in },
            focusRequestID: nil,
            sidebarLiveWidth: liveWidth,
            resampleSidebarPointer: { nil },
            onSidebarHover: { _ in }
        )
        .environment(settings)
        .environment(UpdateController())
        .environment(SidebarPeekModel())
        .appearanceBridge(settings)

        let (window, _) = SidebarHostedTestHarness.makeWindow(
            rootView: AnyView(sidebarRoot),
            frame: NSRect(x: 0, y: 0, width: width, height: 260)
        )
        self.window = window
    }

    func focusedNewWorkspaceButton() async -> SidebarNewWorkspaceFocusButton? {
        for _ in 0..<3 {
            await SidebarHostedTestHarness.drainMainQueue()
        }
        guard let contentView = window.contentView,
            let target = SidebarHostedTestHarness.firstDescendant(
                of: SidebarNewWorkspaceFocusButton.self,
                in: contentView
            )
        else { return nil }
        return window.firstResponder === target ? target : nil
    }

    func pressSpace() {
        SidebarHostedTestHarness.sendKey(to: window, keyCode: 49, characters: " ")
    }

    func isFirstResponder(_ responder: NSResponder) -> Bool {
        window.firstResponder === responder
    }

    func close() {
        window.close()
    }
}
