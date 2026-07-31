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
    typealias Delay = @MainActor @Sendable (UInt64) async throws -> Void

    private let dwellNanoseconds: UInt64
    var delay: Delay
    private var task: Task<Void, Never>?

    deinit {
        task?.cancel()
    }

    init(
        dwellNanoseconds: UInt64,
        delay: @escaping Delay = {
            try await ContinuousClock().sleep(
                for: .nanoseconds(Int64(clamping: $0))
            )
        }
    ) {
        self.dwellNanoseconds = dwellNanoseconds
        self.delay = delay
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

        let delay = delay
        task = Task { @MainActor [dwellNanoseconds, delay] in
            do {
                try await delay(dwellNanoseconds)
            } catch {
                return
            }

            acknowledgeIfCurrent(selectedSessionID, baseline)
        }
    }
}
