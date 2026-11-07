import AwesoMuxCore
import DesignSystem
import SwiftUI

struct AgentActivityPanelItem: Identifiable, Equatable {
    let row: AgentActivityRoster.Row
    let title: String
    let locationText: String
    let groupText: String
    let workspaceText: String
    let remoteHost: String?

    var id: UUID { row.paneID }
}

/// A global pane index. Placement freezes during interaction, while labels stay live.
struct AgentActivityPanel: View {
    enum NavigationTarget: Hashable {
        case section(AgentActivityRoster.Section), pane(UUID), updates
    }

    private enum KeyboardTarget: Hashable {
        case section(AgentActivityRoster.Section), pane(UUID), seen(UUID), updates
    }

    let items: [AgentActivityPanelItem]
    let scrollTarget: AgentDisplayState?
    let scrollRequestID: UUID
    let livePaneIDs: Set<UUID>
    let selectedPaneID: UUID?
    @Binding var collapsedSections: Set<AgentActivityRoster.Section>
    let tintedHighContrast: Bool
    let tintAccentsByPaneID: [UUID: AwTintAccent]
    let onSelect: (AgentActivityRoster.Row) -> Void
    let onMarkSeen: (AgentActivityRoster.Row) -> Void
    let onDismissReminder: (AgentActivityRoster.Row) -> Void
    var compact = false

    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @State private var heldIDs: [UUID] = []
    @State private var heldItems: [AgentActivityPanelItem] = []
    @State private var heldSections: [UUID: AgentActivityRoster.Section] = [:]
    @State private var pointerInside = false
    @FocusState private var keyboardTarget: KeyboardTarget?
    @AccessibilityFocusState private var accessibilityPaneID: UUID?
    @AccessibilityFocusState private var seenAccessibilityID: UUID?
    @AccessibilityFocusState private var updatesAccessibilityFocused: Bool
    @AccessibilityFocusState private var accessibilitySection: AgentActivityRoster.Section?

    private var seenFocusID: UUID? {
        if case let .seen(id) = keyboardTarget { id } else { nil }
    }

