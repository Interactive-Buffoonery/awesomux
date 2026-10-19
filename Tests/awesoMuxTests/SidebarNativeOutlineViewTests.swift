import AppKit
import SwiftUI
import Testing
@testable import awesoMux

@Suite("Native sidebar outline")
@MainActor
struct SidebarNativeOutlineViewTests {

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

    @Test(arguments: ["matching", "missing expected", "wrong workspace", "wrong drag", "group", "empty"])
    func workspaceDragPayload(scenario: String) throws {
        let workspace = UUID(), drag = UUID()
        let item = WorkspaceDragItem(sessionID: workspace, dragID: drag)
        let data: Data
        switch scenario {
        case "group": data = try JSONEncoder().encode(WorkspaceGroupDragItem(groupID: UUID(), dragID: drag))
        case "empty": data = Data()
        default: data = try JSONEncoder().encode(item)
        }
        let expected: WorkspaceDragItem?
        switch scenario {
        case "missing expected": expected = nil
        case "wrong workspace": expected = WorkspaceDragItem(sessionID: UUID(), dragID: drag)
        case "wrong drag": expected = WorkspaceDragItem(sessionID: workspace, dragID: UUID())
        default: expected = item
        }
        #expect(SidebarNativeOutlineView.externalWorkspaceID(data: data, expected: expected) == (scenario == "matching" ? workspace : nil))
        let lowerLevel = WorkspaceDragItem(data: data, expectedDragID: scenario == "wrong drag" ? UUID() : drag)
        #expect(lowerLevel?.sessionID == (["wrong drag", "group", "empty"].contains(scenario) ? nil : workspace))
    }

    @Test(arguments: [false, true])
    func rowAccessibilityActions(virtual: Bool) {
        final class VirtualElement: NSObject {
            var performed: (() -> Bool)?
            @objc func accessibilityCustomActions() -> [NSAccessibilityCustomAction] {
                [NSAccessibilityCustomAction(name: "Rename Workspace") { self.performed?() ?? false }]
            }
        }
        let row = SidebarNativeOutlineView.HostedRow()
        let child = NSView()
        var performed = false
        let handler = {
            performed = true; return true
        }
        let element = VirtualElement()
        if virtual {
            #expect(!(element is any NSAccessibilityProtocol))
            element.performed = handler
            child.setAccessibilityChildren([element])
        } else {
            child.setAccessibilityCustomActions([NSAccessibilityCustomAction(name: "Rename Workspace", handler: handler)])
        }
        row.addSubview(child)
        let action = row.accessibilityCustomActions()?.first
        #expect(action?.name == "Rename Workspace")
        #expect(action?.handler?() == true)
        #expect(performed)
    }

    @Test func internalMoveSourcesCannotBecomeTerminalText() {
        #expect(GhosttySurfaceNSView.isInternalMoveSource(SidebarWorkspaceDragSource.DragSourceView()))
        #expect(GhosttySurfaceNSView.isInternalMoveSource(SidebarNativeOutlineView.Outline()))
        #expect(GhosttySurfaceNSView.isInternalMoveSource(PaneDragSource.DragSourceView()))
        #expect(!GhosttySurfaceNSView.isInternalMoveSource(nil))
        #expect(!GhosttySurfaceNSView.isInternalMoveSource(NSView()))
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

    @Test(arguments: ["removed", "late hidden", "new drag"])
    func dragEndCleanup(scenario: String) async {
        let coordinator = SidebarNativeOutlineView.Coordinator()
        let id = UUID()
        var ended = false
        coordinator.latest = SidebarNativeOutlineView(
            groups: scenario == "removed" ? [] : [.init(id: id, name: "group", workspaces: [])],
            collapsedIDs: [id], selectedID: nil, select: { _ in }, collapse: { _, _ in },
            moveWorkspace: { _, _, _ in }, moveGroup: { _, _ in }, dragActivityChanged: { ended = $0 == nil })
        let outline = NSOutlineView()
        if scenario != "removed" {
            let column = NSTableColumn(identifier: .init("group"))
            outline.addTableColumn(column)
            outline.outlineTableColumn = column
            outline.dataSource = coordinator
            outline.delegate = coordinator
            coordinator.outline = outline
            coordinator.applyLatest()
            coordinator.source = coordinator.outlineView(outline, child: 0, ofItem: nil) as? SidebarNativeOutlineView.Node
        }
        coordinator.dragActivity.kind = .group
        coordinator.finishDrag()
        if scenario == "new drag" { coordinator.source = SidebarNativeOutlineView.Node(.group(UUID())) }
        if scenario != "removed" { outline.hideRows(at: IndexSet(integer: 0), withAnimation: []) }
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        if scenario == "removed" {
            #expect(ended)
            #expect(coordinator.dragActivity.kind == nil)
        }
        if scenario != "removed" {
            #expect(outline.hiddenRowIndexes.contains(0) == (scenario == "new drag"))
            #expect((outline.rect(ofRow: 0).height > 0) == (scenario != "new drag"))
        }
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

    @Test(arguments: [0, 1, 2, -1])
    func groupDropIndex(sourceIndex: Int) {
        if sourceIndex == -1 {
            let first = UUID(), moving = UUID()
            let frames = [first: CGRect(x: 0, y: 0, width: 276, height: 210)]
            #expect(SidebarNativeOutlineView.groupInsertionIndex(y: 90, sourceID: moving, groupIDs: [first, moving], frames: frames) == 0)
            #expect(SidebarNativeOutlineView.groupInsertionIndex(y: 150, sourceID: moving, groupIDs: [first, moving], frames: frames) == 2)
            #expect(SidebarNativeOutlineView.groupInsertionIndex(y: -20, sourceID: moving, groupIDs: [first, moving], frames: frames) == 0)
            return
        }
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
