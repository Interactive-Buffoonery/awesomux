import AwesoMuxTestSupport
import Foundation
import SQLite3
import Testing

@testable import AwesoMuxCore

@Suite("OpenCode transcript database", .serialized)
struct OpenCodeTranscriptDatabaseTests {
    @Test("an exact session reads committed WAL rows in chronological order")
    func readsLiveWALByExactSessionID() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        try fixture.insertSession("ses_target")
        try fixture.insertSession("ses_other")
        try fixture.insertMessage(
            id: "msg_2", sessionID: "ses_target", time: 2,
            role: "assistant", partID: "part_2", part: ["type": "text", "text": "second"]
        )
        try fixture.insertMessage(
            id: "msg_1", sessionID: "ses_target", time: 1,
            role: "user", partID: "part_1", part: ["type": "text", "text": "first"]
        )
        try fixture.insertMessage(
            id: "msg_other", sessionID: "ses_other", time: 3,
            role: "user", partID: "part_other", part: ["type": "text", "text": "not ours"]
        )

        let snapshot = try OpenCodeTranscriptDatabase.read(
            dataHome: fixture.dataHome,
            sessionID: "ses_target"
        ).get()

        #expect(snapshot.messages.map(\.id) == ["msg_1", "msg_2"])
        #expect(
            snapshot.messages.flatMap(\.parts).compactMap(\.data).contains {
                String(data: $0, encoding: .utf8)?.contains("first") == true
            })
        #expect(
            !snapshot.messages.flatMap(\.parts).compactMap(\.data).contains {
                String(data: $0, encoding: .utf8)?.contains("not ours") == true
            })
    }

    @Test("non-renderable recent rows cannot hide the last renderable turn")
    func neverEmptyWhenSessionHasARenderableTurn() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        try fixture.insertSession("ses_target")
        try fixture.insertMessage(
            id: "msg_old", sessionID: "ses_target", time: 1,
            role: "user", partID: "part_old", part: ["type": "text", "text": "kept"]
        )
        for index in 2...20 {
            try fixture.insertMessage(
                id: "msg_\(index)", sessionID: "ses_target", time: index,
                role: "assistant", partID: "part_\(index)", part: ["type": "step-start"]
            )
        }

        let snapshot = try OpenCodeTranscriptDatabase.read(
            dataHome: fixture.dataHome,
            sessionID: "ses_target",
            maximumTurns: 1
        ).get()

        #expect(snapshot.messages.map(\.id) == ["msg_old"])
        #expect(!snapshot.isTruncated)
    }

    @Test("the query keeps only the newest bounded turns and reports truncation")
    func boundsRecentTurns() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        try fixture.insertSession("ses_target")
        for index in 1...4 {
            try fixture.insertMessage(
                id: "msg_\(index)", sessionID: "ses_target", time: index,
                role: index.isMultiple(of: 2) ? "assistant" : "user",
                partID: "part_\(index)",
                part: ["type": "text", "text": "turn \(index)"]
            )
        }

        let snapshot = try OpenCodeTranscriptDatabase.read(
            dataHome: fixture.dataHome,
            sessionID: "ses_target",
            maximumTurns: 2
        ).get()

        #expect(snapshot.messages.map(\.id) == ["msg_3", "msg_4"])
        #expect(snapshot.isTruncated)
    }

    @Test("read-only open never creates a missing database")
    func missingDatabaseStaysMissing() throws {
        let directory = try TemporaryDirectory(prefix: "opencode-transcript-missing")
        let dataHome = directory.url.appending(path: "opencode", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dataHome, withIntermediateDirectories: true)
        let databaseURL = dataHome.appending(path: "opencode.db")

        #expect(
            OpenCodeTranscriptDatabase.read(dataHome: dataHome, sessionID: "ses_target")
                == .failure(.notFound)
        )
        #expect(!FileManager.default.fileExists(atPath: databaseURL.path))
    }

    @Test("a closed WAL database remains readable without sidecars or directory writes")
    func readsClosedWALWithoutSidecarsInReadOnlyDirectory() throws {
        let fixture = try Fixture()
        try fixture.insertSession("ses_target")
        try fixture.insertMessage(
            id: "msg_1", sessionID: "ses_target", time: 1,
            role: "user", partID: "part_1", part: ["type": "text", "text": "deployed"]
        )
        fixture.close()
        try fixture.removeWALSidecars()
        try fixture.makeDataHomeReadOnly()
        defer { try? fixture.restoreDataHomePermissions() }

        #expect(!FileManager.default.fileExists(atPath: fixture.databaseURL.path + "-wal"))
        #expect(!FileManager.default.fileExists(atPath: fixture.databaseURL.path + "-shm"))

        let snapshot = try OpenCodeTranscriptDatabase.read(
            dataHome: fixture.dataHome,
            sessionID: "ses_target"
        ).get()

        #expect(snapshot.messages.map(\.id) == ["msg_1"])
        #expect(
            snapshot.messages.flatMap(\.parts).compactMap(\.data).contains {
                String(data: $0, encoding: .utf8)?.contains("deployed") == true
            })
    }

    @Test("a symlink cannot redirect the fixed database path")
    func finalSymlinkIsRefused() throws {
        let fixture = try Fixture()
        let target = fixture.databaseURL
        fixture.close()
        let linkHome = fixture.root.url.appending(path: "linked", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: linkHome, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: linkHome.appending(path: "opencode.db"),
            withDestinationURL: target
        )

        #expect(
            OpenCodeTranscriptDatabase.read(dataHome: linkHome, sessionID: "ses_target")
                == .failure(.databaseUnavailable)
        )
    }

    @Test("a corrupt part row cannot leak another session through a shared message id")
    func mismatchedPartSessionIDIsIgnored() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        try fixture.insertSession("ses_target")
        try fixture.insertSession("ses_other")
        try fixture.insertMessage(
            id: "msg_shared", sessionID: "ses_target", time: 1,
            role: "user", partID: "part_target", part: ["type": "text", "text": "ours"]
        )
        try fixture.insertForeignPart(
            id: "part_foreign",
            messageID: "msg_shared",
            sessionID: "ses_other",
            time: 2,
            part: ["type": "text", "text": "not ours"]
        )

        let snapshot = try OpenCodeTranscriptDatabase.read(
            dataHome: fixture.dataHome,
            sessionID: "ses_target"
        ).get()

        #expect(snapshot.messages.map(\.id) == ["msg_shared"])
        #expect(
            snapshot.messages.flatMap(\.parts).compactMap(\.data).contains {
                String(data: $0, encoding: .utf8)?.contains("ours") == true
            })
        #expect(
            !snapshot.messages.flatMap(\.parts).compactMap(\.data).contains {
                String(data: $0, encoding: .utf8)?.contains("not ours") == true
            })
    }

    @Test("byte caps measure UTF-8 bytes, not Unicode characters")
    func byteCapsUseOctetLength() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        try fixture.insertSession("ses_target")
        let wideText = String(repeating: "\u{1F600}", count: 70_000)
        try fixture.insertMessage(
            id: "msg_wide", sessionID: "ses_target", time: 1,
            role: "user", partID: "part_wide", part: ["type": "text", "text": wideText]
        )

        let snapshot = try OpenCodeTranscriptDatabase.read(
            dataHome: fixture.dataHome,
            sessionID: "ses_target"
        ).get()

        let part = try #require(snapshot.messages.first?.parts.first)
        #expect(part.data == nil)
        #expect(part.byteCount > OpenCodeTranscriptDatabase.maximumPartBytes)
    }

    @Test("a cumulative source-byte budget keeps only the newest rows")
    func boundsCumulativeSourceBytes() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        try fixture.insertSession("ses_target")
        for index in 1...3 {
            try fixture.insertMessage(
                id: "msg_\(index)", sessionID: "ses_target", time: index,
                role: "user", partID: "part_\(index)",
                part: ["type": "text", "text": String(repeating: "x", count: 300)]
            )
        }

        let snapshot = try OpenCodeTranscriptDatabase.read(
            dataHome: fixture.dataHome,
            sessionID: "ses_target",
            maximumSourceBytes: 500
        ).get()

        #expect(snapshot.messages.map(\.id) == ["msg_3"])
        #expect(snapshot.isTruncated)
        let retainedBytes = snapshot.messages.reduce(into: 0) { count, message in
            count += message.data?.count ?? 0
            count += message.parts.reduce(0) { $0 + ($1.data?.count ?? 0) }
        }
        #expect(retainedBytes <= 500)
    }
}

