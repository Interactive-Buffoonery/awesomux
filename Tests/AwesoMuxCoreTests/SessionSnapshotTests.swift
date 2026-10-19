import AwesoMuxBridgeProtocol
import Foundation
import XCTest
@testable import AwesoMuxCore

final class SessionSnapshotTests: XCTestCase {

    func testLegacyTerminalPaneMintsTerminalSessionID() throws {
        let json = """
            {
              "id": "\(UUID().uuidString)",
              "title": "zsh",
              "isTitleUserEdited": false,
              "workingDirectory": "~",
              "agentKind": "Shell",
              "agentExecutionState": "idle",
              "unreadNotificationCount": 0
            }
            """

        let decoded = try JSONDecoder().decode(TerminalPane.self, from: Data(json.utf8))

        XCTAssertLessThanOrEqual(
            decoded.terminalSessionID.rawValue.utf8.count,
            TerminalSessionID.maxAmxSessionNameUTF8Bytes
        )
        XCTAssertTrue(TerminalSessionID.isValid(decoded.terminalSessionID.rawValue))
    }


    func testRejectsFutureSchemaVersionReportsVersions() {
        let json = #"{"schemaVersion":\#(SessionSnapshot.currentSchemaVersion + 1),"groups":[]}"#
        XCTAssertThrowsError(try SessionSnapshot.decode(from: Data(json.utf8))) { error in
            guard case DecodingError.dataCorrupted = error else {
                XCTFail("Expected dataCorrupted, got \(error)")
                return
            }
        }
    }

    func testDecodeThreadsSchemaVersionIntoNestedModels() throws {
        let terminal = TerminalPane(
            title: "zsh",
            workingDirectory: "~",
            executionPlan: .local
        )
        let sessionID = UUID()
        let documentID = UUID()
        let groupID = UUID()
        let terminalJSON = String(decoding: try JSONEncoder().encode(terminal), as: UTF8.self)
        let json = """
            {
              "schemaVersion": 7,
              "groups": [{
                "id": "\(groupID.uuidString)",
                "name": "main",
                "sessions": [{
                  "id": "\(sessionID.uuidString)",
                  "title": "workspace",
                  "workingDirectory": "~",
                  "layout": {"split":{"_0":{
                    "id": "\(UUID().uuidString)",
                    "orientation": "vertical",
                    "firstFraction": 0.5,
                    "first": {"pane":{"_0":\(terminalJSON)}},
                    "second": {"documentGroup":{"_0":{
                      "id": "\(UUID().uuidString)",
                      "tabs": [{
                        "id": "\(documentID.uuidString)",
                        "fileURL": "file:///tmp/cache.md",
                        "title": "cache.md",
                        "remoteSnapshotOrigin": "devbox:/repo/cache.md"
                      }],
                      "selectedTabID": "\(documentID.uuidString)"
                    }}}
                  }}},
                  "activePaneID": "\(terminal.id.uuidString)"
                }]
              }],
              "selectedSessionID": "\(sessionID.uuidString)"
            }
            """

        let legacyData = Data(
            json.replacingOccurrences(
                of: #""schemaVersion": 7"#,
                with: #""schemaVersion": 6"#
            ).utf8
        )
        let migrated = try SessionSnapshot.decode(from: legacyData)
        let recovered = try SessionSnapshot.decode(from: Data(json.utf8))

        XCTAssertEqual(
            migrated.groups.first?.sessions.first?.layout.firstDocumentGroup?
                .selectedTab?.remoteSnapshotOrigin,
            "devbox:/repo/cache.md"
        )
        XCTAssertEqual(recovered.droppedDocumentTabCountDuringDecoding, 1)
        XCTAssertNil(recovered.groups.first?.sessions.first?.layout.firstDocumentGroup)
    }

    // MARK: - Pane-color tolerance through the SessionSnapshot decode path

}
