import AppKit
import AwesoMuxCore
import DesignSystem
import Foundation
import SwiftUI

/// Per-pane title bar. Renders only in a multi-pane workspace (the workspace
/// title bar already names a lone pane). Sits directly under the pane's focus
/// accent and above the terminal surface. Fixed height + single line: a long
/// title truncates and never reflows the surface (INT-283).
struct PaneTitleBarView: View {
    // `session` + `sessionStore` route the inline-rename and context-menu
    // affordances below to renamePane/resetPaneTitle keyed on session.id.
    let session: TerminalSession
    let pane: TerminalPane
    let sessionStore: SessionStore
    /// The title bar is also the pane's drag handle (the old corner glyph is
    /// gone), so it hosts the same AppKit `PaneDragSource` the glyph used to.
    let dragCoordinator: PaneDragCoordinator
    /// Closing a pane must discard its native surface (and its agent event-file
    /// watcher + refresh task) — the store close alone only reaps reducer
    /// bookkeeping, so the close button has to pair with `discardSurface` like
    /// every other close path does (review finding).
    let runtime: GhosttyRuntime
    /// Passed from the ungated pane-layout parent so a live accessibility
    /// environment update crosses this view's `.equatable()` optimization.
    let reduceTransparency: Bool

    @State private var isEditing = false
    @State private var draft = ""
    @FocusState private var isFieldFocused: Bool

    /// Fixed band height. The terminal surface gets the remaining space; this
    /// constant is the ONLY vertical cost, independent of title length.
    static let height: CGFloat = 24
    static let washOpacity = 0.22

