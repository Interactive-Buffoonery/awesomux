import AwesoMuxConfig
import DesignSystem
import SwiftUI

// MARK: - Resolved shortcuts

/// The chords the tour names, already resolved against the user's keyboard
/// config. Grouped because the same five travel from the controller through
/// both the live panel root and the per-beat measurement pass; the views
/// themselves must never resolve, or rebound keys would stop being taught.
struct FirstRunTourShortcuts {
    let newWorkspace: KeyBinding
    let toggleFloatingPanel: KeyBinding
    let togglePopUpTerminal: KeyBinding
    let toggleCommandPalette: KeyBinding
    let showKeyboardCheatsheet: KeyBinding

    init(keyboard: KeyboardConfig) {
        newWorkspace = KeyboardShortcutCatalog.resolved(
            KeyboardShortcutCatalog.newWorkspace, keyboard: keyboard)
        toggleFloatingPanel = KeyboardShortcutCatalog.resolved(
            KeyboardShortcutCatalog.toggleFloatingPanel, keyboard: keyboard)
        togglePopUpTerminal = KeyboardShortcutCatalog.resolved(
            KeyboardShortcutCatalog.togglePopUpTerminal, keyboard: keyboard)
        toggleCommandPalette = KeyboardShortcutCatalog.resolved(
            KeyboardShortcutCatalog.toggleCommandPalette, keyboard: keyboard)
        showKeyboardCheatsheet = KeyboardShortcutCatalog.resolved(
            KeyboardShortcutCatalog.showKeyboardCheatsheet, keyboard: keyboard)
    }
}

// MARK: - Copy

/// Beat copy in two renderings. `visible` carries the glyph chord (`⌘N`);
/// `spoken` carries the spelled-out one, because VoiceOver reads a bare glyph
/// as an ambiguous symbol name. Both interpolate the *resolved* binding — a
/// literal chord in this copy teaches the wrong key the moment a user rebinds.
enum FirstRunTourCopy {
    typealias Body = (visible: String, spoken: String)

    static func workspacesBeat(newWorkspace: KeyBinding) -> Body {
        (
            visible: String(
                localized:
                    "Every project gets a workspace — its own folder, its own shell, its own name in the sidebar. Press \(newWorkspace.displaySymbol) to make one.",
                comment:
                    "Welcome tour beat one. Argument is the New Workspace keyboard shortcut as symbols, e.g. ⌘N."),
            spoken: String(
                localized:
                    "Every project gets a workspace — its own folder, its own shell, its own name in the sidebar. Press \(newWorkspace.spokenForm) to make one.",
                comment:
                    "Spoken form of beat one. Argument is the New Workspace shortcut spelled out, e.g. Command N.")
        )
    }

    static func sidebarBeat() -> Body {
        let text = String(
            localized:
                "Workspaces live in the vertical sidebar, and you can drag them into groups to keep a project together. Splitting a workspace adds panes inside it — one sidebar row, however many panes.",
            comment: "Welcome tour beat two, explaining the sidebar and panes.")
        return (visible: text, spoken: text)
    }

    static func agentsBeat() -> Body {
        let text = String(
            localized:
                "This is the part a plain terminal can't do. Run Claude Code, Codex, or another agent in a workspace and awesoMux watches it for you: the sidebar shows whether it's thinking, waiting on you, or done, and a notification says so even when awesoMux is behind another app.",
            comment: "Welcome tour beat three, introducing agent awareness and notifications.")
        return (visible: text, spoken: text)
    }

    static func companionBeat(floatingPanel: KeyBinding, popUpTerminal: KeyBinding) -> Body {
        (
            visible: String(
                localized:
                    "Press \(floatingPanel.displaySymbol) to float the current workspace above your other windows, or \(popUpTerminal.displaySymbol) to drop the Terminal Companion down over whatever app you're in.",
                comment:
                    "Welcome tour beat four. Arguments are the floating-panel and Terminal Companion shortcuts as symbols."),
            spoken: String(
                localized:
                    "Press \(floatingPanel.spokenForm) to float the current workspace above your other windows, or \(popUpTerminal.spokenForm) to drop the Terminal Companion down over whatever app you're in.",
                comment:
                    "Spoken form of beat four. Arguments are those two shortcuts spelled out.")
        )
    }

