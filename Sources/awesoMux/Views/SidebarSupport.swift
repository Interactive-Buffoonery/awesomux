import AwesoMuxBridgeProtocol
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

    /// The index is only a fallback for groups not yet adopted by SessionStore.
    init(group: SessionGroup, index: Int) {
        let resolvedAccent = Self.accent(for: group.resolvedColor(at: index))

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
    /// Workspaces awaiting a human answer, lifted into the synthetic Needs Input
    /// section. Empty when the feature is off. Removed from `entries` by
    /// `SidebarAttentionProjection`.
    let attention: [LiftedSessionEntry]
    /// Pinned workspaces lifted into the synthetic Pinned section, in pin
    /// order. Removed from `entries` by `SidebarPinnedProjection` (INT-737).
    let pinned: [LiftedSessionEntry]
    /// Highest-ranked filtered session across all groups, used by ⏎ to
    /// commit a search to a selection. Nil when no query is active.
    let topMatchID: TerminalSession.ID?

    /// The exact title each row renders in this snapshot. A title search match
    /// owns an immutable scored string so its highlight ranges stay valid even
    /// if the coarse channel advances before SwiftUI replaces the row.
    func displayedTitles(
        fallingBackTo titles: [TerminalSession.ID: String]
    ) -> [TerminalSession.ID: String] {
        var displayed = titles

        func apply(_ entry: SidebarSessionEntry) {
            guard entry.match?.field == .title,
                let matchedTitle = entry.match?.matchedTitle
            else { return }
            displayed[entry.session.id] = matchedTitle
        }

        for group in entries {
            for entry in group.sessions {
                apply(entry)
            }
        }
        for lifted in attention {
            apply(lifted.entry)
        }
        for lifted in pinned {
            apply(lifted.entry)
        }
        return displayed
    }
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
        case .hermes:
            .hermes
        case .generic:
            .generic
        case .shell:
            .shell
        }
    }
}

extension View {
    @ViewBuilder
    func sidebarRotorEntry(id: UUID, namespace: Namespace.ID?) -> some View {
        if let namespace { accessibilityRotorEntry(id: id, in: namespace) } else { self }
    }

    @ViewBuilder
    func sidebarDrag<Preview: View>(
        enabled: Bool,
        data: @escaping () -> NSItemProvider,
        @ViewBuilder preview: () -> Preview
    ) -> some View {
        if enabled { onDrag(data, preview: preview) } else { self }
    }

    func sidebarDrop<Delegate: DropDelegate>(
        enabled: Bool,
        delegate: Delegate
    ) -> some View {
        // Keep the native source mounted when its drag enables the destinations.
        onDrop(of: enabled ? [.utf8PlainText] : [], delegate: delegate)
    }
}
