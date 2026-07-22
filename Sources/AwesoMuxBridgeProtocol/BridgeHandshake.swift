import Foundation

/// The three `awesomux-bridge-v1` handshake frames — `hello`/`hello-ack`/
/// `hello-nack`. Per the spec's Handshake section, this is a **separate,
/// minimal schema exempt from `BridgeEnvelope`'s required-field set**:
/// there is no `v` field (the handshake predates version negotiation — a
/// `hello-nack` is how an unsupported `proto` is rejected in the first
/// place), and `hello-nack` in particular carries neither `token` nor
/// `session`, since it exists precisely for the case where those never got
/// validated.
public enum BridgeHandshake: Sendable, Equatable {
    /// Helper → app, must be the first frame on any connection.
    case hello(proto: String, token: String, session: String, ts: Double, helper: String)
    /// App → helper, sent once `hello` passes validation.
    case helloAck(session: String, proto: String, ts: Double)
    /// App → helper, sent when `hello.proto` names an unsupported version.
    case helloNack(supported: [String])

    private static let decoder = JSONDecoder()
    private static let encoder = JSONEncoder()

    // MARK: - Decoding

    public static func parse(line: String) -> BridgeHandshake? {
        guard let data = line.data(using: .utf8) else {
            return nil
        }
        return parse(data: data)
    }

    public static func parse(data: Data) -> BridgeHandshake? {
        guard let wire = try? decoder.decode(Wire.self, from: data) else {
            return nil
        }

        // Unknown `type` is dropped, never coerced into one of the three
        // known shapes — same discipline as the envelope's unknown-type
        // handling.
        switch wire.type {
        case "hello":
            guard let proto = wire.proto, let token = wire.token, let session = wire.session,
                  let ts = wire.ts, let helper = wire.helper
            else { return nil }
            return .hello(proto: proto, token: token, session: session, ts: ts, helper: helper)

        case "hello-ack":
            guard let session = wire.session, let proto = wire.proto, let ts = wire.ts else {
                return nil
            }
            return .helloAck(session: session, proto: proto, ts: ts)

        case "hello-nack":
            guard let supported = wire.supported else {
                return nil
            }
            return .helloNack(supported: supported)

        default:
            return nil
        }
    }

    // MARK: - Encoding

    /// See `BridgeEnvelope.encodedLine()`'s doc comment: re-decoding and
    /// asserting equality with `self` guarantees this never emits a line
    /// `parse` would then drop, without duplicating validation a second
    /// time on the encode path.
    public func encodedLine() throws -> String {
        let data = try Self.encoder.encode(Wire(handshake: self))
        let line = String(decoding: data, as: UTF8.self)
        guard Self.parse(line: line) == self else {
            throw EncodingError.invalidValue(
                self,
                EncodingError.Context(codingPath: [], debugDescription: "BridgeHandshake failed its own round-trip validation")
            )
        }
        return line
    }

    private struct Wire: Codable {
        var type: String
        var proto: String?
        var token: String?
        var session: String?
        var ts: Double?
        var helper: String?
        var supported: [String]?

        init(handshake: BridgeHandshake) {
            switch handshake {
            case .hello(let proto, let token, let session, let ts, let helper):
                type = "hello"
                self.proto = proto
                self.token = token
                self.session = session
                self.ts = ts
                self.helper = helper
            case .helloAck(let session, let proto, let ts):
                type = "hello-ack"
                self.session = session
                self.proto = proto
                self.ts = ts
            case .helloNack(let supported):
                type = "hello-nack"
                self.supported = supported
            }
        }
    }
}
