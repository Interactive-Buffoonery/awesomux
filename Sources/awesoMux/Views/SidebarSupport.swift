import AwesoMuxCore
import DesignSystem
import SwiftUI
import UniformTypeIdentifiers

/// Installs the ⌘-held monitor only while the rail is collapsed. The `if/else`
/// in `body` produces two distinct `_ConditionalContent` branch types, so SwiftUI
/// treats a collapsed→expanded transition as an unmount of the true branch — running
/// `onDisappear` and removing the NSEvent monitor — rather than diffing in place.
/// When expanded we also clear any stale held state.
struct CollapsedCommandKeyTracking: ViewModifier {
    let isCollapsed: Bool
    @Binding var isHeld: Bool

    func body(content: Content) -> some View {
        if isCollapsed {
            content.trackingCommandKeyHeld($isHeld)
        } else {
            content.onAppear { isHeld = false }
        }
    }
}

struct SidebarDensity {
    let groupStackSpacing: CGFloat
    let groupHeaderBottomPadding: CGFloat
    let sessionStackSpacing: CGFloat
    let sessionTileVerticalPadding: CGFloat
    let emptyGroupVerticalPadding: CGFloat

    init(compact: Bool) {
        self = compact ? .compact : .standard
    }

    private static let standard = SidebarDensity(
        groupStackSpacing: 14,
        groupHeaderBottomPadding: 3,
        sessionStackSpacing: 5,
        sessionTileVerticalPadding: 9,
        emptyGroupVerticalPadding: 7
    )

    private static let compact = SidebarDensity(
        groupStackSpacing: 8,
        groupHeaderBottomPadding: 1,
        sessionStackSpacing: 3,
        sessionTileVerticalPadding: 6,
        emptyGroupVerticalPadding: 5
    )

    private init(
        groupStackSpacing: CGFloat,
        groupHeaderBottomPadding: CGFloat,
        sessionStackSpacing: CGFloat,
        sessionTileVerticalPadding: CGFloat,
        emptyGroupVerticalPadding: CGFloat
    ) {
        self.groupStackSpacing = groupStackSpacing
        self.groupHeaderBottomPadding = groupHeaderBottomPadding
        self.sessionStackSpacing = sessionStackSpacing
        self.sessionTileVerticalPadding = sessionTileVerticalPadding
        self.emptyGroupVerticalPadding = emptyGroupVerticalPadding
    }
}

struct ProjectTint {
    let accent: AwTintAccent

    /// Bright fill for the group dot, active rail, and selection glow.
    let hue: Color

    /// Contrast-tuned variant for the selected-row border: bright in Mocha,
    /// darkened in Latte so the hairline clears WCAG 1.4.11 (see `tintBorder`).
    let borderHue: Color

    // Mauve stays reserved for the awesoMux group, and peach is excluded from
    // the auto-cycle: it's the exact hex of `status.needs`, so an auto-assigned
    // peach workspace collides with the needs-attention cue. Both remain valid
    // explicit choices via `accent(for:)`.
    // See INT-491.
    private static let palette: [AwTintAccent] = [.teal, .green, .blue, .pink, .yellow, .red, .gray]

    /// `index` must be the group's position in the unfiltered store. Keying off
    /// the filtered position would shift colors as users typed search queries.
    init(groupName: String, color: WorkspaceGroupColor?, index: Int) {
        let resolvedAccent: AwTintAccent
        if let color {
            resolvedAccent = Self.accent(for: color)
        } else if groupName.range(of: "awesomux", options: .caseInsensitive) != nil {
            resolvedAccent = .mauve
        } else {
            resolvedAccent = Self.palette[index % Self.palette.count]
        }

        accent = resolvedAccent
        hue = Color.aw.tint(resolvedAccent)
        borderHue = Color.aw.tintBorder(resolvedAccent)
    }

    static func accent(for color: WorkspaceGroupColor) -> AwTintAccent {
        switch color {
        case .mauve: .mauve
        case .peach: .peach
        case .green: .green
        case .teal: .teal
        case .blue: .blue
        case .pink: .pink
        case .yellow: .yellow
        case .red: .red
        case .gray: .gray
        case .sky: .sky
        case .lavender: .lavender
        }
    }

    /// File-private so `SidebarGroupView`'s color menu can render the
    /// swatch preview using the exact same hue mapping the rendered tint
    /// will use — keeps the picker and the dot in lockstep.
    static func color(for color: WorkspaceGroupColor) -> Color {
        Color.aw.tint(accent(for: color))
    }
}

struct SidebarSnapshot {
    let entries: [SidebarGroupEntry]
    /// Pinned workspaces floated into the synthetic Pinned section, in pin
    /// order. Removed from `entries` by `SidebarPinnedProjection` (INT-737).
    let pinned: [PinnedSessionEntry]
    /// Highest-ranked filtered session across all groups, used by ⏎ to
    /// commit a search to a selection. Nil when no query is active.
    let topMatchID: TerminalSession.ID?
}

extension AgentKind {
    var awAgentIcon: AwAgentIcon {
        switch self {
        case .claudeCode:
            .claude
        case .codex:
            .codex
        case .openCode:
            .openCode
        case .pi:
            .pi
        case .grok:
            .grok
        case .shell:
            .shell
        }
    }
}

extension View {
    @ViewBuilder
    func sidebarDrop<Delegate: DropDelegate>(
        enabled: Bool,
        delegate: Delegate
    ) -> some View {
        if enabled {
            onDrop(of: [.utf8PlainText], delegate: delegate)
        } else {
            self
        }
    }
}
