/// The user decision returned by an awesoMux modal.
public enum AwModalDecision: Sendable, Equatable {
    /// The user accepted the confirm action.
    case confirm
    /// The user cancelled or dismissed the modal.
    case cancel
}
