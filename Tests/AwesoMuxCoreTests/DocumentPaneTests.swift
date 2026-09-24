import Foundation
import Testing
@testable import AwesoMuxCore

@Suite struct DocumentPaneTests {

    @Test func rejectsMalformedLegacyRemoteOrigins() {
        for origin in [
            "",
            ":/repo/cache.md",
            "devbox:relative.md",
            "devbox:/repo/file.txt",
        ] {
            let data = Data(
                "{\"id\":\"11111111-1111-1111-1111-111111111111\",\"fileURL\":\"file:///tmp/cache.md\",\"title\":\"cache.md\",\"remoteSnapshotOrigin\":\"\(origin)\"}"
                    .utf8
            )
            let decoder = JSONDecoder()
            decoder.userInfo[.snapshotSchemaVersion] = 6

            #expect(throws: DecodingError.self) {
                try decoder.decode(DocumentPane.self, from: data)
            }
        }
    }

    @Test func rejectsLocalOrMalformedRemoteIdentity() throws {
        let pane = DocumentPane(fileURL: URL(fileURLWithPath: "/tmp/a.md"), title: "a.md")
        let encoded = try JSONEncoder().encode(pane)
        var json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json["remoteResourceIdentity"] = [
            "location": ["kind": "local"],
            "path": ["rawValue": "/repo/a.md"],
        ]
        let decoder = JSONDecoder()
        decoder.userInfo[.snapshotSchemaVersion] = 7

        #expect(throws: DecodingError.self) {
            try decoder.decode(
                DocumentPane.self,
                from: JSONSerialization.data(withJSONObject: json)
            )
        }
    }

    @Test func schemaSevenRejectsLegacyOrigin() throws {
        let data = Data(
            #"{"id":"11111111-1111-1111-1111-111111111111","fileURL":"file:///tmp/cache.md","title":"cache.md","remoteSnapshotOrigin":"devbox:/repo/cache.md"}"#
                .utf8
        )
        let decoder = JSONDecoder()
        decoder.userInfo[.snapshotSchemaVersion] = 7

        #expect(throws: DecodingError.self) {
            try decoder.decode(DocumentPane.self, from: data)
        }
    }
}

@Suite struct DocumentGroupDecodingTests {
    @Test func emptyRecoveredGroupThrowsTypedSignal() {
        let data = Data(
            #"{"id":"22222222-2222-2222-2222-222222222222","tabs":[],"selectedTabID":"11111111-1111-1111-1111-111111111111"}"#.utf8
        )

        #expect(throws: EmptyDocumentGroupDecodingError.self) {
            try JSONDecoder().decode(DocumentGroup.self, from: data)
        }
    }

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
        let terminal = TerminalPane(title: "shell", workingDirectory: "/tmp", executionPlan: .local)
        let bad = DocumentPane(fileURL: URL(fileURLWithPath: "/tmp/bad.md"), title: "bad.md")
        let layout = TerminalPaneLayout.split(
            TerminalSplit(
                orientation: .vertical,
                first: .pane(terminal),
                second: .documentGroup(DocumentGroup(tabs: [bad], selectedTabID: bad.id))
            ))
        let encoded = try JSONEncoder().encode(layout)
        var json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var splitCase = try #require(json["split"] as? [String: Any])
        var split = try #require(splitCase["_0"] as? [String: Any])
        var secondCase = try #require(split["second"] as? [String: Any])
        var groupCase = try #require(secondCase["documentGroup"] as? [String: Any])
        var group = try #require(groupCase["_0"] as? [String: Any])
        var tabs = try #require(group["tabs"] as? [[String: Any]])
        tabs[0]["remoteSnapshotOrigin"] = "bad"
        group["tabs"] = tabs
        groupCase["_0"] = group
        secondCase["documentGroup"] = groupCase
        split["second"] = secondCase
        splitCase["_0"] = split
        json["split"] = splitCase
        let decoder = JSONDecoder()
        decoder.userInfo[.snapshotSchemaVersion] = 6

        let decoded = try decoder.decode(
            TerminalPaneLayout.self,
            from: JSONSerialization.data(withJSONObject: json)
        )

        #expect(decoded == .pane(terminal))
    }
}
