import AppKit
import GhosttyKit

/// Identifies a terminal-requested cursor shape independent of any concrete
/// `NSCursor` instance, so the libghostty enum -> cursor mapping is testable
/// without a live NSCursor/WindowServer context. Mirrors Ghostty's own
/// `CursorStyle` abstraction (`vendor/ghostty/macos/Sources/Helpers/Cursor.swift`).
enum GhosttyCursorStyle: Equatable {
    case `default`
    case text
    case grab
    case grabbing
    case pointer
    case resizeWest
    case resizeEast
    case resizeNorth
    case resizeSouth
    case resizeNorthSouth
    case resizeEastWest
    case verticalText
    case contextMenu
    case crosshair
    case notAllowed
}

enum GhosttyCursorMapper {
    /// Maps libghostty's requested mouse shape to an awesoMux cursor style.
    ///
    /// libghostty's `ghostty_action_mouse_shape_e` has more cases (HELP,
    /// PROGRESS, WAIT, CELL, ALIAS, COPY, MOVE, NO_DROP, ALL_SCROLL,
    /// COL/ROW_RESIZE, the diagonal resizes, ZOOM_IN/OUT) than Ghostty's own
    /// macOS app maps (`SurfaceView_AppKit.swift:480-531`). Returns `nil` for
    /// those, matching Ghostty's `default: return` — callers should leave the
    /// current cursor unchanged rather than clearing it.
    static func style(for shape: ghostty_action_mouse_shape_e) -> GhosttyCursorStyle? {
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_DEFAULT:
            .default
        case GHOSTTY_MOUSE_SHAPE_TEXT:
            .text
        case GHOSTTY_MOUSE_SHAPE_GRAB:
            .grab
        case GHOSTTY_MOUSE_SHAPE_GRABBING:
            .grabbing
        case GHOSTTY_MOUSE_SHAPE_POINTER:
            .pointer
        case GHOSTTY_MOUSE_SHAPE_W_RESIZE:
            .resizeWest
        case GHOSTTY_MOUSE_SHAPE_E_RESIZE:
            .resizeEast
        case GHOSTTY_MOUSE_SHAPE_N_RESIZE:
            .resizeNorth
        case GHOSTTY_MOUSE_SHAPE_S_RESIZE:
            .resizeSouth
        case GHOSTTY_MOUSE_SHAPE_NS_RESIZE:
            .resizeNorthSouth
        case GHOSTTY_MOUSE_SHAPE_EW_RESIZE:
            .resizeEastWest
        case GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT:
            .verticalText
        case GHOSTTY_MOUSE_SHAPE_CONTEXT_MENU:
            .contextMenu
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR:
            .crosshair
        case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED:
            .notAllowed
        default:
            nil
        }
    }
}

extension GhosttyCursorStyle {
    /// awesoMux's deployment target is macOS 15+, so unlike Ghostty's own
    /// mapping this doesn't need an `#available(macOS 15.0, *)` fallback
    /// branch for the directional resize cursors.
    var nsCursor: NSCursor {
        switch self {
        case .default:
            .arrow
        case .grab:
            .openHand
        case .grabbing:
            .closedHand
        case .text:
            .iBeam
        case .verticalText:
            .iBeamCursorForVerticalLayout
        case .pointer:
            .pointingHand
        case .resizeWest:
            .columnResize(directions: .left)
        case .resizeEast:
            .columnResize(directions: .right)
        case .resizeNorth:
            .rowResize(directions: .up)
        case .resizeSouth:
            .rowResize(directions: .down)
        case .resizeNorthSouth:
            .rowResize
        case .resizeEastWest:
            .columnResize
        case .contextMenu:
            .contextualMenu
        case .crosshair:
            .crosshair
        case .notAllowed:
            .operationNotAllowed
        }
    }
}
