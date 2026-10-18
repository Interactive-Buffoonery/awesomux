import Foundation
import Testing
@testable import AwesoMuxCore

@Suite struct WorkspaceLayoutIntentTests {
    private func localPane(title: String = "zsh", pinned: Bool = false) -> TerminalPane {
        TerminalPane(
            title: title,
            isTitleUserEdited: pinned,
            workingDirectory: "/tmp",
            executionPlan: .local
        )
    }

    @Test(arguments: [("-1", 0.15), ("\"NaN\"", 0.5), ("\"Infinity\"", 0.5), ("9", 0.85)])
    func decodedFraction(value: String, expected: Double) throws {
        let text = """
            {"root":{"split":{"_0":{"orientation":"vertical","firstFraction":\(value),
            "first":{"terminal":{"_0":{}}},"second":{"terminal":{"_0":{}}}}}}}
            """
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        let decoded = try decoder.decode(WorkspaceLayoutIntent.self, from: Data(text.utf8))
        guard case let .split(split) = decoded.root else { Issue.record("expected split"); return }
        #expect(split.firstFraction == expected)
    }

    @Test func encodedIntentContainsNoLiveOnlyIdentifiers() throws {
        let layout = TerminalPaneLayout.split(
            TerminalSplit(
                orientation: .vertical,
                first: .pane(localPane(title: "A", pinned: true)),
                second: .pane(localPane(title: "B", pinned: true))
            ))
        let intent = try #require(layout.layoutIntent)
        let data = try JSONEncoder().encode(intent)
        let json = try #require(try JSONSerialization.jsonObject(with: data))

        var keys: Set<String> = []
        collectKeys(json, into: &keys)

        // Strongest guarantee: the encoded key set is a SUBSET of the allowlist.
        // Any future field added to the intent DTO introduces a new key and fails
        // this — stronger than a substring blocklist (which misses renames) and
        // without its false-positives (a benign "width"/"hidden"/"grid" would trip
        // a substring scan). The allowlist is the two enum case tags, the single-
        // associated-value wrapper key, the struct field names, and `color`
        // (allowed though absent here since the fixture pins a nil color).
        let allowedKeys: Set<String> = [
            "root", "split", "terminal", "_0",
            "orientation", "firstFraction", "first", "second",
            "title", "color",
        ]
        #expect(
            keys.isSubset(of: allowedKeys),
            "unexpected intent key(s) — possible live-state leak: \(keys.subtracting(allowedKeys))"
        )

    }

    private func collectKeys(_ obj: Any, into keys: inout Set<String>) {
        if let dict = obj as? [String: Any] {
            for (key, value) in dict {
                keys.insert(key)
                collectKeys(value, into: &keys)
            }
        } else if let array = obj as? [Any] {
            for value in array {
                collectKeys(value, into: &keys)
            }
        }
    }
}
