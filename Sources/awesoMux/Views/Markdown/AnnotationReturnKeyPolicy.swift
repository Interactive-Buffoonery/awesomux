import AppKit

enum AnnotationReturnKeyOutcome: Equatable {
    case save
    case insertNewline
}

enum AnnotationReturnKeyPolicy {
    static func outcome(for modifiers: NSEvent.ModifierFlags) -> AnnotationReturnKeyOutcome {
        modifiers.contains(.shift) || modifiers.contains(.option) ? .insertNewline : .save
    }
}
