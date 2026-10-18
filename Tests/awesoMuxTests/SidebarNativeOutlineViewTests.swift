import AppKit
import SwiftUI
import Testing
@testable import awesoMux

@Suite("Native sidebar outline")
@MainActor
struct SidebarNativeOutlineViewTests {
    @Test func hostedRowsReceiveNativeOverridesAfterTheInheritedEnvironment() {
        struct Probe: View {
            @Environment(\.isNativeSidebarRow) var native
            @Environment(SidebarNativeDragActivity.self) var activity: SidebarNativeDragActivity?
            var read: (Bool, SidebarNativeDragActivity?) -> Void
            var body: some View {
                let _ = read(native, activity)
                Color.clear.frame(height: 40)
            }
        }
        _ = NSApplication.shared
        let coordinator = SidebarNativeOutlineView.Coordinator()
        let outline = NSOutlineView()
        outline.addTableColumn(NSTableColumn(identifier: .init("test")))
        outline.dataSource = coordinator
        coordinator.outline = outline
        var native: Bool?, activity: SidebarNativeDragActivity?
        coordinator.latest = SidebarNativeOutlineView(
            groups: [.init(id: UUID(), name: "group", workspaces: [])],
            collapsedIDs: [], selectedID: nil, select: { _ in }, collapse: { _, _ in },
            moveWorkspace: { _, _, _ in }, moveGroup: { _, _ in },
            content: { _ in
                AnyView(
                    Probe {
                        native = $0; activity = $1
                    })
            }
        )
        coordinator.applyLatest()
        #expect(native == true)
        #expect(activity === coordinator.dragActivity)
    }

    @Test func keyboardSelectionDoesNotActivateTheTerminal() {
        _ = NSApplication.shared
        let group = UUID(), workspace = UUID()
        var activated: [UUID] = [], selected: [UUID] = []
        let coordinator = SidebarNativeOutlineView.Coordinator()
        let outline = NSOutlineView()
        outline.addTableColumn(NSTableColumn(identifier: .init("test")))
        outline.dataSource = coordinator
        coordinator.outline = outline
        coordinator.latest = SidebarNativeOutlineView(
            groups: [.init(id: group, name: "group", workspaces: [.init(id: workspace, title: "shell", path: "~")])],
            collapsedIDs: [], selectedID: nil, select: { activated.append($0) }, collapse: { _, _ in },
            moveWorkspace: { _, _, _ in }, moveGroup: { _, _ in }, keyboardSelect: { selected.append($0) }
        )
        coordinator.applyLatest()
        outline.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        coordinator.outlineViewSelectionDidChange(Notification(name: NSOutlineView.selectionDidChangeNotification))
        #expect(selected == [workspace])
        #expect(activated.isEmpty)
    }

