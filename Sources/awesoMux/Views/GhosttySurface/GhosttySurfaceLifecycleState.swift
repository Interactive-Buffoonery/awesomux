import AppKit
import AwesoMuxCore

@MainActor
final class GhosttySurfaceLifecycleState {
    weak var observedWindow: NSWindow?
    var lastKnownOcclusionVisible: Bool = false
    var lastAppliedSurfaceBackingState: SurfaceBackingState?
    var pendingSurfaceCreationWorkItem: DispatchWorkItem?
    var coldStartCreationState = ColdStartSurfaceCreationState()
    var windowFrameSettleState = WindowFrameSettleState()
    var nativeSurfaceWasDisposed = false
    var contentSizeBacking: NSSize?
    /// True while an eased sidebar-divider settle animation is in flight (#81). The
    /// animation moves the divider programmatically, so AppKit never raises
    /// `inLiveResize`; this stands in for it so per-frame surface reflow coalesces
    /// and flushes once when the settle ends.
    var isSettlingDividerAnimation = false
    var remoteHandoffTask: Task<Void, Never>?
    var bridgePreflightTask: Task<Void, Never>?
    var bridgePreflightGeneration: UInt64 = 0
    var bridgePreflightDependencies = BridgePreflightDependencies.live
    var nextMouseSurfaceIncarnationID: UInt64 = 0
    var mouseSurfaceIncarnationID: UInt64?
}