    var body: some View {
        // Computed once — used by both the Text and its a11y label below; this
        // body re-runs whenever ANY pane in the tree is retitled (the session
        // struct flows down by value), so avoid the double string alloc.
        let title = Self.displayTitle(for: pane)
        return HStack(spacing: 6) {
            // No leading agent glyph in v1: `AwAgentIcon` has no plain
            // `systemImageName` (Codex-verified), and the agent state is already
            // shown by the focus accent + sidebar peek. Reserve this slot for the
            // future tab strip / icon mapping rather than forcing one now.
            if isEditing {
                TextField("Pane name", text: $draft)
                    .textFieldStyle(.plain)
                    .awFont(AwFont.Mono.meta)
                    .foregroundStyle(titleColor)
                    .focused($isFieldFocused)
                    .onSubmit { commit() }
                    .onExitCommand { isEditing = false }
                    // Clicking away (focus loss) commits, rather than stranding
                    // the bar in edit mode with the drag/close overlays hidden
                    // (Codex). `commit()` guards on isEditing so the focus loss
                    // triggered by ⏎/esc themselves doesn't double-fire.
                    .onChange(of: isFieldFocused) { _, focused in
                        if !focused { commit() }
                    }
                    .onAppear {
                        draft = pane.isTitleUserEdited ? pane.title : ""
                        isFieldFocused = true
                    }
            } else {
                titleLabel(title)
            }

            if let remoteHost = pane.remotePresentationHost {
                Label(remoteHost, systemImage: "network")
                    .awFont(AwFont.Mono.meta)
                    .foregroundStyle(titleColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 180)
                    .help(
                        String(
                            localized: "Remote session on \(remoteHost)",
                            comment: "Tooltip for the remote host badge in a pane title bar."
                        )
                    )
                    .accessibilityHidden(true)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: Self.height)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(barBackground)
        // The AppKit drag source owns the bar's mouse events and disambiguates
        // press-drag (move), double-click (rename), right-click (menu), and
        // single-click (focus). It replaces the Task-5 SwiftUI
        // `.onTapGesture(count:2)` + `.contextMenu`, which can't coexist with the
        // AppKit drag gesture on the same surface. Hosted as an `.overlay`
        // (front), not `.background` — `.background` is not reliably in the
        // hit-test path under SwiftUI (the proven `PaneDragHandle` placement).
        // Suppressed while editing so the TextField keeps first responder.
        .overlay {
            if !isEditing {
                PaneDragSource(
                    sessionID: session.id,
                    paneID: pane.id,
                    coordinator: dragCoordinator,
                    glyphName: "dot.square",
                    onDoubleClick: { beginEditing() },
                    onActivate: { sessionStore.setActivePane(id: pane.id, in: session.id) },
                    contextMenuItems: {
                        [
                            PaneContextMenuItem(
                                title: "Rename…",
                                isEnabled: true,
                                action: { beginEditing() }
                            ),
                            PaneContextMenuItem(
                                title: "Reset to Terminal Title",
                                isEnabled: pane.isTitleUserEdited,
                                action: {
                                    sessionStore.resetPaneTitle(
                                        sessionID: session.id, paneID: pane.id
                                    )
                                }
                            ),
                            PaneContextMenuItem(
                                title: "Color…",
                                isEnabled: true,
                                children: colorMenuItems()
                            ),
                        ]
                    }
                )
                // Force the source view to fill the bar: an NSViewRepresentable
                // in an `.overlay` can otherwise collapse to its intrinsic
                // (zero) size, leaving most of the bar non-interactive.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .help("Drag to rearrange · double-click to rename")
                // Pointer-only affordance — its actions are exposed to VoiceOver
                // on the title text above (and via keyboard equivalents
                // elsewhere), so hide the bare source view from a11y.
                .accessibilityHidden(true)
            }
        }
        // Close button — layered ON TOP of the drag source (a later overlay) so
        // its click isn't swallowed by the source filling the bar. Hidden while
        // editing. Sets up the tabs route (a per-tab close affordance).
        .overlay(alignment: .trailing) {
            if !isEditing {
                // A real NSButton with `refusesFirstResponder` — clicking it does
                // NOT steal first responder from the terminal surface, so closing
                // a pane behaves EXACTLY like ⌘W (the surface keeps / its sibling
                // reclaims focus instead of blanking). A SwiftUI Button stole
                // focus on click, which broke the surface's vacant-responder
                // reclaim path. Being a real button also keeps VoiceOver semantics.
                PaneCloseButton(tint: titleColor.opacity(0.85)) {
                    // Pair the store close with surface disposal — otherwise the
                    // native libghostty surface + its agent event-file watcher +
                    // refresh task leak until the next app-resign sweep.
                    // The bar is multi-pane-only, so this is always `.pane`.
                    if case let .pane(closedPaneID)? =
                        sessionStore.closePane(id: pane.id, in: session.id)
                    {
                        runtime.discardSurface(for: closedPaneID)
                        // Same announcement the ⌘W path posts — the two entry
                        // points to the same close must not diverge for
                        // VoiceOver users (WCAG 4.1.3).
                        TerminalAccessibilityAnnouncer.announce(
                            String(
                                localized: "Pane closed",
                                comment: "VoiceOver announcement after the title-bar close button closes a pane."
                            )
                        )
                    }
                }
                // 24×24 hit target meets WCAG 2.5.8 (the bar is 24pt tall, so it
                // fits); the 9pt glyph stays small inside it (a11y).
                .frame(width: 24, height: 24)
                .padding(.trailing, 2)
            }
        }
        // NOT `.combine` — that flattened the close button and the edit field out
        // of the a11y tree, so VoiceOver couldn't reach them. Children stay
        // individually accessible.
        .accessibilityElement(children: .contain)
        // If a keyboard move/swap/close swaps a different pane into this
        // structural slot mid-edit, cancel the edit so a stale draft can't commit
        // against the wrong pane (cross-task review).
        .onChange(of: pane.id) { _, _ in
            isEditing = false
        }
    }

    nonisolated static func bandTreatment(
        for color: PaneColor?,
        reduceTransparency: Bool
    ) -> PaneTitleBarBandTreatment {
        switch color {
        case .palette(let color):
            let accent = ProjectTint.accent(for: color)
            return reduceTransparency ? .opaqueMuted(accent) : .wash(accent)
        case nil:
            return .chrome
        }
    }

    /// NSColor swatch for a palette color, for the context-menu dot.
    private static func swatchColor(for color: WorkspaceGroupColor) -> NSColor {
        NSColor(ProjectTint.color(for: color))
    }

    /// The "Color…" submenu children: "Default" + the curated palette, each wired
    /// to `setPaneColor`, with a checkmark on the pane's current selection.
    private func colorMenuItems() -> [PaneContextMenuItem] {
        // NSColor.tertiaryLabelColor as swatch keeps the image column aligned with
        // the palette entries below — a missing image on "Default" creates a visible
        // indent gap that makes the submenu look mis-aligned (Fix 4).
        let defaultColor = PaneContextMenuItem(
            title: "Default",
            isEnabled: true,
            action: { sessionStore.setPaneColor(sessionID: session.id, paneID: pane.id, color: nil) },
            swatch: NSColor.tertiaryLabelColor,
            isChecked: pane.color == nil
        )
        let legacyCurrentColor: [PaneContextMenuItem]
        if case .palette(let color) = pane.color,
            !WorkspaceGroupColor.pickerCases.contains(color)
        {
            legacyCurrentColor = [
                PaneContextMenuItem(
                    title: color.displayName,
                    isEnabled: false,
                    swatch: Self.swatchColor(for: color),
                    isChecked: true
                )
            ]
        } else {
            legacyCurrentColor = []
        }
        let colors = WorkspaceGroupColor.pickerCases.map { color in
            PaneContextMenuItem(
                title: color.displayName,
                isEnabled: true,
                action: {
                    sessionStore.setPaneColor(
                        sessionID: session.id, paneID: pane.id, color: .palette(color)
                    )
                },
                swatch: Self.swatchColor(for: color),
                isChecked: pane.color == .palette(color)
            )
        }
        return [defaultColor] + legacyCurrentColor + colors
    }

    /// Chrome background matching the bottom path bar (`Color.aw.surface.chrome`
    /// + a `border2` hairline), so the top title bar and bottom path bar read as
    /// a matched pair of chrome bands framing the terminal. The border sits at
    /// the BOTTOM here (the path bar's is on top), so each border faces the
    /// terminal. Deliberately app-chrome, not terminal-bg-derived — the symmetry
    /// with the path bar is the point.
    ///
    /// Normal mode keeps the 0.22 wash shipped by INT-554. Reduce Transparency
    /// selects a precomposited opaque DesignSystem fill with the same muted hue,
    /// avoiding both a translucent layer and the contrast loss of raising alpha.
    private var barBackground: some View {
        Group {
            switch Self.bandTreatment(
                for: pane.color,
                reduceTransparency: reduceTransparency
            ) {
            case .chrome:
                Color.aw.surface.chrome
            case .wash(let accent):
                Color.aw.surface.chrome
                    .overlay { Color.aw.tint(accent).opacity(Self.washOpacity) }
            case .opaqueMuted(let accent):
                Color.aw.paneTitleBand(accent)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.aw.border2)
                .frame(height: 0.5)
        }
    }

    // The bar is opaque chrome (matching the path bar), so the text reads
    // against chrome — no terminal-background contrast tuning needed.
    private var titleColor: Color {
        Color.aw.text
    }

    /// Shared pane display title for the title bar and sidebar peek row: the
    /// pane title, else the working-directory basename.
    ///
    /// `nonisolated` so the pure logic is callable off the main actor (the view
    /// itself is implicitly `@MainActor`); the unit test exercises it directly.
    nonisolated static func displayTitle(for pane: TerminalPane) -> String {
        let trimmed = pane.title.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return trimmed }
        let basename = (pane.workingDirectory as NSString).lastPathComponent
        return basename.isEmpty ? pane.workingDirectory : basename
    }

