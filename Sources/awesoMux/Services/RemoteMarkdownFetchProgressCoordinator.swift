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

    /// Begins one waiter. Returns `true` when this is the first waiter for
    /// the identity in this session (loading speech belongs here, like OSC).
    @discardableResult
    func begin(
        sessionID: TerminalSession.ID,
        identity: ResourceIdentity,
        origin: Origin
    ) -> Bool {
        let key = Key(sessionID: sessionID, identity: identity)
        var state = waiters[key] ?? WaiterState()
        let isFirstWaiter = state.count == 0
        state.count += 1
        switch origin {
        case .surface(let paneID):
            state.surfacePaneIDs[paneID, default: 0] += 1
        case .document:
            state.documentCount += 1
        }
        waiters[key] = state
        notify(origin: origin, sessionID: sessionID)
        return isFirstWaiter
    }

    func finish(
        sessionID: TerminalSession.ID,
        identity: ResourceIdentity,
        origin: Origin
    ) {
        let key = Key(sessionID: sessionID, identity: identity)
        guard var state = waiters[key], state.count > 0 else { return }
        state.count -= 1
        switch origin {
        case .surface(let paneID):
            let remaining = (state.surfacePaneIDs[paneID] ?? 1) - 1
            if remaining <= 0 {
                state.surfacePaneIDs[paneID] = nil
            } else {
                state.surfacePaneIDs[paneID] = remaining
            }
        case .document:
            state.documentCount = max(0, state.documentCount - 1)
        }
        if state.count == 0 {
            waiters[key] = nil
        } else {
            waiters[key] = state
        }
        notify(origin: origin, sessionID: sessionID)
    }

    func isInFlight(sessionID: TerminalSession.ID, identity: ResourceIdentity) -> Bool {
        (waiters[Key(sessionID: sessionID, identity: identity)]?.count ?? 0) > 0
    }

    func isSurfaceBusy(sessionID: TerminalSession.ID, paneID: TerminalPane.ID) -> Bool {
        waiters.contains { key, state in
            key.sessionID == sessionID && (state.surfacePaneIDs[paneID] ?? 0) > 0
        }
    }

    func isDocumentBusy(sessionID: TerminalSession.ID) -> Bool {
        waiters.contains { key, state in
            key.sessionID == sessionID && state.documentCount > 0
        }
    }

    func registerSurface(
        _ presenter: any RemoteMarkdownFetchProgressSurfacePresenting,
        sessionID: TerminalSession.ID,
        paneID: TerminalPane.ID
    ) {
        compactPresenters(removing: presenter)
        let key = SurfaceKey(sessionID: sessionID, paneID: paneID)
        surfacePresenters[key] = WeakSurfacePresenter(presenter)
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
    }

    private func notify(origin: Origin, sessionID: TerminalSession.ID) {
        switch origin {
        case .surface(let paneID):
            let key = SurfaceKey(sessionID: sessionID, paneID: paneID)
            if let presenter = surfacePresenters[key]?.presenter {
                presenter.syncRemoteMarkdownFetchProgress(
                    isBusy: isSurfaceBusy(sessionID: sessionID, paneID: paneID)
                )
            } else {
                surfacePresenters[key] = nil
            }
        case .document:
            break
        }
    }

    private func compactPresenters(
        removing presenter: (any RemoteMarkdownFetchProgressSurfacePresenting)? = nil
    ) {
        let objectID = presenter.map { ObjectIdentifier($0 as AnyObject) }
        surfacePresenters = surfacePresenters.filter { _, box in
            guard box.presenter != nil else { return false }
            if let objectID, box.objectID == objectID { return false }
            return true
        }
    }
}
