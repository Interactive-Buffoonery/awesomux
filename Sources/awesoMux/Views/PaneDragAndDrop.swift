import AppKit
import AwesoMuxCore
import DesignSystem
import os
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Drag coordinator (INT-223)

/// Shared, per-workspace drag state for pane rearrangement. A pane drag started
/// on one leaf must be visible to the drop overlays on every *other* leaf, so the
/// "is a drag in flight, and which pane" signal can't live in any single pane's
/// `@State` — it's hoisted to one coordinator threaded through the pane tree by
/// reference.
///
/// `@MainActor @Observable`: drop delegates and overlays read `draggedPaneID` on
/// the main actor, and mutating it must restyle the zones, so it participates in
/// SwiftUI observation.
@MainActor
@Observable
final class PaneDragCoordinator {
    /// The pane currently being dragged, or nil when no pane drag is in flight.
    /// The dragged pane shows no drop zones on itself; every other pane does.
    private(set) var draggedPaneID: TerminalPane.ID?

    /// Discriminates the live drag so a stale `.onDrop` callback from a previous
    /// gesture can't act on the current one — mirrors the sidebar `dragID` guard.
    private(set) var dragID: UUID?

    func begin(paneID: TerminalPane.ID) -> UUID {
        let id = UUID()
        draggedPaneID = paneID
        dragID = id
        return id
    }

    func end() {
        draggedPaneID = nil
        dragID = nil
    }

    var isDragging: Bool { draggedPaneID != nil }
}

// MARK: - AppKit drag source

/// AppKit-backed drag source for a pane. Replaces SwiftUI's `.onDrag`, whose
/// only end signal is `DropDelegate.dropExited` — that fires when the in-flight
/// drag merely leaves the origin pane's bounds (killing a real drag mid-gesture),
/// and never fires at all for a drag released over dead space (sidebar, divider,
/// Escape, off-window), leaking `isDragging = true` forever so the full-pane
/// hit-testing overlays eat all terminal mouse input.
///
/// `NSDraggingSource` gives one authoritative `draggingSession(_:endedAt:)`
/// callback that funnels EVERY termination — drop, cancel, Escape, off-window —
/// into `coordinator.end()`. The payload is the same UTF8 JSON `PaneDragItem`
/// under `public.utf8-plain-text`, so the existing SwiftUI `.onDrop` DropDelegates
/// keep working unchanged: SwiftUI drop targets are standard NSView dragging
/// destinations and receive AppKit-originated sessions on the shared dragging
/// pasteboard.
struct PaneDragSource: NSViewRepresentable {
    let sessionID: TerminalSession.ID
    let paneID: TerminalPane.ID
    let coordinator: PaneDragCoordinator
    let glyphName: String
    /// Fired on a stationary double-click (clickCount >= 2) — the title bar uses
    /// this to enter inline rename without the click also starting a drag.
    var onDoubleClick: (() -> Void)?
    /// Fired on a single click that never crossed the drag threshold — the title
    /// bar uses this to focus the pane.
    var onActivate: (() -> Void)?
    /// Builds the right-click menu lazily at click time so disabled-state (e.g.
    /// "Reset" only when user-edited) reflects the live pane.
    var contextMenuItems: (() -> [PaneContextMenuItem])?

    func makeNSView(context: Context) -> DragSourceView {
        let view = DragSourceView()
        view.configure(
            sessionID: sessionID,
            paneID: paneID,
            coordinator: coordinator,
            glyphName: glyphName,
            onDoubleClick: onDoubleClick,
            onActivate: onActivate,
            contextMenuItems: contextMenuItems
        )
        return view
    }

    func updateNSView(_ nsView: DragSourceView, context: Context) {
        nsView.configure(
            sessionID: sessionID,
            paneID: paneID,
            coordinator: coordinator,
            glyphName: glyphName,
            onDoubleClick: onDoubleClick,
            onActivate: onActivate,
            contextMenuItems: contextMenuItems
        )
    }

