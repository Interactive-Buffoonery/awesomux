import Foundation
import Testing
@testable import AwesoMuxCore

@Suite struct WorkspaceLayoutPresetTests {
    private func localPane(title: String = "zsh", pinned: Bool = false) -> TerminalPane {
        TerminalPane(
            title: title,
            isTitleUserEdited: pinned,
            workingDirectory: "/tmp",
            executionPlan: .local
        )
    }

    private func terminalNode(title: String? = nil) -> WorkspaceLayoutIntent.Node {
        .terminal(.init(title: title, color: nil))
    }

    /// A left-leaning chain of `depth` nested splits (depth 0 = lone terminal).
    private func chainedSplits(depth: Int) -> WorkspaceLayoutIntent.Node {
        var node = terminalNode()
        for _ in 0..<depth {
            node = .split(
                .init(orientation: .vertical, firstFraction: 0.5, first: node, second: terminalNode())
            )
        }
        return node
    }

    /// A balanced tree with `count` terminal leaves.
    private func balancedTerminals(count: Int) -> WorkspaceLayoutIntent.Node {
        precondition(count >= 1)
        guard count > 1 else { return terminalNode() }
        let firstCount = count / 2
        return .split(
            .init(
                orientation: .horizontal,
                firstFraction: 0.5,
                first: balancedTerminals(count: firstCount),
                second: balancedTerminals(count: count - firstCount)
            )
        )
    }

    /// Builds preset WIRE BYTES by wrapping the encoded intent manually, so
    /// over-cap fixtures can exist as files even though the save-side init
    /// refuses to construct them in memory.
    private func encodePreset(_ node: WorkspaceLayoutIntent.Node) throws -> Data {
        let layoutData = try JSONEncoder().encode(WorkspaceLayoutIntent(root: node))
        let text = "{\"version\":1,\"layout\":" + String(decoding: layoutData, as: UTF8.self) + "}"
        return Data(text.utf8)
    }

    private func decodePreset(_ data: Data) throws -> WorkspaceLayoutPreset {
        try JSONDecoder().decode(WorkspaceLayoutPreset.self, from: data)
    }

    // MARK: - Version gate

    @Test func currentVersionRoundTrips() throws {
        let decoded = try decodePreset(try encodePreset(chainedSplits(depth: 2)))
        #expect(decoded.version == WorkspaceLayoutPreset.currentVersion)
        #expect(decoded.layout.root == chainedSplits(depth: 2))
    }

