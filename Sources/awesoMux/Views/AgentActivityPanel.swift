import AwesoMuxCore
import DesignSystem
import SwiftUI

struct AgentActivityPanelItem: Identifiable, Equatable {
    let row: AgentActivityRoster.Row
    let title: String
    let locationText: String
    let workspaceText: String

    var id: UUID { row.paneID }
}

/// A global pane index. Placement freezes during interaction, while labels stay live.
struct AgentActivityPanel: View {
    let items: [AgentActivityPanelItem]
    let scrollTarget: AgentDisplayState?
    let scrollRequestID: UUID
    let focusRequestID: UUID?
    let livePaneIDs: Set<UUID>
    let selectedPaneID: UUID?
    let onSelect: (AgentActivityRoster.Row) -> Void
    let onMarkSeen: (AgentActivityRoster.Row) -> Void
    let onDismissReminder: (AgentActivityRoster.Row) -> Void
    let onClose: () -> Void

    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @State private var heldIDs: [UUID] = []
    @State private var heldItems: [AgentActivityPanelItem] = []
    @State private var heldSections: [UUID: AgentActivityRoster.Section] = [:]
    @State private var pointerInside = false
    @FocusState private var focusedPaneID: UUID?
    @AccessibilityFocusState private var accessibilityPaneID: UUID?
    @FocusState private var seenFocusID: UUID?
    @AccessibilityFocusState private var seenAccessibilityID: UUID?
    @FocusState private var updatesFocused: Bool
    @AccessibilityFocusState private var updatesAccessibilityFocused: Bool

    private var interacting: Bool {
        pointerInside || focusedPaneID != nil || accessibilityPaneID != nil || seenFocusID != nil || seenAccessibilityID != nil
            || updatesFocused || updatesAccessibilityFocused
    }