    static func elsewhereBeat(commandPalette: KeyBinding, keyboardCheatsheet: KeyBinding) -> Body {
        (
            visible: String(
                localized:
                    "\(commandPalette.displaySymbol) opens the command palette — every command awesoMux has, searchable. \(keyboardCheatsheet.displaySymbol) shows the full keyboard cheatsheet. The ? button in the sidebar footer brings this tour back whenever you want it. Go build something. — D.A.V.E.",
                comment:
                    "Beat five. Arguments are the command-palette and cheatsheet shortcuts as symbols; D.A.V.E. is the mascot."),
            spoken: String(
                localized:
                    "\(commandPalette.spokenForm) opens the command palette — every command awesoMux has, searchable. \(keyboardCheatsheet.spokenForm) shows the full keyboard cheatsheet. The question mark button in the sidebar footer brings this tour back whenever you want it. Go build something. — D.A.V.E.",
                comment:
                    "Spoken form of beat five. Arguments are those two shortcuts spelled out.")
        )
    }

    /// Headings and bodies for a beat index. The index is already clamped to
    /// `0..<beatCount` by `FirstRunTourController`, so the final case doubles
    /// as the out-of-range landing spot rather than a crash or a blank panel.
    static func beat(_ beat: Int, shortcuts: FirstRunTourShortcuts) -> (heading: String, body: Body) {
        switch beat {
        case 0:
            return (
                heading: String(
                    localized: "workspaces, not tabs",
                    comment: "Welcome tour heading for the workspaces beat"),
                body: workspacesBeat(newWorkspace: shortcuts.newWorkspace)
            )
        case 1:
            return (
                heading: String(
                    localized: "the sidebar",
                    comment: "Welcome tour heading for the sidebar beat"),
                body: sidebarBeat()
            )
        case 2:
            return (
                heading: String(
                    localized: "agents, watched",
                    comment: "Welcome tour heading for the agents beat"),
                body: agentsBeat()
            )
        case 3:
            return (
                heading: String(
                    localized: "always within reach",
                    comment: "Welcome tour heading for the floating panel and Terminal Companion beat"),
                body: companionBeat(
                    floatingPanel: shortcuts.toggleFloatingPanel,
                    popUpTerminal: shortcuts.togglePopUpTerminal)
            )
        default:
            return (
                heading: String(
                    localized: "where everything else lives",
                    comment: "Welcome tour heading for the closing beat"),
                body: elsewhereBeat(
                    commandPalette: shortcuts.toggleCommandPalette,
                    keyboardCheatsheet: shortcuts.showKeyboardCheatsheet)
            )
        }
    }
}

// MARK: - Panel root

/// Panel root. Holds the controller so the `currentBeat` read below happens
/// inside a `body` and is tracked by Observation; `FirstRunTourPage` is the
/// pure half the controller measures without a live controller.
struct FirstRunTourView: View {
    let controller: FirstRunTourController
    let shortcuts: FirstRunTourShortcuts
    let onOpenAgentSettings: () -> Void

    var body: some View {
        FirstRunTourPage(
            beat: controller.currentBeat,
            shortcuts: shortcuts,
            onBack: { controller.retreat() },
            onNext: { controller.advance() },
            onDismiss: { controller.dismissByUser() },
            onOpenAgentSettings: onOpenAgentSettings
        )
    }
}

// MARK: - Page

struct FirstRunTourPage: View {
    let beat: Int
    let shortcuts: FirstRunTourShortcuts
    let onBack: () -> Void
    let onNext: () -> Void
    let onDismiss: () -> Void
    let onOpenAgentSettings: () -> Void

    @Environment(\.awAccent) private var accentResolver

    private var isFirstBeat: Bool { beat <= 0 }
    private var isLastBeat: Bool { beat >= FirstRunTourController.beatCount - 1 }