    /// The NSView that owns the drag gesture. `mouseDown` records the start; a
    /// drag past the system threshold begins an `NSDraggingSession` whose source
    /// is `self`.
    final class DragSourceView: NSView, NSDraggingSource {
        private var sessionID: TerminalSession.ID?
        private var paneID: TerminalPane.ID?
        private var coordinator: PaneDragCoordinator?
        private var glyphName: String = "dot.square"
        private var mouseDownPoint: NSPoint?
        private var onDoubleClick: (() -> Void)?
        private var onActivate: (() -> Void)?
        private var contextMenuItems: (() -> [PaneContextMenuItem])?

        func configure(
            sessionID: TerminalSession.ID,
            paneID: TerminalPane.ID,
            coordinator: PaneDragCoordinator,
            glyphName: String,
            onDoubleClick: (() -> Void)?,
            onActivate: (() -> Void)?,
            contextMenuItems: (() -> [PaneContextMenuItem])?
        ) {
            self.sessionID = sessionID
            self.paneID = paneID
            self.coordinator = coordinator
            self.glyphName = glyphName
            self.onDoubleClick = onDoubleClick
            self.onActivate = onActivate
            self.contextMenuItems = contextMenuItems
        }

        override func mouseDown(with event: NSEvent) {
            // A double-click is a rename intent, not a drag — clear the drag
            // origin so no later mouseDragged can fire, and forward to the
            // editor. Returning here also means mouseUp sees no mouseDownPoint,
            // so the double-click's first up won't ALSO fire onActivate (F3).
            if event.clickCount >= 2 {
                mouseDownPoint = nil
                onDoubleClick?()
                return
            }
            mouseDownPoint = convert(event.locationInWindow, from: nil)
        }

        override func mouseDragged(with event: NSEvent) {
            guard let mouseDownPoint else { return }
            let current = convert(event.locationInWindow, from: nil)
            let dx = current.x - mouseDownPoint.x
            let dy = current.y - mouseDownPoint.y
            // 3pt mirrors AppKit's own drag-detection slop; below it the gesture
            // is still a click, not a drag.
            guard (dx * dx + dy * dy) >= 9 else { return }
            self.mouseDownPoint = nil
            beginDrag(with: event)
        }

        override func mouseUp(with event: NSEvent) {
            // A single-click press that never crossed the drag threshold is a
            // click → focus the pane. mouseDragged clears mouseDownPoint once a
            // real drag starts, so a completed drag won't fire activate. Gate on
            // clickCount == 1 so the first mouse-up of a double-click (which set
            // mouseDownPoint to nil in mouseDown) doesn't ALSO activate (F3).
            if mouseDownPoint != nil, event.clickCount == 1 {
                onActivate?()
            }
            mouseDownPoint = nil
        }

        // Primary right-click path. AppKit asks the view under the cursor for its
        // menu, so the drag source — which owns the bar's mouse events — must
        // build it rather than relying on a SwiftUI `.contextMenu` that would
        // never see the right-click.
        //
        // FALLBACK: if `menu(for:)` does NOT fire under the SwiftUI `.overlay`
        // host (the spike in the plan's Task 7 Step 0 falsifies this), switch to
        // an injected `onContextMenu: ((NSEvent) -> Void)?`, override
        // `rightMouseDown(with:)` to call it, and present the menu from SwiftUI
        // state instead. Only one of the two paths ships; this is the primary.
        override func menu(for event: NSEvent) -> NSMenu? {
            guard let items = contextMenuItems?(), !items.isEmpty else { return nil }
            let menu = NSMenu()
            menu.autoenablesItems = false
            for item in items { menu.addItem(makeMenuItem(item)) }
            return menu
        }

        private func makeMenuItem(_ item: PaneContextMenuItem) -> NSMenuItem {
            let entry = NSMenuItem(
                title: item.title,
                action: item.children == nil ? #selector(runMenuItem(_:)) : nil,
                keyEquivalent: ""
            )
            entry.target = item.children == nil ? self : nil
            entry.isEnabled = item.isEnabled
            entry.state = item.isChecked ? .on : .off
            if let swatch = item.swatch {
                entry.image = Self.swatchImage(swatch)
            }
            if let children = item.children {
                let submenu = NSMenu()
                submenu.autoenablesItems = false
                for child in children { submenu.addItem(makeMenuItem(child)) }
                entry.submenu = submenu
            } else {
                // representedObject is ALWAYS a () -> Void — runMenuItem casts to
                // that type. Don't assign other types here.
                entry.representedObject = item.action
            }
            return entry
        }

