public enum QuitAlertPresentationPolicy {
    public struct WindowCandidate<ID: Equatable>: Equatable {
        public let id: ID
        public let isVisible: Bool
        public let canBecomeMain: Bool
        public let hasAttachedSheet: Bool
        public let isAttachedSheet: Bool

        public init(
            id: ID,
            isVisible: Bool,
            canBecomeMain: Bool,
            hasAttachedSheet: Bool,
            isAttachedSheet: Bool
        ) {
            self.id = id
            self.isVisible = isVisible
            self.canBecomeMain = canBecomeMain
            self.hasAttachedSheet = hasAttachedSheet
            self.isAttachedSheet = isAttachedSheet
        }

        var isSuitableSheetParent: Bool {
            isVisible && canBecomeMain && !hasAttachedSheet && !isAttachedSheet
        }

        var blocksFocusedSheetPresentation: Bool {
            isVisible && ((canBecomeMain && hasAttachedSheet) || isAttachedSheet)
        }
    }

    public enum Target<ID: Equatable>: Equatable {
        case sheet(ID)
        case appModal
    }

    /// Prefer the focused window when safe; use app-modal when a focused sheet would hide the alert.
    public static func target<ID: Equatable>(
        mainWindow: WindowCandidate<ID>?,
        keyWindow: WindowCandidate<ID>?,
        orderedWindows: [WindowCandidate<ID>]
    ) -> Target<ID> {
        if let mainWindow, mainWindow.isSuitableSheetParent {
            return .sheet(mainWindow.id)
        }

        if let keyWindow, keyWindow.isSuitableSheetParent {
            return .sheet(keyWindow.id)
        }

        if mainWindow?.blocksFocusedSheetPresentation == true
            || keyWindow?.blocksFocusedSheetPresentation == true {
            return .appModal
        }

        if let fallback = orderedWindows.first(where: \.isSuitableSheetParent) {
            return .sheet(fallback.id)
        }

        return .appModal
    }
}
