import AppKit
import Carbon.HIToolbox
import SwiftUI
import Testing
@testable import DesignSystem

@Suite("AwModal")
struct AwModalTests {
    @Test("configuration defaults confirm to destructive")
    func configurationDefaultsConfirmToDestructive() {
        let configuration = AwModalConfiguration(
            title: "Quit awesoMux?",
            body: "Running work may be interrupted.",
            confirmTitle: "Quit Anyway",
            cancelTitle: "Cancel"
        )

        #expect(configuration.isConfirmDestructive)
        #expect(configuration.confirmAccessibilityLabel == nil)
        #expect(configuration.cancelAccessibilityLabel == nil)
        #expect(configuration.keyboardHint == nil)
    }

    @Test("configuration preserves custom labels and non-destructive confirm")
    func configurationPreservesOverrides() {
        let configuration = AwModalConfiguration(
            title: "Open Workspace?",
            body: "This will create a new workspace.",
            confirmTitle: "Open",
            cancelTitle: "Cancel",
            confirmAccessibilityLabel: "Open workspace",
            cancelAccessibilityLabel: "Do not open workspace",
            keyboardHint: "Press Command-Return to open. Esc cancels.",
            isConfirmDestructive: false
        )

        #expect(configuration.title == "Open Workspace?")
        #expect(configuration.body == "This will create a new workspace.")
        #expect(configuration.confirmTitle == "Open")
        #expect(configuration.cancelTitle == "Cancel")
        #expect(configuration.confirmAccessibilityLabel == "Open workspace")
        #expect(configuration.cancelAccessibilityLabel == "Do not open workspace")
        #expect(configuration.keyboardHint == "Press Command-Return to open. Esc cancels.")
        #expect(!configuration.isConfirmDestructive)
    }

    @Test("decisions compare by case")
    func decisionsCompareByCase() {
        #expect(AwModalDecision.confirm == .confirm)
        #expect(AwModalDecision.cancel == .cancel)
        #expect(AwModalDecision.confirm != .cancel)
    }

    // Pins the INT-725 unification premise at the modal's seam: the accept
    // chord AwModal's panel consults must take keypad Enter (with its
    // ride-along .numericPad flag), exactly like the NSAlert dialogs.
    @Test(
        "modal accept chord takes Return and keypad Enter with command",
        arguments: [
            UInt16(kVK_Return),
            UInt16(kVK_ANSI_KeypadEnter)
        ]
    )
    func modalAcceptChordTakesReturnFamilyWithCommand(keyCode: UInt16) {
        #expect(
            AwKeyboardAcceptChord.isKeyboardAcceptKeyDown(
                keyCode: keyCode,
                modifiers: [.command, .numericPad]
            )
        )
        #expect(
            !AwKeyboardAcceptChord.isKeyboardAcceptKeyDown(
                keyCode: keyCode,
                modifiers: []
            )
        )
    }

    @Test("standalone hosted root injects the current UI font")
    @MainActor
    func standaloneHostedRootInjectsCurrentUIFont() {
        let previous = AwUIFontRuntime.current
        defer { AwUIFontRuntime.current = previous }
        AwUIFontRuntime.current = AwUIFontResolver(family: "Geist")

        let recorder = UIFontEnvironmentRecorder()
        let root = AwModalHostedRoot {
            UIFontEnvironmentProbe(recorder: recorder)
        }
        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = NSRect(x: 0, y: 0, width: 100, height: 40)

        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.alphaValue = 0
        window.orderFrontRegardless()
        window.layoutIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        window.orderOut(nil)

        #expect(recorder.family == "Geist")
    }
}

@MainActor
private final class UIFontEnvironmentRecorder {
    var family: String?
}

private struct UIFontEnvironmentProbe: View {
    @Environment(\.awUIFont) private var uiFont
    let recorder: UIFontEnvironmentRecorder

    var body: some View {
        Color.clear.onAppear {
            recorder.family = uiFont.family
        }
    }
}
