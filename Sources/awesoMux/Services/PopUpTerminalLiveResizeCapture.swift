import CoreGraphics

/// Distinguishes user-driven live resizes of the Terminal Companion from
/// programmatic frame mutations (fold animations, reanchoring), so only the
/// user's chosen size is remembered.
struct PopUpTerminalLiveResizeCapture {
    private var isActive = false
    private var programmaticMutationDepth = 0

    var isResizing: Bool { isActive }

    mutating func start() {
        guard programmaticMutationDepth == 0 else { return }
        isActive = true
    }

    mutating func finish(with size: CGSize) -> CGSize? {
        guard programmaticMutationDepth == 0, isActive else {
            isActive = false
            return nil
        }
        isActive = false
        return size
    }

    mutating func beginProgrammaticMutation() {
        programmaticMutationDepth += 1
        isActive = false
    }

    mutating func endProgrammaticMutation() {
        // A fold completion can land after close()/tearDown() already ran
        // reset(); the floor keeps the depth non-negative in that ordering.
        programmaticMutationDepth = max(0, programmaticMutationDepth - 1)
    }

    mutating func reset() {
        isActive = false
        programmaticMutationDepth = 0
    }
}
