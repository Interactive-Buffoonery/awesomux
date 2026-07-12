/// Copy and behavior options for an awesoMux modal.
public struct AwModalConfiguration: Sendable, Equatable {
    /// The modal title.
    public let title: String
    /// The modal body copy.
    public let body: String
    /// The confirm button title.
    public let confirmTitle: String
    /// The cancel button title.
    public let cancelTitle: String
    /// The optional VoiceOver label for the confirm button.
    public let confirmAccessibilityLabel: String?
    /// The optional VoiceOver label for the cancel button.
    public let cancelAccessibilityLabel: String?
    /// The optional keyboard hint shown with the modal body. Supply a
    /// verb-specific line matching the confirm action (for example
    /// "Press ⌘Return to open. Return or Esc cancels.") — the generic
    /// "to confirm" fallback is a last resort, not a convention.
    public let keyboardHint: String?
    /// Whether the confirm action is destructive.
    public let isConfirmDestructive: Bool

    /// Creates a modal configuration.
    public init(
        title: String,
        body: String,
        confirmTitle: String,
        cancelTitle: String,
        confirmAccessibilityLabel: String? = nil,
        cancelAccessibilityLabel: String? = nil,
        keyboardHint: String? = nil,
        isConfirmDestructive: Bool = true
    ) {
        self.title = title
        self.body = body
        self.confirmTitle = confirmTitle
        self.cancelTitle = cancelTitle
        self.confirmAccessibilityLabel = confirmAccessibilityLabel
        self.cancelAccessibilityLabel = cancelAccessibilityLabel
        self.keyboardHint = keyboardHint
        self.isConfirmDestructive = isConfirmDestructive
    }
}