        private static func swatchImage(_ color: NSColor, diameter: CGFloat = 10) -> NSImage {
            let size = NSSize(width: diameter, height: diameter)
            // NSImage(size:flipped:drawingHandler:) renders into a Retina-aware
            // backing store at the display's actual scale factor, avoiding the
            // blurry 1× bitmap produced by the deprecated lockFocus/unlockFocus path.
            let image = NSImage(size: size, flipped: false) { rect in
                color.setFill()
                NSBezierPath(ovalIn: rect).fill()
                return true
            }
            // Template = false so AppKit renders the literal hue, not a tinted mask.
            image.isTemplate = false
            return image
        }

        @objc private func runMenuItem(_ sender: NSMenuItem) {
            (sender.representedObject as? () -> Void)?()
        }

        private func beginDrag(with event: NSEvent) {
            guard let sessionID, let paneID, let coordinator else { return }

            let dragID = coordinator.begin(paneID: paneID)
            let pasteboardItem = NSPasteboardItem()
            if let data = try? JSONEncoder().encode(
                PaneDragItem(sessionID: sessionID, paneID: paneID, dragID: dragID)
            ) {
                pasteboardItem.setData(data, forType: .init(UTType.utf8PlainText.identifier))
            }

            let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
            let image = Self.dragImage(glyphName: glyphName)
            let imageSize = image.size
            let origin = convert(event.locationInWindow, from: nil)
            draggingItem.setDraggingFrame(
                NSRect(
                    x: origin.x - imageSize.width / 2,
                    y: origin.y - imageSize.height / 2,
                    width: imageSize.width,
                    height: imageSize.height
                ),
                contents: image
            )

            beginDraggingSession(with: [draggingItem], event: event, source: self)
        }

        private static let logger = Logger(
            subsystem: "com.interactivebuffoonery.awesomux",
            category: "pane-drag"
        )

        private static func dragImage(glyphName: String) -> NSImage {
            let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
            if let symbol = NSImage(systemSymbolName: glyphName, accessibilityDescription: nil)?
                .withSymbolConfiguration(config) {
                return symbol
            }
            logger.debug("SF Symbol \(glyphName, privacy: .public) unavailable; using blank drag image")
            return NSImage(size: NSSize(width: 16, height: 16))
        }

        // The payload never leaves the app — `[]` for `.outsideApplication`
        // preserves the previous `.ownProcess` posture (no cross-app drop).
        func draggingSession(
            _ session: NSDraggingSession,
            sourceOperationMaskFor context: NSDraggingContext
        ) -> NSDragOperation {
            switch context {
            case .withinApplication:
                return .move
            case .outsideApplication:
                return []
            @unknown default:
                return []
            }
        }

        func draggingSession(
            _ session: NSDraggingSession,
            willBeginAt screenPoint: NSPoint
        ) {
            // `coordinator.begin` already ran in `beginDrag` (it mints the dragID
            // baked into the pasteboard payload); nothing more to do here. The
            // hook is kept for symmetry with the authoritative `endedAt` below.
        }

        // THE authoritative end signal. Drop, cancel, Escape, off-window — every
        // way a drag can finish funnels here, so the coordinator's active-drag
        // state can never leak. `performDrop` may also call `end()` first; the
        // second `end()` is idempotent.
        func draggingSession(
            _ session: NSDraggingSession,
            endedAt screenPoint: NSPoint,
            operation: NSDragOperation
        ) {
            coordinator?.end()
        }
    }
}

// MARK: - Context menu

/// A single entry for the pane title bar's right-click menu, bridged into an
/// AppKit `NSMenu` because the drag source owns the bar's mouse events (a SwiftUI
/// `.contextMenu` would never see the right-click that the drag source consumes).
struct PaneContextMenuItem {
    let title: String
    let isEnabled: Bool
    // TODO: make this @MainActor () -> Void before enabling Swift 6 language mode
    // — the closures call @MainActor setPaneColor; runtime-safe today because AppKit
    // menu actions are main-thread, but the type erasure should be annotated before
    // strict concurrency.
    var action: () -> Void = {}
    /// Non-nil → this item is a submenu parent and `action` is ignored.
    var children: [PaneContextMenuItem]? = nil
    /// A leading color swatch (e.g. a palette dot). Nil → no image.
    var swatch: NSColor? = nil
    /// Renders a checkmark (the current selection in a single-choice submenu).
    var isChecked: Bool = false
}

