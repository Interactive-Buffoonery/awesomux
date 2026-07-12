import AppKit
import Carbon.HIToolbox
import DesignSystem
import Testing
@testable import awesoMux

@Suite("Floating panel event policy")
struct FloatingPanelEventPolicyTests {
    private static let escapeKeyCode = UInt16(kVK_Escape)

    @Test("reclick activation accepts left mouse down")
    func reclickActivationAcceptsLeftMouseDown() {
        #expect(FloatingPanelEventPolicy.isReclickActivation(type: .leftMouseDown))
    }

    @Test("reclick activation preserves scroll wheel re-keying")
    func reclickActivationAcceptsScrollWheel() {
        #expect(FloatingPanelEventPolicy.isReclickActivation(type: .scrollWheel))
    }

    @Test(
        "reclick activation rejects other pointer and input events",
        arguments: [
            NSEvent.EventType.leftMouseUp,
            .rightMouseDown,
            .otherMouseDown,
            .mouseMoved,
            .keyDown,
            .flagsChanged,
            .tabletPoint,
            .pressure,
            .gesture
        ]
    )
    func reclickActivationRejectsOtherEvents(type: NSEvent.EventType) {
        #expect(!FloatingPanelEventPolicy.isReclickActivation(type: type))
    }

    @Test("dismiss chord accepts bare escape key down")
    func dismissChordAcceptsBareEscapeKeyDown() {
        #expect(
            FloatingPanelEventPolicy.isDismissChord(
                type: .keyDown,
                keyCode: Self.escapeKeyCode,
                isARepeat: false,
                modifiers: []
            )
        )
    }

    @Test(
        "dismiss chord rejects escape with active modifiers",
        arguments: [
            NSEvent.ModifierFlags.command,
            .shift,
            .option,
            .control,
            [.command, .capsLock],
            [.option, .function]
        ]
    )
    func dismissChordRejectsEscapeWithActiveModifiers(
        modifiers: NSEvent.ModifierFlags
    ) {
        #expect(
            !FloatingPanelEventPolicy.isDismissChord(
                type: .keyDown,
                keyCode: Self.escapeKeyCode,
                isARepeat: false,
                modifiers: modifiers
            )
        )
    }

    @Test(
        "dismiss chord ignores caps lock and function modifiers",
        arguments: [
            NSEvent.ModifierFlags.capsLock,
            .function,
            [.capsLock, .function]
        ]
    )
    func dismissChordIgnoresCapsLockAndFunctionModifiers(
        modifiers: NSEvent.ModifierFlags
    ) {
        #expect(
            FloatingPanelEventPolicy.isDismissChord(
                type: .keyDown,
                keyCode: Self.escapeKeyCode,
                isARepeat: false,
                modifiers: modifiers
            )
        )
    }

    @Test("dismiss chord rejects repeated escape")
    func dismissChordRejectsRepeatedEscape() {
        #expect(
            !FloatingPanelEventPolicy.isDismissChord(
                type: .keyDown,
                keyCode: Self.escapeKeyCode,
                isARepeat: true,
                modifiers: []
            )
        )
    }

    @Test(
        "dismiss chord rejects non-escape key codes",
        arguments: [
            UInt16(kVK_ANSI_A),
            UInt16(kVK_Tab),
            UInt16(kVK_Space),
            UInt16(kVK_Return),
            UInt16(kVK_Delete),
            UInt16(kVK_LeftArrow)
        ]
    )
    func dismissChordRejectsNonEscapeKeyCodes(keyCode: UInt16) {
        #expect(
            !FloatingPanelEventPolicy.isDismissChord(
                type: .keyDown,
                keyCode: keyCode,
                isARepeat: false,
                modifiers: []
            )
        )
    }

    @Test(
        "dismiss chord rejects non-key-down events",
        arguments: [
            NSEvent.EventType.keyUp,
            .flagsChanged,
            .leftMouseDown
        ]
    )
    func dismissChordRejectsNonKeyDownEvents(type: NSEvent.EventType) {
        #expect(
            !FloatingPanelEventPolicy.isDismissChord(
                type: type,
                keyCode: Self.escapeKeyCode,
                isARepeat: false,
                modifiers: []
            )
        )
    }

    // Real per-key modifier shapes: main-row Return carries only .command,
    // but keypad Enter keyDowns always carry the .numericPad device flag. The
    // pre-fix suite tested keypad Enter with a bare .command it never actually
    // receives (false green); these tuples use the flags each key really sends.
    @Test(
        "promote chord accepts command return per real key modifier shape",
        arguments: [
            (UInt16(kVK_Return), NSEvent.ModifierFlags.command),
            (UInt16(kVK_ANSI_KeypadEnter), [.command, .numericPad]),
            (UInt16(kVK_ANSI_KeypadEnter), [.command, .numericPad, .capsLock]),
            // Some full-size external keyboards' keypad Enter carries both
            // device flags.
            (UInt16(kVK_ANSI_KeypadEnter), [.command, .numericPad, .function])
        ] as [(UInt16, NSEvent.ModifierFlags)]
    )
    func promoteChordAcceptsCommandReturn(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags
    ) {
        #expect(
            FloatingPanelEventPolicy.isPromoteChord(
                type: .keyDown,
                keyCode: keyCode,
                isARepeat: false,
                modifiers: modifiers
            )
        )
    }

    @Test(
        "promote chord rejects non-command return variants",
        arguments: [
            NSEvent.ModifierFlags(),
            [.command, .shift],
            .option,
            [.command, .control]
        ]
    )
    func promoteChordRejectsNonCommandReturnVariants(
        modifiers: NSEvent.ModifierFlags
    ) {
        #expect(
            !FloatingPanelEventPolicy.isPromoteChord(
                type: .keyDown,
                keyCode: UInt16(kVK_Return),
                isARepeat: false,
                modifiers: modifiers
            )
        )
    }

    // Keypad-specific rejections: a real extra modifier (.shift) still vetoes,
    // and Command remains required even though .numericPad is subtracted.
    @Test(
        "promote chord rejects keypad enter without command or with extra modifier",
        arguments: [
            NSEvent.ModifierFlags([.command, .numericPad, .shift]),
            [.numericPad]
        ]
    )
    func promoteChordRejectsKeypadEnterVariants(
        modifiers: NSEvent.ModifierFlags
    ) {
        #expect(
            !FloatingPanelEventPolicy.isPromoteChord(
                type: .keyDown,
                keyCode: UInt16(kVK_ANSI_KeypadEnter),
                isARepeat: false,
                modifiers: modifiers
            )
        )
    }

    @Test("promote chord rejects repeats and non-return keys")
    func promoteChordRejectsRepeatsAndNonReturnKeys() {
        #expect(
            !FloatingPanelEventPolicy.isPromoteChord(
                type: .keyDown,
                keyCode: UInt16(kVK_Return),
                isARepeat: true,
                modifiers: .command
            )
        )
        #expect(
            !FloatingPanelEventPolicy.isPromoteChord(
                type: .keyDown,
                keyCode: UInt16(kVK_ANSI_A),
                isARepeat: false,
                modifiers: .command
            )
        )
    }

    @Test("floating panel promote is blocked while its panel has an attached sheet")
    func floatingPanelPromoteBlocksAttachedSheet() {
        #expect(FloatingPanelEventPolicy.canPromoteFloatingPanel(hasAttachedSheet: false))
        #expect(!FloatingPanelEventPolicy.canPromoteFloatingPanel(hasAttachedSheet: true))
    }

    @Test(
        "NSAlert keyboard accept accepts command return",
        arguments: [
            UInt16(kVK_Return),
            UInt16(kVK_ANSI_KeypadEnter)
        ]
    )
    func alertKeyboardAcceptAcceptsCommandReturn(keyCode: UInt16) {
        #expect(
            AwKeyboardAcceptChord.isKeyboardAcceptKeyDown(
                keyCode: keyCode,
                modifiers: .command
            )
        )
    }

    @Test(
        "NSAlert keyboard accept ignores passive modifiers",
        arguments: [
            NSEvent.ModifierFlags.capsLock,
            .function,
            .numericPad,
            [.capsLock, .function, .numericPad]
        ]
    )
    func alertKeyboardAcceptIgnoresPassiveModifiers(
        modifiers: NSEvent.ModifierFlags
    ) {
        #expect(
            AwKeyboardAcceptChord.isKeyboardAcceptKeyDown(
                keyCode: UInt16(kVK_Return),
                modifiers: [.command, modifiers]
            )
        )
    }

    @Test(
        "NSAlert keyboard accept rejects non-command variants",
        arguments: [
            NSEvent.ModifierFlags(),
            .shift,
            [.command, .shift],
            .option,
            [.command, .control]
        ]
    )
    func alertKeyboardAcceptRejectsNonCommandVariants(
        modifiers: NSEvent.ModifierFlags
    ) {
        #expect(
            !AwKeyboardAcceptChord.isKeyboardAcceptKeyDown(
                keyCode: UInt16(kVK_Return),
                modifiers: modifiers
            )
        )
    }

    @Test("NSAlert keyboard accept rejects non-return keys")
    func alertKeyboardAcceptRejectsNonReturnKeys() {
        #expect(
            !AwKeyboardAcceptChord.isKeyboardAcceptKeyDown(
                keyCode: UInt16(kVK_ANSI_A),
                modifiers: .command
            )
        )
    }
}
