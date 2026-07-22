import AwesoMuxBridgeProtocol
import AwesoMuxCore
import DesignSystem
import SwiftUI

/// Full reap-confirm sheet for a *non-orphan* daemon (owned or detached). Names
/// exactly what is lost — a live pane drops to a recoverable error, a restorable
/// session loses its reopen entry — so the kill is never a surprise. Orphans use
/// the cheaper inline confirm in `SessionManagerPanel`.
///
/// The "clear reopen entry / permanent close" checkbox from the mockup is
/// deliberately omitted here — that's tracked separately (INT-282) and out of
/// scope for this surface.
@MainActor
struct SessionManagerReapSheet: View {
    let row: DaemonRow
    let onCancel: () -> Void
    let onReap: () -> Void

    private var isOwned: Bool { row.lifecycle == .owned }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("REAP")
                    .awFont(AwFont.Mono.kicker)
                    .tracking(1.5)
                    .foregroundStyle(Color.aw.red)
                Text("Kill this session?")
                    .awFont(AwFont.UI.title)
                    .foregroundStyle(Color.aw.text)
            }

            // The daemon, restated with its lifecycle, activity, identity, owner.
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    StateTag(lifecycle: row.lifecycle)
                    ActivityIndicator(activity: row.activity)
                    Spacer(minLength: 0)
                    if row.pinned {
                        HStack(spacing: 5) {
                            Image(systemName: "pin.fill").font(.system(size: 10))
                            Text("pinned").awFont(AwFont.Mono.kbd)
                        }
                        // Snapshot-only: this sheet lives under the bare Session Manager panel root and reads the live accent mailbox per summon.
                        .foregroundStyle(Color.aw.accent)
                    }
                }
                ShortID(id: row.id)
                HStack(spacing: 14) {
                    OwnerCell(owner: row.owner)
                    Text("\(RelativeAge.string(sinceEpoch: row.createdEpoch, now: Int(Date().timeIntervalSince1970))) · \(LocalizedPluralStrings.sessionManagerClients(count: row.clients))")
                        .awFont(AwFont.Mono.kbd)
                        .foregroundStyle(Color.aw.textFaint)
                }
            }
            .padding(12)
            .background(Color.aw.surface.elevated, in: RoundedRectangle(cornerRadius: AwRadius.panel))
            .overlay {
                RoundedRectangle(cornerRadius: AwRadius.panel)
                    .stroke(Color.aw.border2, lineWidth: 0.5)
            }

            Text(consequence)
                .awFont(AwFont.UI.meta)
                .foregroundStyle(Color.aw.text2)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Text("$ amx kill \(SessionManagerPanel.shortIDSuffix(row.id))…")
                    .awFont(AwFont.Mono.meta)
                    .foregroundStyle(Color.aw.text3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Color.aw.surface.chrome2, in: RoundedRectangle(cornerRadius: AwRadius.button))
            .overlay {
                RoundedRectangle(cornerRadius: AwRadius.button)
                    .stroke(Color.aw.border2, lineWidth: 0.5)
            }

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Cancel", action: onCancel)
                    .buttonStyle(SessionManagerGhostButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(action: onReap) {
                    Label("Reap session", systemImage: "trash")
                }
                .buttonStyle(SessionManagerDangerButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .background(Color.aw.surface.chrome, in: RoundedRectangle(cornerRadius: AwRadius.window))
        .overlay {
            RoundedRectangle(cornerRadius: AwRadius.window)
                .stroke(Color.aw.border, lineWidth: 0.5)
        }
        .awShadow(.sheet)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Confirm reap of \(row.owner ?? "this session")")
    }

    private var consequence: String {
        let process = row.activity == .busy ? " and the running process" : ""
        if isOwned {
            return "This daemon is owned by an open pane. Reaping kills its shell\(process), and the pane will drop to a recoverable error. Its scrollback is discarded."
        }
        return "This daemon is detached but restorable. Reaping kills the shell\(process) and discards its scrollback — relaunch will no longer bring it back."
    }
}