    private var interacting: Bool {
        pointerInside || keyboardTarget != nil || accessibilityPaneID != nil || seenAccessibilityID != nil
            || updatesAccessibilityFocused || accessibilitySection != nil
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

    static func navigationTargets(
        rows: [(UUID, AgentActivityRoster.Section)], collapsedSections: Set<AgentActivityRoster.Section>,
        livePaneIDs: Set<UUID>, hasUpdates: Bool
    ) -> [NavigationTarget] {
        var targets: [NavigationTarget] = []
        var sections = Set<AgentActivityRoster.Section>()
        for (id, section) in rows {
            if sections.insert(section).inserted {
                targets.append(.section(section))
                if hasUpdates && sections.count == 1 { targets.append(.updates) }
            }
            if !collapsedSections.contains(section) && livePaneIDs.contains(id) { targets.append(.pane(id)) }
        }
        if rows.isEmpty && hasUpdates { targets.append(.updates) }
        return targets
    }

    private var currentNavigationTargets: [NavigationTarget] {
        Self.navigationTargets(
            rows: placedItems.map { ($0.id, heldSections[$0.id] ?? $0.row.section) },
            collapsedSections: collapsedSections, livePaneIDs: livePaneIDs, hasUpdates: hasPlacementUpdates)
    }

    static func nextNavigationTarget(
        in targets: [NavigationTarget], keyboardFocus: NavigationTarget?, accessibilityFocus: NavigationTarget?, offset: Int
    ) -> NavigationTarget? {
        guard !targets.isEmpty else { return nil }
        let index = (keyboardFocus ?? accessibilityFocus).flatMap { targets.firstIndex(of: $0) } ?? (offset > 0 ? -1 : targets.count)
        return targets[max(0, min(targets.count - 1, index + offset))]
    }

    private var keyboardFocus: NavigationTarget? {
        switch keyboardTarget {
        case let .section(section): .section(section)
        case let .pane(id), let .seen(id): .pane(id)
        case .updates: .updates
        case nil: nil
        }
    }

    private var accessibilityFocus: NavigationTarget? {
        if let section = accessibilitySection { return .section(section) }
        if updatesAccessibilityFocused { return .updates }
        if let id = accessibilityPaneID ?? seenAccessibilityID { return .pane(id) }
        return nil
    }

    private func focus(_ target: NavigationTarget, keyboard: Bool = true, accessibility: Bool? = nil) {
        focusKeyboard(keyboard ? target : nil)
        focusAccessibility((accessibility ?? voiceOverEnabled) ? target : nil)
    }

    private func focusKeyboard(_ target: NavigationTarget?, retainedSeenID: UUID? = nil) {
        switch target {
        case let .section(section): keyboardTarget = .section(section)
        case let .pane(id): keyboardTarget = retainedSeenID == id ? .seen(id) : .pane(id)
        case .updates: keyboardTarget = .updates
        case nil: keyboardTarget = nil
        }
    }

    private func focusAccessibility(_ target: NavigationTarget?, retainedSeenID: UUID? = nil) {
        accessibilitySection = nil
        accessibilityPaneID = nil
        seenAccessibilityID = nil
        updatesAccessibilityFocused = false
        switch target {
        case let .section(section): accessibilitySection = section
        case let .pane(id):
            if retainedSeenID == id { seenAccessibilityID = id } else { accessibilityPaneID = id }
        case .updates: updatesAccessibilityFocused = true
        case nil: break
        }
    }

    private func scroll(to target: NavigationTarget, proxy: ScrollViewProxy) {
        switch target {
        case let .pane(id): proxy.scrollTo(id)
        case .section: proxy.scrollTo(target)
        case .updates: proxy.scrollTo("agent-placement-updates", anchor: .top)
        }
    }

    private func sectionButton(_ section: AgentActivityRoster.Section, count: Int) -> some View {
        let collapsed = collapsedSections.contains(section)
        let color: Color = section == .needsYou ? .aw.status.needs : section == .working ? .aw.status.thinking : .aw.railText
        return Button {
            focus(.section(section))
            if collapsed { collapsedSections.remove(section) } else { collapsedSections.insert(section) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(collapsed ? -90 : 0))
                    .frame(width: 8)
                RoundedRectangle(cornerRadius: 1)
                    .fill(color)
                    .frame(width: 6, height: 6)
                Text(section.label)
                    .awFont(AwFont.Mono.kicker)
                    .tracking(1)
                    .textCase(.uppercase)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if !hasPlacementUpdates {
                    Text(count.formatted()).awFont(AwFont.Mono.meta)
                }
            }
            .foregroundStyle(Color.aw.railText)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable()
        .focused($keyboardTarget, equals: .section(section))
        .accessibilityFocused($accessibilitySection, equals: section)
        .accessibilityLabel(section.label)
        .accessibilityValue(
            [
                collapsed
                    ? String(localized: "Collapsed", comment: "Collapsed sidebar section")
                    : String(localized: "Expanded", comment: "Expanded sidebar section"),
                hasPlacementUpdates ? nil : count.formatted(),
            ].compactMap { $0 }.joined(separator: ", ")
        )
        .accessibilityAddTraits(.isHeader)
        .onKeyPress(keys: [.leftArrow, .rightArrow, .space, .return], phases: .down) { press in
            // Arrow events carry the intrinsic function flag on macOS. Only
            // intentional shortcut modifiers should bypass section commands.
            guard press.modifiers.intersection([.command, .control, .option, .shift]).isEmpty else { return .ignored }
            let collapse = press.key == .leftArrow || (press.key != .rightArrow && !collapsedSections.contains(section))
            if collapse { collapsedSections.insert(section) } else { collapsedSections.remove(section) }
            return .handled
        }
        .id(NavigationTarget.section(section))
    }

    var body: some View {
        let placed = placedItems
        let sections = Dictionary(grouping: placed) { heldSections[$0.id] ?? $0.row.section }
        let liveIDs = Set(items.map(\.id))
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        if placed.isEmpty && !hasPlacementUpdates {
                            Text(String(localized: "No agents to show", comment: "Empty global agent roster"))
                                .awFont(AwFont.UI.label)
                                .foregroundStyle(Color.aw.railText)
                                .padding(.vertical, 16)
                        }
                        if placed.isEmpty && hasPlacementUpdates {
                            placementUpdatesButton
                        }
                        // A single identity scope keeps the same button alive across section moves.
                        ForEach(placed) { item in
                            let section = heldSections[item.id] ?? item.row.section
                            if sections[section]?.first?.id == item.id {
                                HStack(spacing: 8) {
                                    sectionButton(section, count: sections[section]?.count ?? 0)
                                    if hasPlacementUpdates, placed.first?.id == item.id {
                                        placementUpdatesButton
                                    }
                                }
                                .foregroundStyle(Color.aw.railText)
                                .padding(.top, placed.first?.id == item.id ? 8 : 14)
                                .padding(.bottom, 4)
                                .accessibilityElement(children: .contain)
                            }
                            if !collapsedSections.contains(section) {
                                row(item, available: livePaneIDs.contains(item.id), active: liveIDs.contains(item.id))
                                    .id(item.id)
                            }
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

            }
            .onHover { pointerInside = $0 }
            .onMoveCommand { direction in
                guard direction == .up || direction == .down else { return }
                let targets = currentNavigationTargets
                guard
                    let target = Self.nextNavigationTarget(
                        in: targets, keyboardFocus: keyboardFocus, accessibilityFocus: accessibilityFocus,
                        offset: direction == .down ? 1 : -1)
                else { return }
                focus(target)
                scroll(to: target, proxy: proxy)
            }
            .accessibilityElement(children: .contain)
        }
        .frame(maxHeight: .infinity)
        .focusSection()
        .accessibilityLabel(String(localized: "Agents", comment: "Global agent sidebar"))
    }

