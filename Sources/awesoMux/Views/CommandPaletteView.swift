import AppKit
import Carbon.HIToolbox
import DesignSystem
import SwiftUI

@MainActor
struct CommandPaletteView: View {
    @Bindable var presenter: PalettePresenter
    let focusState: CommandPaletteFocusState
    let onDismiss: () -> Void
    /// Posts a VoiceOver announcement against the palette panel. Routed through
    /// the controller (which owns the panel) because announcements posted to
    /// `NSApp.keyWindow` are dropped whenever the panel isn't the key window.
    let onAnnounce: (String) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var results: PaletteResults { presenter.currentResults }
    // Reuse the presenter's cached flatten rather than re-running `flatMap` on
    // every body eval / every row's accessibilityValue.
    private var flattenedResults: [PaletteResult] { presenter.flattenedResults }
    private var selectedResultID: String? { presenter.selectedResult?.id }
    private var resultAnnouncementKey: String? {
        // Key on the count too, so broadening/narrowing a query that keeps the
        // same top selection still re-announces (e.g. 5 → 12 results).
        let count = flattenedResults.count
        if let selectedResultID {
            return "\(count).\(selectedResultID)"
        }
        guard !results.query.isEmpty else {
            return nil
        }
        return "empty.\(results.query)"
    }
    private var indexedGroups: [IndexedPaletteResultGroup] {
        var nextIndex = 0
        return results.groups.map { group in
            let indexedResults = group.results.map { result in
                defer { nextIndex += 1 }
                return IndexedPaletteResult(index: nextIndex, result: result)
            }
            return IndexedPaletteResultGroup(group: group, results: indexedResults)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchHeader
            resultList
            footer
        }
        // Fill the panel's content size (which the controller clamps responsively
        // to the visible frame) rather than a hard 620×430, so the layout reflows
        // on small displays / Split View instead of clipping.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(focusState.isKeyWindow ? Color.aw.border2 : Color.aw.border, lineWidth: 0.5)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                // Snapshot-only: this bare NSHostingController panel root reads the live accent mailbox at each per-summon rebind.
                .stroke(Color.aw.accent.opacity(focusState.isKeyWindow ? 0.18 : 0.06), lineWidth: 1)
        }
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.aw.surface.chrome.opacity(focusState.isKeyWindow ? 0.97 : 0.94))
                .awShadow(.sheet, rendering: .composited)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Command Palette")
        .accessibilityHint("Type to search workspaces and actions. Press Escape to dismiss.")
        .onChange(of: resultAnnouncementKey) { _, _ in
            postResultStateAnnouncement()
        }
    }

    private var searchHeader: some View {
        HStack(spacing: 10) {
            modeBadge

            CommandPaletteSearchField(
                text: $presenter.query,
                onMoveSelection: { presenter.moveSelection(delta: $0) },
                onSubmit: { surface in
                    performSelectedResultAfterDismiss(surface: surface)
                },
                onDismiss: onDismiss
            )
            .frame(minHeight: AwSpacing.searchFieldHeight)
            .accessibilityLabel("Command palette search")
            .accessibilityHint("Type to search. Use Up and Down Arrow to choose a result, Return to open it, or Escape to dismiss.")

            KBD("esc")
                .accessibilityLabel("Escape")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.aw.surface.chrome2.opacity(0.62))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.aw.border2)
                .frame(height: 0.5)
        }
    }

    @ViewBuilder
    private var modeBadge: some View {
        switch results.mode {
        case .unified:
            Text("›")
                .awFont(AwFont.Mono.body).fontWeight(.bold)
                .foregroundStyle(Color.aw.accent)
                .frame(width: 22)
                .accessibilityHidden(true)
        case .actionsOnly:
            Text("actions")
                .awFont(AwFont.Mono.kicker)
                .foregroundStyle(Color.aw.accent)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.aw.accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 4))
                .accessibilityLabel("Actions only mode")
        case .quickRun:
            Text("run")
                .awFont(AwFont.Mono.kicker)
                .foregroundStyle(Color.aw.teal)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.aw.teal.opacity(0.16), in: RoundedRectangle(cornerRadius: 4))
                .accessibilityLabel("Quick run mode")
        }
    }

    private var resultList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if results.groups.isEmpty {
                        emptyState
                    } else {
                        resultGroups
                    }
                }
                .padding(.vertical, 6)
            }
            .onChange(of: selectedResultID) { _, id in
                guard let id else { return }
                if reduceMotion {
                    proxy.scrollTo(id, anchor: .center)
                } else {
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Command palette results")
    }

    private var resultGroups: some View {
        ForEach(indexedGroups) { indexedGroup in
            VStack(alignment: .leading, spacing: 0) {
                groupHeader(indexedGroup.group)

                ForEach(indexedGroup.results) { indexedResult in
                    Button {
                        presenter.select(index: indexedResult.index)
                        performAfterDismiss(indexedResult.result)
                    } label: {
                        CommandPaletteResultRow(
                            result: indexedResult.result,
                            isSelected: presenter.selectedIndex == indexedResult.index
                        )
                    }
                    .buttonStyle(.plain)
                    .id(indexedResult.id)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(accessibilityLabel(for: indexedResult.result))
                    .accessibilityValue("\(indexedResult.index + 1) of \(flattenedResults.count)")
                    .accessibilityAddTraits(presenter.selectedIndex == indexedResult.index ? .isSelected : [])
                    .accessibilityHint(accessibilityHint(for: indexedResult.result))
                }
            }
        }
    }

    private func groupHeader(_ group: PaletteResultGroup) -> some View {
        HStack(spacing: 6) {
            Text(group.title)
            Text("· \(group.results.count)")
                .foregroundStyle(Color.aw.textFaint)
        }
        .awFont(AwFont.Mono.kicker)
        .foregroundStyle(Color.aw.text3)
        .textCase(.uppercase)
        .padding(.horizontal, 16)
        .padding(.top, 9)
        .padding(.bottom, 4)
        .accessibilityAddTraits(.isHeader)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text(results.query.isEmpty ? "Type to search workspaces and actions" : "No results")
                .awFont(AwFont.UI.label)
                .foregroundStyle(Color.aw.text2)

            HStack(spacing: 8) {
                KBD(">")
                Text("actions only")
                    .awFont(AwFont.Mono.meta)
                    .foregroundStyle(Color.aw.text3)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Type the greater-than sign to filter to actions only")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 72)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            if results.mode == .quickRun {
                quickRunFooterHints
            } else {
                HStack(spacing: 14) {
                    KBD("↑↓")
                    Text("navigate")
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Up and Down arrow keys to navigate")

                HStack(spacing: 14) {
                    KBD("↵")
                    Text("open")
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Return key to open")
            }

            Spacer()
            Text("\(flattenedResults.count) results")
                .foregroundStyle(Color.aw.textFaint)
                .accessibilityHidden(true)
        }
        .awFont(AwFont.Mono.meta)
        .foregroundStyle(Color.aw.text3)
        .padding(.horizontal, 16)
        .frame(minHeight: 42)
        .background(Color.aw.surface.chrome2.opacity(0.70))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.aw.border2)
                .frame(height: 0.5)
        }
    }

    private var quickRunFooterHints: some View {
        HStack(spacing: 14) {
            quickRunHint(symbol: "↵", title: "toast", surface: .toast)
            quickRunHint(symbol: "⌘↵", title: "panel", surface: .floatingPanel)
            quickRunHint(symbol: "⌘⇧↵", title: "tab", surface: .newTab)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Quick run shortcuts. Return runs as toast. Command Return runs in the floating panel. Command Shift Return runs in a new tab.")
    }

    private func quickRunHint(
        symbol: String,
        title: String,
        surface: PaletteQuickRunCommitSurface
    ) -> some View {
        let isActive = focusState.quickRunCommitSurface == surface
        return HStack(spacing: 8) {
            KBD(symbol)
            Text(title)
        }
        .foregroundStyle(isActive ? Color.aw.accent : Color.aw.text3)
        .padding(.horizontal, isActive ? 8 : 0)
        .padding(.vertical, isActive ? 4 : 0)
        .background(isActive ? Color.aw.accentSoft : Color.clear, in: RoundedRectangle(cornerRadius: 4))
    }

    @ViewBuilder
    private var panelBackground: some View {
        ZStack {
            Color.aw.surface.chrome.opacity(0.97)
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

    private func accessibilityLabel(for result: PaletteResult) -> String {
        presenter.accessibilityAnnouncement(for: result)
    }

    private func accessibilityHint(for result: PaletteResult) -> String {
        switch result {
        case .quickRun:
            "Press Return to run as a toast, Command Return to run in the floating panel, or Command Shift Return to run in a new tab."
        default:
            ""
        }
    }

    private func postResultStateAnnouncement() {
        let count = flattenedResults.count
        let announcement: String
        if let selected = presenter.selectedResult {
            let countPrefix = "\(LocalizedPluralStrings.commandPaletteResults(count: count)). "
            announcement = countPrefix + presenter.accessibilityAnnouncement(for: selected)
        } else if !results.query.isEmpty {
            announcement = "No command palette results"
        } else {
            return
        }
        onAnnounce(announcement)
    }

    private func performSelectedResultAfterDismiss(surface: PaletteQuickRunCommitSurface = .toast) {
        guard let result = presenter.selectedResult else {
            return
        }
        performAfterDismiss(result, surface: surface)
    }

    private func performAfterDismiss(_ result: PaletteResult, surface: PaletteQuickRunCommitSurface = .toast) {
        guard presenter.canPerform(result) else {
            return
        }
        onDismiss()
        DispatchQueue.main.async {
            presenter.perform(result, surface: surface)
        }
    }
}

private struct CommandPaletteResultRow: View {
    let result: PaletteResult
    let isSelected: Bool

    var body: some View {
        // Align the leading icon (and trailing shortcut) to the title's baseline
        // so they sit on the bold line, not floating at the row's vertical center
        // on two-line rows.
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            icon
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .awFont(AwFont.UI.label)
                    .foregroundStyle(isSelected ? Color.aw.accent : Color.aw.text)
                    .lineLimit(2)

                if let subtitle {
                    Text(subtitle)
                        .awFont(AwFont.Mono.meta)
                        .foregroundStyle(Color.aw.text3)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 10)

            if let shortcut {
                KBD(shortcut.displaySymbol)
                    .accessibilityLabel(shortcut.spokenForm)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(rowBackground, in: RoundedRectangle(cornerRadius: 5))
        .overlay(alignment: .leading) {
            if isSelected {
                Capsule()
                    .fill(Color.aw.accent)
                    .frame(width: 2)
                    .padding(.vertical, 7)
            }
        }
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
    }

    private var icon: some View {
        Text(iconText)
            .awFont(AwFont.Mono.meta)
            .foregroundStyle(isSelected ? Color.aw.accent : Color.aw.text3)
    }

    private var rowBackground: Color {
        isSelected ? Color.aw.accentSoft : Color.clear
    }

    private var iconText: String {
        switch result {
        case .session:
            "▸"
        case .command:
            "⌘"
        case .quickRun:
            "›"
        }
    }

    private var title: String {
        switch result {
        case .session(let session):
            session.title
        case .command(let command):
            command.title
        case .quickRun(let quickRun):
            quickRun.title
        }
    }

    private var subtitle: String? {
        switch result {
        case .session(let session):
            if let subtitle = session.subtitle {
                "\(session.groupName) · \(subtitle)"
            } else {
                session.groupName
            }
        case .command(let command):
            command.subtitle
        case .quickRun(let quickRun):
            quickRun.subtitle
        }
    }

    private var shortcut: KeyBinding? {
        switch result {
        case .session:
            nil
        case .command(let command):
            command.shortcut
        case .quickRun:
            nil
        }
    }
}

private struct IndexedPaletteResultGroup: Identifiable {
    let group: PaletteResultGroup
    let results: [IndexedPaletteResult]

    var id: String { group.id }
}

private struct IndexedPaletteResult: Identifiable {
    let index: Int
    let result: PaletteResult

    var id: String { result.id }
}

private struct CommandPaletteSearchField: NSViewRepresentable {
    @Binding var text: String
    let onMoveSelection: (Int) -> Void
    let onSubmit: (PaletteQuickRunCommitSurface) -> Void
    let onDismiss: () -> Void

    func makeNSView(context: Context) -> PaletteSearchField {
        let field = PaletteSearchField()
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        // Plain text input, not a system search field: NSSearchField always
        // renders its magnifier + cancel button cells (independent of bezel),
        // and the palette already shows its own `›` mode badge. Kill the system
        // focus ring too — the panel chrome draws its own focus treatment, and
        // macOS otherwise stacks a second blue ring (see the two-focus-rings
        // gotcha).
        field.focusRingType = .none
        field.font = NSFont.preferredFont(forTextStyle: .body)
        field.textColor = NSColor.labelColor
        field.placeholderString = "Search workspaces and actions..."
        field.delegate = context.coordinator
        field.onMoveSelection = onMoveSelection
        field.onSubmit = onSubmit
        field.onDismiss = onDismiss
        // First-responder is claimed in updateNSView (which SwiftUI calls
        // immediately after makeNSView, once the field is in a window). Doing it
        // here too races: at make time `field.window` is usually still nil.
        return field
    }

    func updateNSView(_ nsView: PaletteSearchField, context: Context) {
        context.coordinator.update(text: $text)

        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        nsView.onMoveSelection = onMoveSelection
        nsView.onSubmit = onSubmit
        nsView.onDismiss = onDismiss
        guard nsView.currentEditor() == nil else {
            return
        }
        DispatchQueue.main.async { [weak nsView] in
            guard let nsView, nsView.currentEditor() == nil else {
                return
            }
            nsView.window?.makeFirstResponder(nsView)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        private var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func update(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else {
                return
            }
            text.wrappedValue = field.stringValue
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            guard let field = control as? PaletteSearchField,
                  let command = CommandPaletteSearchCommand.command(
                      for: commandSelector,
                      modifiers: field.currentModifierFlags
                  ) else {
                return false
            }

            field.perform(command)
            return true
        }
    }
}

private final class PaletteSearchField: NSTextField {
    var onMoveSelection: ((Int) -> Void)?
    var onSubmit: ((PaletteQuickRunCommitSurface) -> Void)?
    var onDismiss: (() -> Void)?

    var currentModifierFlags: NSEvent.ModifierFlags {
        NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
    }

    override func keyDown(with event: NSEvent) {
        guard let command = CommandPaletteSearchCommand.command(for: event) else {
            super.keyDown(with: event)
            return
        }
        perform(command)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let command = CommandPaletteSearchCommand.modifiedReturnCommand(for: event) else {
            return super.performKeyEquivalent(with: event)
        }
        perform(command)
        return true
    }

    func perform(_ command: CommandPaletteSearchCommand) {
        switch command {
        case .move(let delta):
            onMoveSelection?(delta)
        case .submit(let surface):
            onSubmit?(surface)
        case .dismiss:
            onDismiss?()
        }
    }
}

enum CommandPaletteSearchCommand: Equatable {
    case move(Int)
    case submit(PaletteQuickRunCommitSurface)
    case dismiss

    static func command(
        for selector: Selector,
        modifiers: NSEvent.ModifierFlags = []
    ) -> CommandPaletteSearchCommand? {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            .move(1)
        case #selector(NSResponder.moveUp(_:)):
            .move(-1)
        case #selector(NSResponder.insertNewline(_:)),
             #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            .submit(CommandPaletteFocusState.quickRunCommitSurface(for: modifiers))
        case #selector(NSResponder.cancelOperation(_:)):
            .dismiss
        default:
            nil
        }
    }

    static func command(for event: NSEvent) -> CommandPaletteSearchCommand? {
        command(forKeyCode: event.keyCode, modifiers: event.modifierFlags)
    }

    static func modifiedReturnCommand(for event: NSEvent) -> CommandPaletteSearchCommand? {
        let normalized = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .function])
        guard normalized.contains(.command) else {
            return nil
        }
        return command(forKeyCode: event.keyCode, modifiers: event.modifierFlags)
    }

    static func command(
        forKeyCode keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags = []
    ) -> CommandPaletteSearchCommand? {
        switch Int(keyCode) {
        case kVK_DownArrow:
            .move(1)
        case kVK_UpArrow:
            .move(-1)
        case kVK_Return, kVK_ANSI_KeypadEnter:
            .submit(CommandPaletteFocusState.quickRunCommitSurface(for: modifiers))
        case kVK_Escape:
            .dismiss
        default:
            nil
        }
    }
}
