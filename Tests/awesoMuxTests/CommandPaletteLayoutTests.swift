import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Testing
@testable import awesoMux

@Suite("CommandPaletteLayout")
struct CommandPaletteLayoutTests {
    @Test("centers within the reference frame")
    func centersWithinReferenceFrame() throws {
        let origin = try #require(CommandPaletteLayout.origin(
            panelSize: CGSize(width: 620, height: 430),
            referenceFrame: CGRect(x: 100, y: 100, width: 1200, height: 900),
            screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 1000)
        ))

        #expect(origin.x == 390)
        #expect(origin.y == 335)
    }

    @Test("search field command policy routes field-editor commands")
    func searchFieldCommandPolicyRoutesFieldEditorCommands() {
        #expect(CommandPaletteSearchCommand.command(for: #selector(NSResponder.moveDown(_:))) == .move(1))
        #expect(CommandPaletteSearchCommand.command(for: #selector(NSResponder.moveUp(_:))) == .move(-1))
        #expect(CommandPaletteSearchCommand.command(for: #selector(NSResponder.insertNewline(_:))) == .submit(.toast))
        #expect(CommandPaletteSearchCommand.command(
            for: #selector(NSResponder.insertNewline(_:)),
            modifiers: .command
        ) == .submit(.floatingPanel))
        #expect(CommandPaletteSearchCommand.command(
            for: #selector(NSResponder.insertNewline(_:)),
            modifiers: [.command, .shift]
        ) == .submit(.newTab))
        #expect(CommandPaletteSearchCommand.command(
            for: #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)),
            modifiers: .command
        ) == .submit(.floatingPanel))
        #expect(CommandPaletteSearchCommand.command(for: #selector(NSResponder.cancelOperation(_:))) == .dismiss)
        #expect(CommandPaletteSearchCommand.command(for: #selector(NSResponder.deleteBackward(_:))) == nil)
    }

    @Test("search field command policy routes modified return key events")
    func searchFieldCommandPolicyRoutesModifiedReturnKeyEvents() {
        #expect(CommandPaletteSearchCommand.command(
            forKeyCode: UInt16(kVK_Return)
        ) == .submit(.toast))
        #expect(CommandPaletteSearchCommand.command(
            forKeyCode: UInt16(kVK_Return),
            modifiers: .command
        ) == .submit(.floatingPanel))
        #expect(CommandPaletteSearchCommand.command(
            forKeyCode: UInt16(kVK_Return),
            modifiers: [.command, .shift]
        ) == .submit(.newTab))
        #expect(CommandPaletteSearchCommand.command(
            forKeyCode: UInt16(kVK_ANSI_KeypadEnter),
            modifiers: .command
        ) == .submit(.floatingPanel))
        #expect(CommandPaletteSearchCommand.command(
            forKeyCode: UInt16(kVK_Escape)
        ) == .dismiss)
        #expect(CommandPaletteSearchCommand.command(forKeyCode: UInt16(kVK_ANSI_A)) == nil)
    }

    @Test("clamps to visible screen inset")
    func clampsToVisibleScreen() throws {
        let origin = try #require(CommandPaletteLayout.origin(
            panelSize: CGSize(width: 620, height: 430),
            referenceFrame: CGRect(x: 0, y: 0, width: 500, height: 500),
            screenFrame: CGRect(x: 0, y: 0, width: 760, height: 560)
        ))

        #expect(origin.x >= 16)
        #expect(origin.y >= 16)
        #expect(origin.x + 620 <= 744)
        #expect(origin.y + 430 <= 544)
    }

    @Test("too-small visible frame keeps leading and bottom inset")
    func tooSmallVisibleFrameKeepsLeadingAndBottomInset() throws {
        let origin = try #require(CommandPaletteLayout.origin(
            panelSize: CGSize(width: 620, height: 430),
            referenceFrame: CGRect(x: 0, y: 0, width: 500, height: 400),
            screenFrame: CGRect(x: 0, y: 0, width: 640, height: 440)
        ))

        #expect(origin.x == 16)
        #expect(origin.y == 16)
    }

    @Test("resolved size is unchanged when the screen has room")
    func resolvedSizeUnchangedWithRoom() {
        let size = CommandPaletteLayout.resolvedSize(
            screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900)
        )

        #expect(size == CommandPaletteLayout.defaultSize)
    }

    @Test("resolved size shrinks to fit a small visible frame")
    func resolvedSizeShrinksToFitSmallScreen() {
        let size = CommandPaletteLayout.resolvedSize(
            screenFrame: CGRect(x: 0, y: 0, width: 400, height: 300)
        )

        // 400 - 16*2 = 368 wide, 300 - 16*2 = 268 tall.
        #expect(size.width == 368)
        #expect(size.height == 268)
    }

    @Test("remembered origin is clamped back into the visible frame")
    func clampOriginPullsOffscreenOriginBackOnscreen() {
        let clamped = CommandPaletteLayout.clampOrigin(
            CGPoint(x: 5000, y: 5000),
            panelSize: CGSize(width: 620, height: 430),
            screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900)
        )

        // maxX = 1440 - 620 - 16 = 804, maxY = 900 - 430 - 16 = 454.
        #expect(clamped.x == 804)
        #expect(clamped.y == 454)
    }

    @Test("in-bounds remembered origin is left untouched")
    func clampOriginLeavesInBoundsOriginAlone() {
        let origin = CGPoint(x: 100, y: 120)
        let clamped = CommandPaletteLayout.clampOrigin(
            origin,
            panelSize: CGSize(width: 620, height: 430),
            screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900)
        )

        #expect(clamped == origin)
    }
}
