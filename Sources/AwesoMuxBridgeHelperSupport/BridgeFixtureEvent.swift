import AwesoMuxBridgeProtocol
import Foundation

public enum BridgeFixtureEvent {
    /// `--emit` fixtures are JSONL payload objects using the normal flat wire
    /// fields (`type` plus that type's fields). `v`, `token`, `session`, `id`,
    /// and `ts` may be omitted; the helper supplies its current credentials,
    /// a fresh id, and the injected clock. This keeps fixture files reusable
    /// across reattaches without ever storing the live token.
    public static func parse(
        line: String,
        token: String,
        session: String,
        id: String = UUID().uuidString,
        now: Date = Date()
    ) -> BridgeEnvelope? {
        guard let data = line.data(using: .utf8),
            var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        object["v"] = BridgeEnvelope.supportedVersion
        object["token"] = token
        object["session"] = session
        object["id"] = object["id"] ?? id
        object["ts"] = object["ts"] ?? now.timeIntervalSince1970
        guard let normalized = try? JSONSerialization.data(withJSONObject: object) else {
            return nil
        }
        return BridgeEnvelope.parse(data: normalized)
    }
}
