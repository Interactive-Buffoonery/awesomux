import AwesoMuxCore
import Observation

enum FloatingToggleAction: Equatable {
    case show, restoreFocus, dismiss
}

/// The per-workspace slot bookkeeping for floating-mode terminal panels:
/// one `SessionStore` slot per parent workspace, the open/active sets, and the
/// backgrounded-running-work indicator that drives the sidebar dot. Extracted
/// from the former floating panel controller so the decisions are unit-tested
/// independently of AppKit window lifecycle. The unified controller owns one of
/// these only in floating mode.
///
/// Runtime side effects (refreshing quit-risk state via `GhosttyRuntime`,
/// tearing down libghostty surfaces) stay with the caller — this type only
/// tracks which slot exists and which set it belongs to.
@MainActor
final class FloatingSlotBook {
    /// Sentinel used when the panel is summoned without a selected workspace —
    /// keeps every "no workspace" summon hitting the same slot.
    static let unattachedWorkspaceID = TerminalSession.ID()

    private(set) var activeWorkspaceID: TerminalSession.ID?
    private(set) var openWorkspaceIDs: Set<TerminalSession.ID> = []
    private(set) var workspacesWithBackgroundedRunningWork: Set<TerminalSession.ID> = []
    private var floatingStores: [TerminalSession.ID: SessionStore] = [:]

    var allStores: [SessionStore] { Array(floatingStores.values) }
    var workspaceIDs: Set<TerminalSession.ID> { Set(floatingStores.keys) }

    func store(for id: TerminalSession.ID) -> SessionStore? { floatingStores[id] }

    func ensureStore(for id: TerminalSession.ID, make: () -> SessionStore) -> SessionStore {
        if let existing = floatingStores[id] { return existing }
        let store = make()
        floatingStores[id] = store
        return store
    }

    @discardableResult
    func removeStore(for id: TerminalSession.ID) -> SessionStore? {
        workspacesWithBackgroundedRunningWork.remove(id)
        return floatingStores.removeValue(forKey: id)
    }

    func markOpen(_ id: TerminalSession.ID) { openWorkspaceIDs.insert(id) }
    func markClosed(_ id: TerminalSession.ID) { openWorkspaceIDs.remove(id) }
    func setActive(_ id: TerminalSession.ID?) { activeWorkspaceID = id }

    /// Move the no-workspace sentinel slot onto the first real workspace so a
    /// preserved shell stays reachable from the sidebar and shortcut. Returns
    /// the migrated store so the caller can refresh its quit-risk state and
    /// recompute the backgrounded-work set with the runtime it holds.
    func migrateUnattached(to id: TerminalSession.ID) -> SessionStore? {
        guard activeWorkspaceID == Self.unattachedWorkspaceID,
              id != Self.unattachedWorkspaceID,
              floatingStores[id] == nil,
              let migrated = floatingStores.removeValue(forKey: Self.unattachedWorkspaceID) else {
            return nil
        }
        floatingStores[id] = migrated
        openWorkspaceIDs.remove(Self.unattachedWorkspaceID)
        activeWorkspaceID = id
        return migrated
    }

    func recomputeBackgroundedRunningWork(isVisible: Bool) {
        var next: Set<TerminalSession.ID> = []
        for (id, store) in floatingStores {
            if isVisible && id == activeWorkspaceID { continue }
            if !store.sessionsAtRiskOnQuit.isEmpty { next.insert(id) }
        }
        if next != workspacesWithBackgroundedRunningWork {
            workspacesWithBackgroundedRunningWork = next
        }
    }

    static func toggleAction(isOpen: Bool, isVisible: Bool, isKeyWindow: Bool) -> FloatingToggleAction {
        guard isOpen else { return .show }
        guard isVisible, isKeyWindow else { return .restoreFocus }
        return .dismiss
    }
}
