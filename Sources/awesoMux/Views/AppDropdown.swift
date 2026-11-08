import DesignSystem
import SwiftUI

private let appDropdownWidth: CGFloat = 280

struct AppDropdownItem {
    let title: String
    var id: AnyHashable?
    var isEnabled = true
    var isSelected = false
    var isSeparator = false
    var accessibilityHint: String?
    let action: (() -> Void)?

    struct NavigationState: Equatable {
        let id: AnyHashable
        let isEnabled: Bool
    }

    var navigationState: NavigationState {
        NavigationState(id: id ?? AnyHashable(title), isEnabled: isEnabled && action != nil)
    }

    static var separator: Self { Self(title: "", isSeparator: true, action: nil) }

    static func heading(_ title: String) -> Self { Self(title: title, action: nil) }
}

enum AppDropdownNavigation {
    static func next(after current: Int?, forward: Bool, enabled: [Int]) -> Int? {
        guard !enabled.isEmpty else { return nil }
        guard let current, let index = enabled.firstIndex(of: current) else {
            return forward ? enabled.first : enabled.last
        }
        return enabled[(index + (forward ? 1 : enabled.count - 1)) % enabled.count]
    }

    static func match(prefix: String, titles: [String], enabled: [Int]) -> Int? {
        let folded = prefix.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return enabled.first { titles[$0].folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).hasPrefix(folded) }
    }

    static func reconcile<ID: Hashable>(current: Int?, old: [ID], new: [ID], enabled: [Int], fallback: Int?) -> Int? {
        guard let current, old.indices.contains(current), let updated = new.firstIndex(of: old[current]),
            enabled.contains(updated)
        else { return fallback }
        return updated
    }

}

/// Button-opened app menus share the path bar's opaque, themed foldout chrome.
struct AppDropdown<Label: View>: View {
    let items: [AppDropdownItem]
    var menuTitle = String(localized: "Options", comment: "Fallback accessible title for a button-opened options menu")
    @ViewBuilder let label: () -> Label
    @State private var isPresented = false
    @FocusState private var triggerHasFocus: Bool
    @State private var contentHeight: CGFloat = 360
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            label()
        }
        .buttonStyle(.plain)
        .focusable(interactions: .activate)
        .focused($triggerHasFocus)
        .focusEffectDisabled()
        .awFocusRing(triggerHasFocus, cornerRadius: AwRadius.button)
        .onKeyPress(keys: [.downArrow, .return, .space], phases: .down) { press in
            guard press.modifiers.intersection([.command, .control, .option]).isEmpty else { return .ignored }
            triggerHasFocus = true
            isPresented = true
            return .handled
        }
        .opacity(isEnabled ? 1 : 0.5)
        .background {
            AppDropdownPresenter(
                isPresented: $isPresented, title: menuTitle, contentSize: CGSize(width: appDropdownWidth, height: contentHeight)
            ) {
                dismiss in
                AppDropdownContent(items: items, menuTitle: menuTitle, contentHeight: $contentHeight, dismiss: dismiss)
            }
        }
        .onChange(of: isEnabled) { _, enabled in
            if !enabled { isPresented = false }
        }
        .onDisappear { isPresented = false }
    }
}

extension AppDropdown where Label == AppDropdownLabel {
    init(_ title: String, items: [AppDropdownItem]) {
        self.items = items
        self.menuTitle = title
        self.label = { AppDropdownLabel(title: title) }
    }
}

struct AppDropdownLabel: View {
    let title: String

    var body: some View {
        HStack(spacing: 6) {
            Text(title).lineLimit(1).truncationMode(.middle)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.aw.text3)
                .accessibilityHidden(true)
        }
        .awFont(AwFont.UI.label)
        .foregroundStyle(Color.aw.text)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.aw.surface.elevated, in: RoundedRectangle(cornerRadius: AwRadius.button))
        .overlay {
            RoundedRectangle(cornerRadius: AwRadius.button).stroke(Color.aw.border, lineWidth: 0.5)
        }
        .contentShape(Rectangle())
    }
}

struct AppDropdownPicker<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(value: Value, title: String)]

    var body: some View {
        AppDropdown(
            items: options.map { option in
                AppDropdownItem(title: option.title, id: AnyHashable(option.value), isSelected: option.value == selection) {
                    selection = option.value
                }
            }, menuTitle: title
        ) {
            AppDropdownLabel(title: options.first(where: { $0.value == selection })?.title ?? title)
        }
        .disabled(options.isEmpty)
        .accessibilityLabel(title)
        .accessibilityValue(options.first(where: { $0.value == selection })?.title ?? title)
    }
}

private struct AppDropdownContent: View {
    let items: [AppDropdownItem]
    let menuTitle: String
    @Binding var contentHeight: CGFloat
    let dismiss: () -> Void
    @State private var focusedIndex: Int?
    @FocusState private var keyboardIndex: Int?
    @AccessibilityFocusState private var accessibilityIndex: Int?
    @State private var typedPrefix = ""
    @State private var pointerNavigation = false
    @State private var lastTypedAt: ContinuousClock.Instant?
    @Environment(\.awTextScale) private var textScale

    private var rowHeight: CGFloat { ceil(30 * max(1, textScale)) }

