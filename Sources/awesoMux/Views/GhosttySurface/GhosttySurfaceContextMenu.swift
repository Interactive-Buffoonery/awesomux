import AppKit
import GhosttyKit

/// Terminal surface context menu: right-click, ctrl+left-click, and the
/// keyboard/Accessibility "show menu" request.
///
/// Three routing decisions here are deliberate divergences from
/// `SurfaceView_AppKit.menu(for:)` in
/// `vendor/ghostty/macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift:1561-1616`
/// (MIT; the structure of the `.leftMouseDown` capture guard is taken from
/// there, everything else below is awesoMux's own):
///
/// 1. **Right-click under mouse capture forwards to the terminal instead of
///    showing the menu.** Ghostty's `.rightMouseDown` case falls straight
///    through to building a menu. awesoMux's `rightMouseDown(with:)` sends a
///    real `GHOSTTY_MOUSE_RIGHT` press to libghostty, so a TUI that asked for
///    the mouse (`vim :set mouse=a`, `htop`, `tmux`) gets the right-click it
///    is listening for. Losing right-click inside those apps is the worse
///    trade than losing a menu that Copy/Paste keyboard shortcuts already
///    cover.
/// 2. **ctrl+left-click when NOT captured shows the menu and nothing else.**
///    Ghostty synthesizes a right-button press into the core before returning
///    its menu. awesoMux does not: a synthesized press whose release AppKit
///    may never deliver is a stuck-button hazard, and the menu is the entire
///    point of the gesture. AppKit calls `menu(for:)` BEFORE any mouse event
///    for this gesture, so the left button is pre-armed for suppression here
///    instead — see the `.showMenu` branch.
/// 3. **This menu autoenables its items; `PaneDragAndDrop`'s does not.** Every
///    item here is a nil-target terminal edit action already gated by
///    `GhosttySurfaceNSView.validateUserInterfaceItem` — the same validator
///    the Edit menu resolves against — so autoenablement reuses that single
///    source of truth. `PaneDragAndDrop` builds items from an injected model
///    that carries its own `isEnabled`, with no validator to consult.
extension GhosttySurfaceNSView {
    override func menu(for event: NSEvent) -> NSMenu? {
        let currentSurface = surface
        let mouseCaptured = currentSurface.map { ghostty_surface_mouse_captured($0) } ?? false

        switch event.type {
        case .leftMouseDown:
            switch GhosttySurfaceContextMenuPolicy.ctrlLeftRoute(
                hasControlModifier: event.modifierFlags.contains(.control),
                hasSurface: currentSurface != nil,
                mouseCaptured: mouseCaptured
            ) {
            case .deferToSuper:
                return super.menu(for: event)

            case .suppressMenu:
                return nil

            case .showMenu:
                window?.makeFirstResponder(self)
                // AppKit calls this before any mouse event and then swallows
                // the press once a non-nil menu comes back, so nothing else
                // will consume the focus-only latch that
                // `localEventLeftMouseDown` may have just armed (it runs on a
                // global monitor ahead of the responder chain). Arming the
                // left button with a nil identity consumes that latch AND
                // records the paired release as suppressed, so a `mouseUp`
                // delivered after menu tracking cannot reach libghostty for a
                // press it never saw.
                _ = inputState.mouseButtonPolicy.mouseDown(button: .left, surfaceIdentity: nil)
                return Self.makeContextMenu()
            }

        case .rightMouseDown:
            switch GhosttySurfaceContextMenuPolicy.rightClickRoute(
                hasSurface: currentSurface != nil,
                mouseCaptured: mouseCaptured
            ) {
            // `rightMouseDown(with:)` already pre-armed the button before
            // calling `super`, which is what got us here. Do not arm again.
            case .presentMenu:
                return Self.makeContextMenu()
            // Unreachable from a physical right-click — `rightMouseDown(with:)`
            // only calls `super` on `.presentMenu` — so these are defensive for
            // any direct or synthesized `menu(for:)` caller.
            case .forwardToTerminal:
                return nil
            case .ignore:
                return super.menu(for: event)
            }

        default:
            return super.menu(for: event)
        }
    }

