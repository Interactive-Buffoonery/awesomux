import AppKit
import AwesoMuxConfig
import AwesoMuxCore
import DesignSystem
import SwiftUI

struct RuntimeUnavailableView: View {
    let ghosttyRuntime: GhosttyRuntime
    @State private var lastAnnouncedMessage: String?
    // Bumped on every Reload tap. `reload()` resets readiness/error and
    // re-initializes synchronously, so a reload that fails with the SAME message
    // leaves `readiness`+`errorMessage` unchanged at the next render — without
    // this counter the `.task(id:)` would see an identical id and never re-fire,
    // leaving VoiceOver silent on a repeated failure (the one case this view
    // exists to announce).
    @State private var reloadGeneration = 0

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.aw.surface.terminal)

            VStack(spacing: 18) {
                ContentUnavailableView(
                    "Terminal Unavailable",
                    systemImage: "terminal.fill",
                    description: Text(errorMessage)
                )
                .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Button {
                        reloadGeneration += 1
                        lastAnnouncedMessage = nil
                        ghosttyRuntime.reload()
                    } label: {
                        Label("Reload Terminal", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)

                    Button(role: .destructive) {
                        NSApp.terminate(nil)
                    } label: {
                        Label("Quit awesoMux", systemImage: "power")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(32)
        }
        .task(id: announcementStateID) {
            announceUnavailableStateIfNeeded()
        }
    }

    private var errorMessage: String {
        ghosttyRuntime.errorMessage
            ?? "Ghostty runtime is \(ghosttyRuntime.readiness.rawValue)."
    }

    private var announcementStateID: String {
        "\(reloadGeneration)\u{0}\(ghosttyRuntime.readiness.rawValue)\u{0}\(errorMessage)"
    }

    private func announceUnavailableStateIfNeeded() {
        guard ghosttyRuntime.readiness == .failed else {
            lastAnnouncedMessage = nil
            return
        }

        let announcement = "Terminal unavailable. \(errorMessage)"
        guard announcement != lastAnnouncedMessage else {
            return
        }

        lastAnnouncedMessage = announcement
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: announcement,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue
            ]
        )
    }
}
