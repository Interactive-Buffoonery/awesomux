import AwesoMuxCompanionProtocol
import DesignSystem
import SwiftUI

/// A separate Watch attachment observes handback after the phone socket closes.
/// Its lifetime follows the visible pane and cancellation closes only its socket.
struct CompanionTerminalDrivingBanner: View {
    let paneDescriptor: String
    let paneID: UUID
    let sessionName: String?
    private let driving = CompanionTerminalDriving.shared
    @State private var lastAnnouncement: String?
    @State private var monitorID: UUID?
    @State private var leader: UInt64?
    @State private var grid: CompanionTerminalStream.Grid?

    private struct MonitorKey: Equatable {
        let sessionName: String?
        let revision: UInt64
        let enabled: Bool
    }

    private var device: CompanionTerminalDriving.Device? {
        guard let sessionName, let leader else { return nil }
        return driving.device(paneID: paneID, sessionName: sessionName, leader: leader)
    }

    private var statusText: String? {
        guard let grid, let leader else { return nil }
        if let device {
            return String(
                localized: "\(device.name) is driving · \(grid.cols)×\(grid.rows) · type a letter, arrow or Return to take it back",
                comment:
                    "Terminal leadership banner. Arguments are the paired device’s name, grid columns, and grid rows. Typing on the Mac takes control back."
            )
        }
        if leader == 0 {
            return String(
                localized: "No one is driving · \(grid.cols)×\(grid.rows) · type a letter, arrow or Return to take it back",
                comment:
                    "Terminal leadership banner when no device leads. Arguments are grid columns and rows. Typing on the Mac takes control back."
            )
        }
        return nil
    }

    var body: some View {
        ZStack {
            Color.clear.frame(width: 0, height: 0)
            if let statusText {
                HStack(spacing: 8) {
                    Text(statusText)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if let device {
                        Button(String(localized: "Disconnect", comment: "Button that ends the paired device’s current terminal stream.")) {
                            device.disconnect()
                        }
                        .accessibilityLabel(
                            String(
                                localized: "Disconnect \(device.name) from this terminal",
                                comment: "Accessibility label for ending a terminal stream. Argument is the paired device’s name."))
                    }
                }
                .padding(8)
                .awFont(AwFont.UI.meta)
                .foregroundStyle(Color.aw.text)
                .background(Color.aw.surface.chrome)
            }
        }
        .onChange(of: statusText) { _, status in
            guard let status else {
                if leader != nil { lastAnnouncement = nil }
                return
            }
            let announcement = "\(paneDescriptor): \(status)"
            guard lastAnnouncement != announcement else { return }
            lastAnnouncement = announcement
            TerminalAccessibilityAnnouncer.announce(announcement)
        }
        .task(
            id: MonitorKey(
                sessionName: sessionName, revision: driving.revisions[paneID] ?? 0,
                enabled: driving.monitoredSessions[paneID] == sessionName && sessionName != nil)
        ) {
            let id = UUID()
            monitorID = id
            leader = nil
            grid = nil
            guard let sessionName, driving.monitoredSessions[paneID] == sessionName else { return }
            _ = await CompanionTerminalWatchRelay.attach(
                socketPath: AmxBackend.sessionSocketDirectory() + "/" + sessionName,
                grid: .init(rows: 24, cols: 80),
                delay: { try await ContinuousClock().sleep(for: $0) }
            ) { message in
                guard !Task.isCancelled, monitorID == id else { return .end(.closed) }
                if let authority = CompanionTerminalWatchRelay.Authority(message) {
                    leader = authority.leader
                    grid = authority.grid
                    driving.didObserve(paneID: paneID, sessionName: sessionName, leader: authority.leader)
                }
                if message.tag == CompanionTerminalWatchRelay.ZmxTag.sessionEnd.rawValue { return .end(.sessionEnded) }
                return .continue
            }
            guard monitorID == id else { return }
            leader = nil
            grid = nil
            lastAnnouncement = nil
        }
    }
}