    @Test func liftedWorkspacePayloadMustMatchTheActiveDrag() throws {
        let workspace = UUID(), drag = UUID()
        let item = WorkspaceDragItem(sessionID: workspace, dragID: drag)
        #expect(SidebarNativeOutlineView.externalWorkspaceID(data: try JSONEncoder().encode(item), expected: item) == workspace)
        #expect(SidebarNativeOutlineView.externalWorkspaceID(data: try JSONEncoder().encode(item), expected: nil) == nil)
        #expect(
            SidebarNativeOutlineView.externalWorkspaceID(
                data: try JSONEncoder().encode(item), expected: .init(sessionID: UUID(), dragID: drag)) == nil)
        #expect(
            SidebarNativeOutlineView.externalWorkspaceID(
                data: try JSONEncoder().encode(item), expected: .init(sessionID: workspace, dragID: UUID())) == nil)
    }

    @Test func nativeRowForwardsHostedAccessibilityActions() {
        let row = SidebarNativeOutlineView.HostedRow()
        let child = NSView()
        var performed = false
        child.setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: "Rename Workspace") {
                performed = true; return true
            }
        ])
        row.addSubview(child)
        let action = row.accessibilityCustomActions()?.first
        #expect(action?.name == "Rename Workspace")
        #expect(action?.handler?() == true)
        #expect(performed)
    }

    @Test func collapsedGroupsDoNotBuildTheirWorkspaceViews() throws {
        _ = NSApplication.shared
        let group = UUID()
        var constructed: [SidebarNativeOutlineView.Key] = []
        let coordinator = SidebarNativeOutlineView.Coordinator()
        let outline = NSOutlineView()
        outline.addTableColumn(NSTableColumn(identifier: .init("test")))
        outline.dataSource = coordinator
        coordinator.outline = outline
        coordinator.latest = SidebarNativeOutlineView(
            groups: [.init(id: group, name: "group", workspaces: (0..<40).map { _ in .init(id: UUID(), title: "shell", path: "~") })],
            collapsedIDs: [group], selectedID: nil, select: { _ in }, collapse: { _, _ in },
            moveWorkspace: { _, _, _ in }, moveGroup: { _, _ in },
            content: { key in
                constructed.append(key); return AnyView(Color.red.frame(height: 40))
            }
        )
        coordinator.applyLatest()
        #expect(constructed == [.group(group)])
        constructed.removeAll()
        let node = try #require(coordinator.outlineView(outline, child: 0, ofItem: nil) as? SidebarNativeOutlineView.Node)
        let preview = try #require(coordinator.groupDragImage(for: node))
        #expect(constructed.count == 4)
        #expect(preview.size.height == 112)

    }

    @Test func hostedPeekFramesUseTheWindowRootAndTrackScrolling() {
        final class FlippedView: NSView { override var isFlipped: Bool { true } }
        let root = FlippedView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let clip = NSClipView(frame: NSRect(x: 0, y: 80, width: 300, height: 200))
        let document = FlippedView(frame: NSRect(x: 0, y: 0, width: 300, height: 1000))
        let row = FlippedView(frame: NSRect(x: 0, y: 400, width: 300, height: 50))
        root.addSubview(clip); clip.documentView = document; document.addSubview(row)
        let before = SidebarRowGeometry.Anchor.frameInRoot(row, root: root)
        clip.setBoundsOrigin(NSPoint(x: 0, y: 100))
        let after = SidebarRowGeometry.Anchor.frameInRoot(row, root: root)
        #expect(before.origin.y == 480)
        #expect(after.origin.y == 380)
        #expect(after.size == row.bounds.size)
    }

    @Test func internalMoveSourcesCannotBecomeTerminalText() {
        #expect(GhosttySurfaceNSView.isInternalMoveSource(SidebarWorkspaceDragSource.DragSourceView()))
        #expect(GhosttySurfaceNSView.isInternalMoveSource(SidebarNativeOutlineView.Outline()))
        #expect(GhosttySurfaceNSView.isInternalMoveSource(PaneDragSource.DragSourceView()))
        #expect(!GhosttySurfaceNSView.isInternalMoveSource(nil))
        #expect(!GhosttySurfaceNSView.isInternalMoveSource(NSView()))
    }

    @Test func nativeDragAutoscrollReachesTheOverflowingOuterViewport() throws {
        final class OuterScroll: NSScrollView {
            var scrolled = false
            override func autoscroll(with event: NSEvent) -> Bool { scrolled = true; return true }
        }
        let outer = OuterScroll(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 1000))
        outer.documentView = document
        let inner = NSScrollView(frame: document.bounds)
        document.addSubview(inner)
        let outline = SidebarNativeOutlineView.Outline(frame: document.bounds)
        inner.documentView = outline
        let event = try #require(
            NSEvent.mouseEvent(
                with: .leftMouseDragged, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
                clickCount: 1, pressure: 1))
        #expect(outline.autoscroll(with: event))
        #expect(outer.scrolled)
    }

    @Test func nativeKeyboardRevealReachesTheOverflowingOuterViewport() {
        final class Document: NSView {
            var revealed: NSRect?
            override func scrollToVisible(_ rect: NSRect) -> Bool { revealed = rect; return true }
        }
        let outer = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let document = Document(frame: NSRect(x: 0, y: 0, width: 300, height: 1000))
        outer.documentView = document
        let inner = NSScrollView(frame: document.bounds)
        document.addSubview(inner)
        let outline = SidebarNativeOutlineView.Outline(frame: document.bounds)
        inner.documentView = outline
        let target = NSRect(x: 0, y: 900, width: 300, height: 40)
        #expect(outline.scrollToVisible(target))
        #expect(document.revealed == outline.convert(target, to: document))
    }

    @Test(arguments: [true, false])
    func keyboardTargetChangesRevealTheRowInTheOuterDocument(initiallyAttached: Bool) {
        final class Document: NSView {
            var revealed: [NSRect] = []
            override func scrollToVisible(_ rect: NSRect) -> Bool { revealed.append(rect); return true }
        }
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: .borderless, backing: .buffered, defer: false)
        let group = UUID(), workspace = UUID()
        let coordinator = SidebarNativeOutlineView.Coordinator()
        let outline = SidebarNativeOutlineView.Outline()
        outline.addTableColumn(NSTableColumn(identifier: .init("test")))
        outline.dragCoordinator = coordinator
        outline.dataSource = coordinator
        outline.delegate = coordinator
        let document = Document(frame: NSRect(x: 0, y: 0, width: 300, height: 1000))
        let scroll = NSScrollView(frame: document.bounds)
        if initiallyAttached { document.addSubview(scroll) }
        scroll.documentView = outline
        coordinator.outline = outline
        coordinator.latest = SidebarNativeOutlineView(
            groups: [.init(id: group, name: "group", workspaces: [.init(id: workspace, title: "shell", path: "~")])],
            collapsedIDs: [], selectedID: workspace, select: { _ in }, collapse: { _, _ in },
            moveWorkspace: { _, _, _ in }, moveGroup: { _, _ in }
        )
        coordinator.applyLatest()
        #expect(document.revealed.isEmpty)
        coordinator.latest?.keyboardFocusedKey = .workspace(workspace)
        coordinator.applyLatest()
        if !initiallyAttached {
            #expect(document.revealed.isEmpty)
            document.addSubview(scroll)
            window.contentView = document
        }
        #expect(document.revealed.count == 1)
        coordinator.applyLatest()
        #expect(document.revealed.count == 1)
        coordinator.latest?.keyboardFocusedKey = .group(group)
        coordinator.applyLatest()
        #expect(document.revealed.count == 2)
        #expect(document.revealed.last == outline.convert(outline.rect(ofRow: 0), to: document))
        coordinator.latest?.keyboardFocusedKey = .workspace(UUID())
        coordinator.applyLatest()
        coordinator.latest?.keyboardFocusedKey = .group(group)
        coordinator.applyLatest()
        #expect(document.revealed.count == 3)
    }

    @Test func nativeExpansionRequestsStyledChildrenBeforeTheModelUpdates() throws {
        _ = NSApplication.shared
        let group = UUID(), workspace = UUID()
        let coordinator = SidebarNativeOutlineView.Coordinator()
        let outline = NSOutlineView()
        outline.addTableColumn(NSTableColumn(identifier: .init("test")))
        outline.dataSource = coordinator
        coordinator.outline = outline
        coordinator.latest = SidebarNativeOutlineView(
            groups: [.init(id: group, name: "group", workspaces: [.init(id: workspace, title: "shell", path: "~")])],
            collapsedIDs: [group], selectedID: nil, select: { _ in }, collapse: { _, _ in },
            moveWorkspace: { _, _, _ in }, moveGroup: { _, _ in },
            rowSpacing: 3, content: { _ in AnyView(Color.red.frame(height: 40)) }
        )
        coordinator.applyLatest()
        #expect(outline.intercellSpacing.height == 3)
        let parent = try #require(coordinator.outlineView(outline, child: 0, ofItem: nil) as? SidebarNativeOutlineView.Node)
        let child = try #require(coordinator.outlineView(outline, child: 0, ofItem: parent) as? SidebarNativeOutlineView.Node)
        #expect(coordinator.outlineView(outline, heightOfRowByItem: child) == 40)
        #expect(coordinator.outlineView(outline, viewFor: nil, item: child) is SidebarNativeOutlineView.HostedCell)
    }

    @Test func hostedVirtualAccessibilityElementsNeedNotDeclareTheFullProtocol() {
        final class VirtualElement: NSObject {
            @objc func accessibilityCustomActions() -> [NSAccessibilityCustomAction] {
                [NSAccessibilityCustomAction(name: "Rename Workspace") { true }]
            }
        }
        let element = VirtualElement()
        #expect(!(element is any NSAccessibilityProtocol))
        let child = NSView()
        child.setAccessibilityChildren([element])
        let row = SidebarNativeOutlineView.HostedRow()
        row.addSubview(child)
        #expect(row.accessibilityCustomActions()?.map(\.name) == ["Rename Workspace"])
    }

    @Test func dragEndClearsPresentationAfterTheOutlineIsRemoved() async {
        let coordinator = SidebarNativeOutlineView.Coordinator()
        var ended = false
        coordinator.latest = SidebarNativeOutlineView(
            groups: [], collapsedIDs: [], selectedID: nil, select: { _ in }, collapse: { _, _ in },
            moveWorkspace: { _, _, _ in }, moveGroup: { _, _ in },
            dragActivityChanged: { ended = $0 == nil }
        )
        coordinator.dragActivity.kind = .group
        coordinator.finishDrag()
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        #expect(ended)
        #expect(coordinator.dragActivity.kind == nil)
    }

    @Test func hostedHeaderCollapseActuallyRemovesNativeChildRows() {
        _ = NSApplication.shared
        let group = UUID(), workspace = UUID()
        let coordinator = SidebarNativeOutlineView.Coordinator()
        let outline = SidebarNativeOutlineView.Outline()
        outline.hostsStyledRows = true
        let column = NSTableColumn(identifier: .init("group"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.dataSource = coordinator
        outline.delegate = coordinator
        coordinator.outline = outline
        var model = SidebarNativeOutlineView(
            groups: [.init(id: group, name: "group", workspaces: [.init(id: workspace, title: "shell", path: "~")])],
            collapsedIDs: [], selectedID: workspace, select: { _ in }, collapse: { _, _ in },
            moveWorkspace: { _, _, _ in }, moveGroup: { _, _ in },
            content: { _ in AnyView(Color.red.frame(height: 40)) }
        )
        coordinator.latest = model
        coordinator.applyLatest()
        #expect(outline.numberOfRows == 3)
        let footer = outline.item(atRow: 2)
        #expect(coordinator.outlineView(outline, pasteboardWriterForItem: footer) == nil)
        model = SidebarNativeOutlineView(
            groups: model.groups, collapsedIDs: [group], selectedID: workspace,
            select: { _ in }, collapse: { _, _ in }, moveWorkspace: { _, _, _ in }, moveGroup: { _, _ in },
            content: model.content
        )
        coordinator.latest = model
        coordinator.applyLatest()
        #expect(outline.numberOfRows == 1)
    }

    @Test func hostedRowsSupplyAWholeRowNativeDragImage() throws {
        _ = NSApplication.shared
        let cell = SidebarNativeOutlineView.HostedCell(root: AnyView(Color.red.frame(width: 200, height: 50)))
        cell.frame = CGRect(x: 0, y: 0, width: 200, height: 50)
        cell.layoutSubtreeIfNeeded()
        let components = cell.draggingImageComponents
        #expect(components.count == 1)
        let component = try #require(components.first)
        #expect(component.contents is NSImage)
        #expect(component.frame.size == cell.bounds.size)
    }

    @Test func activeWorkspaceClicksStillActivateAndHeaderClicksToggleOnce() throws {
        _ = NSApplication.shared
        let group = UUID(), workspace = UUID()
        var activations = 0
        var toggles: [Bool] = []
        var focusedGroups: [UUID] = []
        let coordinator = SidebarNativeOutlineView.Coordinator()
        let outline = NSOutlineView()
        let column = NSTableColumn(identifier: .init("group"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.dataSource = coordinator
        outline.delegate = coordinator
        coordinator.outline = outline
        coordinator.latest = SidebarNativeOutlineView(
            groups: [.init(id: group, name: "group", workspaces: [.init(id: workspace, title: "shell", path: "~")])],
            collapsedIDs: [], selectedID: workspace,
            select: { _ in activations += 1 }, collapse: { _, value in toggles.append(value) },
            moveWorkspace: { _, _, _ in }, moveGroup: { _, _ in },
            activateGroup: { focusedGroups.append($0) }
        )
        coordinator.applyLatest()
        let parent = try #require(coordinator.outlineView(outline, child: 0, ofItem: nil) as? SidebarNativeOutlineView.Node)
        let child = try #require(coordinator.outlineView(outline, child: 0, ofItem: parent) as? SidebarNativeOutlineView.Node)
        coordinator.activate(child)
        coordinator.activate(child)
        coordinator.activate(parent)
        #expect(activations == 2)
        #expect(toggles == [true])
        #expect(focusedGroups == [group])
    }

    @Test func hostedControlsAndMenusKeepInputWhileRowDragsStayNative() {
        typealias Cell = SidebarNativeOutlineView.HostedCell
        #expect(!Cell.routesPointerToContent(x: 100, width: 276, eventType: .leftMouseDown, modifiers: []))
        #expect(Cell.routesPointerToContent(x: 243, width: 276, eventType: .leftMouseDown, modifiers: []))
        #expect(Cell.routesPointerToContent(x: 270, width: 276, eventType: .leftMouseDown, modifiers: []))
        #expect(Cell.routesPointerToContent(x: 100, width: 276, eventType: .rightMouseDown, modifiers: []))
        #expect(Cell.routesPointerToContent(x: 100, width: 276, eventType: .leftMouseDown, modifiers: [.control]))
    }

    @Test(arguments: [false, true])
    func nativeEndCleanupRestoresLateHiddenRowsUnlessAnotherDragStarted(startsNewDrag: Bool) async {
        _ = NSApplication.shared
        let id = UUID()
        let coordinator = SidebarNativeOutlineView.Coordinator()
        let outline = NSOutlineView()
        let column = NSTableColumn(identifier: .init("group"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.dataSource = coordinator
        outline.delegate = coordinator
        coordinator.outline = outline
        coordinator.latest = SidebarNativeOutlineView(
            groups: [.init(id: id, name: "group", workspaces: [])],
            collapsedIDs: [id], selectedID: nil, select: { _ in }, collapse: { _, _ in },
            moveWorkspace: { _, _, _ in }, moveGroup: { _, _ in }
        )
        coordinator.applyLatest()
        coordinator.source = coordinator.outlineView(outline, child: 0, ofItem: nil) as? SidebarNativeOutlineView.Node
        coordinator.finishDrag()
        if startsNewDrag { coordinator.source = SidebarNativeOutlineView.Node(.group(UUID())) }
        // AppKit can finish its gap-row bookkeeping after invoking the source callback.
        outline.hideRows(at: IndexSet(integer: 0), withAnimation: [])
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(outline.hiddenRowIndexes.contains(0) == startsNewDrag)
        #expect((outline.rect(ofRow: 0).height > 0) == !startsNewDrag)
    }

    @Test(arguments: [0, 1, 2])
    func groupTargetsKeepPreRemovalIndicesWithDifferentBlockHeights(sourceIndex: Int) {
        let ids = [UUID(), UUID(), UUID()]
        let source = ids[sourceIndex]
        let destinations = ids.filter { $0 != source }
        let frames = [
            destinations[0]: CGRect(x: 0, y: 0, width: 276, height: 90),
            destinations[1]: CGRect(x: 0, y: 95, width: 276, height: 205),
        ]
        #expect(
            SidebarNativeOutlineView.groupInsertionIndex(y: 45, sourceID: source, groupIDs: ids, frames: frames)
                == ids.firstIndex(of: destinations[0]))
        #expect(
            SidebarNativeOutlineView.groupInsertionIndex(y: 46, sourceID: source, groupIDs: ids, frames: frames)
                == ids.firstIndex(of: destinations[1]))
        #expect(SidebarNativeOutlineView.groupInsertionIndex(y: 250, sourceID: source, groupIDs: ids, frames: frames) == 3)
        #expect(SidebarNativeOutlineView.groupInsertionIndex(y: 10, sourceID: source, groupIDs: ids, frames: [:]) == nil)
    }

    @Test func upwardGroupDropUsesTheWholeDestinationBlock() {
        let first = UUID(), moving = UUID()
        let frames = [first: CGRect(x: 0, y: 0, width: 276, height: 210)]
        #expect(SidebarNativeOutlineView.groupInsertionIndex(y: 90, sourceID: moving, groupIDs: [first, moving], frames: frames) == 0)
        #expect(SidebarNativeOutlineView.groupInsertionIndex(y: 150, sourceID: moving, groupIDs: [first, moving], frames: frames) == 2)
        #expect(SidebarNativeOutlineView.groupInsertionIndex(y: -20, sourceID: moving, groupIDs: [first, moving], frames: frames) == 0)
    }

    @Test func reloadPreservesNodeIdentityAcrossGroupAndWorkspaceMoves() throws {
        _ = NSApplication.shared
        let first = UUID(), second = UUID(), workspace = UUID()
        let row = SidebarNativeOutlineView.Workspace(id: workspace, title: "shell", path: "~")
        func probe(_ groups: [SidebarNativeOutlineView.Group]) -> SidebarNativeOutlineView {
            SidebarNativeOutlineView(
                groups: groups, collapsedIDs: [], selectedID: nil,
                select: { _ in }, collapse: { _, _ in }, moveWorkspace: { _, _, _ in }, moveGroup: { _, _ in }
            )
        }
        let coordinator = SidebarNativeOutlineView.Coordinator()
        let outline = NSOutlineView()
        let column = NSTableColumn(identifier: .init("workspace"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.dataSource = coordinator
        outline.delegate = coordinator
        coordinator.outline = outline
        coordinator.latest = probe([
            .init(id: first, name: "first", workspaces: [row]),
            .init(id: second, name: "empty", workspaces: []),
        ])
        coordinator.applyLatest()
        let oldFirst = try #require(coordinator.outlineView(outline, child: 0, ofItem: nil) as? SidebarNativeOutlineView.Node)
        let oldWorkspace = try #require(coordinator.outlineView(outline, child: 0, ofItem: oldFirst) as? SidebarNativeOutlineView.Node)
        #expect(coordinator.outlineView(outline, objectValueFor: column, byItem: oldFirst) as? String == "FIRST")
        #expect(coordinator.outlineView(outline, numberOfChildrenOfItem: nil) == 2)
        #expect(coordinator.outlineView(outline, isItemExpandable: oldFirst))
        #expect(!coordinator.outlineView(outline, isItemExpandable: oldWorkspace))
        coordinator.latest = probe([
            .init(id: second, name: "destination", workspaces: [row]),
            .init(id: first, name: "now empty", workspaces: []),
        ])
        coordinator.applyLatest()
        let newFirst = try #require(coordinator.outlineView(outline, child: 0, ofItem: nil) as? SidebarNativeOutlineView.Node)
        #expect(coordinator.outlineView(outline, child: 1, ofItem: nil) as? SidebarNativeOutlineView.Node === oldFirst)
        #expect(coordinator.outlineView(outline, child: 0, ofItem: newFirst) as? SidebarNativeOutlineView.Node === oldWorkspace)
        #expect(coordinator.outlineView(outline, numberOfChildrenOfItem: oldFirst) == 0)
        #expect(coordinator.outlineView(outline, objectValueFor: column, byItem: oldFirst) as? String == "NOW EMPTY")
        #expect(SidebarNativeOutlineView.Key.group(first).payload != SidebarNativeOutlineView.Key.workspace(first).payload)
    }
}