    private var placementUpdatesButton: some View {
        Button(String(localized: "Show updates", comment: "Apply deferred agent-list placement changes")) {
            applyPlacementUpdates()
        }
        .buttonStyle(.plain)
        .awFont(AwFont.Mono.meta)
        .foregroundStyle(Color.aw.status.needs)
        .accessibilityLabel(
            String(localized: "New activity — show updates", comment: "Apply deferred agent-list placement changes")
        )
        .focusable()
        .id("agent-placement-updates")
        .focused($keyboardTarget, equals: .updates)
        .accessibilityFocused($updatesAccessibilityFocused)
        .onKeyPress(keys: [.space, .return], phases: .down) { press in
            guard press.modifiers.subtracting(.capsLock).isEmpty else { return .ignored }
            applyPlacementUpdates()
            return .handled
        }
    }

    private func clearPanelFocus() {
        focusKeyboard(nil)
        focusAccessibility(nil)
    }

    private func navigate(to row: AgentActivityRoster.Row) {
        clearPanelFocus()
        // Let SwiftUI release its responder before the AppKit terminal takes focus.
        DispatchQueue.main.async { onSelect(row) }
    }

    private func reconcilePlacement() {
        let previousKeyboard = keyboardFocus
        let previousAccessibility = accessibilityFocus
        let previousSeenKeyboard = seenFocusID
        let previousSeenAccessibility = seenAccessibilityID
        let previousTargets = currentNavigationTargets
        heldIDs = items.map(\.id)
        heldItems = items
        heldSections = Dictionary(items.map { ($0.id, $0.row.section) }, uniquingKeysWith: { first, _ in first })
        guard previousKeyboard != nil || previousAccessibility != nil else { return }
        let targets = currentNavigationTargets
        guard !targets.isEmpty else { clearPanelFocus(); return }
        func target(after previous: NavigationTarget) -> NavigationTarget {
            targets.contains(previous) ? previous : targets[min(previousTargets.firstIndex(of: previous) ?? 0, targets.count - 1)]
        }
        DispatchQueue.main.async {
            if let previousKeyboard, keyboardFocus == previousKeyboard {
                focusKeyboard(target(after: previousKeyboard), retainedSeenID: previousSeenKeyboard)
            }
            if let previousAccessibility, accessibilityFocus == previousAccessibility {
                focusAccessibility(target(after: previousAccessibility), retainedSeenID: previousSeenAccessibility)
            }
        }
    }

    private func applyPlacementUpdates() {
        reconcilePlacement()
        let target = items.first(where: { $0.row.section == .needsYou }) ?? items.first
        // Applying updates can replace the pane that hosts a section header.
        // Wait for the new control to register before the explicit action
        // restores focus to the next visible destination.
        DispatchQueue.main.async {
            if let target {
                focus(collapsedSections.contains(target.row.section) ? .section(target.row.section) : .pane(target.id))
            } else {
                clearPanelFocus()
            }
        }
    }

    private func scroll(to state: AgentDisplayState?, proxy: ScrollViewProxy) {
        guard let state, let target = items.first(where: { state == .needsAttention ? $0.row.section == .needsYou : $0.row.state == state })
        else { return }
        if collapsedSections.contains(target.row.section) {
            proxy.scrollTo(NavigationTarget.section(target.row.section), anchor: .top)
        } else {
            proxy.scrollTo(target.id, anchor: .top)
        }
    }