    private var placedItems: [AgentActivityPanelItem] {
        let ranks = Dictionary(heldIDs.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        let live = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let input = interacting ? heldItems.map { live[$0.id] ?? $0 } : items
        return input.enumerated().sorted { lhs, rhs in
            let leftSection = heldSections[lhs.element.id] ?? lhs.element.row.section
            let rightSection = heldSections[rhs.element.id] ?? rhs.element.row.section
            if leftSection != rightSection { return leftSection.rawValue < rightSection.rawValue }
            return (ranks[lhs.element.id] ?? heldIDs.count + lhs.offset) < (ranks[rhs.element.id] ?? heldIDs.count + rhs.offset)
        }.map(\.element)
    }

    private var hasPlacementUpdates: Bool {
        items.map(\.id) != heldIDs || items.contains { heldSections[$0.id] != $0.row.section }
    }

    var body: some View {
        let placed = placedItems
        let sections = Dictionary(grouping: placed) { heldSections[$0.id] ?? $0.row.section }
        let liveIDs = Set(items.map(\.id))
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                // Reserve this space so offering new arrivals never moves a pointer target.
                Button(String(localized: "New activity — show updates", comment: "Apply deferred agent-list placement changes")) {
                    applyPlacementUpdates()
                }
                .buttonStyle(.plain)
                .awFont(AwFont.UI.meta)
                .foregroundStyle(Color.aw.status.needs)
                .frame(maxWidth: .infinity, minHeight: 28)
                .opacity(hasPlacementUpdates ? 1 : 0)
                .disabled(!hasPlacementUpdates)
                .accessibilityHidden(!hasPlacementUpdates)
                .accessibilityLabel(
                    String(localized: "New activity — show updates", comment: "Apply deferred agent-list placement changes")
                )
                .focusable()
                .focused($updatesFocused)
                .accessibilityFocused($updatesAccessibilityFocused)
                .onKeyPress(keys: [.space, .return], phases: .down) { press in
                    guard press.modifiers.subtracting(.capsLock).isEmpty else { return .ignored }
                    applyPlacementUpdates()
                    return .handled
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        if placed.isEmpty && !hasPlacementUpdates {
                            Text(String(localized: "No agents to show", comment: "Empty global agent roster"))
                                .awFont(AwFont.UI.label)
                                .foregroundStyle(Color.aw.railText)
                                .padding(.vertical, 16)
                        }
                        // A single identity scope keeps the same button alive across section moves.
                        ForEach(placed) { item in
                            let section = heldSections[item.id] ?? item.row.section
                            if sections[section]?.first?.id == item.id {
                                HStack {
                                    Text(section.label)
                                        .awFont(AwFont.UI.label)
                                    Spacer()
                                    Text((sections[section]?.count ?? 0).formatted())
                                        .awFont(AwFont.Mono.meta)
                                        .opacity(hasPlacementUpdates ? 0 : 1)
                                        .accessibilityHidden(hasPlacementUpdates)
                                }
                                .foregroundStyle(Color.aw.railText)
                                .padding(.top, 14)
                                .padding(.bottom, 4)
                                .accessibilityAddTraits(.isHeader)
                                .accessibilityElement(children: .combine)
                            }
                            row(item, available: livePaneIDs.contains(item.id), active: liveIDs.contains(item.id))
                                .id(item.id)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 12)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .onAppear {
                    reconcilePlacement()
                    scroll(to: scrollTarget, proxy: proxy)
                }
                .onChange(of: items) { _, _ in if !interacting { reconcilePlacement() } }
                .onChange(of: interacting) { _, active in if !active { reconcilePlacement() } }
                .onChange(of: scrollTarget) { _, target in scroll(to: target, proxy: proxy) }
                .onChange(of: scrollRequestID) { _, _ in
                    reconcilePlacement()
                    scroll(to: scrollTarget, proxy: proxy)
                }
                .onChange(of: focusRequestID) { _, request in
                    guard request != nil else { return }
                    reconcilePlacement()
                    guard let target = items.first(where: { $0.row.section == .needsYou }) ?? items.first else { return }
                    clearPanelFocus()
                    DispatchQueue.main.async {
                        focusRow(target.id)
                        proxy.scrollTo(target.id)
                    }
                }

            }
            .onHover { pointerInside = $0 }
            .onMoveCommand { direction in
                guard direction == .up || direction == .down else { return }
                let navigable = placed.filter { livePaneIDs.contains($0.id) }
                guard !navigable.isEmpty else {
                    if hasPlacementUpdates { updatesFocused = true }
                    return
                }
                if updatesFocused || updatesAccessibilityFocused {
                    let target = navigable[direction == .down ? 0 : navigable.count - 1]
                    updatesFocused = false
                    updatesAccessibilityFocused = false
                    focusRow(target.id)
                    proxy.scrollTo(target.id)
                    return
                }
                let currentID = focusedPaneID ?? seenFocusID ?? selectedPaneID
                let index = navigable.firstIndex { $0.id == currentID } ?? (direction == .down ? -1 : navigable.count)
                if hasPlacementUpdates && ((direction == .up && index == 0) || (direction == .down && index == navigable.count - 1)) {
                    focusedPaneID = nil
                    seenFocusID = nil
                    accessibilityPaneID = nil
                    seenAccessibilityID = nil
                    updatesFocused = true
                    if voiceOverEnabled { updatesAccessibilityFocused = true }
                    return
                }
                let next = max(0, min(navigable.count - 1, index + (direction == .down ? 1 : -1)))
                seenFocusID = nil
                seenAccessibilityID = nil
                focusRow(navigable[next].id)
                proxy.scrollTo(navigable[next].id)
            }
            .accessibilityElement(children: .contain)
        }
        .frame(maxHeight: .infinity)
        .accessibilityLabel(String(localized: "Agents", comment: "Global agent sidebar"))
    }

    private func clearPanelFocus() {
        focusedPaneID = nil
        seenFocusID = nil
        accessibilityPaneID = nil
        seenAccessibilityID = nil
        updatesFocused = false
        updatesAccessibilityFocused = false
    }

    private func focusRow(_ paneID: UUID) {
        focusedPaneID = paneID
        if voiceOverEnabled { accessibilityPaneID = paneID }
    }

    private func navigate(to row: AgentActivityRoster.Row) {
        clearPanelFocus()
        // Let SwiftUI release its responder before the AppKit terminal takes focus.
        DispatchQueue.main.async { onSelect(row) }
    }

    private func reconcilePlacement() {
        heldIDs = items.map(\.id)
        heldItems = items
        heldSections = Dictionary(items.map { ($0.id, $0.row.section) }, uniquingKeysWith: { first, _ in first })
    }

    private func applyPlacementUpdates() {
        reconcilePlacement()
        if let target = items.first(where: { $0.row.section == .needsYou }) ?? items.first {
            focusRow(target.id)
        }
        updatesFocused = false
        updatesAccessibilityFocused = false
    }

    private func scroll(to state: AgentDisplayState?, proxy: ScrollViewProxy) {
        guard let state, let target = items.first(where: { state == .needsAttention ? $0.row.section == .needsYou : $0.row.state == state })
        else { return }
        proxy.scrollTo(target.id, anchor: .top)
    }

