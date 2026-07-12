import Foundation
import AwesoMuxCore

extension AgentRuntimeEvent {
    func hookJSONLineData() throws -> Data {
        var payload: [String: Any] = [
            "v": version,
            "source": source.rawValue
        ]

        if let kind {
            payload["kind"] = kind.rawValue
        }

        if let executionState {
            payload["execution"] = executionState.rawValue
        }

        if let attentionReason {
            payload["attentionReason"] = attentionReason.rawValue
        }

        if let state {
            payload["state"] = state.rawValue
        }

        if let phase {
            payload["phase"] = phase.rawValue
        }

        if let eventID {
            payload["eventID"] = eventID
        }

        if let documentPath {
            payload["documentPath"] = documentPath
        }

        if let providerSessionID {
            payload["providerSessionID"] = providerSessionID
        }

        if let timestamp {
            payload["timestamp"] = timestamp.timeIntervalSince1970
        }

        var data = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        data.append(0x0a)
        return data
    }
}