private final class Fixture {
    let root: TemporaryDirectory
    let dataHome: URL
    let databaseURL: URL
    private var database: OpaquePointer?

    init() throws {
        root = try TemporaryDirectory(prefix: "opencode-transcript-db")
        dataHome = root.url.appending(path: "opencode", directoryHint: .isDirectory)
        databaseURL = dataHome.appending(path: "opencode.db")
        try FileManager.default.createDirectory(at: dataHome, withIntermediateDirectories: true)
        try requireOK(sqlite3_open(databaseURL.path, &database))
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA wal_autocheckpoint=0")
        try execute("CREATE TABLE session (id text PRIMARY KEY, time_created integer NOT NULL)")
        try execute(
            "CREATE TABLE message (id text PRIMARY KEY, session_id text NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL)"
        )
        try execute(
            "CREATE TABLE part (id text PRIMARY KEY, message_id text NOT NULL, session_id text NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL)"
        )
        try execute("CREATE INDEX message_session_time ON message(session_id, time_created, id)")
        try execute("CREATE INDEX part_message_id ON part(message_id, id)")
    }

    func insertSession(_ id: String) throws {
        try execute("INSERT INTO session(id, time_created) VALUES ('\(id)', 1)")
    }

    func insertMessage(
        id: String,
        sessionID: String,
        time: Int,
        role: String,
        partID: String,
        part: [String: Any]
    ) throws {
        let messageJSON = try JSONSerialization.data(withJSONObject: ["role": role])
        let messageData = try #require(String(data: messageJSON, encoding: .utf8))
        let partJSON = try JSONSerialization.data(withJSONObject: part)
        let partData = try #require(String(data: partJSON, encoding: .utf8))
        try execute(
            "INSERT INTO message(id, session_id, time_created, time_updated, data) VALUES ('\(id)', '\(sessionID)', \(time), \(time), '\(messageData)')"
        )
        try execute(
            "INSERT INTO part(id, message_id, session_id, time_created, time_updated, data) VALUES ('\(partID)', '\(id)', '\(sessionID)', \(time), \(time), '\(partData)')"
        )
    }

