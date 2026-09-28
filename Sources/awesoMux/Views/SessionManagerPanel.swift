import AwesoMuxBridgeProtocol
import AwesoMuxCore
import DesignSystem
import SwiftUI

// MARK: - Lifecycle presentation

/// View-side presentation for a `DaemonLifecycle`: the label, tint, SF Symbol,
/// group ordering, and the "safe to clean up" / "can't clean up" group hint. Colour
/// only ever *reinforces* — every state is carried by an icon + text label too,
/// so the surface stays legible under colour-blindness and Increase Contrast.
enum DaemonLifecyclePresentation {
    static let groupOrder: [DaemonLifecycle] = [
        .owned, .detachedRestorable, .abandoned, .expired, .inUseElsewhere
    ]

    static func label(_ lifecycle: DaemonLifecycle) -> String {
        switch lifecycle {
        case .owned: "Owned"
        case .detachedRestorable: "Detached"
        case .abandoned: "Abandoned"
        case .expired: "Expired"
        case .inUseElsewhere: "Elsewhere"
        }
    }

    static func color(_ lifecycle: DaemonLifecycle) -> Color {
        switch lifecycle {
        case .owned: Color.aw.teal
        case .detachedRestorable: Color.aw.sky
        case .abandoned: Color.aw.peach
        case .expired: Color.aw.red
        case .inUseElsewhere: Color.aw.lavender
        }
    }

    static func icon(_ lifecycle: DaemonLifecycle) -> String {
        switch lifecycle {
        case .owned: "link"
        case .detachedRestorable: "moon"
        case .abandoned: "exclamationmark.triangle"
        case .expired: "clock.badge.xmark"
        case .inUseElsewhere: "macwindow.on.rectangle"
        }
    }

    /// Footer-style hint shown beside the group label. Orphan groups read "safe
    /// to clean up"; `inUseElsewhere` reads "can't clean up". Live/restorable
    /// groups get none — their reap is the graduated-confirm path, not a one-click.
    static func groupHint(_ lifecycle: DaemonLifecycle) -> String? {
        switch lifecycle {
        case .abandoned, .expired: "safe to clean up"
        case .inUseElsewhere: "can't clean up"
        case .owned, .detachedRestorable: nil
        }
    }
}

enum SessionManagerPrimaryAction: Equatable { case open, restore, recover }

extension DaemonRow {
    var primaryAction: SessionManagerPrimaryAction? {
        switch lifecycle {
        case .owned: .open
        case .detachedRestorable: .restore
        case .abandoned, .expired: .recover
        case .inUseElsewhere: nil
        }
    }

    func matches(query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return [label, directory, groupName, agentKind?.displayName, id.rawValue]
            .compactMap { $0 }
            .contains { $0.localizedStandardContains(query) }
    }
}

// MARK: - Atoms

/// Activity dot + text. Busy = a filled green dot with a soft halo; idle = a
/// hollow ring. The "busy" / "idle" word is always present so activity never
/// rides on colour alone.
struct ActivityIndicator: View {
    let activity: DaemonActivity

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if activity == .busy {
                    Circle()
                        .fill(Color.aw.green)
                        .frame(width: 7, height: 7)
                        .awGlow(color: Color.aw.green.opacity(0.5), radius: 3)
                } else {
                    Circle()
                        .stroke(Color.aw.textFaint, lineWidth: 1)
                        .frame(width: 7, height: 7)
                }
            }
            Text(activity == .busy ? "busy" : "idle")
                .awFont(AwFont.Mono.kbd)
                .foregroundStyle(activity == .busy ? Color.aw.green : Color.aw.textFaint)
        }
        .accessibilityHidden(true)
    }
}

/// Tinted state tag — icon + uppercase label. Used in the group header (and the
/// reap sheet) to name the lifecycle without relying on colour.
struct StateTag: View {
    let lifecycle: DaemonLifecycle