// MARK: - Drop zone geometry

/// The five drop regions a dragged pane can land on over a target pane. The four
/// edges map to `movePane(adjacentToPane:onEdge:)`; the center maps to
/// `swapPanes`.
enum PaneDropZone: Hashable {
    case edge(PaneMoveEdge)
    case center
}

/// Resolves a point inside a pane's bounds to the drop zone it falls in. The four
/// edge strips occupy a `edgeInset` fraction of each side; the remaining middle is
/// the swap zone. Corners resolve to whichever edge the point is closer to, so
/// every point maps to exactly one zone.
enum PaneDropZoneResolver {
    /// Fraction of the pane's width/height each edge strip occupies.
    static let edgeInset: CGFloat = 0.25

    static func zone(at point: CGPoint, in size: CGSize) -> PaneDropZone {
        guard size.width > 0, size.height > 0 else { return .center }

        let left = size.width * edgeInset
        let right = size.width * (1 - edgeInset)
        let top = size.height * edgeInset
        let bottom = size.height * (1 - edgeInset)

        let inHorizontalEdge = point.x < left || point.x > right
        let inVerticalEdge = point.y < top || point.y > bottom

        // Center: clear of every edge strip.
        if !inHorizontalEdge && !inVerticalEdge {
            return .center
        }

        // Corner overlap: pick the edge whose strip the point penetrates deeper,
        // measured as distance past the strip boundary normalized by pane size so
        // a wide-but-short pane doesn't bias toward the horizontal edges.
        let horizontalDepth: CGFloat = point.x < left
            ? (left - point.x) / size.width
            : (point.x > right ? (point.x - right) / size.width : -1)
        let verticalDepth: CGFloat = point.y < top
            ? (top - point.y) / size.height
            : (point.y > bottom ? (point.y - bottom) / size.height : -1)

        if horizontalDepth >= verticalDepth {
            return .edge(point.x < left ? .left : .right)
        } else {
            return .edge(point.y < top ? .up : .down)
        }
    }
}

// MARK: - Zone validity

/// The five zone-validity booleans for one (drag, target-pane) pair. Validity is
/// constant for the lifetime of one drag — any layout change kills the drag — so
/// the overlay computes this once and hands the delegate a closure reading it,
/// instead of re-running a full reducer dry-run on every pointer-move event (it
/// was running twice: once for the cursor, once for the highlight).
struct PaneDropZoneValidity {
    var left: Bool
    var right: Bool
    var up: Bool
    var down: Bool
    var center: Bool

    func isValid(_ zone: PaneDropZone) -> Bool {
        switch zone {
        case .edge(.left): left
        case .edge(.right): right
        case .edge(.up): up
        case .edge(.down): down
        case .center: center
        }
    }

    /// Dry-run every zone against the store ONCE. Shared by the delegate (cursor)
    /// and the overlay (highlight) so the two can't drift.
    @MainActor
    static func resolve(
        draggedPaneID: TerminalPane.ID,
        targetPaneID: TerminalPane.ID,
        sessionID: TerminalSession.ID,
        sessionStore: SessionStore
    ) -> PaneDropZoneValidity {
        func canMove(_ edge: PaneMoveEdge) -> Bool {
            sessionStore.canMovePane(
                id: draggedPaneID,
                adjacentToPane: targetPaneID,
                onEdge: edge,
                in: sessionID
            )
        }
        return PaneDropZoneValidity(
            left: canMove(.left),
            right: canMove(.right),
            up: canMove(.up),
            down: canMove(.down),
            center: sessionStore.canSwapPanes(
                firstID: draggedPaneID,
                secondID: targetPaneID,
                in: sessionID
            )
        )
    }
}

// MARK: - Drop delegate