    @Test(arguments: [0, -1, 2, 99])
    func nonCurrentIntegerVersionsAreRejectedAsUnsupported(version: Int) throws {
        var text = String(decoding: try encodePreset(terminalNode()), as: UTF8.self)
        text = text.replacingOccurrences(of: "\"version\":1", with: "\"version\":\(version)")
        #expect(text.contains("\"version\":\(version)"))
        #expect(throws: WorkspaceLayoutPresetError.unsupportedVersion(version)) {
            try decodePreset(Data(text.utf8))
        }
    }

    @Test(arguments: ["\"version\":\"1\"", "\"version\":1.5", "\"version\":null"])
    func malformedVersionsAreDecodingErrors(replacement: String) throws {
        var text = String(decoding: try encodePreset(terminalNode()), as: UTF8.self)
        text = text.replacingOccurrences(of: "\"version\":1", with: replacement)
        #expect(text.contains(replacement))
        #expect(throws: DecodingError.self) {
            try decodePreset(Data(text.utf8))
        }
    }

    @Test func missingVersionIsADecodingError() throws {
        let text = "{\"layout\":{\"root\":{\"terminal\":{\"_0\":{}}}}}"
        #expect(throws: DecodingError.self) {
            try decodePreset(Data(text.utf8))
        }
    }

    // MARK: - Untrusted-input tolerance and rejection

    @Test func unknownFieldsAreTolerated() throws {
        // A compatibly-extended future file must keep decoding: extra keys at
        // the preset, terminal, and split levels are all ignored.
        let text = """
            {"version":1,"futureTopLevel":true,"layout":{"root":{"split":{"_0":{
            "orientation":"vertical","firstFraction":0.4,"futureSplitKey":1,
            "first":{"terminal":{"_0":{"title":"A","futureLeafKey":"x"}}},
            "second":{"terminal":{"_0":{}}}}}}}}
            """
        let decoded = try decodePreset(Data(text.utf8))
        guard case let .split(split) = decoded.layout.root else {
            Issue.record("expected split")
            return
        }
        #expect(split.firstFraction == 0.4)
        #expect(split.first == terminalNode(title: "A"))
    }

    @Test func unknownNodeCaseFailsLoudly() throws {
        let text = "{\"version\":1,\"layout\":{\"root\":{\"artifact\":{\"_0\":{}}}}}"
        #expect(throws: DecodingError.self) {
            try decodePreset(Data(text.utf8))
        }
    }

    // MARK: - Depth and size caps

    @Test func decoderLevelDepthGuardRejectsRunawayNesting() throws {
        // Past TerminalSplit.maxDecodedSplitDepth the INTENT decoder itself must
        // throw — this is the guard that bounds decode recursion even for call
        // sites that bypass WorkspaceLayoutPreset's semantic caps.
        let deep = WorkspaceLayoutIntent(
            root: chainedSplits(depth: TerminalSplit.maxDecodedSplitDepth + 4)
        )
        let data = try JSONEncoder().encode(deep)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(WorkspaceLayoutIntent.self, from: data)
        }
    }

    @Test func presetSplitDepthCapIsEnforced() throws {
        let overDepth = WorkspaceLayoutPreset.maxSplitDepth + 1
        let data = try encodePreset(chainedSplits(depth: overDepth))
        #expect(
            throws: WorkspaceLayoutPresetError.layoutTooDeep(
                depth: overDepth,
                limit: WorkspaceLayoutPreset.maxSplitDepth
            )
        ) {
            try decodePreset(data)
        }
    }

    @Test func presetSplitDepthAtCapDecodes() throws {
        let data = try encodePreset(chainedSplits(depth: WorkspaceLayoutPreset.maxSplitDepth))
        let decoded = try decodePreset(data)
        #expect(decoded.layout.splitDepth == WorkspaceLayoutPreset.maxSplitDepth)
    }

    @Test func presetTerminalCountCapIsEnforced() throws {
        let overCount = WorkspaceLayoutPreset.maxTerminalCount + 1
        let data = try encodePreset(balancedTerminals(count: overCount))
        #expect(
            throws: WorkspaceLayoutPresetError.tooManyTerminals(
                count: overCount,
                limit: WorkspaceLayoutPreset.maxTerminalCount
            )
        ) {
            try decodePreset(data)
        }
    }

    @Test func saveSideConstructionEnforcesTheSameCaps() {
        // The live/restore contract allows layouts past the preset caps, so the
        // save-side init must throw the same errors decode does — never write a
        // file this build would refuse to load.
        let overCount = WorkspaceLayoutPreset.maxTerminalCount + 1
        #expect(
            throws: WorkspaceLayoutPresetError.tooManyTerminals(
                count: overCount,
                limit: WorkspaceLayoutPreset.maxTerminalCount
            )
        ) {
            try WorkspaceLayoutPreset(
                layout: WorkspaceLayoutIntent(root: balancedTerminals(count: overCount))
            )
        }

        let overDepth = WorkspaceLayoutPreset.maxSplitDepth + 1
        #expect(
            throws: WorkspaceLayoutPresetError.layoutTooDeep(
                depth: overDepth,
                limit: WorkspaceLayoutPreset.maxSplitDepth
            )
        ) {
            try WorkspaceLayoutPreset(
                layout: WorkspaceLayoutIntent(root: chainedSplits(depth: overDepth))
            )
        }
    }

    @Test func presetCapsSitInsideTheRestoreContract() {
        // An applied preset becomes a persisted session layout; the caps must
        // stay under the restore reducer's collapse threshold or a preset that
        // applies fine would silently collapse on next launch.
        #expect(WorkspaceLayoutPreset.maxSplitDepth < SessionRestoreReducer.maxRestoredLayoutDepth)
        #expect(WorkspaceLayoutPreset.maxSplitDepth < TerminalSplit.maxDecodedSplitDepth)
    }

    // MARK: - Materialize

    @Test func materializeBuildsLocalPanesWithFreshIdentity() throws {
        let intent = WorkspaceLayoutIntent(
            root: .split(
                .init(
                    orientation: .horizontal,
                    firstFraction: 0.3,
                    first: terminalNode(title: "Build"),
                    second: terminalNode()
                )
            )
        )

        let layout = intent.materialize(workingDirectory: "/Users/who/project")
        guard case let .split(split) = layout,
            case let .pane(first) = split.first,
            case let .pane(second) = split.second
        else {
            Issue.record("expected split of two panes")
            return
        }

        #expect(split.orientation == .horizontal)
        #expect(split.firstFraction == 0.3)

        // Pinned title preserved and marked user-edited; missing title falls
        // back to the directory basename, unpinned.
        #expect(first.title == "Build")
        #expect(first.isTitleUserEdited)
        #expect(second.title == "project")
        #expect(!second.isTitleUserEdited)

        for pane in [first, second] {
            #expect(pane.workingDirectory == "/Users/who/project")
            #expect(pane.executionPlan == .local)
            #expect(pane.color == nil)
        }

        // Fresh identity on every materialization — a preset must never reuse
        // pane or daemon-session identity.
        let again = intent.materialize(workingDirectory: "/Users/who/project")
        guard case let .split(againSplit) = again,
            case let .pane(againFirst) = againSplit.first
        else {
            Issue.record("expected split of two panes")
            return
        }
        #expect(againFirst.id != first.id)
        #expect(againFirst.terminalSessionID != first.terminalSessionID)
        #expect(againSplit.id != split.id)
    }

    @Test func materializeSanitizesHostileTitles() {
        let hostile = String(repeating: "A", count: 500) + "\u{0007}\u{202E}"
        let intent = WorkspaceLayoutIntent(root: terminalNode(title: hostile))
        guard case let .pane(pane) = intent.materialize(workingDirectory: "/tmp") else {
            Issue.record("expected pane")
            return
        }
        #expect(pane.title == SessionStoreText.sanitizedTitle(hostile))
        #expect(!pane.title.contains("\u{0007}"))
        #expect(pane.title.count <= SessionStoreText.maxTitleLength)
    }

    @Test func materializeTreatsAllControlTitleAsMissing() {
        let intent = WorkspaceLayoutIntent(root: terminalNode(title: "\u{0007}\u{0000}"))
        guard case let .pane(pane) = intent.materialize(workingDirectory: "/tmp/project") else {
            Issue.record("expected pane")
            return
        }
        // Sanitizes to empty -> falls back to the basename, unpinned.
        #expect(pane.title == "project")
        #expect(!pane.isTitleUserEdited)
    }

    @Test func materializedLayoutProjectsBackToTheSameIntent() throws {
        // save -> apply -> save must be stable: the projection of a
        // materialized intent is the intent itself.
        let original = WorkspaceLayoutIntent(
            root: .split(
                .init(
                    orientation: .vertical,
                    firstFraction: 0.42,
                    first: terminalNode(title: "A"),
                    second: .split(
                        .init(
                            orientation: .horizontal,
                            firstFraction: 0.25,
                            first: terminalNode(),
                            second: terminalNode(title: "B")
                        )
                    )
                )
            )
        )
        let reprojected = original.materialize(workingDirectory: "/tmp").layoutIntent
        #expect(reprojected == original)
    }

    @Test func liveLayoutRoundTripsThroughPresetWire() throws {
        // Full save-side path: live layout -> projection -> preset encode ->
        // preset decode -> materialize -> projection equality.
        let layout = TerminalPaneLayout.split(
            TerminalSplit(
                orientation: .vertical,
                first: .pane(localPane(title: "A", pinned: true)),
                second: .pane(localPane()),
                firstFraction: 0.6
            ))
        let intent = try #require(layout.layoutIntent)
        let data = try JSONEncoder().encode(WorkspaceLayoutPreset(layout: intent))
        let decoded = try decodePreset(data)
        #expect(decoded.layout == intent)
        #expect(decoded.layout.materialize(workingDirectory: "/tmp").layoutIntent == intent)
    }

    // MARK: - Size metrics

    @Test func sizeMetricsCountLeavesAndDepth() {
        let intent = WorkspaceLayoutIntent(root: balancedTerminals(count: 5))
        #expect(intent.terminalCount == 5)
        let lone = WorkspaceLayoutIntent(root: terminalNode())
        #expect(lone.terminalCount == 1)
        #expect(lone.splitDepth == 0)
        #expect(WorkspaceLayoutIntent(root: chainedSplits(depth: 3)).splitDepth == 3)
    }
}