    nonisolated static func accessibilityLabel(for pane: TerminalPane, title: String) -> String {
        guard let remoteHost = pane.remotePresentationHost else {
            return String(
                localized: "Pane: \(title)",
                comment: "VoiceOver label for a local terminal pane title."
            )
        }
        return String(
            localized: "Pane: \(title), Remote session on \(remoteHost)",
            comment: "VoiceOver label for a remote terminal pane title and host."
        )
    }

    /// The displayed title — the semantic element that carries the pointer-only
    /// affordances (double-click rename / context-menu reset) as accessibility
    /// actions so VoiceOver/keyboard users reach them via the rotor.
    /// Reset is offered ONLY when the pane is actually pinned (Codex) — otherwise
    /// it'd be a no-op action; the palette "Reset Pane Title" command is the
    /// general keyboard path.
    ///
    /// Color actions are mirrored here as flat `.accessibilityActions` — the
    /// AppKit "Color…" submenu is not reliably reachable by VoiceOver, so each
    /// color (plus "Clear") gets its own rotor action, matching the pattern that
    /// `SidebarGroupView` uses for workspace-group color (INT-554).
    @ViewBuilder
    private func titleLabel(_ title: String) -> some View {
        let colorSuffix = Self.colorName(for: pane.color).map { ", \($0) tint" } ?? ""
        let base = Text(title)
            .awFont(AwFont.Mono.meta)
            .foregroundStyle(titleColor)
            .lineLimit(1)
            .truncationMode(.tail)
            .accessibilityLabel(Self.accessibilityLabel(for: pane, title: title) + colorSuffix)
            .accessibilityAction(named: "Rename") { beginEditing() }
        if pane.isTitleUserEdited {
            base
                .accessibilityAction(named: "Reset to Terminal Title") {
                    sessionStore.resetPaneTitle(sessionID: session.id, paneID: pane.id)
                }
                .accessibilityActions {
                    colorAccessibilityActions()
                }
        } else {
            base
                .accessibilityActions {
                    colorAccessibilityActions()
                }
        }
    }

