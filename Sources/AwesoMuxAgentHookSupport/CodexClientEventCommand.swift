import AwesoMuxCore
import Darwin
import Foundation

public enum CodexClientEventCommand {
    public static let maximumInputByteCount = 4096

    public static func run(environment: [String: String], stdin: Data) -> Int {
        guard stdin.count <= maximumInputByteCount,
            let payload = try? JSONDecoder().decode(Payload.self, from: stdin),
            payload.v == 1,
            UUID(uuidString: payload.client_id) != nil,
            payload.sequence > 0,
            payload.thread_epoch > 0,
            payload.session_id.map({ UUID(uuidString: $0) != nil }) ?? true,
            payload.input_ready == (payload.status == .ready),
            payload.status != .ready || payload.session_id != nil,
            payload.captured_at.isFinite,
            payload.captured_at >= 0,
            Date().timeIntervalSince1970 - payload.captured_at <= 10,
            payload.captured_at - Date().timeIntervalSince1970 <= 1,
            let path = environment[AgentRuntimeEnvironmentKey.eventFile], !path.isEmpty
        else { return 1 }

        // The callback is a direct child of the TUI; never accept a payload PID.
        let pid = getppid()
        var info = proc_bsdinfo()
        let size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        guard pid > 0, size == Int32(MemoryLayout<proc_bsdinfo>.size) else { return 1 }
        let evidence = AgentClientStatusEvidence(
            clientID: payload.client_id,
            sequence: payload.sequence,
            completedTurns: payload.completed_turns,
            threadEpoch: payload.thread_epoch,
            pid: Int(pid),
            startedAt: Int(info.pbi_start_tvsec) * 1_000_000 + Int(info.pbi_start_tvusec),
            capturedAt: payload.captured_at
        )
        guard evidence.isValid else { return 1 }

        let event = AgentRuntimeEvent(
            source: .codex,
            kind: .codex,
            executionState: payload.status == .unavailable
                ? nil
                : payload.status == .error
                    ? .error
                    : payload.status == .ready ? .waiting : payload.status == .working ? .thinking : .idle,
            attentionReason: payload.status == .blocked ? .userInputRequired : nil,
            phase: .notification,
            eventID: UUID().uuidString,
            providerSessionID: payload.session_id,
            timestamp: Date(timeIntervalSince1970: payload.captured_at),
            clientStatus: evidence
        )
        guard let line = try? event.hookJSONLineData(), line.count <= AgentRuntimeEvent.maximumLineByteCount else {
            return 1
        }
        do {
            try AgentHookEventFileAppender.append(line, to: path)
            return 0
        } catch {
            return 1
        }
    }

    private enum Status: String, Decodable {
        case ready, working, blocked, unavailable, error
    }

    private struct Payload: Decodable {
        var v: Int
        var client_id: String
        var sequence: UInt64
        var completed_turns: UInt64
        var thread_epoch: UInt64
        var session_id: String?
        var input_ready: Bool
        var status: Status
        var captured_at: TimeInterval
    }
}
