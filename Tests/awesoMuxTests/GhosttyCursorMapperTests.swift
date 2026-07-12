import GhosttyKit
import Testing
@testable import awesoMux

@Suite("GhosttyCursorMapper")
struct GhosttyCursorMapperTests {
    @Test(
        "maps every shape Ghostty's own macOS app supports",
        arguments: [
            (GHOSTTY_MOUSE_SHAPE_DEFAULT, GhosttyCursorStyle.default),
            (GHOSTTY_MOUSE_SHAPE_TEXT, .text),
            (GHOSTTY_MOUSE_SHAPE_GRAB, .grab),
            (GHOSTTY_MOUSE_SHAPE_GRABBING, .grabbing),
            (GHOSTTY_MOUSE_SHAPE_POINTER, .pointer),
            (GHOSTTY_MOUSE_SHAPE_W_RESIZE, .resizeWest),
            (GHOSTTY_MOUSE_SHAPE_E_RESIZE, .resizeEast),
            (GHOSTTY_MOUSE_SHAPE_N_RESIZE, .resizeNorth),
            (GHOSTTY_MOUSE_SHAPE_S_RESIZE, .resizeSouth),
            (GHOSTTY_MOUSE_SHAPE_NS_RESIZE, .resizeNorthSouth),
            (GHOSTTY_MOUSE_SHAPE_EW_RESIZE, .resizeEastWest),
            (GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT, .verticalText),
            (GHOSTTY_MOUSE_SHAPE_CONTEXT_MENU, .contextMenu),
            (GHOSTTY_MOUSE_SHAPE_CROSSHAIR, .crosshair),
            (GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED, .notAllowed)
        ] as [(ghostty_action_mouse_shape_e, GhosttyCursorStyle)]
    )
    func mapsSupportedShapes(
        shape: ghostty_action_mouse_shape_e,
        expected: GhosttyCursorStyle
    ) {
        #expect(GhosttyCursorMapper.style(for: shape) == expected)
    }

    @Test(
        "returns nil for shapes Ghostty's own macOS app doesn't map",
        arguments: [
            GHOSTTY_MOUSE_SHAPE_HELP,
            GHOSTTY_MOUSE_SHAPE_PROGRESS,
            GHOSTTY_MOUSE_SHAPE_WAIT,
            GHOSTTY_MOUSE_SHAPE_CELL,
            GHOSTTY_MOUSE_SHAPE_ALIAS,
            GHOSTTY_MOUSE_SHAPE_COPY,
            GHOSTTY_MOUSE_SHAPE_MOVE,
            GHOSTTY_MOUSE_SHAPE_NO_DROP,
            GHOSTTY_MOUSE_SHAPE_ALL_SCROLL,
            GHOSTTY_MOUSE_SHAPE_COL_RESIZE,
            GHOSTTY_MOUSE_SHAPE_ROW_RESIZE,
            GHOSTTY_MOUSE_SHAPE_NE_RESIZE,
            GHOSTTY_MOUSE_SHAPE_NW_RESIZE,
            GHOSTTY_MOUSE_SHAPE_SE_RESIZE,
            GHOSTTY_MOUSE_SHAPE_SW_RESIZE,
            GHOSTTY_MOUSE_SHAPE_NESW_RESIZE,
            GHOSTTY_MOUSE_SHAPE_NWSE_RESIZE,
            GHOSTTY_MOUSE_SHAPE_ZOOM_IN,
            GHOSTTY_MOUSE_SHAPE_ZOOM_OUT
        ]
    )
    func returnsNilForUnmappedShapes(shape: ghostty_action_mouse_shape_e) {
        #expect(GhosttyCursorMapper.style(for: shape) == nil)
    }
}
