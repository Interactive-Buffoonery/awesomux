struct InitialEmptyFocusClearState {
    private(set) var isPending = false
    private var didRequest = false

    mutating func requestIfNeeded(hasSelectedSession: Bool) {
        guard !didRequest else { return }
        didRequest = true
        isPending = !hasSelectedSession
    }

    mutating func consumeIfEligible(
        hasSelectedSession: Bool,
        isHostingWindowKey: Bool
    ) -> Bool {
        guard isPending else { return false }
        guard !hasSelectedSession else {
            isPending = false
            return false
        }
        guard isHostingWindowKey else { return false }

        isPending = false
        return true
    }
}
