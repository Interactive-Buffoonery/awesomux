import AppKit
import AwesoMuxCore
import DesignSystem
import SwiftUI

/// Shared chrome for the path bar's in-place foldout menus (open-target and
/// branches): rounded panel, chrome fill, accent hairline, overlay shadow.
private struct PathBarMenuChrome: ViewModifier {
    let accent: Color

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: AwRadius.panel)
                    .fill(Color.aw.surface.chrome)
                    .overlay {
                        RoundedRectangle(cornerRadius: AwRadius.panel)
                            .stroke(accent.opacity(0.38), lineWidth: 0.75)
                    }
                    .awShadow(.overlay)
                    .accessibilityHidden(true)
            }
    }
}

struct BranchListMenu: View {
    let currentBranch: String?
    /// nil = the git lookup itself failed (distinct from "only one branch"),
    /// so the empty row can be honest about which of the two happened.
    let otherBranches: [String]?
    /// False in agent sessions — rows then copy the branch name instead of
    /// typing into the agent's input.
    let canInsertCheckout: Bool
    let accent: Color
    let onSelect: (String) -> Void

    private static let rowHeight: CGFloat = 30
    private static let minMenuWidth: CGFloat = 180
    private static let maxMenuWidth: CGFloat = 300

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let currentBranch {
                currentRow(branch: currentBranch)
            }
            if let otherBranches, !otherBranches.isEmpty {
                branchRows(otherBranches)
            } else if otherBranches == nil
                // defensive: `toggleBranchMenu()` only ever presents this menu
                // after its own `guard let currentBranch = model.gitBranch`
                // passes, so `currentBranch` is unreachable as nil in
                // practice — kept so this arm degrades safely instead of
                // assuming that caller invariant holds forever.
                || currentBranch == nil
            {
                // nil = git failed (tool missing / timeout) → say so, distinct
                // from "genuinely the only branch". An empty list under a pinned
                // current row gets NO placeholder — the single row already says
                // it, and the extra row left a lopsided gap. The placeholder
                // survives an empty list only when there's no current row either,
                // so the menu is never an empty chrome box.
                Text(otherBranches == nil ? "Branches unavailable" : "No other branches")
                    .awFont(AwFont.Mono.pill)
                    .foregroundStyle(Color.aw.text3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: Self.rowHeight)
                    .padding(.horizontal, 6)
                    .accessibilityAddTraits(.isStaticText)
            }
        }
        .padding(6)
        .frame(minWidth: Self.minMenuWidth, maxWidth: Self.maxMenuWidth, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
        .modifier(PathBarMenuChrome(accent: accent))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Branches menu")
    }

    // Capped rows + a static "+ N more branches" overflow line — deliberately
    // NOT a ScrollView: inside this menu's `.fixedSize(horizontal: true,
    // vertical: false)` container a ScrollView collapses its content to zero
    // height (a 143-branch repo rendered only the pinned row plus a phantom
    // gap). The recency sort makes the top `maxVisibleRows` the useful set;
    // deeper needs mean typing the checkout yourself (or a future filter
    // field) — see `BranchListMenuModel.maxVisibleRows`.
    @ViewBuilder
    private func branchRows(_ otherBranches: [String]) -> some View {
        let (visible, overflow) = BranchListMenuModel.visibleRows(otherBranches)
        VStack(alignment: .leading, spacing: 4) {
            ForEach(visible, id: \.self) { branch in
                branchRow(branch: branch)
            }
            if overflow > 0 {
                let overflowLabel = LocalizedPluralStrings.branchMenuMoreBranches(count: overflow)
                Text(overflowLabel)
                    .awFont(AwFont.Mono.pill)
                    .foregroundStyle(Color.aw.text3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: Self.rowHeight)
                    .padding(.horizontal, 6)
                    .accessibilityAddTraits(.isStaticText)
                    .accessibilityLabel(overflowLabel)
            }
        }
    }

    /// The pinned current branch: informative, not clickable — mirrors the
    /// open-target menu's "Default" tag styling.
    private func currentRow(branch: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 12))
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
            Text(branch)
                .awFont(AwFont.UI.label)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            Text("Current")
                .awFont(AwFont.Mono.pill)
                .foregroundStyle(accent.opacity(0.8))
        }
        .foregroundStyle(accent)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: Self.rowHeight, alignment: .leading)
        .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: AwRadius.pill))
        .overlay {
            RoundedRectangle(cornerRadius: AwRadius.pill)
                .stroke(accent.opacity(0.38), lineWidth: 0.5)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(branch), current branch")
    }

    private func branchRow(branch: String) -> some View {
        Button {
            onSelect(branch)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 12))
                    .frame(width: 16, height: 16)
                    .accessibilityHidden(true)
                Text(branch)
                    .awFont(AwFont.UI.label)
                    .foregroundStyle(Color.aw.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(Color.aw.text2)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: Self.rowHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(PathBarMenuRowButtonStyle(tone: Color.aw.text3, filled: false))
        .help(
            canInsertCheckout
                ? "Insert `git checkout \(branch)` at the prompt"
                : "Copy branch name"
        )
        .accessibilityLabel(branch)
        .accessibilityHint(
            canInsertCheckout
                ? "Inserts the checkout command at the prompt."
                : "Copies the branch name.")
    }
}

struct OpenTargetMenu: View {
    let installedIDEs: [InstalledIDE]
    let showsIDEOptions: Bool
    let accent: Color
    let appIcon: (InstalledIDE) -> AnyView
    let onOpenInIDEWithApp: (InstalledIDE) -> Void
    let onOpenInFinder: () -> Void
    let onCopyPath: () -> Void
    /// Called once the "Copied" acknowledgement has been visible long enough
    /// to register — the other rows close the menu immediately, but this one
    /// needs a beat first so the green wash is actually seen.
    let onCopyPathAcknowledged: () -> Void

