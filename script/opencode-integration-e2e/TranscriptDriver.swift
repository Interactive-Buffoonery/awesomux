import Foundation

// The reader only returns these two importer errors. Keeping this harness
// independent of the app graph lets it exercise real provider databases.
public enum AgentTranscriptUnavailable: Error, Equatable, Sendable {
    case notFound
    case databaseUnavailable
}

@main
struct TranscriptDriver {
    static func main() throws {
        guard CommandLine.arguments.count == 4 else {
            throw NSError(
                domain: "TranscriptDriver", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Expected data home, session id, and expected fixture text"])
        }
        let snapshot = try OpenCodeTranscriptDatabase.read(
            dataHome: URL(fileURLWithPath: CommandLine.arguments[1]),
            sessionID: CommandLine.arguments[2]
        ).get()
        let parts = snapshot.messages.flatMap(\.parts)
        let containsExpectedText = parts.contains { part in
            part.data.flatMap { String(data: $0, encoding: .utf8) }?.contains(CommandLine.arguments[3]) == true
        }
        let report: [String: Any] = [
            "messages": snapshot.messages.count,
            "parts": parts.count,
            "truncated": snapshot.isTruncated,
            "containsExpectedText": containsExpectedText,
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        guard containsExpectedText else {
            throw NSError(
                domain: "TranscriptDriver", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Expected fixture text was absent from the production reader output"])
        }
    }
}
