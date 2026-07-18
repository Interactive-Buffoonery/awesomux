import Foundation

/// Whether a leaf is currently mounted to a visible surface. The mounting layer
/// owns this — it is not a property of the leaf value — so it is supplied, not
/// derived. A valid-but-unmounted leaf is "hidden" (the issue's lifecycle term).
public enum PaneVisibility: String, CaseIterable, Hashable, Sendable {
    case visible
    case hidden

    public init(isMounted: Bool) {
        self = isMounted ? .visible : .hidden
    }
}

/// A leaf's transient close phase. The close pipeline drives this — it has no
/// stored or derivable representation on the leaf — so it is supplied by the
/// close flow, defaulting to `.active` (not closing).
public enum PaneClosePhase: String, CaseIterable, Hashable, Sendable {
    case active
    case closing
    case closed
}

/// A leaf's full lifecycle across its three independent axes.
///
/// Composing three small value types (rather than one muddy enum) keeps each
/// axis produced by its own authority: `availability` is DERIVED from the leaf +
/// runtime signals, `visibility` is supplied by the mounting layer, and
/// `closePhase` by the close pipeline. Together they make the issue's whole
/// lifecycle vocabulary — restored/awaiting-hydration, attached, hidden,
/// disconnected/unavailable, stale/invalid, closing, closed — representable and
/// pattern-matchable, without any axis fabricating a state it cannot observe
/// (e.g. no classifier can emit `closing`, which only the close pipeline knows).
public struct PaneLifecycle: Hashable, Sendable {
    public let availability: PaneAvailability
    public let visibility: PaneVisibility
    public let closePhase: PaneClosePhase

    public init(
        availability: PaneAvailability,
        visibility: PaneVisibility = .visible,
        closePhase: PaneClosePhase = .active
    ) {
        self.availability = availability
        // The one real cross-axis invariant: a `.closed` leaf is gone and cannot
        // remain visible/mounted, so it normalizes to `.hidden`. `.closing` may
        // still be visible (animating out), so it is left free.
        self.visibility = closePhase == .closed ? .hidden : visibility
        self.closePhase = closePhase
    }
}

public extension WorkspaceLeaf {
    /// The leaf's lifecycle: `availability` derived from the leaf, `visibility`
    /// and `closePhase` supplied by their owning layers (defaults
    /// visible/active for a mounted, non-closing leaf).
    func lifecycle(
        isMounted: Bool = true,
        closePhase: PaneClosePhase = .active
    ) -> PaneLifecycle {
        PaneLifecycle(
            availability: availability,
            visibility: PaneVisibility(isMounted: isMounted),
            closePhase: closePhase
        )
    }
}
