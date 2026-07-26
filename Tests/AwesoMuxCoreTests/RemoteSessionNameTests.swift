import Foundation
import Testing
@testable import AwesoMuxCore

@Suite struct RemoteSessionNameTests {
    @Test(
        "accepts safe socket-path components",
        arguments: [
            "build",
            "Build42",
            "api.staging",
            "api_staging",
            "api-staging",
            "0",
            String(repeating: "a", count: 64),
        ])
    func acceptsValidNames(raw: String) {
        #expect(RemoteSessionName(rawValue: raw)?.rawValue == raw)
    }

    @Test(
        "rejects names that are not safe on a remote command line",
        arguments: [
            "",
            "   ",
            "my session",
            "-rf",
            ".",
            "..",
            "a;b",
            "a$b",
            "a`b",
            "a\"b",
            "a'b",
            "a|b",
            "a&b",
            "a>b",
            "a\nb",
            "a/b",
            "/abs",
            "café",
            String(repeating: "a", count: 65),
            "a\u{200B}b",
            "a\u{202E}b",
        ])
    func rejectsInvalidNames(raw: String) {
        #expect(RemoteSessionName(rawValue: raw) == nil)
    }

    @Test func roundTripsThroughCodable() throws {
        let name = RemoteSessionName(rawValue: "build-42")!
        let data = try JSONEncoder().encode(name)
        #expect(String(decoding: data, as: UTF8.self) == "\"build-42\"")
        #expect(try JSONDecoder().decode(RemoteSessionName.self, from: data) == name)
    }

    @Test("decoding rejects malformed names", arguments: ["\"bad name\"", "\"..\"", "\"-x\""])
    func decodingRejectsMalformedNames(json: String) {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(RemoteSessionName.self, from: Data(json.utf8))
        }
    }
}
