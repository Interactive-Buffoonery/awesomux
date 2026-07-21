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
    var remoteHandoffTask: Task<Void, Never>?
    var bridgePreflightTask: Task<Void, Never>?
    var bridgePreflightGeneration: UInt64 = 0
    var bridgePreflightDependencies = BridgePreflightDependencies.live
    var nextMouseSurfaceIncarnationID: UInt64 = 0
    var mouseSurfaceIncarnationID: UInt64?
}
