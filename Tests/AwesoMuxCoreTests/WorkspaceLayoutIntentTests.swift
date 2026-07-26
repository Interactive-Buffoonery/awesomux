import AwesoMuxBridgeProtocol
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

    private func remotePane() -> TerminalPane {
        TerminalPane(
            title: "ssh",
            workingDirectory: "/tmp",
            executionPlan: .ssh(SSHExecution(target: RemoteTarget(user: "ed", host: "box")!))
        )
    }

    private func group() -> DocumentGroup {
        let doc = DocumentPane(
            fileURL: URL(fileURLWithPath: NSTemporaryDirectory() + "in-\(UUID().uuidString).md"),
            title: "notes.md"
        )
        return DocumentGroup(tabs: [doc], selectedTabID: doc.id)
    }

    // MARK: - Prune-and-normalize

    @Test func singleLocalTerminalProjects() {
        let intent = TerminalPaneLayout.pane(localPane()).layoutIntent
        #expect(intent?.root == .terminal(.init(title: nil, color: nil)))
    }

    @Test func onlyPinnedTitleSurvivesLiveTitleDropped() {
        let live = TerminalPaneLayout.pane(localPane(title: "live-osc-title", pinned: false)).layoutIntent
        #expect(live?.root == .terminal(.init(title: nil, color: nil)))
        let pinned = TerminalPaneLayout.pane(localPane(title: "My Build", pinned: true)).layoutIntent
        #expect(pinned?.root == .terminal(.init(title: "My Build", color: nil)))
    }

    @Test func documentLeafIsPrunedSplitCollapses() {
        let term = localPane(title: "A", pinned: true)
        let layout = TerminalPaneLayout.split(
            TerminalSplit(
                orientation: .vertical,
                first: .pane(term),
                second: .documentGroup(group())
            ))
        // Document pruned -> unary split collapses to the surviving terminal.
        #expect(layout.layoutIntent?.root == .terminal(.init(title: "A", color: nil)))
    }

    @Test func remoteTerminalIsPruned() {
        let layout = TerminalPaneLayout.split(
            TerminalSplit(
                orientation: .vertical,
                first: .pane(localPane(title: "L", pinned: true)),
                second: .pane(remotePane())
            ))
        #expect(layout.layoutIntent?.root == .terminal(.init(title: "L", color: nil)))
    }

    @Test func twoLocalTerminalsKeepTheSplit() {
        let layout = TerminalPaneLayout.split(
            TerminalSplit(
                orientation: .horizontal,
                first: .pane(localPane(title: "A", pinned: true)),
                second: .pane(localPane(title: "B", pinned: true)),
                firstFraction: 0.3
            ))
        guard case let .split(split)? = layout.layoutIntent?.root else {
            Issue.record("expected a split intent")
            return
        }
        #expect(split.orientation == .horizontal)
        #expect(split.firstFraction == 0.3)
        #expect(split.first == .terminal(.init(title: "A", color: nil)))
        #expect(split.second == .terminal(.init(title: "B", color: nil)))
    }

    @Test func nestedPruneCollapsesInnerSplit() {
        // split( split(localA, doc), localB ) -> inner collapses to localA ->
        // split(localA, localB).
        let inner = TerminalPaneLayout.split(
            TerminalSplit(
                orientation: .vertical,
                first: .pane(localPane(title: "A", pinned: true)),
                second: .documentGroup(group())
            ))
        let layout = TerminalPaneLayout.split(
            TerminalSplit(
                orientation: .horizontal,
                first: inner,
                second: .pane(localPane(title: "B", pinned: true))
            ))
        guard case let .split(split)? = layout.layoutIntent?.root else {
            Issue.record("expected a split intent")
            return
        }
        #expect(split.first == .terminal(.init(title: "A", color: nil)))
        #expect(split.second == .terminal(.init(title: "B", color: nil)))
    }

    @Test func documentOnlyLayoutProjectsToNil() {
        #expect(TerminalPaneLayout.documentGroup(group()).layoutIntent == nil)
    }

    @Test func remoteOnlyLayoutProjectsToNil() {
        #expect(TerminalPaneLayout.pane(remotePane()).layoutIntent == nil)
    }

    @Test func splitWithBothChildrenPrunedProjectsToNil() {
        // A split whose BOTH children prune (document + remote terminal) leaves
        // no preset-eligible terminal — the whole projection collapses to nil.
        let layout = TerminalPaneLayout.split(
            TerminalSplit(
                orientation: .vertical,
                first: .documentGroup(group()),
                second: .pane(remotePane())
            ))
        #expect(layout.layoutIntent == nil)
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
        ]
        #expect(keys.isDisjoint(with: forbiddenExact))

        // Structure is present (sanity).
        #expect(keys.isSuperset(of: ["orientation", "firstFraction", "first", "second", "title"]))
    }

    @Test func intentRoundTripsThroughCodable() throws {
        let layout = TerminalPaneLayout.split(
            TerminalSplit(
                orientation: .horizontal,
                first: .pane(localPane(title: "A", pinned: true)),
                second: .pane(localPane(title: "B", pinned: true)),
                firstFraction: 0.42
            ))
        let intent = try #require(layout.layoutIntent)
        let data = try JSONEncoder().encode(intent)
        let decoded = try JSONDecoder().decode(WorkspaceLayoutIntent.self, from: data)
        #expect(decoded == intent)
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