    /// Flat color actions for VoiceOver — mirrors the "Color…" context-menu
    /// submenu as individually reachable rotor entries. "Clear" is shown only
    /// when a color is already set; each unselected palette entry is shown so the
    /// user can switch directly without going through None first (selected color
    /// is filtered out — `false` is pane-absent only, not an idempotent no-op).
    ///
    /// Each action posts a WCAG 4.1.3 status announcement so VoiceOver confirms
    /// the color change even when focus stays on the same element.
    @ViewBuilder
    private func colorAccessibilityActions() -> some View {
        if pane.color != nil {
            Button("Clear Pane Color") {
                sessionStore.setPaneColor(sessionID: session.id, paneID: pane.id, color: nil)
                TerminalAccessibilityAnnouncer.announce(
                    String(
                        localized: "Pane color cleared",
                        comment: "VoiceOver status message after clearing a pane's name-plate color."
                    )
                )
            }
        }
        ForEach(WorkspaceGroupColor.pickerCases, id: \.self) { color in
            if pane.color != .palette(color) {
                Button("Set Pane Color to \(color.displayName)") {
                    sessionStore.setPaneColor(
                        sessionID: session.id, paneID: pane.id, color: .palette(color)
                    )
                    TerminalAccessibilityAnnouncer.announce(
                        String(
                            localized: "Pane color set to \(color.displayName)",
                            comment:
                                "VoiceOver status message after setting a pane's name-plate color. The placeholder is a color name such as 'Teal' or 'Mauve'."
                        )
                    )
                }
            }
        }
    }

    /// Human-readable name for the pane's current color, used in the a11y label.
    /// Returns nil when no color is set so the label omits the suffix entirely.
    private static func colorName(for color: PaneColor?) -> String? {
        switch color {
        case .palette(let c): c.displayName
        case nil: nil
        }
    }

    private func beginEditing() {
        draft = pane.isTitleUserEdited ? pane.title : ""
        isEditing = true
    }

    private func commit() {
        // Guard so the focus-loss `onChange` and ⏎/esc can't double-commit: the
        // first to fire flips isEditing false and the rest no-op.
        guard isEditing else { return }
        defer { isEditing = false }
        switch Self.resolveCommit(
            input: draft,
            current: pane.title,
            isUserEdited: pane.isTitleUserEdited
        ) {
        case let .rename(title):
            sessionStore.renamePane(sessionID: session.id, paneID: pane.id, title: title)
        case .reset:
            sessionStore.resetPaneTitle(sessionID: session.id, paneID: pane.id)
        case .noChange:
            break
        }
    }
}

extension PaneTitleBarView: Equatable {
    // Skip re-running `body` when nothing this bar renders changed. The whole
    // session struct flows down by value, so a background agent retitling ANY
    // pane would otherwise re-render EVERY title bar. The bar's output
    // depends only on these — not on focus (the accent lives in TerminalPaneView)
    // and not on the stable store/coordinator/runtime references.
    nonisolated static func == (lhs: PaneTitleBarView, rhs: PaneTitleBarView) -> Bool {
        lhs.pane.id == rhs.pane.id
            && lhs.pane.title == rhs.pane.title
            && lhs.pane.workingDirectory == rhs.pane.workingDirectory
            && lhs.pane.isTitleUserEdited == rhs.pane.isTitleUserEdited
            && lhs.pane.color == rhs.pane.color
            && lhs.pane.remotePresentationHost == rhs.pane.remotePresentationHost
            && lhs.session.id == rhs.session.id
            && lhs.reduceTransparency == rhs.reduceTransparency
    }
}