    /// Presents the same menu for the context-menu keyboard shortcut and the
    /// Accessibility ShowMenu action.
    ///
    /// Two deliberate divergences from the mouse routes:
    ///
    /// 1. **A dead surface still gets a menu.** The mouse routes return `nil`
    ///    and stay silent; here the menu opens with every item correctly
    ///    disabled, because audible "dimmed" feedback tells an assistive
    ///    technology user what state the pane is in, and silence tells them
    ///    nothing at all.
    /// 2. **Mouse capture is not consulted.** `NSView`'s default implementation
    ///    synthesizes a right-mouse-down and routes it through `menu(for:)`,
    ///    which would suppress the menu whenever a mouse-mode TUI is running —
    ///    but an explicit Show Menu action is unambiguous intent, and there is
    ///    no pointer gesture to forward, so the trade that justifies
    ///    suppression on right-click does not apply.
    override func showContextMenuForSelection(_ sender: Any?) {
        // Every item is a nil-target action that validates against
        // `isFirstResponder === self`, so without this the whole menu opens
        // disabled. Matches the `.showMenu` branch and `rightMouseDown(with:)`.
        window?.makeFirstResponder(self)
        // Matches what NSView's default does without `selectionAnchorRect`:
        // anchor on the view's own bounds.
        Self.makeContextMenu().popUp(
            positioning: nil,
            at: NSPoint(x: bounds.midX, y: bounds.midY),
            in: self
        )
    }

    /// Items keep AppKit's default nil target, so each action resolves through
    /// the responder chain to the focused surface exactly as the Edit menu's
    /// does. No key equivalents: the Edit menu already owns ⌘C/⌘V/⌘A, and a
    /// second binding here would be a parallel shortcut surface.
    static func makeContextMenu() -> NSMenu {
        let menu = NSMenu(
            title: String(
                localized: "Terminal Actions",
                comment: "Title of the terminal surface right-click context menu"
            )
        )
        menu.addItem(
            withTitle: String(
                localized: "Copy",
                comment: "Terminal context menu item that copies the selection"
            ),
            action: #selector(GhosttySurfaceNSView.copy(_:)),
            keyEquivalent: ""
        )
        menu.addItem(
            withTitle: String(
                localized: "Paste",
                comment: "Terminal context menu item that pastes the clipboard into the terminal"
            ),
            action: #selector(GhosttySurfaceNSView.paste(_:)),
            keyEquivalent: ""
        )
        menu.addItem(
            withTitle: String(
                localized: "Select All",
                comment: "Terminal context menu item that selects the whole terminal buffer"
            ),
            action: #selector(GhosttySurfaceNSView.selectAll(_:)),
            keyEquivalent: ""
        )
        menu.addItem(.separator())
        menu.addItem(
            withTitle: String(
                localized: "Search Selection",
                comment: "Terminal context menu item that searches the terminal for the current selection"
            ),
            action: #selector(GhosttySurfaceNSView.selectionForFind(_:)),
            keyEquivalent: ""
        )
        return menu
    }
}

/// Pure routing for the terminal context menu, so the load-bearing branches
/// are testable without an AppKit event loop.
enum GhosttySurfaceContextMenuPolicy {
    enum RightClickRoute: Equatable {
        /// Send a real right-button press to libghostty (mouse-mode TUI).
        case forwardToTerminal
        /// Show the awesoMux terminal context menu.
        case presentMenu
        /// Dead pane: neither, matching the pre-menu behavior.
        case ignore
    }

    static func rightClickRoute(hasSurface: Bool, mouseCaptured: Bool) -> RightClickRoute {
        guard hasSurface else {
            return .ignore
        }
        return mouseCaptured ? .forwardToTerminal : .presentMenu
    }

    enum CtrlLeftRoute: Equatable {
        /// Captured: let the click through to the terminal as a real event.
        case suppressMenu
        /// Live and uncaptured: the gesture means "context menu".
        case showMenu
        /// Not a ctrl+click, or no surface — AppKit's default applies.
        case deferToSuper
    }

    static func ctrlLeftRoute(
        hasControlModifier: Bool,
        hasSurface: Bool,
        mouseCaptured: Bool
    ) -> CtrlLeftRoute {
        guard hasControlModifier, hasSurface else {
            return .deferToSuper
        }
        return mouseCaptured ? .suppressMenu : .showMenu
    }
}
