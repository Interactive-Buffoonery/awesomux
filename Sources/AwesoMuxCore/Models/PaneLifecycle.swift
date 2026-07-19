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

/// A leaf's lifecycle, modeled as a SUM of mutually-exclusive stages so invalid
/// combinations are unrepresentable by construction.
///
/// A leaf is EITHER live — carrying its derived `availability` and its supplied
/// `visibility` — or being torn down (`.closing`, which may still animate
/// visibly) or gone (`.closed`). A product of three independent axes could
/// express nonsense like closed-but-attached or closed-but-visible; the sum type
/// cannot. It still covers the issue's whole vocabulary: awaiting-hydration /
/// attached / unavailable / stale via `.live` availability, hidden via `.live`
/// visibility, plus `.closing` and `.closed`. Each input is produced by its own
/// authority — availability derived from the leaf, visibility from the mounting
/// layer, phase from the close pipeline.
public enum PaneLifecycle: Hashable, Sendable {
    case live(availability: PaneAvailability, visibility: PaneVisibility)
    case closing
    case closed
}

public extension WorkspaceLeaf {
    /// The leaf's lifecycle: `availability` derived from the leaf, mount state
    /// and close phase supplied by their owning layers (defaults to a mounted,
    /// non-closing live leaf).
    func lifecycle(
        isMounted: Bool = true,
        closePhase: PaneClosePhase = .active
    ) -> PaneLifecycle {
        switch closePhase {
        case .active:
            .live(availability: availability, visibility: PaneVisibility(isMounted: isMounted))
        case .closing:
            .closing
        case .closed:
            .closed
        }
    }
}
