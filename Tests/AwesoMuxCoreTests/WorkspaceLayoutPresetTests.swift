import Foundation
import Testing
@testable import AwesoMuxCore

@Suite struct WorkspaceLayoutPresetTests {

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

    private enum Rejection: CaseIterable { case splitDepth, terminalCount, decoderDepth, version }

    @Test(arguments: Rejection.allCases)
    private func rejectsUntrustedPreset(rejection: Rejection) throws {
        switch rejection {
        case .splitDepth:
            let depth = WorkspaceLayoutPreset.maxSplitDepth + 1
            let data = try encodePreset(chainedSplits(depth: depth))
            #expect(throws: WorkspaceLayoutPresetError.layoutTooDeep(depth: depth, limit: WorkspaceLayoutPreset.maxSplitDepth)) {
                try decodePreset(data)
            }
        case .terminalCount:
            let count = WorkspaceLayoutPreset.maxTerminalCount + 1
            let data = try encodePreset(balancedTerminals(count: count))
            #expect(throws: WorkspaceLayoutPresetError.tooManyTerminals(count: count, limit: WorkspaceLayoutPreset.maxTerminalCount)) {
                try decodePreset(data)
            }
        case .decoderDepth:
            let data = try JSONEncoder().encode(WorkspaceLayoutIntent(root: chainedSplits(depth: TerminalSplit.maxDecodedSplitDepth + 4)))
            #expect(throws: DecodingError.self) { try JSONDecoder().decode(WorkspaceLayoutIntent.self, from: data) }
        case .version:
            let text = String(decoding: try encodePreset(terminalNode()), as: UTF8.self).replacingOccurrences(
                of: "\"version\":1", with: "\"version\":99")
            #expect(throws: WorkspaceLayoutPresetError.unsupportedVersion(99)) { try decodePreset(Data(text.utf8)) }
        }
    }

    @Test func materializeBuildsLocalPanesWithFreshIdentity() {
        let intent = WorkspaceLayoutIntent(
            root: .split(
                .init(
                    orientation: .horizontal, firstFraction: 0.3,
                    first: terminalNode(title: "Build"), second: terminalNode()
                )))
        let firstLayout = intent.materialize(workingDirectory: "/tmp")
        let againLayout = intent.materialize(workingDirectory: "/tmp")
        for layout in [firstLayout, againLayout] {
            guard case let .split(split) = layout else {
                Issue.record("expected split")
                return
            }
            #expect(split.orientation == .horizontal)
            #expect(split.firstFraction == 0.3)
            guard case .pane = split.first, case .pane = split.second else {
                Issue.record("expected two direct pane children")
                return
            }
        }
        let first = TerminalSession(title: "preset", workingDirectory: "/tmp", layout: firstLayout).panes
        let again = TerminalSession(title: "preset", workingDirectory: "/tmp", layout: againLayout).panes
        #expect(Set(first.map(\.id)).isDisjoint(with: again.map(\.id)))
        #expect(Set(first.map(\.terminalSessionID)).isDisjoint(with: again.map(\.terminalSessionID)))
        for pane in first + again { #expect(pane.executionPlan == .local) }
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

}
