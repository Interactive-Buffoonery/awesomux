import AwesoMuxCore
import DesignSystem
import SwiftUI

// MARK: - DocumentTabStripView

/// The document viewer's tab strip (INT-748 PR2): one pill per open tab plus
/// the trailing Files toggle. Replaces `DocumentPaneTitleBarView` — the strip
/// shows even with a single tab so the title and close affordance never
/// disappear. Matches `PaneTitleBarView.height` so the strip and the terminal
/// title bars in the same split line up to the pixel.
///
/// Tab *selection* is a plain SwiftUI button: it mutates only `selectedTabID`,
/// never remounts a terminal surface, so first-responder theft is harmless.
/// Per-tab *close* is `PaneCloseButton` (NSButton, `refusesFirstResponder`):
/// closing the last tab collapses the split and remounts the terminal surface,
/// which only reclaims keyboard focus when the first responder is vacant — a
/// SwiftUI button would hold it and blank the survivor (INT-562 PR1).
///
    /// `Equatable` + `.equatable()` at the call site skip re-rendering the whole
    /// strip when a sibling terminal retitles (the same gate `PaneTitleBarView`
    /// uses). Accent and Increase Contrast arrive as VALUES, not
    /// environment reads, because the gate can't be trusted to pass env
    /// invalidation through (see `TerminalPaneLayoutView.accentResolver`).
struct DocumentTabStripView: View {
    let group: AwesoMuxCore.DocumentGroup
    let isBrowsingFiles: Bool
    let canBrowseFiles: Bool
    let filesToggleHelp: String
    let accent: AwAccent
    let increasedContrast: Bool
    let selectedTaskProgress: TaskProgress?
    let revisionIndicators: DocumentRevisionIndicatorState
    let onSelectTab: (DocumentPane.ID) -> Void
    let onCloseTab: (DocumentPane) -> Void
    let onExpandRevision: (DocumentPane) -> Void
    let onDismissRevision: () -> Void
    let onRevisionInteractionChanged: (Bool) -> Void
    let onToggleFiles: () -> Void

    static let height: CGFloat = PaneTitleBarView.height

    private var accentColor: Color { Color.aw.accent(accent) }
    private var accentSoftColor: Color { Color.aw.accentSoft(accent) }

    var body: some View {
        HStack(spacing: 6) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 4) {
                        ForEach(Array(group.tabs.enumerated()), id: \.element.id) { index, tab in
                            let indicator = revisionIndicators.indicator(for: tab)
                            DocumentTabPill(
                                tab: tab,
                                tabIndex: index + 1,
                                tabCount: group.tabs.count,
                                isSelected: tab.id == group.selectedTabID,
                                accentColor: accentColor,
                                accentSoftColor: accentSoftColor,
                                increasedContrast: increasedContrast,
                                taskProgress: tab.id == group.selectedTabID ? selectedTaskProgress : nil,
                                compactRevision: shouldShowCompactIndicator(indicator, for: tab)
                                    ? indicator?.revision
                                    : nil,
                                onSelect: { onSelectTab(tab.id) },
                                onRevealRevision: { onExpandRevision(tab) },
                                onClose: { onCloseTab(tab) }
                            )
                            .id(tab.id)
                        }
                    }
                }
                .scrollIndicators(.hidden)
                // Keep the selected pill visible when the strip overflows —
                // keyboard next/previous-tab cycling would otherwise select
                // pills the user can't see. Known cosmetic flake: a tab
                // appended AND selected in the same transaction may not have
                // laid out yet, so this scrollTo can no-op; the next selection
                // change self-heals it.
                .onChange(of: group.selectedTabID) { _, newValue in
                    proxy.scrollTo(newValue)
                }
                .onAppear {
                    proxy.scrollTo(group.selectedTabID)
                }
            }
            if let revision = expandedRevision {
                DocumentRevisionPill(
                    revision: revision,
                    onDismiss: onDismissRevision,
                    onInteractionChanged: onRevisionInteractionChanged
                )
            }
            filesToggle
        }
        .padding(.horizontal, 8)
        .frame(height: Self.height)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DocumentPaneChrome.barBackground)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(
            localized: "Document tabs",
            comment: "Accessibility label for the document viewer's tab strip"
        ))
    }

    private var expandedRevision: LineDiffCount? {
        guard !isBrowsingFiles,
              let tab = group.selectedTab,
              let indicator = revisionIndicators.indicator(for: tab),
              indicator.presentation == .expanded
        else {
            return nil
        }
        return indicator.revision
    }

    private func shouldShowCompactIndicator(
        _ indicator: DocumentRevisionIndicatorState.Indicator?,
        for tab: DocumentPane
    ) -> Bool {
        guard let indicator else { return false }
        return tab.id != group.selectedTabID || indicator.presentation == .compact
    }

    /// Visible box height for the strip's floating pills (Files toggle,
    /// revision pill). The 4pt focus-accent reservation above the strip is
    /// chrome-colored, so a full-height 24pt pill reads bottom-flush against
    /// the bar's bottom hairline (INT-738). A 20pt box floats 2pt clear of
    /// both strip edges while the text keeps the terminal title bars' center
    /// line; hit targets stay 24pt.
    static let floatingPillHeight: CGFloat = 20

    private var filesToggle: some View {
        Button(action: onToggleFiles) {
            Label(
                isBrowsingFiles ? "Document" : "Files",
                systemImage: isBrowsingFiles ? "doc.text" : "folder"
            )
            .labelStyle(.titleAndIcon)
            .awFont(AwFont.Mono.meta)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .frame(height: Self.floatingPillHeight)
            .background(
                isBrowsingFiles
                    ? accentSoftColor
                    : Color.aw.surface.chrome2.opacity(0.72),
                in: RoundedRectangle(cornerRadius: 5)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .stroke(
                        isBrowsingFiles
                            ? (increasedContrast ? accentColor : accentColor.opacity(0.35))
                            : Color.aw.border2,
                        lineWidth: 0.5
                    )
            }
            .frame(height: Self.height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isBrowsingFiles ? accentColor : Color.aw.text2)
        .help(filesToggleHelp)
        .disabled(!canBrowseFiles)
        .opacity(canBrowseFiles ? 1 : 0.45)
        .accessibilityLabel(String(
            localized: isBrowsingFiles ? "Back to document" : "Browse Markdown files",
            comment: "Accessibility label for the document viewer's Files toggle button"
        ))
    }
}