    private func row(_ item: AgentActivityPanelItem, available: Bool, active: Bool) -> some View {
        let detail =
            !available
            ? String(localized: "Pane closed", comment: "A held agent row whose pane has closed")
            : !active
                ? String(localized: "Agent no longer active", comment: "A held row whose terminal is no longer running an agent")
                : item.row.detail
        let unread = available && active && item.row.unread > 0 && item.row.executionState != .done
        let unreadLabel = unread ? String(localized: "Unread", comment: "Agent has unread output; not proof of completion") : ""
        let a11yLabel = [item.title, item.workspaceText, item.row.agentKind.spokenName, detail, unreadLabel, item.locationText].filter {
            !$0.isEmpty
        }.joined(separator: ", ")
        let canMarkSeen =
            active && item.row.canMarkSeen
        let markSeenLabel = String(localized: "Mark \(item.title) as seen", comment: "Pane-specific mark-seen accessibility action")
        return VStack(alignment: .leading, spacing: 4) {
            Button {
                navigate(to: item.row)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        StatusDot(item.row.state.awState)
                            .accessibilityHidden(true)
                        Text(verbatim: item.title)
                            .awFont(AwFont.UI.label)
                            .lineLimit(2, reservesSpace: true)
                    }
                    Text(verbatim: item.workspaceText)
                        .awFont(AwFont.UI.meta)
                        .foregroundStyle(Color.aw.railText)
                        .lineLimit(2, reservesSpace: true)
                    Text(verbatim: "\(item.row.agentKind.shortName) · \(item.locationText)")
                        .awFont(AwFont.Mono.meta)
                        .foregroundStyle(Color.aw.railText)
                        .lineLimit(1)
                    HStack {
                        Text(detail)
                        if unread {
                            Text(unreadLabel)
                        }
                    }
                    .lineLimit(1)
                    .awFont(AwFont.UI.meta)
                    .foregroundStyle(item.row.section == .needsYou ? Color.aw.status.needs : Color.aw.railText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable()
            .focused($focusedPaneID, equals: item.id)
            .accessibilityFocused($accessibilityPaneID, equals: item.id)
            .onKeyPress(keys: [.space, .return], phases: .down) { press in
                guard available, press.modifiers.subtracting(.capsLock).isEmpty else { return .ignored }
                navigate(to: item.row)
                return .handled
            }
            .accessibilityLabel(a11yLabel)
            .accessibilityHint(
                String(
                    localized: "Goes to this agent's pane without answering or approving its request", comment: "Agent row navigation hint")
            )
            .accessibilityAddTraits(selectedPaneID == item.id ? .isSelected : [])
            ZStack(alignment: .leading) {
                Color.clear.frame(height: 20).allowsHitTesting(false).accessibilityHidden(true)
                if canMarkSeen || seenFocusID == item.id || seenAccessibilityID == item.id {
                    Button(String(localized: "Mark as seen", comment: "Clear notification without approving a request")) {
                        onMarkSeen(item.row)
                    }
                    .buttonStyle(.plain)
                    .awFont(AwFont.UI.meta)
                    .foregroundStyle(Color.aw.railText)
                    .accessibilityHint(
                        String(
                            localized: "Clears the notification; permission approval remains separate", comment: "Mark seen boundary hint")
                    )
                    .accessibilityLabel(markSeenLabel)
                    .focusable()
                    .focused($seenFocusID, equals: item.id)
                    .accessibilityFocused($seenAccessibilityID, equals: item.id)
                    .onKeyPress(keys: [.space, .return], phases: .down) { press in
                        guard available, press.modifiers.subtracting(.capsLock).isEmpty else { return .ignored }
                        onMarkSeen(item.row)
                        return .handled
                    }
                }
            }
            .frame(minHeight: 20)
        }
        .disabled(!available)
        .contextMenu {
            if item.row.attentionReason?.awaitsExplicitAnswer != true && (item.row.attentionReason != nil || item.row.hasUnansweredTurn) {
                Button(
                    String(
                        localized: "Dismiss attention reminder", comment: "Explicit dismissal of a stale reminder, not permission approval")
                ) {
                    onDismissReminder(item.row)
                }
                .help(
                    String(
                        localized: "Dismisses the reminder without approving or denying a permission request",
                        comment: "Attention reminder dismissal boundary"))
            }
        }
        .padding(8)
        .background(
            selectedPaneID == item.id ? Color.aw.text.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: AwRadius.pill))
    }
}