    private func row(_ item: AgentActivityPanelItem, available: Bool, active: Bool) -> some View {
        let detail =
            !available
            ? String(localized: "Pane closed", comment: "A held agent row whose pane has closed")
            : !active
                ? String(localized: "Agent no longer active", comment: "A held row whose terminal is no longer running an agent")
                : item.row.detail
        let selected = selectedPaneID == item.id
        let needsAttention = available && active && item.row.section == .needsYou
        let highContrast = contrast == .increased
        let borderColor: Color = {
            if selected {
                return highContrast && !tintedHighContrast ? .aw.dividerHoverHC : .aw.tintBorder(tintAccentsByPaneID[item.id] ?? .mauve)
            }
            if needsAttention { return item.row.state.awState.color }
            return highContrast ? .aw.dividerRestHC : .aw.border
        }()
        let finished = available && active && item.row.section == .finished && item.row.executionState == .done
        let unread = available && active && item.row.unread > 0
        let unreadLabel =
            unread && !finished ? String(localized: "Unread", comment: "Agent has unread output; not proof of completion") : ""
        let a11yLabel = [
            item.groupText, item.title, item.workspaceText, item.row.agentKind.spokenName, detail, unreadLabel, item.locationText,
        ].filter {
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
                    if compact {
                        HStack(alignment: .top, spacing: 6) {
                            AgentTile(agent: item.row.agentKind.awAgentIcon, state: .idle, size: 20, badgeStyle: .collapsed)
                                .accessibilityHidden(true)
                            Text(verbatim: item.title)
                                .awFont(AwFont.UI.label)
                                .fontWeight(.semibold)
                                .lineLimit(2)
                        }
                        Text(verbatim: [item.groupText, item.workspaceText].filter { !$0.isEmpty }.joined(separator: " / "))
                            .awFont(AwFont.Mono.meta)
                            .foregroundStyle(Color.aw.railText)
                            .lineLimit(1)
                    } else {
                        HStack(spacing: 6) {
                            // Identity only; the status line below owns execution state.
                            AgentTile(agent: item.row.agentKind.awAgentIcon, state: .idle, size: 20, badgeStyle: .collapsed)
                                .accessibilityHidden(true)
                            if !item.groupText.isEmpty {
                                Text(verbatim: item.groupText)
                                    .awFont(AwFont.Mono.meta)
                                    .foregroundStyle(Color.aw.railText)
                                    .lineLimit(1)
                            }
                    }
                    Text(verbatim: item.title)
                        .awFont(AwFont.UI.label)
                        .lineLimit(2)
                    if !item.workspaceText.isEmpty {
                        Text(verbatim: item.workspaceText)
                                .awFont(AwFont.Mono.meta)
                            .foregroundStyle(Color.aw.railText)
                            .lineLimit(2)
                    }
                    }
                    if let host = item.remoteHost {
                        Text(verbatim: host)
                            .awFont(AwFont.Mono.meta)
                            .foregroundStyle(Color.aw.railText)
                            .lineLimit(1)
                    }

                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable()
            .focused($keyboardTarget, equals: .pane(item.id))
            .accessibilityFocused($accessibilityPaneID, equals: item.id)
            .onKeyPress(keys: [.space, .return], phases: .down) { press in
                guard available, press.modifiers.subtracting(.capsLock).isEmpty else { return .ignored }
                navigate(to: item.row)
                return .handled
            }
            .accessibilityLabel(a11yLabel)
            .help("\(item.row.agentKind.shortName) · \(item.locationText)")
            .accessibilityHint(
                String(
                    localized: "Goes to this agent's pane without answering or approving its request", comment: "Agent row navigation hint")
            )
            .accessibilityAddTraits(selected ? .isSelected : [])
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    if available && active && item.row.state.awState == .thinking {
                        StatusDot(.thinking)
                            .frame(width: 10, height: 10)
                    }
                    Text(
                        finished
                            ? String(localized: "Finished", comment: "Agent execution completed; not a review verdict") : detail
                    )
                    .lineLimit(1)
                    .awFont(AwFont.Mono.meta)
                    .foregroundStyle(needsAttention ? Color.aw.status.needs : Color.aw.railText)
                }
                .accessibilityHidden(true)
                Spacer(minLength: 0)
                if canMarkSeen || seenFocusID == item.id || seenAccessibilityID == item.id {
                    Button(String(localized: "Mark as seen", comment: "Clear notification without approving a request")) {
                        onMarkSeen(item.row)
                    }
                    .buttonStyle(.plain)
                    .awFont(AwFont.Mono.meta)
                    .foregroundStyle(unread ? Color.aw.status.needs : Color.aw.railText)
                    .accessibilityHint(
                        String(
                            localized: "Clears the notification; permission approval remains separate", comment: "Mark seen boundary hint")
                    )
                    .accessibilityLabel(markSeenLabel)
                    .focusable()
                    .focused($keyboardTarget, equals: .seen(item.id))
                    .accessibilityFocused($seenAccessibilityID, equals: item.id)
                    .onKeyPress(keys: [.space, .return], phases: .down) { press in
                        guard available, press.modifiers.subtracting(.capsLock).isEmpty else { return .ignored }
                        onMarkSeen(item.row)
                        return .handled
                    }
                }
            }

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
            selected ? Color.aw.text.opacity(0.04) : Color.clear, in: RoundedRectangle(cornerRadius: AwRadius.panel)
        )
        .overlay {
            RoundedRectangle(cornerRadius: AwRadius.panel)
                .strokeBorder(
                    borderColor,
                    style: StrokeStyle(
                        lineWidth: selected ? (highContrast ? 2 : 1.5) : (highContrast ? 1 : 0.5)
                    )
                )
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}