    var body: some View {
        let tint = DaemonLifecyclePresentation.color(lifecycle)
        HStack(spacing: 6) {
            Image(systemName: DaemonLifecyclePresentation.icon(lifecycle))
                .font(.system(size: 11, weight: .semibold))
            Text(DaemonLifecyclePresentation.label(lifecycle).uppercased())
                .awFont(AwFont.Mono.pill).fontWeight(.bold)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: AwRadius.button))
        .overlay {
            RoundedRectangle(cornerRadius: AwRadius.button)
                .stroke(tint.opacity(0.34), lineWidth: 0.5)
        }
    }
}

/// Short daemon id — `amx:` faint prefix + first 8 chars of the session id.
/// The row's primary identity now that the agent/task column is deferred.
struct ShortID: View {
    let id: TerminalSessionID

    var body: some View {
        (
            Text("amx:").foregroundStyle(Color.aw.textFaint)
                + Text(SessionManagerPanel.shortIDSuffix(id)).foregroundStyle(Color.aw.text2)
        )
        .awFont(AwFont.Mono.meta)
    }
}

/// Owner cell — "workspace · pane" with a tint dot, or an italic "no owner".
struct OwnerCell: View {
    let owner: String?

    var body: some View {
        if let owner {
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 1)
                    // Snapshot-only: this bare NSHostingController panel root reads the live accent mailbox at each per-summon rebind.
                    .fill(Color.aw.accent)
                    .frame(width: 6, height: 6)
                Text(owner)
                    .awFont(AwFont.UI.meta)
                    .foregroundStyle(Color.aw.text2)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        } else {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.aw.textFaint.opacity(0.5))
                    .frame(width: 6, height: 6)
                Text("no owner")
                    .awFont(AwFont.UI.meta).italic()
                    .foregroundStyle(Color.aw.textFaint)
            }
        }
    }
}

// MARK: - Panel

/// The Session Manager overlay: persistent `amx` daemons grouped by lifecycle,
/// with pin (exempt from auto-reap) and reap (deliberate kill) actions. Bound to
/// a `SessionManagerModel` whose polling is scoped to panel-open by the
/// presenter. Orphan reaps use a cheap inline confirm; live/restorable reaps use
/// the full `SessionManagerReapSheet`.
@MainActor
struct SessionManagerPanel: View {
    @State var model: SessionManagerModel
    let focusState: SessionManagerFocusState
    /// Selects the workspace/pane that owns a daemon, then dismisses. Wired by
    /// the app to the same selection path the command palette uses.
    let onActivate: (DaemonRow) -> Void
    let onConfigureAutoCleanup: () -> Void

    /// Orphan (abandoned/expired) row awaiting the cheap inline confirm.
    @State private var inlineConfirmID: TerminalSessionID?
    /// Live/restorable row awaiting the full confirm sheet.
    @State private var sheetRow: DaemonRow?
    @State private var query = ""
    @State private var searchAnnouncementWorkItem: DispatchWorkItem?
    @FocusState private var focusedRowID: TerminalSessionID?

    static func shortIDSuffix(_ id: TerminalSessionID) -> String {
        String(id.rawValue.prefix(8))
    }

