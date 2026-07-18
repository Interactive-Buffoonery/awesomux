import Foundation

/// A workspace leaf's runtime-attachment classification — the DERIVABLE part of
/// the "type-aware lifecycle" the typed model owns.
///
/// The issue's lifecycle vocabulary (restored/awaiting-hydration, attached,
/// hidden, disconnected/unavailable, stale/invalid, closing, closed) splits
/// across three independent axes; conflating them into one classifier enum
/// produces cases no producer can ever emit. This type is only the axis that a
/// pure function can derive from a leaf plus its runtime signals:
///
/// - **Availability** (this type) — derived from the leaf + runtime signals.
/// - **Visibility** — a separate `isMounted: Bool` the mounting layer owns; a
///   valid-but-unmounted leaf is "hidden". Not modeled here because it is not a
///   property of the leaf, and a `Bool` needs no enum.
/// - **Close phase** — `closing`/`closed` are transient states the close
///   pipeline drives (see `PaneCloseConsequence`); they have no stored
///   representation, so no classifier branch fabricates them.
///
/// See `docs/architecture.md` — "Typed workspace-pane model" for the mapping.
public enum PaneAvailability: String, CaseIterable, Hashable, Sendable {
    /// Restored from disk, not yet attached to a live surface/daemon (lazy
    /// mount). The safe default for a freshly decoded leaf.
    case awaitingHydration
    /// Attached to a live process, surface, or daemon session.
    case attached
    /// The source is gone or a dead bridge needs a manual reconnect. Never
    /// silently reclassified as a healthy local attach.
    case unavailable
    /// Remotely degraded — a possibly-stale connection or a reconnect in flight.
    case stale
}

public extension PaneAvailability {
    static func of(_ leaf: WorkspaceLeaf) -> PaneAvailability {
        switch leaf {
        case let .terminal(pane):
            terminal(
                liveness: pane.foregroundProcessLiveness,
                connectionHealth: pane.remoteConnectionHealth,
                reconnect: pane.remoteReconnect,
                backendMetadata: pane.terminalBackendMetadata
            )
        case .documentGroup:
            // A document group has no runtime attachment lifecycle: once present
            // in a layout it is rendered from a local cache, so it is always
            // attached. Per-tab source reachability is a content concern, not a
            // layout-availability one.
            .attached
        }
    }

    /// Pure terminal truth table. Order encodes precedence: an explicit reconnect
    /// state (disconnected → unavailable, in-flight → stale) outranks a bare
    /// `.exited` liveness, because a reconnecting bridge's old child exits by
    /// design — an in-flight reconnect must read as `.stale`, not `.unavailable`.
    /// A dead source then outranks a stale hint, which outranks the un-mounted
    /// default.
    static func terminal(
        liveness: ForegroundProcessLiveness,
        connectionHealth: RemoteConnectionHealth,
        reconnect: RemoteReconnectState?,
        backendMetadata: TerminalBackendMetadata
    ) -> PaneAvailability {
        if case .disconnected = reconnect {
            return .unavailable
        }
        if case .reconnecting = reconnect {
            return .stale
        }
        if liveness == .exited {
            return .unavailable
        }
        if connectionHealth == .possiblyStale {
            return .stale
        }
        if liveness == .unsampled, backendMetadata == .empty {
            return .awaitingHydration
        }
        return .attached
    }
}

public extension WorkspaceLeaf {
    var availability: PaneAvailability {
        .of(self)
    }
}