/// Handles a `PaneDragItem` dropped onto a single target pane. Resolves the
/// hovered zone live (driving the highlight) and routes the drop to the store —
/// `movePane(adjacentToPane:onEdge:)` for an edge, `swapPanes` for the center.
/// An invalid zone is surfaced as a disabled highlight while hovering and an
/// `NSSound.beep()` on drop, never a silent no-op.
struct PaneDropDelegate: DropDelegate {
    let targetPaneID: TerminalPane.ID
    let sessionID: TerminalSession.ID
    let sessionStore: SessionStore
    let coordinator: PaneDragCoordinator
    let paneSize: CGSize
    let setHoveredZone: (PaneDropZone?) -> Void
    /// Reads the overlay's cached per-(drag, target) validity. Computed once per
    /// drag; the delegate never re-runs the reducer dry-run itself.
    let isZoneValid: (PaneDropZone) -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        coordinator.isDragging
            && coordinator.draggedPaneID != targetPaneID
            && info.hasItemsConforming(to: [UTType.utf8PlainText])
    }

    func dropEntered(info: DropInfo) {
        guard validateDrop(info: info) else {
            setHoveredZone(nil)
            return
        }
        setHoveredZone(zone(for: info))
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info) else {
            setHoveredZone(nil)
            return nil
        }
        let zone = zone(for: info)
        setHoveredZone(zone)
        // Propose `.move` only when the resolved drop would actually be accepted,
        // so the cursor reflects validity; otherwise `.forbidden` (the zone still
        // highlights in its disabled style as the visible-rejection cue on hover).
        return DropProposal(operation: isZoneValid(zone) ? .move : .forbidden)
    }

    func dropExited(info: DropInfo) {
        setHoveredZone(nil)
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            setHoveredZone(nil)
            // Clear the active drag immediately on drop; the decode below is
            // async, so the gesture is logically over the moment we accept it.
            // The drag source's `endedAt` hook also calls `end()` — idempotent.
            coordinator.end()
        }
        guard validateDrop(info: info),
              let draggedPaneID = coordinator.draggedPaneID,
              let provider = info.itemProviders(for: [UTType.utf8PlainText]).first else {
            return false
        }

        let zone = zone(for: info)
        let expectedDragID = coordinator.dragID
        let targetPaneID = targetPaneID
        let sessionID = sessionID
        let sessionStore = sessionStore

        decodePaneDragItem(from: provider) { item in
            // A decode failure on an accepted drop (`performDrop` already
            // returned true) would be an invisible no-op — surface it.
            guard let item else {
                NSSound.beep()
                return
            }
            // Reject a stale provider from a prior gesture, one whose payload
            // disagrees with the coordinator's live drag, or one that crossed
            // workspaces (the target pane lives in `sessionID`).
            guard item.dragID == expectedDragID,
                  item.paneID == draggedPaneID,
                  item.sessionID == sessionID else {
                NSSound.beep()
                return
            }

            let moved: Bool
            let announcement: String
            switch zone {
            case let .edge(edge):
                moved = sessionStore.movePane(
                    id: item.paneID,
                    adjacentToPane: targetPaneID,
                    onEdge: edge,
                    in: sessionID
                )
                announcement = String(
                    localized: "Moved pane next to target",
                    comment: "VoiceOver announcement after a drag drops a pane onto an edge of another pane."
                )
            case .center:
                moved = sessionStore.swapPanes(
                    firstID: item.paneID,
                    secondID: targetPaneID,
                    in: sessionID
                )
                announcement = String(
                    localized: "Swapped panes",
                    comment: "VoiceOver announcement after a drag drops a pane onto the center swap zone of another pane."
                )
            }

            // Invalid / no-op drops are surfaced audibly AND announced rather
            // than swallowed — INT-223 requires invalid drops be visibly
            // rejected, not ignored.
            if moved {
                TerminalAccessibilityAnnouncer.announce(announcement)
            } else {
                NSSound.beep()
                TerminalAccessibilityAnnouncer.announce(
                    String(
                        localized: "Pane move not allowed",
                        comment: "VoiceOver announcement when a pane drag drops on a zone that can't accept the move."
                    )
                )
            }
        }
        return true
    }

    private func zone(for info: DropInfo) -> PaneDropZone {
        PaneDropZoneResolver.zone(at: info.location, in: paneSize)
    }
}

// MARK: - Drop zones overlay

