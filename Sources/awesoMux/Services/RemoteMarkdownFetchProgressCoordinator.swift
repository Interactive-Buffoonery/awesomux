import AwesoMuxCore
import Foundation
import Observation

/// A surface that can show terminal-origin remote Markdown fetch chrome.
///
/// `GhosttySurfaceNSView` is the production presenter. Tests use a fake so
/// refcount and workspace-switch reshow can be asserted without SSH.
@MainActor
protocol RemoteMarkdownFetchProgressSurfacePresenting: AnyObject {
    func syncRemoteMarkdownFetchProgress(isBusy: Bool)
}

/// Runtime in-flight chrome for remote Markdown fetches, keyed by session +
/// `ResourceIdentity` so coalesced waiters share one spinner and first-waiter
/// loading speech.
///
/// This is not a `DocumentPane` and is not persisted. Callers begin before
/// the SSH round trip and finish in `defer` so every waiter of a coalesced
/// fetch releases chrome. Presenters register independently: a workspace
/// switch that clears a surface spinner can reshow from still-in-flight
/// waiters when the pane remounts.
///
/// Document overlay is identity-keyed (fetch identity plus an optional source
/// pin), not session-wide, so switching to a local or unrelated tab mid-fetch
/// clears that pane's overlay. Views observe `documentOverlayKeys` — a set
/// updated on begin/finish edges — rather than the whole waiters map.
@MainActor
@Observable
final class RemoteMarkdownFetchProgressCoordinator {
    static let shared = RemoteMarkdownFetchProgressCoordinator()

    enum Origin: Equatable, Sendable {
        case surface(paneID: TerminalPane.ID)
        case document
    }

    struct Key: Hashable, Sendable {
        let sessionID: TerminalSession.ID
        let identity: ResourceIdentity
    }

    /// One begun waiter. Typed-path sheet submit claims this synchronously
    /// before dismiss; `open` adopts it instead of beginning again.
    struct Claim: Equatable, Sendable {
        let sessionID: TerminalSession.ID
        let identity: ResourceIdentity
        let origin: Origin
        let overlayIdentity: ResourceIdentity?
        let isFirstWaiter: Bool
    }

    private struct SurfaceKey: Hashable {
        let sessionID: TerminalSession.ID
        let paneID: TerminalPane.ID
    }

    private struct WaiterState {
        var count = 0
        var surfacePaneIDs: [TerminalPane.ID: Int] = [:]
        var documentCount = 0
    }

    private final class WeakSurfacePresenter {
        weak var presenter: (any RemoteMarkdownFetchProgressSurfacePresenting)?
        let objectID: ObjectIdentifier

        init(_ presenter: any RemoteMarkdownFetchProgressSurfacePresenting) {
            self.presenter = presenter
            self.objectID = ObjectIdentifier(presenter as AnyObject)
        }
    }

    private var waiters: [Key: WaiterState] = [:]
    private var surfacePresenters: [SurfaceKey: WeakSurfacePresenter] = [:]
    private var presenterKeys: [ObjectIdentifier: SurfaceKey] = [:]
    private var documentOverlayCounts: [Key: Int] = [:]
    private var surfaceBusyCounts: [SurfaceKey: Int] = [:]

    /// Identity-keyed document overlay pins. Tiny overlay hosts observe this
    /// set instead of walking `waiters`.
    private(set) var documentOverlayKeys: Set<Key> = []
    private var surfaceBusyPanes: Set<SurfaceKey> = []

    /// Begins one waiter. Returns `true` when this is the first waiter for
    /// the identity in this session (loading speech belongs here, like OSC).
    ///
    /// `overlayIdentity` pins document chrome to a source tab when the fetch
    /// identity differs (Md→Md, typed-path from a snapshot to another path).
    @discardableResult
    func begin(
        sessionID: TerminalSession.ID,
        identity: ResourceIdentity,
        origin: Origin,
        overlayIdentity: ResourceIdentity? = nil
    ) -> Bool {
        let key = Key(sessionID: sessionID, identity: identity)
        var state = waiters[key] ?? WaiterState()
        let isFirstWaiter = state.count == 0
        state.count += 1
        switch origin {
        case .surface(let paneID):
            state.surfacePaneIDs[paneID, default: 0] += 1
            incrementSurfaceBusy(sessionID: sessionID, paneID: paneID)
        case .document:
            state.documentCount += 1
            incrementOverlay(sessionID: sessionID, identity: identity)
            if let overlayIdentity, overlayIdentity != identity {
                incrementOverlay(sessionID: sessionID, identity: overlayIdentity)
            }
        }
        waiters[key] = state
        notify(origin: origin, sessionID: sessionID)
        return isFirstWaiter
    }

    /// Begins one waiter and returns a claim the caller can adopt later.
    func beginClaim(
        sessionID: TerminalSession.ID,
        identity: ResourceIdentity,
        origin: Origin,
        overlayIdentity: ResourceIdentity? = nil
    ) -> Claim {
        Claim(
            sessionID: sessionID,
            identity: identity,
            origin: origin,
            overlayIdentity: overlayIdentity,
            isFirstWaiter: begin(
                sessionID: sessionID,
                identity: identity,
                origin: origin,
                overlayIdentity: overlayIdentity
            )
        )
    }

