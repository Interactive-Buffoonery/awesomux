import Foundation
import Testing
@testable import AwesoMuxCore

@Suite struct DocumentPaneTests {

    @Test(arguments: [
        (6, #""remoteSnapshotOrigin":"""#),
        (6, #""remoteSnapshotOrigin":":/repo/cache.md""#),
        (6, #""remoteSnapshotOrigin":"devbox:relative.md""#),
        (6, #""remoteSnapshotOrigin":"devbox:/repo/file.txt""#),
        (7, #""remoteResourceIdentity":{"location":{"kind":"local"},"path":{"rawValue":"/repo/a.md"}}"#),
        (7, #""remoteSnapshotOrigin":"devbox:/repo/cache.md""#),
    ])
    func rejectsInvalidOrigin(version: Int, origin: String) {
        let text = """
            {"id":"11111111-1111-1111-1111-111111111111","fileURL":"file:///tmp/cache.md","title":"cache.md",\(origin)}
            """
        let decoder = JSONDecoder()
        decoder.userInfo[.snapshotSchemaVersion] = version
        #expect(throws: DecodingError.self) { try decoder.decode(DocumentPane.self, from: Data(text.utf8)) }
    }

}

@Suite struct DocumentGroupDecodingTests {

    @Test func dropsOnlyMalformedTabsAndClampsSelection() throws {
        let data = Data(
            #"{"id":"22222222-2222-2222-2222-222222222222","tabs":[{"id":"11111111-1111-1111-1111-111111111111","fileURL":"file:///tmp/bad.md","title":"bad.md","remoteSnapshotOrigin":"bad"},{"id":"33333333-3333-3333-3333-333333333333","fileURL":"file:///tmp/good.md","title":"good.md"}],"selectedTabID":"11111111-1111-1111-1111-111111111111"}"#
                .utf8
        )
        let decoder = JSONDecoder()
        decoder.userInfo[.snapshotSchemaVersion] = 6

        let group = try decoder.decode(DocumentGroup.self, from: data)

        #expect(group.tabs.map(\.title) == ["good.md"])
        #expect(group.selectedTabID == group.tabs[0].id)
    }

    @Test func emptyRecoveredDocumentLeafCollapsesToTerminalSibling() throws {
        let data = Data(
            #"""
            {"split":{"_0":{"id":"44444444-4444-4444-4444-444444444444","orientation":"vertical","firstFraction":0.5,
            "first":{"pane":{"_0":{"id":"55555555-5555-5555-5555-555555555555","title":"shell","workingDirectory":"/tmp","executionPlan":{"kind":"local"}}}},
            "second":{"documentGroup":{"_0":{"id":"22222222-2222-2222-2222-222222222222",
            "tabs":[{"id":"11111111-1111-1111-1111-111111111111","fileURL":"file:///tmp/bad.md","title":"bad.md","remoteSnapshotOrigin":"bad"}],
            "selectedTabID":"11111111-1111-1111-1111-111111111111"}}}}}}
            """#.utf8)
        let decoder = JSONDecoder()
        decoder.userInfo[.snapshotSchemaVersion] = 6
        let decoded = try decoder.decode(TerminalPaneLayout.self, from: data)
        guard case let .pane(terminal) = decoded else { Issue.record("expected terminal sibling"); return }
        #expect(terminal.id == UUID(uuidString: "55555555-5555-5555-5555-555555555555"))
        #expect(terminal.title == "shell")
    }

}