    func insertForeignPart(
        id: String,
        messageID: String,
        sessionID: String,
        time: Int,
        part: [String: Any]
    ) throws {
        let partJSON = try JSONSerialization.data(withJSONObject: part)
        let partData = try #require(String(data: partJSON, encoding: .utf8))
        try execute(
            "INSERT INTO part(id, message_id, session_id, time_created, time_updated, data) VALUES ('\(id)', '\(messageID)', '\(sessionID)', \(time), \(time), '\(partData)')"
        )
    }

    func close() {
        if let database {
            sqlite3_close(database)
            self.database = nil
        }
    }

    func makeDataHomeReadOnly() throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555],
            ofItemAtPath: dataHome.path
        )
    }

    func removeWALSidecars() throws {
        for suffix in ["-wal", "-shm"] {
            let sidecarURL = URL(fileURLWithPath: databaseURL.path + suffix)
            if FileManager.default.fileExists(atPath: sidecarURL.path) {
                try FileManager.default.removeItem(at: sidecarURL)
            }
        }
    }

    func restoreDataHomePermissions() throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: dataHome.path
        )
    }

    private func execute(_ sql: String) throws {
        try requireOK(sqlite3_exec(database, sql, nil, nil, nil))
    }

    private func requireOK(_ result: Int32) throws {
        guard result == SQLITE_OK else {
            throw NSError(
                domain: "OpenCodeTranscriptDatabaseTests",
                code: Int(result),
                userInfo: [NSLocalizedDescriptionKey: database.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite error"]
            )
        }
    }
}