    func finish(
        sessionID: TerminalSession.ID,
        identity: ResourceIdentity,
        origin: Origin,
        overlayIdentity: ResourceIdentity? = nil
    ) {
        let key = Key(sessionID: sessionID, identity: identity)
        guard var state = waiters[key], state.count > 0 else { return }
        switch origin {
        case .surface(let paneID):
            guard let paneCount = state.surfacePaneIDs[paneID], paneCount > 0 else {
                return
            }
            let remaining = paneCount - 1
            if remaining == 0 {
                state.surfacePaneIDs[paneID] = nil
            } else {
                state.surfacePaneIDs[paneID] = remaining
            }
            decrementSurfaceBusy(sessionID: sessionID, paneID: paneID)
        case .document:
            guard state.documentCount > 0 else { return }
            state.documentCount -= 1
            decrementOverlay(sessionID: sessionID, identity: identity)
            if let overlayIdentity, overlayIdentity != identity {
                decrementOverlay(sessionID: sessionID, identity: overlayIdentity)
            }
        }
        state.count -= 1
        if state.count == 0 {
            waiters[key] = nil
        } else {
            waiters[key] = state
        }
        notify(origin: origin, sessionID: sessionID)
    }

    func finish(_ claim: Claim) {
        finish(
            sessionID: claim.sessionID,
            identity: claim.identity,
            origin: claim.origin,
            overlayIdentity: claim.overlayIdentity
        )
    }

    func isInFlight(sessionID: TerminalSession.ID, identity: ResourceIdentity) -> Bool {
        (waiters[Key(sessionID: sessionID, identity: identity)]?.count ?? 0) > 0
    }

    func isSurfaceBusy(sessionID: TerminalSession.ID, paneID: TerminalPane.ID) -> Bool {
        surfaceBusyPanes.contains(SurfaceKey(sessionID: sessionID, paneID: paneID))
    }

    /// Document overlay for this selected-tab identity, including a source pin
    /// when the in-flight fetch identity differs.
    func isDocumentOverlayBusy(
        sessionID: TerminalSession.ID,
        identity: ResourceIdentity
    ) -> Bool {
        documentOverlayKeys.contains(Key(sessionID: sessionID, identity: identity))
    }

    func registerSurface(
        _ presenter: any RemoteMarkdownFetchProgressSurfacePresenting,
        sessionID: TerminalSession.ID,
        paneID: TerminalPane.ID
    ) {
        compactPresenters(removing: presenter)
        let key = SurfaceKey(sessionID: sessionID, paneID: paneID)
        let box = WeakSurfacePresenter(presenter)
        surfacePresenters[key] = box
        presenterKeys[box.objectID] = key
        presenter.syncRemoteMarkdownFetchProgress(
            isBusy: isSurfaceBusy(sessionID: sessionID, paneID: paneID)
        )
    }

    func unregisterSurface(_ presenter: any RemoteMarkdownFetchProgressSurfacePresenting) {
        compactPresenters(removing: presenter)
    }

    func resetForTesting() {
        waiters.removeAll()
        surfacePresenters.removeAll()
        presenterKeys.removeAll()
        documentOverlayCounts.removeAll()
        documentOverlayKeys.removeAll()
        surfaceBusyCounts.removeAll()
        surfaceBusyPanes.removeAll()
    }

    private func incrementOverlay(sessionID: TerminalSession.ID, identity: ResourceIdentity) {
        let key = Key(sessionID: sessionID, identity: identity)
        let next = (documentOverlayCounts[key] ?? 0) + 1
        documentOverlayCounts[key] = next
        if next == 1 {
            documentOverlayKeys.insert(key)
        }
    }

    private func decrementOverlay(sessionID: TerminalSession.ID, identity: ResourceIdentity) {
        let key = Key(sessionID: sessionID, identity: identity)
        guard let current = documentOverlayCounts[key], current > 0 else { return }
        if current == 1 {
            documentOverlayCounts[key] = nil
            documentOverlayKeys.remove(key)
        } else {
            documentOverlayCounts[key] = current - 1
        }
    }

    private func incrementSurfaceBusy(sessionID: TerminalSession.ID, paneID: TerminalPane.ID) {
        let key = SurfaceKey(sessionID: sessionID, paneID: paneID)
        let next = (surfaceBusyCounts[key] ?? 0) + 1
        surfaceBusyCounts[key] = next
        if next == 1 {
            surfaceBusyPanes.insert(key)
        }
    }

    private func decrementSurfaceBusy(sessionID: TerminalSession.ID, paneID: TerminalPane.ID) {
        let key = SurfaceKey(sessionID: sessionID, paneID: paneID)
        guard let current = surfaceBusyCounts[key], current > 0 else { return }
        if current == 1 {
            surfaceBusyCounts[key] = nil
            surfaceBusyPanes.remove(key)
        } else {
            surfaceBusyCounts[key] = current - 1
        }
    }

    private func notify(origin: Origin, sessionID: TerminalSession.ID) {
        switch origin {
        case .surface(let paneID):
            let key = SurfaceKey(sessionID: sessionID, paneID: paneID)
            if let presenter = surfacePresenters[key]?.presenter {
                presenter.syncRemoteMarkdownFetchProgress(
                    isBusy: isSurfaceBusy(sessionID: sessionID, paneID: paneID)
                )
            } else if let box = surfacePresenters.removeValue(forKey: key) {
                presenterKeys.removeValue(forKey: box.objectID)
            }
        case .document:
            break
        }
    }

    private func compactPresenters(
        removing presenter: (any RemoteMarkdownFetchProgressSurfacePresenting)? = nil
    ) {
        if let presenter {
            let objectID = ObjectIdentifier(presenter as AnyObject)
            if let existingKey = presenterKeys.removeValue(forKey: objectID) {
                surfacePresenters[existingKey] = nil
            }
        }
        let staleKeys = surfacePresenters.compactMap { key, box -> SurfaceKey? in
            box.presenter == nil ? key : nil
        }
        for key in staleKeys {
            if let box = surfacePresenters.removeValue(forKey: key) {
                presenterKeys.removeValue(forKey: box.objectID)
            }
        }
    }
}