/// Overlays a target pane with the five hover-highlighted drop zones while a pane
/// drag is in flight. The dragged pane itself renders no overlay (the caller gates
/// on `coordinator.draggedPaneID != pane.id`).
struct PaneDropZonesOverlay: View {
    let targetPaneID: TerminalPane.ID
    let sessionID: TerminalSession.ID
    let sessionStore: SessionStore
    let coordinator: PaneDragCoordinator
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.awAccent) private var accentResolver
    @Environment(\.terminalBackgroundColor) private var terminalBackground
    @State private var hoveredZone: PaneDropZone?
    /// Cached zone validity for the active drag. Computed lazily once per drag
    /// (validity is constant for a drag's lifetime — any layout change kills it),
    /// keyed off the coordinator's `dragID` so a new gesture recomputes.
    @State private var cachedValidity: PaneDropZoneValidity?
    @State private var cachedDragID: UUID?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let hoveredZone {
                    zoneHighlight(hoveredZone, in: proxy.size)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .contentShape(Rectangle())
            .onDrop(
                of: [.utf8PlainText],
                delegate: PaneDropDelegate(
                    targetPaneID: targetPaneID,
                    sessionID: sessionID,
                    sessionStore: sessionStore,
                    coordinator: coordinator,
                    paneSize: proxy.size,
                    setHoveredZone: { hoveredZone = $0 },
                    isZoneValid: { isZoneValid($0) }
                )
            )
            .onChange(of: coordinator.isDragging) { _, dragging in
                if !dragging {
                    hoveredZone = nil
                    cachedValidity = nil
                    cachedDragID = nil
                }
            }
        }
        .allowsHitTesting(true)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func zoneHighlight(_ zone: PaneDropZone, in size: CGSize) -> some View {
        let valid = isZoneValid(zone)
        // Both tints route through the contrast picker against the actual
        // terminal background — the zones sit over the terminal surface, whose
        // color is independent of the app chrome (INT-285), so a chrome-keyed
        // accent/red can fall below the WCAG floor. The dashed border (below)
        // carries the valid/invalid distinction; the tint only has to stay
        // legible.
        let tint = valid
            ? Color.aw.focusAccent(accentResolver.accent, terminalBackground: terminalBackground)
            : Color.aw.contrastTuned(Color.aw.red, terminalBackground: terminalBackground)
        let frame = zoneFrame(zone, in: size)
        let fillOpacity = reduceTransparency ? 0.30 : 0.20

        RoundedRectangle(cornerRadius: 6)
            .fill(tint.opacity(fillOpacity))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(
                        tint.opacity(valid ? 0.9 : 0.7),
                        style: StrokeStyle(
                            lineWidth: 2,
                            dash: valid ? [] : [5, 4]
                        )
                    )
            }
            .frame(width: frame.width, height: frame.height)
            .position(x: frame.midX, y: frame.midY)
            .animation(nil, value: zone)
    }

    private func zoneFrame(_ zone: PaneDropZone, in size: CGSize) -> CGRect {
        let inset = PaneDropZoneResolver.edgeInset
        let w = size.width
        let h = size.height
        switch zone {
        case .center:
            return CGRect(
                x: w * inset,
                y: h * inset,
                width: w * (1 - 2 * inset),
                height: h * (1 - 2 * inset)
            )
        case .edge(.left):
            return CGRect(x: 0, y: 0, width: w * inset, height: h)
        case .edge(.right):
            return CGRect(x: w * (1 - inset), y: 0, width: w * inset, height: h)
        case .edge(.up):
            return CGRect(x: 0, y: 0, width: w, height: h * inset)
        case .edge(.down):
            return CGRect(x: 0, y: h * (1 - inset), width: w, height: h * inset)
        }
    }

    /// Reads the cached validity for the live drag, computing it once on first
    /// access for this drag (dragID change invalidates). The delegate calls this
    /// through the closure it's handed, so cursor + highlight share one source.
    private func isZoneValid(_ zone: PaneDropZone) -> Bool {
        guard let draggedPaneID = coordinator.draggedPaneID,
              let dragID = coordinator.dragID else { return false }

        let validity: PaneDropZoneValidity
        if let cachedValidity, cachedDragID == dragID {
            validity = cachedValidity
        } else {
            validity = PaneDropZoneValidity.resolve(
                draggedPaneID: draggedPaneID,
                targetPaneID: targetPaneID,
                sessionID: sessionID,
                sessionStore: sessionStore
            )
            cachedValidity = validity
            cachedDragID = dragID
        }
        return validity.isValid(zone)
    }
}