    var body: some View {
        let copy = FirstRunTourCopy.beat(beat, shortcuts: shortcuts)
        let accentColor = Color.aw.accent(accentResolver.accent)

        VStack(alignment: .leading, spacing: AwSpacing.sectionGap) {
            DaveMark()

            VStack(alignment: .leading, spacing: 10) {
                Text(copy.heading)
                    .awFont(AwFont.Mono.kicker)
                    .tracking(1.2)
                    .textCase(.uppercase)
                    .foregroundStyle(accentColor)
                    .accessibilityAddTraits(.isHeader)

                Text(copy.body.visible)
                    .awFont(AwFont.UI.body)
                    .foregroundStyle(Color.aw.text2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(copy.body.spoken)

                if beat == FirstRunTourController.notificationBeatIndex {
                    Button(
                        String(
                            localized: "Set up agents…",
                            comment: "Welcome tour button opening the agent settings section"),
                        action: onOpenAgentSettings
                    )
                    .buttonStyle(.bordered)
                    .padding(.top, 2)
                }
            }
            // One reading order per beat: heading, body, and the agent button
            // are each their own stop, and the group is what pages under the
            // user rather than the window.
            .accessibilityElement(children: .contain)
            .accessibilityLabel(
                String(
                    localized: "Step \(beat + 1) of \(FirstRunTourController.beatCount)",
                    comment:
                        "Accessibility label for one welcome tour beat. First argument is the current step, second is the total."))

            Spacer(minLength: 0)

            controls
        }
        .padding(AwSpacing.panelPadding)
        // Vertical traffic-light clearance, matching AboutWindowView: the panel
        // shows standard window buttons and the content starts at the top edge.
        .padding(.top, AwSpacing.titlebar - AwSpacing.panelPadding)
        .frame(width: 420, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: AwRadius.window)
                .fill(Color.aw.surface.window)
                .awShadow(.sheet, rendering: .composited)
        }
        .clipShape(RoundedRectangle(cornerRadius: AwRadius.window))
        .overlay {
            RoundedRectangle(cornerRadius: AwRadius.window)
                .stroke(Color.aw.border2, lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            String(
                localized: "Welcome to awesoMux",
                comment: "Accessibility label for the welcome tour panel"))
    }

    private var controls: some View {
        HStack(spacing: 10) {
            progressDots

            Spacer(minLength: 12)

            Button(
                String(localized: "Skip", comment: "Welcome tour button dismissing the tour"),
                action: onDismiss
            )
            .buttonStyle(.link)

            Button(
                String(localized: "Back", comment: "Welcome tour button returning to the previous beat"),
                action: onBack
            )
            .buttonStyle(.bordered)
            .disabled(isFirstBeat)

            Button(
                isLastBeat
                    ? String(localized: "Done", comment: "Welcome tour button closing the tour on the last beat")
                    : String(localized: "Next", comment: "Welcome tour button advancing to the next beat"),
                action: isLastBeat ? onDismiss : onNext
            )
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
    }

    private var progressDots: some View {
        HStack(spacing: 5) {
            ForEach(0..<FirstRunTourController.beatCount, id: \.self) { index in
                Circle()
                    .fill(
                        index == beat
                            ? Color.aw.accent(accentResolver.accent) : Color.aw.textFaint
                    )
                    .frame(width: 5, height: 5)
            }
        }
        // The beat group above already announces "Step N of 5"; repeating it
        // here would make every page turn read twice.
        .accessibilityHidden(true)
    }
}

// MARK: - D.A.V.E.

private struct DaveMark: View {
    @Environment(\.awAccent) private var accentResolver

    // Art, not copy — deliberately outside the string catalog. Monospaced so
    // the three rows stay aligned; the surrounding beat copy carries every
    // word a screen reader needs. The leading `\u{20}` on the indented rows
    // survives any whitespace trimming that would otherwise shear the head off
    // the body.
    private static let art = """
        \u{20}   _
        \u{20}__(.)<   H O N K !
        (_____)
        """

    var body: some View {
        Text(Self.art)
            .awFont(AwFont.Mono.body)
            .foregroundStyle(Color.aw.accent(accentResolver.accent))
            .awGlow(color: Color.aw.accentGlow(accentResolver.accent), radius: 6)
            .accessibilityHidden(true)
    }
}