    private var enabledIndices: [Int] {
        items.indices.filter { items[$0].action != nil && items[$0].isEnabled }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(items.indices, id: \.self) { index in
                        let item = items[index]
                        if item.isSeparator {
                            Divider().overlay(Color.aw.border2).padding(.vertical, 3).accessibilityHidden(true)
                        } else if let action = item.action {
                            Button {
                                guard item.isEnabled else { return }
                                dismiss()
                                action()
                            } label: {
                                HStack(spacing: 8) {
                                    Text(item.title)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 8)
                                    if item.isSelected {
                                        Image(systemName: "checkmark").accessibilityHidden(true)
                                    }
                                }
                                .awFont(AwFont.UI.label)
                                .foregroundStyle(item.isEnabled ? Color.aw.text : Color.aw.text3)
                                .padding(.horizontal, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .frame(minHeight: rowHeight)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(AppMenuRowButtonStyle(tone: Color.aw.accent, filled: item.isSelected || focusedIndex == index))
                            .overlay {
                                RoundedRectangle(cornerRadius: AwRadius.pill)
                                    .stroke(focusedIndex == index ? Color.aw.accentOnChrome : .clear, lineWidth: 1.5)
                                    .allowsHitTesting(false)
                                    .accessibilityHidden(true)
                            }
                            .disabled(!item.isEnabled)
                            .focusable()
                            .focusEffectDisabled()
                            .focused($keyboardIndex, equals: index)
                            .onAppear {
                                if focusedIndex == index { keyboardIndex = index }
                            }
                            .accessibilityFocused($accessibilityIndex, equals: index)
                            .onKeyPress(keys: [.upArrow, .downArrow], action: handleNavigation)
                            .onKeyPress(keys: [.return, .space], phases: .down, action: handleActivation)
                            .onKeyPress(characters: .alphanumerics.union(.punctuationCharacters).union(.symbols), action: handleTyping)
                            .onHover { hovering in
                                if hovering && item.isEnabled {
                                    pointerNavigation = true
                                    focusedIndex = index
                                }
                            }
                            .accessibilityAddTraits(item.isSelected ? [.isSelected] : [])
                            .accessibilityHint(item.accessibilityHint ?? "", isEnabled: item.accessibilityHint != nil)
                            .help(item.accessibilityHint ?? item.title)
                            .id(index)
                        } else {
                            Text(item.title)
                                .awFont(AwFont.UI.meta)
                                .foregroundStyle(Color.aw.text3)
                                .padding(.horizontal, 8)
                                .frame(minHeight: rowHeight)
                                .lineLimit(1)
                                .help(item.title)
                                .accessibilityAddTraits(.isHeader)
                        }
                    }
                }
                .padding(6)
                .onGeometryChange(for: CGFloat.self) {
                    min(max(ceil($0.size.height), 1), 360)
                } action: {
                    contentHeight = $0
                }
            }
            .onChange(of: focusedIndex) { _, index in
                if !pointerNavigation, let index { proxy.scrollTo(index) }
                keyboardIndex = index
                accessibilityIndex = index
            }
        }
        .frame(width: appDropdownWidth, height: contentHeight)
        .modifier(AppMenuChrome(accent: Color.aw.accent))
        .task {
            focusedIndex = enabledIndices.first(where: { items[$0].isSelected }) ?? enabledIndices.first
        }
        .onKeyPress(keys: [.upArrow, .downArrow], action: handleNavigation)
        .onKeyPress(keys: [.return, .space], phases: .down, action: handleActivation)
        .onKeyPress(characters: .alphanumerics.union(.punctuationCharacters).union(.symbols), action: handleTyping)
        .onChange(of: keyboardIndex) { _, index in
            if let index, enabledIndices.contains(index) { focusedIndex = index }
        }
        .onChange(of: accessibilityIndex) { _, index in
            if let index, enabledIndices.contains(index) {
                pointerNavigation = false
                focusedIndex = index
            }
        }
        .onChange(of: items.map(\.navigationState)) { old, new in
            focusedIndex = AppDropdownNavigation.reconcile(
                current: focusedIndex, old: old.map(\.id), new: new.map(\.id), enabled: enabledIndices,
                fallback: enabledIndices.first(where: { items[$0].isSelected }) ?? enabledIndices.first)
        }
        .onExitCommand(perform: dismiss)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(menuTitle)
    }

    private func handleNavigation(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.intersection([.command, .control, .option]).isEmpty else { return .ignored }
        pointerNavigation = false
        focusedIndex = AppDropdownNavigation.next(
            after: focusedIndex, forward: press.key == .downArrow, enabled: enabledIndices)
        return .handled
    }

    private func handleActivation(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.intersection([.command, .control, .option]).isEmpty else { return .ignored }
        if press.key == .space, !typedPrefix.isEmpty, let lastTypedAt,
            ContinuousClock.now - lastTypedAt <= .seconds(1)
        {
            return handleTyping(press)
        }
        guard let focusedIndex, enabledIndices.contains(focusedIndex), let action = items[focusedIndex].action else { return .handled }
        dismiss()
        action()
        return .handled
    }

    private func handleTyping(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.intersection([.command, .control, .option]).isEmpty else { return .ignored }
        pointerNavigation = false
        let now = ContinuousClock.now
        if let lastTypedAt, now - lastTypedAt > .seconds(1) { typedPrefix = "" }
        lastTypedAt = now
        typedPrefix += press.characters
        let titles = items.map(\.title)
        if let match = AppDropdownNavigation.match(prefix: typedPrefix, titles: titles, enabled: enabledIndices) {
            focusedIndex = match
        } else {
            typedPrefix = press.characters
            if let match = AppDropdownNavigation.match(prefix: typedPrefix, titles: titles, enabled: enabledIndices) {
                focusedIndex = match
            }
        }
        return .handled
    }

}
