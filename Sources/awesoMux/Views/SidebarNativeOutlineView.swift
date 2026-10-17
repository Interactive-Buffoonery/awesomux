import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
final class SidebarNativeDragActivity {
    var kind: SidebarDragKind?
}

/// Hosts existing sidebar rows while AppKit owns hierarchy layout and drag feedback.
struct SidebarNativeOutlineView: NSViewRepresentable {
    static func groupInsertionIndex(y: CGFloat, sourceID: UUID, groupIDs: [UUID], frames: [UUID: CGRect]) -> Int? {
        guard groupIDs.contains(sourceID), groupIDs.filter({ $0 != sourceID }).allSatisfy({ (frames[$0]?.height ?? 0) > 0 }) else {
            return nil
        }
        for (index, id) in groupIDs.enumerated() where id != sourceID {
            if y <= frames[id]!.midY { return index }
        }
        return groupIDs.count
    }

    static func externalWorkspaceID(data: Data?, expected: WorkspaceDragItem?) -> UUID? {
        guard let data, let expected,
            let item = WorkspaceDragItem(data: data, expectedDragID: expected.dragID), item.sessionID == expected.sessionID
        else { return nil }
        return item.sessionID
    }

    struct Workspace: Equatable {
        let id: UUID
        let title: String
        let path: String
    }
    struct Group: Equatable {
        let id: UUID
        let name: String
        let workspaces: [Workspace]
    }
    let groups: [Group]
    let collapsedIDs: Set<UUID>
    let selectedID: UUID?
    let select: (UUID) -> Void
    let collapse: (UUID, Bool) -> Void
    let moveWorkspace: (UUID, UUID, Int) -> Void
    let moveGroup: (UUID, Int) -> Void
    var keyboardSelect: (UUID) -> Void = { _ in }
    var keyboardFocusedKey: Key? = nil
    var incomingWorkspace: WorkspaceDragItem? = nil
    var dragActivityChanged: (SidebarDragKind?) -> Void = { _ in }
    var activateGroup: (UUID) -> Void = { _ in }
    var createWorkspace: (UUID) -> Void = { _ in }
    var rowSpacing: CGFloat = 5
    var content: (@MainActor (Key) -> AnyView)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.contentView.drawsBackground = false
        let outline = Outline()
        outline.hostsStyledRows = content != nil
        outline.dragCoordinator = context.coordinator
        outline.autoresizingMask = [.width]
        outline.style = .plain
        outline.headerView = nil
        outline.backgroundColor = .clear
        outline.intercellSpacing = NSSize(width: 0, height: rowSpacing)
        outline.indentationPerLevel = content == nil ? 14 : 0
        outline.selectionHighlightStyle = content == nil ? .regular : .none
        outline.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let column = NSTableColumn(identifier: .init("native-hierarchy"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.registerForDraggedTypes([Coordinator.type, .init(UTType.utf8PlainText.identifier)])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.setDraggingSourceOperationMask([], forLocal: false)
        outline.draggingDestinationFeedbackStyle = .gap
        outline.verticalMotionCanBeginDrag = true
        outline.allowsMultipleSelection = false
        outline.allowsTypeSelect = false
        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        outline.target = context.coordinator
        outline.action = #selector(Coordinator.activateRow(_:))
        context.coordinator.latest = self
        context.coordinator.environment = context.environment
        context.coordinator.outline = outline
        scroll.documentView = outline
        context.coordinator.applyLatest()
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.latest = self
        context.coordinator.environment = context.environment
        if context.coordinator.source == nil { context.coordinator.applyLatest() }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        let width = proposal.width ?? 276
        (nsView.documentView as? NSOutlineView)?.tableColumns.first?.width = width
        let coordinator = context.coordinator
        if coordinator.width != width, coordinator.source == nil {
            coordinator.width = width
            coordinator.refreshHostedRows()
            if let outline = nsView.documentView as? NSOutlineView {
                outline.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<outline.numberOfRows))
            }
        }
        let height = groups.reduce(CGFloat.zero) { total, group in
            total + coordinator.height(for: .group(group.id)) + rowSpacing
                + (collapsedIDs.contains(group.id)
                    ? 0
                    : group.workspaces.reduce(CGFloat.zero) {
                        $0 + coordinator.height(for: .workspace($1.id)) + rowSpacing
                    } + (content == nil ? 0 : coordinator.height(for: .newWorkspace(group.id)) + rowSpacing))
        }
        return CGSize(width: width, height: max(1, height))
    }

    final class Outline: NSOutlineView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { dragCoordinator?.revealKeyboardTarget() }
        }

        override func scrollToVisible(_ rect: NSRect) -> Bool {
            // The outer sidebar owns overflow; the inner clip only stabilizes drag gaps.
            if let document = enclosingScrollView?.superview {
                return document.scrollToVisible(convert(rect, to: document))
            }
            return super.scrollToVisible(rect)
        }

        var hostsStyledRows = false
        var dragCoordinator: Coordinator?
        override func frameOfOutlineCell(atRow row: Int) -> NSRect {
            hostsStyledRows ? .zero : super.frameOfOutlineCell(atRow: row)
        }
    }

    enum Key: Hashable {
        case group(UUID)
        case workspace(UUID)
        case newWorkspace(UUID)
        var payload: String {
            switch self {
            case let .group(id): "group:\(id.uuidString)"
            case let .workspace(id): "workspace:\(id.uuidString)"
            case let .newWorkspace(id): "new-workspace:\(id.uuidString)"
            }
        }
    }
    final class Node: NSObject {
        let key: Key
        var children: [Node] = []
        var title = ""
        var path = ""
        init(_ key: Key) { self.key = key }
        var isGroup: Bool { if case .group = key { true } else { false } }
        var displayText: String { isGroup ? title.uppercased() : "\(title)\n\(path)" }
    }

    final class HostedCell: NSTableCellView {
        let host: RowHost

        init(root: AnyView) {
            host = RowHost(rootView: root)
            super.init(frame: .zero)
            host.autoresizingMask = [.width, .height]
            addSubview(host)
        }
        required init?(coder: NSCoder) { nil }
        override func layout() {
            super.layout()
            host.frame = bounds
        }
        static func routesPointerToContent(x: CGFloat, width: CGFloat, eventType: NSEvent.EventType?, modifiers: NSEvent.ModifierFlags)
            -> Bool
        {
            if eventType == .rightMouseDown || modifiers.contains(.control) { return true }
            return eventType != .leftMouseDown || x >= width - 36
        }
    }

    final class HostedRow: NSTableRowView {
        override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
            var visited = Set<ObjectIdentifier>()
            func actions(in element: Any) -> [NSAccessibilityCustomAction] {
                guard let object = element as? NSObject, visited.insert(ObjectIdentifier(object)).inserted else { return [] }
                let actionsSelector = NSSelectorFromString("accessibilityCustomActions")
                let childrenSelector = NSSelectorFromString("accessibilityChildren")
                let own =
                    object.responds(to: actionsSelector)
                    ? object.perform(actionsSelector)?.takeUnretainedValue() as? [NSAccessibilityCustomAction] ?? [] : []
                let children =
                    object.responds(to: childrenSelector)
                    ? object.perform(childrenSelector)?.takeUnretainedValue() as? [Any] ?? [] : []
                let views = (object as? NSView)?.subviews ?? []
                return own + children.flatMap(actions) + views.flatMap(actions)
            }
            let result = subviews.flatMap(actions)
            return result.isEmpty ? super.accessibilityCustomActions() : result
        }
    }

    final class RowHost: NSHostingView<AnyView> {
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard
                HostedCell.routesPointerToContent(
                    x: point.x, width: bounds.width, eventType: NSApp.currentEvent?.type,
                    modifiers: NSApp.currentEvent?.modifierFlags ?? []
                )
            else { return nil }
            return super.hitTest(point)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        static let type = NSPasteboard.PasteboardType("com.interactivebuffoonery.awesomux.sidebar-outline")
        weak var outline: NSOutlineView?
        var latest: SidebarNativeOutlineView?
        var environment = EnvironmentValues()
        var width: CGFloat = 276
        var source: Node?
        let dragActivity = SidebarNativeDragActivity()
        private var roots: [Node] = []
        private var nodes: [Key: Node] = [:]
        private var frozenShape: [[Key]] = []
        private var frozenGroupFrames: [UUID: CGRect] = [:]
        private var renderedShape: [[Key]] = []
        private var applying = false
        private var revealedKeyboardKey: Key?
        private var hostedCells: [Key: HostedCell] = [:]
        private var hostedHeights: [Key: CGFloat] = [:]
        private func shape(_ groups: [Group]) -> [[Key]] {
            groups.map {
                [.group($0.id)] + $0.workspaces.map { .workspace($0.id) } + (latest?.content == nil ? [] : [.newWorkspace($0.id)])
            }
        }
        private func node(_ key: Key) -> Node {
            if let node = nodes[key] { return node }
            let node = Node(key)
            nodes[key] = node
            return node
        }

        @discardableResult
        private func updateHostedRow(_ key: Key) -> HostedCell? {
            guard let content = latest?.content else { return nil }
            let root = AnyView(
                content(key).environment(\.isNativeSidebarRow, true).environment(dragActivity).environment(\.self, environment).frame(
                    width: width))
            let cell: HostedCell
            if let cached = hostedCells[key] {
                cell = cached
                cell.host.rootView = root
            } else {
                cell = HostedCell(root: root)
                hostedCells[key] = cell
            }
            hostedHeights[key] = max(1, cell.host.fittingSize.height)
            return cell
        }

        func refreshHostedRows() {
            guard let latest, latest.content != nil else { return }
            let visibleKeys = Set(
                roots.flatMap { root -> [Key] in
                    guard case let .group(id) = root.key else { return [] }
                    return [root.key] + (latest.collapsedIDs.contains(id) ? [] : root.children.map(\.key))
                })
            hostedCells = hostedCells.filter { visibleKeys.contains($0.key) }
            hostedHeights = [:]
            for key in visibleKeys { updateHostedRow(key) }
        }

        func height(for key: Key) -> CGFloat {
            if let height = hostedHeights[key] { return height }
            if updateHostedRow(key) != nil, let height = hostedHeights[key] { return height }
            if case .group = key { return 30 }
            return 55
        }
        func applyLatest() {
            guard let latest, let outline else { return }
            outline.intercellSpacing = NSSize(width: 0, height: latest.rowSpacing)
            applying = true
            defer { applying = false }
            roots = latest.groups.map { group in
                let parent = node(.group(group.id))
                parent.title = group.name
                parent.children = group.workspaces.map { workspace in
                    let child = node(.workspace(workspace.id))
                    child.title = workspace.title
                    child.path = workspace.path
                    return child
                }
                if latest.content != nil { parent.children.append(node(.newWorkspace(group.id))) }
                return parent
            }
            let validKeys = Set(shape(latest.groups).flatMap { $0 })
            nodes = nodes.filter { validKeys.contains($0.key) }
            let oldHeights = hostedHeights
            refreshHostedRows()
            let nextShape = shape(latest.groups)
            if renderedShape != nextShape {
                renderedShape = nextShape
                outline.reloadData()
            }
            for root in roots {
                guard case let .group(id) = root.key else { continue }
                if latest.collapsedIDs.contains(id) { outline.collapseItem(root) } else { outline.expandItem(root) }
            }
            if oldHeights != hostedHeights {
                outline.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<outline.numberOfRows))
            }
            for row in 0..<outline.numberOfRows {
                if let node = outline.item(atRow: row) as? Node,
                    let label = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTextField
                {
                    label.stringValue = node.displayText
                }
            }
            if let id = latest.selectedID, let selected = nodes[.workspace(id)] {
                let row = outline.row(forItem: selected)
                if row >= 0 {
                    outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                } else {
                    outline.deselectAll(nil)
                }
            } else {
                outline.deselectAll(nil)
            }
            revealKeyboardTarget()
        }

        func revealKeyboardTarget() {
            guard let latest, let outline else { return }
            if latest.keyboardFocusedKey != revealedKeyboardKey {
                revealedKeyboardKey = nil
                if outline.enclosingScrollView?.superview != nil,
                    let key = latest.keyboardFocusedKey, let focused = nodes[key]
                {
                    let row = outline.row(forItem: focused)
                    if row >= 0 {
                        // Every row fits the inner clip; reveal it in the actual outer viewport.
                        _ = outline.scrollToVisible(outline.rect(ofRow: row))
                        revealedKeyboardKey = key
                    }
                }
            }
        }
        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            (item as? Node)?.children.count ?? roots.count
        }
        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            ((item as? Node)?.children ?? roots)[index]
        }
        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? Node)?.isGroup == true }
        func outlineView(_ outlineView: NSOutlineView, objectValueFor tableColumn: NSTableColumn?, byItem item: Any?) -> Any? {
            (item as? Node)?.displayText
        }
        func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
            guard let node = item as? Node else { return 30 }
            return height(for: node.key)
        }
        func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
            latest?.content == nil ? nil : HostedRow()
        }
        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? Node else { return nil }
            if let cell = hostedCells[node.key] ?? updateHostedRow(node.key) { return cell }
            let label = NSTextField(labelWithString: node.displayText)
            label.font = .systemFont(ofSize: node.isGroup ? 12 : 13, weight: node.isGroup ? .semibold : .regular)
            label.textColor = node.isGroup ? .secondaryLabelColor : .labelColor
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = node.isGroup ? 1 : 2
            return label
        }
        func outlineViewSelectionDidChange(_ notification: Notification) {
            switch NSApp.currentEvent?.type {
            case .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .rightMouseUp: return
            default: break
            }
            guard !applying, let outline, let latest,
                let node = outline.item(atRow: outline.selectedRow) as? Node,
                case let .workspace(id) = node.key, latest.selectedID != id
            else { return }
            latest.keyboardSelect(id)
        }
        @objc func activateRow(_ sender: NSOutlineView) {
            guard let node = sender.item(atRow: sender.clickedRow) as? Node else { return }
            activate(node)
        }
        func activate(_ node: Node) {
            guard source == nil, let outline, let latest else { return }
            switch node.key {
            case let .group(id):
                latest.activateGroup(id)
                latest.collapse(id, outline.isItemExpanded(node))
            case let .workspace(id): latest.select(id)
            case let .newWorkspace(id): latest.createWorkspace(id)
            }
        }
        func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
            source == nil
        }
        func outlineViewItemDidExpand(_ notification: Notification) { expansionChanged(notification, collapsed: false) }
        func outlineViewItemDidCollapse(_ notification: Notification) { expansionChanged(notification, collapsed: true) }
        private func expansionChanged(_ notification: Notification, collapsed: Bool) {
            guard !applying, source == nil, let node = notification.userInfo?["NSObject"] as? Node,
                case let .group(id) = node.key
            else { return }
            latest?.collapse(id, collapsed)
        }
        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
            guard let node = item as? Node else { return nil }
            if case .newWorkspace = node.key { return nil }
            let writer = NSPasteboardItem()
            writer.setString(node.key.payload, forType: Self.type)
            return writer
        }
        func groupDragImage(for group: Node) -> NSImage? {
            let keys =
                [group.key]
                + group.children.compactMap { child -> Key? in
                    if case .workspace = child.key { return child.key }
                    return nil
                }.prefix(3)
            let images = keys.compactMap { key -> NSImage? in
                guard let cell = updateHostedRow(key) else { return nil }
                let size = NSSize(width: width, height: height(for: key))
                let originalFrame = cell.frame
                defer { cell.frame = originalFrame; cell.layoutSubtreeIfNeeded() }
                cell.frame.size = size
                cell.layoutSubtreeIfNeeded()
                guard let bitmap = cell.bitmapImageRepForCachingDisplay(in: cell.bounds) else { return nil }
                cell.cacheDisplay(in: cell.bounds, to: bitmap)
                let image = NSImage(size: size)
                image.addRepresentation(bitmap)
                return image
            }
            guard let header = images.first else { return nil }
            let cards = Array(images.dropFirst())
            let height = header.size.height + (cards.first?.size.height ?? 0) + CGFloat(max(0, cards.count - 1)) * 16
            return NSImage(size: NSSize(width: width, height: height), flipped: true) { rect in
                for (index, card) in cards.enumerated().reversed() {
                    card.draw(
                        in: NSRect(x: 0, y: header.size.height + CGFloat(index) * 16, width: rect.width, height: card.size.height),
                        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                }
                header.draw(
                    in: NSRect(origin: .zero, size: header.size), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                    hints: nil)
                return true
            }
        }
        func outlineView(
            _ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint,
            forItems draggedItems: [Any]
        ) {
            guard draggedItems.count == 1, let node = draggedItems.first as? Node, let latest else { return }
            source = node
            dragActivity.kind = node.isGroup ? .group : .workspace
            latest.dragActivityChanged(dragActivity.kind)
            frozenShape = shape(latest.groups)
            if node.isGroup {
                if let image = groupDragImage(for: node) {
                    session.enumerateDraggingItems(options: [], for: outlineView, classes: [NSPasteboardItem.self], searchOptions: [:]) {
                        item, _, _ in
                        var frame = item.draggingFrame
                        frame.size = image.size
                        item.setDraggingFrame(frame, contents: image)
                    }
                }
                outlineView.collapseItem(node)
            }
            let row = outlineView.row(forItem: node)
            if row >= 0 { outlineView.hideRows(at: IndexSet(integer: row), withAnimation: []) }
            frozenGroupFrames = [:]
            if node.isGroup {
                for root in roots where root !== node {
                    guard case let .group(id) = root.key else { continue }
                    let first = outlineView.row(forItem: root)
                    guard first >= 0 else { continue }
                    let last = root.children.last.map { outlineView.row(forItem: $0) } ?? first
                    let block = outlineView.rect(ofRow: first).union(outlineView.rect(ofRow: max(first, last)))
                    let targetSpace = outlineView.enclosingScrollView?.contentView ?? outlineView
                    frozenGroupFrames[id] = outlineView.convert(block, to: targetSpace)
                }
            }
        }
        private func destination(_ outline: NSOutlineView, info: any NSDraggingInfo, item: Any?, index: Int) -> (Node?, Int)? {
            guard let latest else { return nil }
            let nativeSource = info.draggingSource as? NSOutlineView === outline
            if nativeSource {
                guard let source, frozenShape == shape(latest.groups),
                    info.draggingPasteboard.string(forType: Self.type) == source.key.payload
                else { return nil }
            } else {
                guard info.draggingSource is SidebarWorkspaceDragSource.DragSourceView,
                    Self.externalID(info: info, latest: latest) != nil
                else { return nil }
            }
            let proposed = item as? Node
            if nativeSource, let source, source.isGroup {
                let targetSpace = outline.enclosingScrollView?.contentView ?? outline
                let point = targetSpace.convert(info.draggingLocation, from: nil)
                guard case let .group(id) = source.key,
                    let target = SidebarNativeOutlineView.groupInsertionIndex(
                        y: point.y, sourceID: id, groupIDs: latest.groups.map(\.id), frames: frozenGroupFrames
                    )
                else { return nil }
                // Native gap feedback moves headers; resolve against whole blocks frozen before it opens.
                return (nil, target)
            }
            if let proposed, proposed.isGroup {
                let count = workspaceCount(in: proposed)
                let onHeader = outline.isItemExpanded(proposed) ? 0 : count
                return (proposed, index < 0 ? onHeader : min(index, count))
            }
            if let proposed, let group = outline.parent(forItem: proposed) as? Node,
                let child = group.children.firstIndex(where: { $0 === proposed })
            {
                let point = outline.convert(info.draggingLocation, from: nil)
                let after = point.y > outline.rect(ofRow: outline.row(forItem: proposed)).midY
                return (group, min(child + (after ? 1 : 0), workspaceCount(in: group)))
            }
            guard !roots.isEmpty else { return nil }
            let group = roots[min(max(index - 1, 0), roots.count - 1)]
            return (group, index <= 0 ? 0 : workspaceCount(in: group))
        }
        private static func externalID(info: any NSDraggingInfo, latest: SidebarNativeOutlineView) -> UUID? {
            SidebarNativeOutlineView.externalWorkspaceID(
                data: info.draggingPasteboard.data(forType: .init(UTType.utf8PlainText.identifier)), expected: latest.incomingWorkspace
            )
        }
        private func workspaceCount(in group: Node) -> Int {
            group.children.filter { if case .workspace = $0.key { true } else { false } }.count
        }
        func outlineView(
            _ outlineView: NSOutlineView, validateDrop info: any NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int
        ) -> NSDragOperation {
            guard let (parent, child) = destination(outlineView, info: info, item: item, index: index) else { return [] }
            outlineView.setDropItem(parent, dropChildIndex: child)
            return .move
        }
        func outlineView(_ outlineView: NSOutlineView, acceptDrop info: any NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
            guard let (parent, child) = destination(outlineView, info: info, item: item, index: index),
                let latest
            else { return false }
            let key = source?.key ?? Self.externalID(info: info, latest: latest).map(Key.workspace)
            guard let key else { return false }
            switch key {
            case let .group(id):
                latest.moveGroup(id, child)
            case let .workspace(id):
                guard let parent, case let .group(groupID) = parent.key else { return false }
                let from = parent.children.firstIndex(where: { $0.key == key })
                let target = from.map { $0 < child ? child - 1 : child } ?? child
                if target == from { return true }
                latest.moveWorkspace(id, groupID, target)
                latest.collapse(groupID, false)
            case .newWorkspace: return false
            }
            return true
        }
        func outlineView(
            _ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint,
            operation: NSDragOperation
        ) {
            finishDrag()
        }

        func finishDrag() {
            source = nil
            frozenGroupFrames = [:]
            // Native gap bookkeeping continues after the source-end callback returns.
            DispatchQueue.main.async { [self] in
                guard source == nil else { return }
                defer {
                    dragActivity.kind = nil
                    latest?.dragActivityChanged(nil)
                }
                guard let outline else { return }
                outline.unhideRows(at: outline.hiddenRowIndexes, withAnimation: [])
                self.applyLatest()
                outline.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<outline.numberOfRows))
            }
        }
    }
}