enum PaneTitleBarBandTreatment: Equatable {
    case chrome
    case wash(AwTintAccent)
    case opaqueMuted(AwTintAccent)
}

enum PaneTitleCommit: Equatable {
    case rename(String)
    case reset
    case noChange
}

extension PaneTitleBarView {
    /// Decides what a committed edit means, given the raw input, the pane's
    /// current title, and whether it's already user-frozen.
    /// - blank → reset to live title
    /// - same text AND already frozen → no change
    /// - otherwise → rename (pins/refreezes)
    ///
    /// `nonisolated` so the pure logic is callable off the main actor; the unit
    /// test exercises it directly.
    nonisolated static func resolveCommit(
        input: String,
        current: String,
        isUserEdited: Bool
    ) -> PaneTitleCommit {
        let sanitized = SessionStore.sanitizedTitle(input)
        if sanitized.isEmpty {
            return .reset
        }
        if sanitized == current && isUserEdited {
            return .noChange
        }
        return .rename(sanitized)
    }
}

/// The pane title bar's close button. A real `NSButton` (so VoiceOver reads a
/// button) with `refusesFirstResponder = true` — clicking it does NOT pull
/// first responder off the terminal surface, so closing a pane via the title
/// bar behaves exactly like ⌘W instead of blanking the surviving terminal until
/// it's clicked. A SwiftUI `Button` stole first responder on click, which broke
/// the libghostty surface's "reclaim focus only when the responder is vacant"
/// path (see `GhosttySurfaceContainerView` focus gating).
///
/// Shared (not `private`) so the document tab strip's per-tab close X reuses
/// the exact same first-responder-safe close affordance — a SwiftUI `Button`
/// there stole focus on click and blanked the surviving terminal when the
/// split collapsed (the same mechanism this button exists to avoid — INT-562
/// PR1, INT-748 PR2).
struct PaneCloseButton: NSViewRepresentable {
    let tint: Color
    /// Spoken label + tooltip — the terminal bar says "Close pane", the document
    /// bar says "Close document", so the affordance is not generically named.
    var accessibilityLabel: String = "Close pane"
    let action: () -> Void

    func makeNSView(context: Context) -> NSButton {
        Self.makeButton(
            tint: tint,
            accessibilityLabel: accessibilityLabel,
            target: context.coordinator
        )
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        context.coordinator.action = action
        // A document tab keeps its pill identity when the inline Files browser
        // replaces its file, so the label set at make time can name the OLD
        // file. Change-guarded to keep the sibling-retitle hot path free of
        // per-update AppKit writes (INT-748 PR2).
        if nsView.toolTip != accessibilityLabel {
            nsView.setAccessibilityLabel(accessibilityLabel)
            nsView.toolTip = accessibilityLabel
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    /// Builds the configured `NSButton`, wiring its target/action to `target`.
    /// Extracted from `makeNSView` so the first-responder-safe configuration is
    /// exercisable in tests without forging a `Context` (INT-562 PR1).
    static func makeButton(
        tint: Color,
        accessibilityLabel: String,
        target: Coordinator
    ) -> NSButton {
        let button = NSButton()
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imagePosition = .imageOnly
        button.image = NSImage(
            systemSymbolName: "xmark",
            accessibilityDescription: accessibilityLabel
        )
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
        button.refusesFirstResponder = true
        button.setButtonType(.momentaryChange)
        button.target = target
        button.action = #selector(Coordinator.fire)
        button.setAccessibilityLabel(accessibilityLabel)
        button.toolTip = accessibilityLabel
        // `tint` is constant — set it once here, not on every updateNSView (which
        // runs on every sibling retitle and would alloc a throwaway NSColor on the
        // hot path).
        button.contentTintColor = NSColor(tint)
        return button
    }

    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc func fire() {
            action()
        }
    }
}
