import Foundation

extension Notification.Name {
    /// Posted when a genuinely-presented scrollback-dump sheet dismisses, so
    /// the app root can replay a queued managed-SSH workspace offer. The dump
    /// sheet lives per-pane in the surface search overlay and cannot reach
    /// the app's sheet-request state directly; before issue #202 the replay
    /// rode the aggregate `isAnySheetPresented` onChange, which also fired
    /// for sheets that never actually presented.
    static let awesoMuxManagedSSHOfferReplayRequested = Notification.Name(
        "com.interactivebuffoonery.awesomux.managedSSHOfferReplayRequested"
    )
}
