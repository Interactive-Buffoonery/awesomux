import DesignSystem
import SwiftUI

struct KeyboardCheatsheetView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Bindable var model: KeyboardCheatsheetModel
    let onRunSelected: () -> Void
    let onRunEntry: (KeyboardShortcutEntry.ID) -> Void
    let onDismiss: () -> Void

    @State private var isSearchFocused = false

    private var visibleShortcutCountText: String {
        LocalizedPluralStrings.keyboardCheatsheetMatchingShortcuts(count: model.visibleShortcutCount)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.aw.border2)
            shortcutList
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.aw.border2, lineWidth: 0.5)
        }
        .overlay(alignment: .topTrailing) {
            FloatingPanelCloseButton(
                accessibilityLabel: "Close keyboard shortcuts",
                action: onDismiss
            )
            .padding(.top, 12)
            .padding(.trailing, FloatingPanelChromeMetrics.closeButtonEdgeInset)
        }
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.aw.surface.chrome.opacity(0.97))
                .awShadow(.overlay, rendering: .composited)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Keyboard shortcuts")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Keyboard")
                        .awFont(AwFont.Mono.kicker)
                        .textCase(.uppercase)
                        .foregroundStyle(Color.aw.text3)
                        .accessibilityHidden(true)

                    Text("Shortcuts")
                        .awFont(AwFont.UI.title)
                        .foregroundStyle(Color.aw.text)
                        .accessibilityAddTraits(.isHeader)
                }
            }

            HStack(spacing: 10) {
                KeyboardCheatsheetSearchField(
                    text: $model.query,
                    onMoveSelection: model.moveSelection,
                    onRunSelected: onRunSelected,
                    onDismiss: onDismiss,
                    onFocusChanged: { isSearchFocused = $0 }
                )
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(Color.aw.surface.elevated, in: RoundedRectangle(cornerRadius: 6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            // Snapshot-only: this bare NSHostingController panel root reads the live accent mailbox at each per-summon rebind.
                            .stroke(Color.aw.accent, lineWidth: isSearchFocused ? 0.75 : 0.5)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.aw.accentSoft, lineWidth: isSearchFocused ? 2 : 0)
                    }
                    .accessibilityLabel("Search shortcuts")

                Text(visibleShortcutCountText)
                    .awFont(AwFont.Mono.kbd)
                    .foregroundStyle(Color.aw.text3)
                    .padding(.horizontal, 9)
                    .frame(height: 28)
                    .background(Color.aw.surface.elevated, in: RoundedRectangle(cornerRadius: 5))
                    .overlay {
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(Color.aw.border2, lineWidth: 0.5)
                    }
                    .accessibilityLabel(visibleShortcutCountText)
            }
        }
        .padding(.horizontal, 18)
        .padding(.trailing, 64)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.aw.surface.chrome2.opacity(0.56))
    }

    private var shortcutList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if model.filteredSections.isEmpty {
                        emptyState
                    } else {
                        ForEach(model.filteredSections) { section in
                            KeyboardCheatsheetSectionView(
                                section: section,
                                selectedEntryID: model.selectedEntryID,
                                onRunEntry: onRunEntry
                            )
                        }
                    }
                }
                .padding(12)
            }
            .background(Color.aw.surface.window.opacity(0.28))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Shortcut groups")
            .onChange(of: model.selectedEntryID) { _, entryID in
                guard let entryID else { return }
                if reduceMotion {
                    proxy.scrollTo(entryID, anchor: .center)
                } else {
                    withAnimation(.easeOut(duration: 0.16)) {
                        proxy.scrollTo(entryID, anchor: .center)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("No matching shortcuts")
                .awFont(AwFont.UI.label)
                .foregroundStyle(Color.aw.text2)

            Text(model.query)
                .awFont(AwFont.Mono.meta)
                .foregroundStyle(Color.aw.text3)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            footerHint(binding: KeyboardShortcutCatalog.showKeyboardCheatsheet, title: "open")
            footerHint(symbols: ["↑", "↓"], title: "select")
            footerHint(symbol: "↵", title: "run")
            footerHint(symbols: ["⌘", "C"], title: "copy")
            Spacer(minLength: 12)
            footerHint(symbol: "esc", title: "close")
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 42)
        .background(Color.aw.surface.chrome2.opacity(0.70))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.aw.border2)
                .frame(height: 0.5)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Question mark opens shortcuts when text is not focused. Command slash opens shortcuts anywhere. Up and down arrows select a shortcut. Return runs the selected shortcut. Command C copies the selected shortcut. Escape closes.")
    }

    private func footerHint(symbol: String, title: String) -> some View {
        footerHint(symbols: [symbol], title: title)
    }

    private func footerHint(symbols: [String], title: String) -> some View {
        HStack(spacing: 7) {
            HStack(spacing: 5) {
                ForEach(symbols, id: \.self) { symbol in
                    KBD(symbol)
                }
            }
            Text(title)
                .awFont(AwFont.Mono.kbd)
                .foregroundStyle(Color.aw.text3)
        }
    }

    private func footerHint(binding: KeyBinding, title: String) -> some View {
        HStack(spacing: 7) {
            ShortcutChordView(binding: binding)
            Text(title)
                .awFont(AwFont.Mono.kbd)
                .foregroundStyle(Color.aw.text3)
        }
    }

    @ViewBuilder
    private var panelBackground: some View {
        ZStack {
            Color.aw.surface.chrome.opacity(0.96)
            LinearGradient(
                colors: [
                    Color.aw.accent.opacity(0.08),
                    Color.clear,
                    Color.aw.teal.opacity(0.05)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

}

private struct KeyboardCheatsheetSectionView: View {
    let section: KeyboardShortcutSection
    let selectedEntryID: String?
    let onRunEntry: (KeyboardShortcutEntry.ID) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(section.title)
                    .awFont(AwFont.Mono.kicker)
                    .textCase(.uppercase)
                    .foregroundStyle(Color.aw.accent)
                    .accessibilityAddTraits(.isHeader)

                Spacer(minLength: 12)

                Text("\(section.entries.count)")
                    .awFont(AwFont.Mono.kbd)
                    .foregroundStyle(Color.aw.textFaint)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(Color.aw.accent.opacity(0.06))
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.aw.border)
                    .frame(height: 0.5)
            }

            ForEach(Array(section.entries.enumerated()), id: \.element.id) { index, entry in
                KeyboardCheatsheetRow(
                    entry: entry,
                    isFirst: index == 0,
                    isSelected: entry.id == selectedEntryID,
                    onRun: { onRunEntry(entry.id) }
                )
                .id(entry.id)
            }
        }
        .background(Color.aw.surface.elevated.opacity(0.62), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.aw.border, lineWidth: 0.5)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct KeyboardCheatsheetRow: View {
    let entry: KeyboardShortcutEntry
    let isFirst: Bool
    let isSelected: Bool
    let onRun: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            horizontalLayout
            verticalLayout
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: 42)
        .background(rowBackground, in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.aw.accent.opacity(0.46), lineWidth: 0.75)
            }
        }
        .overlay(alignment: .top) {
            if !isFirst {
                Rectangle()
                    .fill(Color.aw.border)
                    .frame(height: 0.5)
            }
        }
        .overlay(alignment: .leading) {
            if isSelected {
                Capsule()
                    .fill(Color.aw.accent)
                    .frame(width: 3)
                    .padding(.vertical, 8)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Run Shortcut", onRun)
    }

    private var horizontalLayout: some View {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            chords
                .frame(minWidth: 118, alignment: .trailing)
            textContent
        }
    }

    private var verticalLayout: some View {
        VStack(alignment: .leading, spacing: 6) {
            chords
            textContent
        }
    }

    private var chords: some View {
        HStack(spacing: 6) {
            ForEach(Array(entry.bindings.enumerated()), id: \.element.id) { index, binding in
                if index > 0 {
                    Text("or")
                        .awFont(AwFont.Mono.kbd)
                        .foregroundStyle(Color.aw.textFaint)
                }
                ShortcutChordView(binding: binding)
            }
        }
    }

    private var textContent: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.action)
                .awFont(AwFont.UI.label)
                .foregroundStyle(Color.aw.text)
                .lineLimit(2)

            if let detail = entry.detail {
                Text(detail)
                    .awFont(AwFont.Mono.meta)
                    .foregroundStyle(Color.aw.text3)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var rowBackground: Color {
        isSelected ? Color.aw.accentSoft : Color.clear
    }

    private var accessibilityLabel: String {
        let shortcut = entry.bindings.map(\.spokenForm).joined(separator: " or ")
        if let detail = entry.detail {
            return "\(entry.action), \(shortcut), \(detail)"
        }
        return "\(entry.action), \(shortcut)"
    }
}