    private var groups: [(lifecycle: DaemonLifecycle, rows: [DaemonRow])] {
        let byLifecycle = Dictionary(grouping: model.rows.filter { $0.matches(query: query) }, by: \.lifecycle)
        return DaemonLifecyclePresentation.groupOrder.compactMap { lifecycle in
            guard let rows = byLifecycle[lifecycle], !rows.isEmpty else { return nil }
            return (lifecycle, rows)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            FloatingPanelTitlebar(
                title: String(
                    localized: "Session Manager",
                    comment: "Session Manager panel title bar."
                ),
                hint: String(
                    localized:
                        "Background sessions. Pin a session to exempt it from auto-cleanup, or end it when you no longer need it.",
                    comment: "Session Manager panel accessibility hint."
                )
            )
            header
            if model.rows.isEmpty {
                emptyState
            } else {
                TextField("Search sessions", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, AwSpacing.panelPadding)
                    .padding(.vertical, 8)
                if groups.isEmpty {
                    Text("No matching sessions")
                        .awFont(AwFont.UI.meta)
                        .foregroundStyle(Color.aw.text2)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityAddTraits(.isStaticText)
                } else {
                    list
                }
            }
            if let status = model.activationStatus {
                Text(status)
                    .awFont(AwFont.UI.meta)
                    .foregroundStyle(Color.aw.text2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, AwSpacing.panelPadding)
                    .padding(.vertical, 6)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .onChange(of: query) { _, _ in announceSearchResults() }
        .onDisappear { searchAnnouncementWorkItem?.cancel() }
        .sheet(item: $sheetRow) { row in
            SessionManagerReapSheet(
                row: row,
                reapDisabled: model.activatingID != nil,
                onCancel: { sheetRow = nil },
                onReap: {
                    guard model.activatingID == nil else { return }
                    Task { _ = await model.reap(row) }
                    sheetRow = nil
                }
            )
        }
        // No container label: `FloatingPanelTitlebar` carries this panel's
        // identity and hint now, so labelling the container too made VoiceOver
        // announce "Session Manager" on entry and again on the first element
        // inside. `children: .contain` stays — it groups, it does not name.
        .accessibilityElement(children: .contain)
    }

    // MARK: Header

    // The window identity moved into `FloatingPanelTitlebar`, so the kicker
    // that used to repeat it is gone and this row no longer steps around the
    // traffic lights. What stays is the part carrying live data: the daemon
    // count, which the band cannot show because a title bar should not change
    // meaning as its content does.
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Text("Background sessions")
                .awFont(AwFont.UI.title)
                .foregroundStyle(Color.aw.text)
            Text(countSummary)
                .awFont(AwFont.Mono.meta)
                .foregroundStyle(Color.aw.text3)
        }
        .padding(.horizontal, AwSpacing.panelPadding)
        .padding(.top, 16)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.aw.border).frame(height: 0.5)
        }
    }

    private var countSummary: String {
        let total = model.rows.count
        let daemons = LocalizedPluralStrings.sessionManagerDaemons(count: total)
        let abandoned = model.rows.filter { $0.lifecycle == .abandoned }.count
        return abandoned > 0 ? "\(daemons) · \(abandoned) abandoned" : daemons
    }

    // MARK: List

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(groups, id: \.lifecycle) { group in
                    groupHeader(group.lifecycle, count: group.rows.count)
                    VStack(spacing: 2) {
                        ForEach(group.rows) { row in
                            rowView(row)
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
    }

    private func groupHeader(_ lifecycle: DaemonLifecycle, count: Int) -> some View {
        let tint = DaemonLifecyclePresentation.color(lifecycle)
        return HStack(spacing: 8) {
            Image(systemName: DaemonLifecyclePresentation.icon(lifecycle))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
            Text(DaemonLifecyclePresentation.label(lifecycle).uppercased())
                .awFont(AwFont.Mono.kicker)
                .tracking(1.5)
                .foregroundStyle(tint)
            Text("\(count)")
                .awFont(AwFont.Mono.kbd)
                .foregroundStyle(Color.aw.textFaint)
            Rectangle().fill(Color.aw.border).frame(height: 0.5)
            if let hint = DaemonLifecyclePresentation.groupHint(lifecycle) {
                Text(hint.uppercased())
                    .awFont(AwFont.Mono.kbd).fontWeight(.bold)
                    .tracking(1)
                    .foregroundStyle(Color.aw.textFaint)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 12)
        .padding(.bottom, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(groupAccessibilityLabel(lifecycle, count: count))
    }

    private func groupAccessibilityLabel(_ lifecycle: DaemonLifecycle, count: Int) -> String {
        var label = "\(DaemonLifecyclePresentation.label(lifecycle)), \(LocalizedPluralStrings.sessionManagerSessions(count: count))"
        if let hint = DaemonLifecyclePresentation.groupHint(lifecycle) {
            label += ", \(hint)"
        }
        return label
    }

    // MARK: Row

    @ViewBuilder
    private func rowView(_ row: DaemonRow) -> some View {
        let isConfirming = inlineConfirmID == row.id
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                ActivityIndicator(activity: row.activity)
                    .frame(width: 64, alignment: .leading)
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.label).lineLimit(1).truncationMode(.middle)
                        .awFont(AwFont.UI.meta).foregroundStyle(Color.aw.text)
                    ShortID(id: row.id)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(row.directory ?? "—")
                    .lineLimit(1).truncationMode(.middle)
                    .awFont(AwFont.Mono.meta).foregroundStyle(Color.aw.text2)
                    .frame(width: 180, alignment: .leading)
                Text(RelativeAge.string(
                    sinceEpoch: row.createdEpoch,
                    now: Int(Date().timeIntervalSince1970)
                ))
                .awFont(AwFont.Mono.meta)
                .foregroundStyle(row.lifecycle == .expired ? Color.aw.red : Color.aw.text2)
                .frame(width: 44, alignment: .trailing)
                Text("\(row.clients)")
                    .awFont(AwFont.Mono.meta)
                    .foregroundStyle(row.clients > 0 ? Color.aw.text : Color.aw.textFaint)
                    .frame(width: 36, alignment: .trailing)
                actions(row)
                    .frame(width: 100, alignment: .trailing)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            if isConfirming {
                inlineConfirm(row)
            }
        }
        .focusable(row.primaryAction != nil)
        .focused($focusedRowID, equals: row.id)
        .focusEffectDisabled()
        .onKeyPress(keys: [.space, .return], phases: .down) { press in
            guard focusedRowID == row.id,
                row.primaryAction != nil,
                model.activatingID == nil,
                press.modifiers.subtracting(.capsLock).isEmpty
            else { return .ignored }
            onActivate(row)
            return .handled
        }
        .awFocusRing(focusedRowID == row.id, cornerRadius: AwRadius.panel)
        .background {
            RoundedRectangle(cornerRadius: AwRadius.panel)
                .fill(isConfirming ? Color.aw.peach.opacity(0.08) : Color.aw.surface.hover.opacity(0.0))
        }
        .overlay(alignment: .leading) {
            // Left accent rail on pinned rows.
            if row.pinned {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.aw.accent)
                    .frame(width: 2)
                    .padding(.vertical, 8)
                    .awGlow(color: Color.aw.accentGlow, radius: 4)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: AwRadius.panel)
                .stroke(
                    isConfirming ? Color.aw.peach.opacity(0.45)
                        : (row.pinned ? Color.aw.accent.opacity(0.22) : Color.clear),
                    lineWidth: 0.5
                )
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func actions(_ row: DaemonRow) -> some View {
        if row.lifecycle == .inUseElsewhere {
            // Non-actionable: attached by another client.
            HStack(spacing: 5) {
                Image(systemName: "macwindow.on.rectangle")
                    .font(.system(size: 11))
                Text("in use")
                    .awFont(AwFont.Mono.kbd)
            }
            .foregroundStyle(Color.aw.textFaint)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(rowAccessibilityLabel(row) + ", can't clean up while in use elsewhere")
        } else {
            HStack(spacing: 2) {
                if let primaryAction = row.primaryAction {
                    Button {
                        onActivate(row)
                    } label: {
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.aw.text3)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .disabled(model.activatingID != nil)
                    .accessibilityLabel(
                        String(
                            format: String(
                                localized: "%1$@ %2$@",
                                comment: "Session Manager action followed by the session name"
                            ),
                            primaryAction.label, row.label
                        )
                    )
                    .accessibilityHint(
                        row.directory
                            ?? String(
                                localized: "Session directory unavailable",
                                comment: "Session Manager action hint when the session directory is unknown"
                            )
                    )
                    .help(primaryAction.label)
                }
                Button {
                    model.setPinned(!row.pinned, for: row.id)
                } label: {
                    Image(systemName: row.pinned ? "pin.fill" : "pin")
                        .font(.system(size: 12))
                        .foregroundStyle(row.pinned ? Color.aw.accent : Color.aw.textFaint)
                        .frame(width: 28, height: 28)
                        .background(
                            row.pinned ? Color.aw.accentSoft : Color.clear,
                            in: RoundedRectangle(cornerRadius: AwRadius.button)
                        )
                }
                .buttonStyle(.plain)
                .disabled(model.activatingID != nil)
                .accessibilityLabel(row.pinned ? "Unpin session" : "Pin session")
                .accessibilityHint("Pinned sessions are exempt from auto-cleanup.")

                Button {
                    confirmOrReap(row)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.aw.text3)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .disabled(model.activatingID != nil)
                .accessibilityLabel("End session")
                .accessibilityHint("Stops the session's shell and discards its scrollback.")
            }
            // Compose the row's identity into one spoken element ahead of the
            // buttons so VoiceOver reads state + activity + owner + age before
            // the actions, without swallowing the buttons' own labels.
            .accessibilityElement(children: .contain)
            .accessibilityLabel(rowAccessibilityLabel(row))
        }
    }

    private func rowAccessibilityLabel(_ row: DaemonRow) -> String {
        var parts = [
            DaemonLifecyclePresentation.label(row.lifecycle),
            row.activity == .busy ? "busy" : "idle",
            row.label,
            row.directory
                ?? String(
                    localized: "directory unavailable",
                    comment: "Session Manager row description when the session directory is unknown"
                ),
            "\(RelativeAge.string(sinceEpoch: row.createdEpoch, now: Int(Date().timeIntervalSince1970))) old",
            LocalizedPluralStrings.sessionManagerClients(count: row.clients)
        ]
        if row.pinned { parts.append("pinned") }
        parts.append(row.shortID)
        return parts.joined(separator: ", ")
    }

    // MARK: Reap confirm

    /// Orphans (abandoned/expired) get the cheap inline confirm; live/restorable
    /// sessions get the full sheet that names what's lost.
    private func confirmOrReap(_ row: DaemonRow) {
        switch row.lifecycle {
        case .abandoned, .expired:
            inlineConfirmID = row.id
        default:
            sheetRow = row
        }
    }

    private func inlineConfirm(_ row: DaemonRow) -> some View {
        HStack(spacing: 12) {
            Text("End this ")
                .foregroundStyle(Color.aw.text2)
                + Text(DaemonLifecyclePresentation.label(row.lifecycle).lowercased())
                .foregroundStyle(Color.aw.peach).bold()
                + Text(" daemon? This discards its scrollback.")
                .foregroundStyle(Color.aw.text2)
            Spacer(minLength: 0)
            Button("Cancel") { inlineConfirmID = nil }
                .buttonStyle(SessionManagerGhostButtonStyle())
            Button {
                guard model.activatingID == nil else { return }
                Task { _ = await model.reap(row) }
                inlineConfirmID = nil
            } label: {
                Label("Clean up", systemImage: "trash")
            }
            .buttonStyle(SessionManagerDangerButtonStyle())
            .disabled(model.activatingID != nil)
        }
        .awFont(AwFont.UI.meta)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.aw.peach.opacity(0.3)).frame(height: 0.5)
        }
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "moon.zzz")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Color.aw.textFaint)
            VStack(spacing: 7) {
                Text("No background sessions")
                    .awFont(AwFont.UI.title)
                    .foregroundStyle(Color.aw.text)
                Text(
                    "Every session is attached to an open pane. When you quit with a session running, it keeps the shell and scrollback alive — and shows up here to pin or end."
                )
                    .awFont(AwFont.UI.meta)
                    .foregroundStyle(Color.aw.text2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            HStack(spacing: 7) {
                Circle().fill(Color.aw.green).frame(width: 6, height: 6)
                Text("nothing to clean up")
                    .awFont(AwFont.Mono.meta)
            }
            .foregroundStyle(Color.aw.green)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(Color.aw.green.opacity(0.12), in: RoundedRectangle(cornerRadius: AwRadius.button))
            .overlay {
                RoundedRectangle(cornerRadius: AwRadius.button)
                    .stroke(Color.aw.green.opacity(0.3), lineWidth: 0.5)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No background sessions. Nothing to clean up.")
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 14) {
            HStack(spacing: 7) {
                HStack(spacing: 7) {
                    Image(systemName: "clock.badge.xmark")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.aw.textFaint)
                    Text("Auto-cleanup")
                        .foregroundStyle(Color.aw.text3)
                    Text(capChipText)
                        .awFont(AwFont.Mono.kbd)
                        .foregroundStyle(Color.aw.text)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.aw.surface.elevated, in: RoundedRectangle(cornerRadius: AwRadius.pill))
                        .overlay {
                            RoundedRectangle(cornerRadius: AwRadius.pill)
                                .stroke(Color.aw.border2, lineWidth: 0.5)
                        }
                }
                .awFont(AwFont.UI.meta)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(autoCleanupAccessibilityLabel)

                Button(action: onConfigureAutoCleanup) {
                    Text("Configure ›")
                        .awFont(AwFont.UI.meta)
                        .foregroundStyle(Color.aw.accent)
                        .frame(minHeight: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    String(
                        localized: "Configure auto-cleanup in Settings",
                        comment: "Session Manager button that opens the auto-cleanup controls in Terminal settings"
                    ))
            }

            HStack(spacing: 6) {
                Image(systemName: "pin.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.aw.accent)
                Text("pinned are exempt")
                    .awFont(AwFont.UI.meta)
                    .foregroundStyle(Color.aw.text3)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                String(
                    localized: "Pinned sessions are exempt.",
                    comment: "Session Manager footer accessibility summary for pinned sessions"
                ))

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                Text("pin · end session").foregroundStyle(Color.aw.textFaint)
                KBD("Esc")
                Text("dismiss").foregroundStyle(Color.aw.textFaint)
            }
            .awFont(AwFont.Mono.kbd)
            .accessibilityElement(children: .combine)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.aw.surface.chrome)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.aw.border).frame(height: 0.5)
        }
        .accessibilityElement(children: .contain)
    }

    /// Chip text reflecting the real cap config — "off" on the default (disabled)
    /// config rather than a fixed "7d idle" that promises a reap that never fires.
    private var capChipText: String {
        let cap = model.capSummary
        return cap.enabled ? "\(cap.days)d idle" : "off"
    }

    private var autoCleanupAccessibilityLabel: String {
        let cap = model.capSummary
        return cap.enabled
            ? LocalizedPluralStrings.sessionManagerAutoCleanupDays(count: cap.days)
            : String(
                localized: "Auto-cleanup is off.",
                comment: "Session Manager footer accessibility summary when auto-cleanup is disabled"
            )
    }

    private func announceSearchResults() {
        searchAnnouncementWorkItem?.cancel()
        let workItem = DispatchWorkItem {
            let count = groups.reduce(0) { $0 + $1.rows.count }
            model.announce(
                count == 0
                    ? String(
                        localized: "No matching sessions",
                        comment: "Session Manager search announcement when no sessions match"
                    )
                    : LocalizedPluralStrings.sessionManagerSessions(count: count)
            )
        }
        searchAnnouncementWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: workItem)
    }
}