extension DocumentTabStripView: Equatable {
    // Closures excluded: their behavior derives from the compared values (the
    // group and the owning session id, which is fixed for a mounted view).
    // `nonisolated` per the PaneTitleBarView pattern — a MainActor-isolated
    // conformance to the nonisolated Equatable requirement is a Swift 6 error.
    nonisolated static func == (lhs: DocumentTabStripView, rhs: DocumentTabStripView) -> Bool {
        lhs.group == rhs.group
            && lhs.isBrowsingFiles == rhs.isBrowsingFiles
            && lhs.canBrowseFiles == rhs.canBrowseFiles
            && lhs.filesToggleHelp == rhs.filesToggleHelp
            && lhs.accent == rhs.accent
            && lhs.increasedContrast == rhs.increasedContrast
            && lhs.selectedTaskProgress == rhs.selectedTaskProgress
            && lhs.revisionIndicators == rhs.revisionIndicators
    }
}

// MARK: - DocumentRevisionPill

private struct DocumentRevisionPill: View {
    let revision: LineDiffCount
    let onDismiss: () -> Void
    let onInteractionChanged: (Bool) -> Void

    @State private var isHovering = false
    @FocusState private var isKeyboardFocused: Bool
    @AccessibilityFocusState private var accessibilityTarget: AccessibilityTarget?

    private enum AccessibilityTarget: Hashable {
        case label
        case dismiss
    }

    private static let dismissLabel = String(
        localized: "Dismiss revision indicator",
        comment: "Tooltip and accessibility label for the button that hides the document revision indicator"
    )

    private var label: String {
        LocalizedPluralStrings.documentRevisionIndicator(
            added: revision.added,
            removed: revision.removed
        )
    }

    var body: some View {
        HStack(spacing: 5) {
            Text(label)
                .awFont(AwFont.Mono.meta)
                .lineLimit(1)
                .accessibilityFocused($accessibilityTarget, equals: .label)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            // 24×24 hit target meets WCAG 2.5.8, same as the tab pill's close
            // X; contentShape makes the whole frame clickable, not the glyph.
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
            .foregroundStyle(Color.aw.text2)
            .help(Self.dismissLabel)
            .accessibilityLabel(Self.dismissLabel)
            .focused($isKeyboardFocused)
            .accessibilityFocused($accessibilityTarget, equals: .dismiss)
        }
        .foregroundStyle(Color.aw.text)
        .padding(.leading, 7)
        .padding(.trailing, 2)
        // Floats like the Files toggle (see floatingPillHeight); the dismiss
        // button keeps its 24pt hit target and just overflows the box.
        .frame(height: DocumentTabStripView.floatingPillHeight)
        .background(Color.aw.surface.chrome2.opacity(0.72), in: RoundedRectangle(cornerRadius: 5))
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .stroke(Color.aw.border2, lineWidth: 0.5)
        }
        // Claim the full row height like filesToggle does, so the pill's
        // layout footprint doesn't depend on the strip's fixed outer frame.
        .frame(height: DocumentTabStripView.height)
        .onHover { hovering in
            isHovering = hovering
            reportInteraction(hovering: hovering)
        }
        .onChange(of: isKeyboardFocused) { _, _ in
            reportInteraction()
        }
        .onChange(of: accessibilityTarget) { _, _ in
            reportInteraction()
        }
    }

    private func reportInteraction(hovering: Bool? = nil) {
        onInteractionChanged(
            (hovering ?? isHovering) || isKeyboardFocused || accessibilityTarget != nil
        )
    }
}

