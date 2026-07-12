import CoreGraphics

/// The two layout modes a sidebar width resolves to: full rows or the icon rail.
/// (Free-drag has no intermediate mode — see `SidebarWidthPolicy.mode(for:)`.)
public enum SidebarWidthMode: Equatable, Sendable {
    case expanded
    case collapsed
}

/// Canonical sidebar-width policy for the main shell.
///
/// The sidebar drags freely; its dynamic maximum is enforced by the split
/// delegate against the live window width (INT-535). A commit preserves the
/// exact dragged width above the rail threshold and settles to the tight rail
/// below it.
public enum SidebarWidthPolicy {
    public static let expandedWidth: CGFloat = 296
    public static let collapsedWidth: CGFloat = 60
    public static let defaultWidth: CGFloat = expandedWidth
    public static let fallbackLastNonCollapsedWidth: CGFloat = expandedWidth

    /// Free-drag uses two layout modes: full rows (`expanded`) until the sidebar is
    /// dragged narrower than this, then the icon rail (`collapsed`). Below it the
    /// width settles to the tight `collapsedWidth` (no wide, mostly-empty rail).
    public static let railThreshold: CGFloat = 250

    /// Free-drag commit width: above the rail threshold, preserve the exact dragged
    /// width (the *maximum* is enforced dynamically by the split delegate against
    /// the live window width, so the sidebar can go arbitrarily wide). In the rail
    /// zone, settle to the tight `collapsedWidth` so the rail is never a wide,
    /// mostly-empty column.
    public static func committedWidth(for width: CGFloat) -> CGFloat {
        guard width.isFinite else { return defaultWidth }
        let floored = max(width, collapsedWidth)
        return floored < railThreshold ? collapsedWidth : floored
    }

    /// Live/programmatic width clamp: enforce the dynamic split maximum while
    /// preserving the no-wide-rail invariant used by committed sidebar widths.
    public static func constrainedLiveWidth(for proposed: CGFloat, maxWidth: CGFloat) -> CGFloat {
        guard proposed.isFinite else { return collapsedWidth }
        let ceiling = max(collapsedWidth, maxWidth)
        let clamped = min(max(proposed, collapsedWidth), ceiling)
        return clamped < railThreshold ? collapsedWidth : clamped
    }

    /// True when the sidebar is sitting at the rail, the window now has room for an
    /// expanded sidebar again, and the user did not choose the rail themselves — so
    /// a too-narrow window forced the collapse and the caller should restore the
    /// last expanded width.
    public static func shouldRestoreExpanded(
        currentWidth: CGFloat,
        maxWidth: CGFloat,
        userChoseRail: Bool
    ) -> Bool {
        currentWidth < railThreshold
            && maxWidth >= railThreshold
            && !userChoseRail
    }

    /// Free-drag layout mode: full rows until the rail threshold, then the icon
    /// rail. Two modes only — narrowing keeps the full rows until the threshold,
    /// then snaps straight to the rail.
    public static func mode(for width: CGFloat) -> SidebarWidthMode {
        committedWidth(for: width) < railThreshold ? .collapsed : .expanded
    }

    public static func normalizedLastNonCollapsedWidth(_ width: CGFloat?) -> CGFloat {
        guard let width else {
            return fallbackLastNonCollapsedWidth
        }

        // Preserve the exact free width so `⌘\` restores what the user dragged to,
        // not a snapped canonical (INT-535). Only fall back when the stored width
        // is itself collapsed-band or non-finite.
        let committed = committedWidth(for: width)
        return mode(for: committed) == .collapsed
            ? fallbackLastNonCollapsedWidth
            : committed
    }

    public static func toggleWidth(
        currentWidth: CGFloat,
        lastNonCollapsedWidth: CGFloat?
    ) -> CGFloat {
        if mode(for: currentWidth) == .collapsed {
            return normalizedLastNonCollapsedWidth(lastNonCollapsedWidth)
        }

        return collapsedWidth
    }

    public static func updatedLastNonCollapsedWidth(
        currentWidth: CGFloat,
        previousLastNonCollapsedWidth: CGFloat?
    ) -> CGFloat {
        // Preserve the exact free width (INT-535) — only retain the previous value
        // when the current width is in the collapsed band.
        let committed = committedWidth(for: currentWidth)
        if mode(for: committed) == .collapsed {
            return normalizedLastNonCollapsedWidth(previousLastNonCollapsedWidth)
        }
        return committed
    }
}