extension SessionManagerPrimaryAction {
    var label: String {
        switch self {
        case .open: String(localized: "Open session", comment: "Session Manager action to select an open session")
        case .restore: String(localized: "Restore session", comment: "Session Manager action to restore a detached session")
        case .recover: String(localized: "Recover session", comment: "Session Manager action to recover an abandoned session")
        }
    }

    func successLabel(for sessionLabel: String) -> String {
        let format =
            switch self {
            case .open: String(localized: "Opened session %@.", comment: "Session Manager successful open announcement")
            case .restore: String(localized: "Restored session %@.", comment: "Session Manager successful restore announcement")
            case .recover: String(localized: "Recovered session %@.", comment: "Session Manager successful recovery announcement")
            }
        return String(format: format, sessionLabel)
    }
}

// MARK: - Button styles

/// Ghost (outlined) button — Cancel in the inline confirm and the reap sheet.
struct SessionManagerGhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .awFont(AwFont.UI.meta)
            .foregroundStyle(Color.aw.text2)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(
                configuration.isPressed ? Color.aw.surface.hover : Color.clear,
                in: RoundedRectangle(cornerRadius: AwRadius.button)
            )
            .overlay {
                RoundedRectangle(cornerRadius: AwRadius.button)
                    .stroke(Color.aw.border2, lineWidth: 0.5)
            }
    }
}

/// Solid destructive button — the Reap confirm action.
struct SessionManagerDangerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .awFont(AwFont.UI.meta).fontWeight(.semibold)
            .foregroundStyle(Color.aw.status.onLoud)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(
                Color.aw.red.opacity(configuration.isPressed ? 0.85 : 1),
                in: RoundedRectangle(cornerRadius: AwRadius.button)
            )
    }
}