// MARK: - DocumentTabPill

/// A single tab pill: title (selects on click) + first-responder-safe close X.
/// Selected styling reuses the Files-pill treatment (accent-soft fill, accent
/// stroke, accent text) so selection is a fill+stroke shape change, not a
/// color-only signal (WCAG 1.4.1); under Increase Contrast the accent stroke
/// goes fully opaque.
private struct DocumentTabPill: View {
    let tab: DocumentPane
    /// 1-based position and count, spoken so VoiceOver reads
    /// "plan.md, tab 2 of 4, selected".
    let tabIndex: Int
    let tabCount: Int
    let isSelected: Bool
    let accentColor: Color
    let accentSoftColor: Color
    let increasedContrast: Bool
    let taskProgress: TaskProgress?
    let compactRevision: LineDiffCount?
    let onSelect: () -> Void
    let onRevealRevision: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onSelect) {
                HStack(spacing: 4) {
                    Text(tab.title)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let taskProgress {
                        Text("\(taskProgress.done)/\(taskProgress.total)")
                            .foregroundStyle(Color.aw.text2)
                            .layoutPriority(1)
                            .accessibilityHidden(true)
                    }
                }
                .awFont(AwFont.Mono.meta)
                .frame(maxWidth: 160, alignment: .leading)
                .padding(.leading, 7)
                .padding(.trailing, 5)
                .frame(height: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(titleColor)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            if let compactRevision {
                revisionMarker(compactRevision)
            }

            // Constant tint: PaneCloseButton applies its tint once at creation
            // (hot-path guard), so a hover/selection-dependent color would go
            // stale after mount. `text` at 0.85 reads on every pill fill.
            PaneCloseButton(
                tint: Color.aw.text.opacity(0.85),
                accessibilityLabel: String(
                    localized: "Close \(tab.title)",
                    comment: "Accessibility label and tooltip for a document tab's close button"
                ),
                action: onClose
            )
            // 24×24 hit target meets WCAG 2.5.8, same as the terminal bar's X.
            .frame(width: 24, height: 24)
        }
        .background(fillColor, in: RoundedRectangle(cornerRadius: 5))
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .stroke(strokeColor, lineWidth: 0.5)
        }
        .onHover { isHovering = $0 }
        .help(tab.title)
    }

    private func revisionMarker(_ revision: LineDiffCount) -> some View {
        let label = LocalizedPluralStrings.documentRevisionIndicator(
            added: revision.added,
            removed: revision.removed
        )
        return Button(action: onRevealRevision) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 9, weight: .semibold))
                .frame(width: 18, height: 18)
                .background(accentSoftColor, in: Circle())
        }
        .buttonStyle(.plain)
        .frame(width: 22, height: 24)
        .foregroundStyle(accentColor)
        .help(label)
        .accessibilityLabel(String(
            localized: "\(tab.title): \(label)",
            comment: "Accessibility label for a compact document revision indicator"
        ))
        .accessibilityHint(String(
            localized: "Show revision details",
            comment: "Accessibility hint for a compact document revision indicator"
        ))
    }

    private var titleColor: Color {
        if isSelected { return accentColor }
        return isHovering ? Color.aw.text : Color.aw.text2
    }

    private var fillColor: Color {
        if isSelected { return accentSoftColor }
        return isHovering
            ? Color.aw.surface.chrome2
            : Color.aw.surface.chrome2.opacity(0.72)
    }

    private var strokeColor: Color {
        guard isSelected else { return Color.aw.border2 }
        return increasedContrast ? accentColor : accentColor.opacity(0.35)
    }

    private var accessibilityLabel: String {
        var parts = [tab.title]
        if let taskProgress {
            parts.append(LocalizedPluralStrings.documentTaskProgress(
                done: taskProgress.done,
                total: taskProgress.total
            ))
        }
        parts.append(String(
            localized: "tab \(tabIndex) of \(tabCount)",
            comment: "Position of a document tab within its tab strip"
        ))
        return parts.joined(separator: ", ")
    }
}