    @State private var didCopyPath = false

    private static let maxVisibleRows = 8
    private static let rowHeight: CGFloat = 30
    private static let minMenuWidth: CGFloat = 180
    private static let maxMenuWidth: CGFloat = 260
    private static let copyAcknowledgementDelay = Duration.milliseconds(500)

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if showsIDEOptions {
                ideRows
            }
            menuRow(
                title: "Show in Finder",
                tone: Color.aw.text3,
                isDefault: false,
                action: onOpenInFinder
            ) {
                Image(systemName: "folder")
                    .font(.system(size: 12))
                    .frame(width: 14, height: 14)
                    .accessibilityHidden(true)
            }
            copyPathRow
        }
        .padding(6)
        .frame(minWidth: Self.minMenuWidth, maxWidth: Self.maxMenuWidth, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
        .modifier(PathBarMenuChrome(accent: accent))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Open menu")
    }

    @ViewBuilder
    private var ideRows: some View {
        if installedIDEs.isEmpty {
            Text("No supported editors found")
                .awFont(AwFont.Mono.pill)
                .foregroundStyle(Color.aw.text3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: Self.rowHeight)
                .padding(.horizontal, 6)
                .accessibilityAddTraits(.isStaticText)
                .accessibilityLabel("No supported editors found")
        } else {
            let rows = VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(installedIDEs.enumerated()), id: \.element.bundleIdentifier) { index, ide in
                    let isDefault = index == 0
                    menuRow(
                        title: ide.displayName,
                        tone: isDefault ? accent : Color.aw.text2,
                        isDefault: isDefault
                    ) {
                        onOpenInIDEWithApp(ide)
                    } icon: {
                        appIcon(ide)
                    }
                }
            }

            if installedIDEs.count > Self.maxVisibleRows {
                ScrollView {
                    rows
                }
                .frame(maxHeight: CGFloat(Self.maxVisibleRows) * (Self.rowHeight + 4))
            } else {
                rows
            }
        }
    }

    private func menuRow(
        title: String,
        tone: Color,
        isDefault: Bool,
        action: @escaping () -> Void,
        @ViewBuilder icon: () -> some View
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                icon()
                    .frame(width: 16, height: 16)
                Text(title)
                    .awFont(AwFont.UI.label)
                    .foregroundStyle(isDefault ? tone : Color.aw.text)
                    .lineLimit(1)

                if isDefault {
                    Spacer(minLength: 6)
                    Text("Default")
                        .awFont(AwFont.Mono.pill)
                        .foregroundStyle(tone.opacity(0.8))
                }
            }
            .foregroundStyle(tone)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: Self.rowHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(PathBarMenuRowButtonStyle(tone: tone, filled: isDefault))
        .accessibilityLabel(isDefault ? "\(title), default editor" : title)
    }

    /// Green wash + checkmark on copy, then a brief hold before the menu
    /// closes — every other row here closes the menu instantly, but a copy
    /// with no visible confirmation reads as "did that work?"
    private var copyPathRow: some View {
        // Text-safe green, not the raw palette token: `Color.aw.green` alone
        // (`#40a02b`) only clears ~2.75:1 against this menu's Latte chrome —
        // under the WCAG 1.4.3 4.5:1 floor for normal-weight text.
        // `accentOnChrome` is this design system's existing chrome-text-safe
        // resolution (darkens per theme via `AwAccent.chromeTextHex()`).
        let ackTone = Color.aw.accentOnChrome(.green)
        return Button {
            onCopyPath()
            didCopyPath = true
            TerminalAccessibilityAnnouncer.announce(
                String(localized: "Path copied.", comment: "VoiceOver announcement after Copy Path succeeds"))
        } label: {
            HStack(spacing: 8) {
                Image(systemName: didCopyPath ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 12))
                    .frame(width: 14, height: 14)
                    .accessibilityHidden(true)
                Text(didCopyPath ? "Copied" : "Copy Path")
                    .awFont(AwFont.UI.label)
                    .foregroundStyle(didCopyPath ? ackTone : Color.aw.text)
                    .lineLimit(1)
            }
            .foregroundStyle(didCopyPath ? ackTone : Color.aw.text3)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: Self.rowHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(PathBarMenuRowButtonStyle(tone: didCopyPath ? ackTone : Color.aw.text3, filled: didCopyPath))
        .disabled(didCopyPath)
        .accessibilityLabel(didCopyPath ? "Copied" : "Copy Path")
        .task(id: didCopyPath) {
            guard didCopyPath else { return }
            do {
                try await Task.sleep(for: Self.copyAcknowledgementDelay)
            } catch {
                // Cancelled because the menu was torn down for another reason
                // (Escape, a pane switch, reopening a different menu) — don't
                // let a stale completion close whatever's presented now.
                return
            }
            onCopyPathAcknowledged()
        }
    }
}

private struct PathBarMenuRowButtonStyle: ButtonStyle {
    let tone: Color
    let filled: Bool
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        let active = isHovering || configuration.isPressed
        let fillOpacity = filled ? (active ? 0.18 : 0.12) : (active ? 0.10 : 0.05)
        return configuration.label
            .background(tone.opacity(fillOpacity), in: RoundedRectangle(cornerRadius: AwRadius.pill))
            .overlay {
                RoundedRectangle(cornerRadius: AwRadius.pill)
                    .stroke(tone.opacity(filled ? 0.38 : (active ? 0.28 : 0.16)), lineWidth: 0.5)
            }
            .onHover { isHovering = $0 }
    }
}
