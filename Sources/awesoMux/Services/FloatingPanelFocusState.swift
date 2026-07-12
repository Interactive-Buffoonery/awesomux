import Observation

@MainActor
@Observable
final class FloatingPanelFocusState {
    var isKeyWindow = false
    var promotionPhase: FloatingPanelPromotionPhase = .idle
    var discardConfirmationPending = false
}
