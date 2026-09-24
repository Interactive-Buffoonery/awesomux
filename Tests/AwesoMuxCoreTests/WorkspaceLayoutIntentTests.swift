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

    @Test func canonicalFractionClampsLowAndNonFinite() {
        func fraction(_ value: Double) -> Double {
            WorkspaceLayoutIntent.SplitIntent(
                orientation: .vertical,
                firstFraction: value,
                first: .terminal(.init(title: nil, color: nil)),
                second: .terminal(.init(title: nil, color: nil))
            ).firstFraction
        }
        #expect(fraction(-1) == 0.15)
        #expect(fraction(.nan) == 0.5)
        #expect(fraction(.infinity) == 0.5)
    }

    // MARK: - Preset boundary (the load-bearing guarantee)

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

        // Explicit belt: none of the known live-only field names appear.
        let forbiddenExact: Set<String> = [
            "id", "terminalSessionID", "sessionID", "executionPlan",
            "workingDirectory", "fileURL", "url", "remoteResourceIdentity",
            "remoteTarget", "target", "agentKind", "agentExecutionState",
            "associatedTerminalPaneID", "persistenceOwner", "host", "user", "path",
            "sessionName",
        ]
        #expect(keys.isDisjoint(with: forbiddenExact))

        // Structure is present (sanity).
        #expect(keys.isSuperset(of: ["orientation", "firstFraction", "first", "second", "title"]))
    }

    @Test func decodedIntentCanonicalizesOutOfRangeFraction() throws {
        let layout = TerminalPaneLayout.split(
            TerminalSplit(
                orientation: .vertical,
                first: .pane(localPane(title: "A", pinned: true)),
                second: .pane(localPane(title: "B", pinned: true)),
                firstFraction: 0.5
            ))
        let intent = try #require(layout.layoutIntent)
        // Force an out-of-range fraction into the wire bytes without depending on
        // the enum wrapper shape.
        var text = String(decoding: try JSONEncoder().encode(intent), as: UTF8.self)
        text = text.replacingOccurrences(of: "\"firstFraction\":0.5", with: "\"firstFraction\":9")
        #expect(text.contains("\"firstFraction\":9"))  // guard the substitution landed
        let decoded = try JSONDecoder().decode(WorkspaceLayoutIntent.self, from: Data(text.utf8))
        guard case let .split(split) = decoded.root else {
            Issue.record("expected split")
            return
        }
        #expect(split.firstFraction == 0.85)  // clamped on decode
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
