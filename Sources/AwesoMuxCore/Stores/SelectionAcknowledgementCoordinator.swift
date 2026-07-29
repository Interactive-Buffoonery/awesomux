import Foundation

/// The selection-dwell baseline. Post INT-504 the dwell acks the ACTIVE pane
/// only, so it captures the active pane's identity and its unread count: if the
/// active pane changes mid-dwell, the baseline no longer applies and the ack is
/// skipped (R3).
struct SelectionAcknowledgementBaseline: Sendable {
    var activePaneID: TerminalPane.ID
    var paneUnreadCount: Int
}

@MainActor
final class SelectionAcknowledgementCoordinator {
    private let dwellNanoseconds: UInt64
    private var task: Task<Void, Never>?

    deinit {
        task?.cancel()
    }

    init(dwellNanoseconds: UInt64) {
        self.dwellNanoseconds = dwellNanoseconds
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    func schedule(
        selectedSessionID: TerminalSession.ID?,
        baseline: SelectionAcknowledgementBaseline?,
        acknowledgeIfCurrent: @escaping @MainActor @Sendable (
            _ selectedSessionID: TerminalSession.ID,
            _ baseline: SelectionAcknowledgementBaseline
        ) -> Void
    ) {
        cancel()

        guard let selectedSessionID, let baseline else {
            return
        }

        task = Task { @MainActor [dwellNanoseconds] in
            do {
                try await Task.sleep(nanoseconds: dwellNanoseconds)
            } catch {
                return
            }

            acknowledgeIfCurrent(selectedSessionID, baseline)
        }
    }
}
