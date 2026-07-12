import Foundation

struct FloatingPanelDismissConfirmationState: Equatable {
    static let pendingConfirmationTimeout: TimeInterval = 3

    enum RequestSource: Equatable {
        case escape
        case nonEscape
    }

    enum Decision: Equatable {
        case dismiss
        case hide
        case needsConfirmation
        case discardConfirmed
    }

    private(set) var isPending = false
    private var pendingArmedAt: Date?

    mutating func decision(
        hasDiscardRisk: Bool,
        source: RequestSource = .escape,
        now: Date = Date()
    ) -> Decision {
        expirePendingConfirmation(now: now)

        guard hasDiscardRisk else {
            reset()
            return .dismiss
        }

        guard source == .escape else {
            reset()
            return .hide
        }

        if isPending {
            reset()
            return .discardConfirmed
        }

        isPending = true
        pendingArmedAt = now
        return .needsConfirmation
    }

    mutating func reset() {
        isPending = false
        pendingArmedAt = nil
    }

    mutating func expirePendingConfirmation(now: Date = Date()) {
        guard let pendingArmedAt,
              now.timeIntervalSince(pendingArmedAt) >= Self.pendingConfirmationTimeout else {
            return
        }
        reset()
    }
}
