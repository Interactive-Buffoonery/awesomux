import AwesoMuxBridgeProtocol
import AwesoMuxCore
import DesignSystem
import SwiftUI

// MARK: - Lifecycle presentation

/// View-side presentation for a `DaemonLifecycle`: the label, tint, SF Symbol,
/// group ordering, and the "safe to reap" / "not reapable" group hint. Colour
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
    /// to reap"; `inUseElsewhere` reads "not reapable". Live/restorable groups
    /// get none — their reap is the graduated-confirm path, not a one-click.
    static func groupHint(_ lifecycle: DaemonLifecycle) -> String? {
        switch lifecycle {
        case .abandoned, .expired: "safe to reap"
        case .inUseElsewhere: "not reapable"
        case .owned, .detachedRestorable: nil
        }
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
    let onDismiss: () -> Void
    /// Selects the workspace/pane that owns a daemon, then dismisses. Wired by
    /// the app to the same selection path the command palette uses.
    let onJump: (TerminalSessionID) -> Void

    /// Orphan (abandoned/expired) row awaiting the cheap inline confirm.
    @State private var inlineConfirmID: TerminalSessionID?
    /// Live/restorable row awaiting the full confirm sheet.
    @State private var sheetRow: DaemonRow?

    static func shortIDSuffix(_ id: TerminalSessionID) -> String {
        String(id.rawValue.prefix(8))
    }

    private var groups: [(lifecycle: DaemonLifecycle, rows: [DaemonRow])] {
        let byLifecycle = Dictionary(grouping: model.rows, by: \.lifecycle)
        return DaemonLifecyclePresentation.groupOrder.compactMap { lifecycle in
            guard let rows = byLifecycle[lifecycle], !rows.isEmpty else { return nil }
            return (lifecycle, rows)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.rows.isEmpty {
                emptyState
            } else {
                list
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
        .overlay(alignment: .topTrailing) {
            FloatingPanelCloseButton(
                accessibilityLabel: "Close Session Manager",
                action: onDismiss
            )
            .padding(.top, 12)
            .padding(.trailing, FloatingPanelChromeMetrics.closeButtonEdgeInset)
        }
        .overlay {
            if let sheetRow {
                reapSheetOverlay(sheetRow)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Session Manager")
        .accessibilityHint("Background sessions. Pin a session to exempt it from auto-cleanup, or reap it to kill it.")
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Session Manager".uppercased())
                .awFont(AwFont.Mono.kicker)
                .tracking(2)
                .foregroundStyle(Color.aw.text3)
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text("Background sessions")
                    .awFont(AwFont.UI.title)
                    .foregroundStyle(Color.aw.text)
                Text(countSummary)
                    .awFont(AwFont.Mono.meta)
                    .foregroundStyle(Color.aw.text3)
            }
        }
        .padding(.horizontal, AwSpacing.panelPadding)
        .padding(.trailing, 64)
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
                ShortID(id: row.id)
                    .frame(maxWidth: .infinity, alignment: .leading)
                OwnerCell(owner: row.owner)
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
            .accessibilityLabel(rowAccessibilityLabel(row) + ", not reapable")
        } else {
            HStack(spacing: 2) {
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
                .accessibilityLabel(row.pinned ? "Unpin session" : "Pin session")
                .accessibilityHint("Pinned sessions are exempt from auto-cleanup.")

                if row.owner != nil {
                    Button {
                        onJump(row.id)
                    } label: {
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.aw.text3)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Jump to owning pane")
                }

                Button {
                    confirmOrReap(row)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.aw.text3)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Reap session")
                .accessibilityHint("Kills the daemon and its shell.")
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
            row.owner ?? "no owner",
            "\(RelativeAge.string(sinceEpoch: row.createdEpoch, now: Int(Date().timeIntervalSince1970))) old",
            LocalizedPluralStrings.sessionManagerClients(count: row.clients)
        ]
        if row.pinned { parts.append("pinned") }
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
            Text("Reap this ")
                .foregroundStyle(Color.aw.text2)
                + Text(DaemonLifecyclePresentation.label(row.lifecycle).lowercased())
                .foregroundStyle(Color.aw.peach).bold()
                + Text(" daemon? It has no owner — nothing restores it.")
                .foregroundStyle(Color.aw.text2)
            Spacer(minLength: 0)
            Button("Cancel") { inlineConfirmID = nil }
                .buttonStyle(SessionManagerGhostButtonStyle())
            Button {
                Task { _ = await model.reap(row) }
                inlineConfirmID = nil
            } label: {
                Label("Reap", systemImage: "trash")
            }
            .buttonStyle(SessionManagerDangerButtonStyle())
        }
        .awFont(AwFont.UI.meta)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.aw.peach.opacity(0.3)).frame(height: 0.5)
        }
    }

    private func reapSheetOverlay(_ row: DaemonRow) -> some View {
        ZStack {
            Color.aw.surface.chrome2.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture { sheetRow = nil }
            SessionManagerReapSheet(
                row: row,
                onCancel: { sheetRow = nil },
                onReap: {
                    Task { _ = await model.reap(row) }
                    sheetRow = nil
                }
            )
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
                Text("Every session is attached to an open pane. When you quit with a session running, its daemon keeps the shell and scrollback alive — and shows up here to pin or reap.")
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
                // Non-functional pointer to Preferences — the real cap UI is Task 11.
                Text("Configure ›")
                    .foregroundStyle(Color.aw.accent)
            }
            .awFont(AwFont.UI.meta)

            HStack(spacing: 6) {
                Image(systemName: "pin.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.aw.accent)
                Text("pinned are exempt")
                    .awFont(AwFont.UI.meta)
                    .foregroundStyle(Color.aw.text3)
            }

            Spacer(minLength: 0)

            // Honest hint: pin/reap are click actions, Esc dismisses. Full
            // keyboard nav (focus a row, Space/↑↓/P/⌫) is a deferred fast-follow
            // (INT-577) — don't advertise keys that do nothing yet.
            HStack(spacing: 6) {
                Text("click to pin · reap").foregroundStyle(Color.aw.textFaint)
                KBD("Esc")
                Text("dismiss").foregroundStyle(Color.aw.textFaint)
            }
            .awFont(AwFont.Mono.kbd)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.aw.surface.chrome)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.aw.border).frame(height: 0.5)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(footerAccessibilityLabel)
    }

    /// Chip text reflecting the real cap config — "off" on the default (disabled)
    /// config rather than a fixed "7d idle" that promises a reap that never fires.
    private var capChipText: String {
        let cap = model.capSummary
        return cap.enabled ? "\(cap.days)d idle" : "off"
    }

    private var footerAccessibilityLabel: String {
        let cap = model.capSummary
        let policy = cap.enabled
            ? LocalizedPluralStrings.sessionManagerAutoCleanupDays(count: cap.days)
            : "Auto-cleanup is off. Configure in Preferences."
        return "\(policy) Pinned sessions are exempt."
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
