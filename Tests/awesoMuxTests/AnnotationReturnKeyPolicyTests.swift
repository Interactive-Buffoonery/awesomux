import AppKit
import Testing

@testable import awesoMux

@Suite("Annotation return-key policy")
struct AnnotationReturnKeyPolicyTests {
    @Test("plain Return saves")
    func plainReturnSaves() {
        #expect(AnnotationReturnKeyPolicy.outcome(for: []) == .save)
    }

    @Test("Shift-Return inserts a newline")
    func shiftReturnInsertsNewline() {
        #expect(AnnotationReturnKeyPolicy.outcome(for: [.shift]) == .insertNewline)
    }

    @Test("Option-Return inserts a newline")
    func optionReturnInsertsNewline() {
        #expect(AnnotationReturnKeyPolicy.outcome(for: [.option]) == .insertNewline)
    }

    @Test("Shift-Option-Return inserts a newline")
    func shiftOptionReturnInsertsNewline() {
        #expect(AnnotationReturnKeyPolicy.outcome(for: [.shift, .option]) == .insertNewline)
    }

    @Test("plain keypad Return saves")
    func keypadPlainReturnSaves() {
        #expect(AnnotationReturnKeyPolicy.outcome(for: [.numericPad]) == .save)
    }

    @Test("keypad Shift-Return inserts a newline")
    func keypadShiftReturnInsertsNewline() {
        #expect(AnnotationReturnKeyPolicy.outcome(for: [.shift, .numericPad]) == .insertNewline)
    }

    @Test("keypad Option-Return inserts a newline")
    func keypadOptionReturnInsertsNewline() {
        #expect(AnnotationReturnKeyPolicy.outcome(for: [.option, .numericPad]) == .insertNewline)
    }

    @Test("keypad Shift-Option-Return inserts a newline")
    func keypadShiftOptionReturnInsertsNewline() {
        #expect(
            AnnotationReturnKeyPolicy.outcome(for: [.shift, .option, .numericPad])
                == .insertNewline
        )
    }
}
