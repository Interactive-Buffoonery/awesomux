import Foundation

/// When the notification permission *explanation* may be shown.
///
/// Priming at launch is the bug this replaces: on a fresh install the user is
/// asked about "a background workspace or agent" before either exists. Every
/// row here is a case that made the naive "does a workspace exist" gate wrong.
enum NotificationPrimePolicy {
    struct Inputs {
        var hasEligibleSession: Bool
        var isLaunchEvaluation: Bool
        var tourIsVisible: Bool
        var tourReachedNotificationBeat: Bool
        var anyChannelEnabled: Bool
        var requestInFlight: Bool
        var isNotDetermined: Bool
    }

    static func shouldPrime(_ inputs: Inputs) -> Bool {
        guard inputs.isNotDetermined else { return false }
        guard !inputs.requestInFlight else { return false }
        guard inputs.anyChannelEnabled else { return false }
        // Restore can make a workspace exist at launch; priming then would
        // reintroduce the launch-time ask under a different condition.
        guard !inputs.isLaunchEvaluation else { return false }
        guard inputs.hasEligibleSession else { return false }
        // The modal explanation would otherwise stack over the tour — the exact
        // two-competing-surfaces failure this work exists to remove.
        if inputs.tourIsVisible, !inputs.tourReachedNotificationBeat { return false }
        return true
    }
}
