import AwesoMuxTestSupport
import Foundation
import SQLite3
import Testing

@testable import AwesoMuxCore

@Suite("OpenCode transcript database", .serialized)
struct OpenCodeTranscriptDatabaseTests {
    @Test("V2 reads inline prompts and ordinal assistant parts from its split schema")
    func readsV2SplitMessages() throws {
        let fixture = try Fixture(v2: true)
        defer { fixture.close() }
        try fixture.insertSession("ses_target")
        try fixture.insertSession("ses_other")
        try fixture.insertMessage(
            id: "msg_user", sessionID: "ses_target", time: 99, sequence: 1,
            role: "user", partID: "part_unused", part: ["type": "text", "text": "question"]
        )
        try fixture.insertMessage(
            id: "msg_assistant", sessionID: "ses_target", time: 1, sequence: 2,
            role: "assistant", partID: "part_0", part: ["type": "reasoning", "text": "consider"]
        )
        try fixture.insertPart(
            id: "part_1", messageID: "msg_assistant", sessionID: "ses_target", time: 1,
            part: ["type": "text", "text": "answer"]
        )
        try fixture.insertPart(
            id: "part_2", messageID: "msg_assistant", sessionID: "ses_target", time: 0,
            part: [
                "type": "tool", "name": "shell",
                "state": ["status": "completed", "input": [:], "content": [["type": "text", "text": "tool result"]]],
            ]
        )
        try fixture.insertMessage(
            id: "msg_other", sessionID: "ses_other", time: 3,
            role: "user", partID: "part_unused", part: ["type": "text", "text": "not ours"]
        )
        let snapshot = try OpenCodeTranscriptDatabase.read(
            dataHome: fixture.dataHome, sessionID: "ses_target"
        ).get()
        #expect(snapshot.messages.map(\.id) == ["msg_user", "msg_assistant"])
        let parts = try snapshot.messages.flatMap(\.parts).map {
            try JSONSerialization.jsonObject(with: #require($0.data)) as? [String: Any]
        }
        #expect(parts.compactMap { $0?["text"] as? String } == ["question", "consider", "answer"])
        let tool = try #require(parts.last ?? nil)
        #expect(tool["tool"] as? String == "shell")
        let state = try #require(tool["state"] as? [String: Any])
        let output = try #require(state["output"] as? [[String: Any]])
        #expect(output.first?["text"] as? String == "tool result")
        let roles = try snapshot.messages.map {
            try JSONSerialization.jsonObject(with: #require($0.data)) as? [String: Any]
        }
        #expect(roles.compactMap { $0?["role"] as? String } == ["user", "assistant"])
    }

    @Test("V2 inline assistant content follows split parts in the same message")
    func readsV2InlineAndMixedAssistantContent() throws {
        let fixture = try Fixture(v2: true)
        defer { fixture.close() }
        try fixture.insertSession("ses_target")
        try fixture.insertInlineAssistant(
            id: "msg_inline", sessionID: "ses_target", time: 1,
            content: [
                ["type": "text", "text": "inline answer"],
                ["type": "reasoning", "text": "inline thought"],
                ["type": "tool", "name": "shell", "state": ["input": [:], "content": [["type": "text", "text": "inline tool result"]]]],
            ]
        )
        try fixture.insertInlineAssistant(
            id: "msg_mixed", sessionID: "ses_target", time: 2,
            content: [["type": "text", "text": "inline tail"]]
        )
        try fixture.insertPart(
            id: "part_0", messageID: "msg_mixed", sessionID: "ses_target", time: 100,
            part: ["type": "text", "text": "split first"]
        )
        let snapshot = try OpenCodeTranscriptDatabase.read(
            dataHome: fixture.dataHome, sessionID: "ses_target"
        ).get()
        #expect(snapshot.messages.map(\.id) == ["msg_inline", "msg_mixed"])
        #expect(snapshot.messages.map { $0.parts.count } == [3, 2])
        let parts = try snapshot.messages.flatMap(\.parts).map {
            try JSONSerialization.jsonObject(with: #require($0.data)) as? [String: Any]
        }
        #expect(parts.compactMap { $0?["text"] as? String } == ["inline answer", "inline thought", "split first", "inline tail"])
        try #require(parts.count > 2)
        let tool = try #require(parts[2])
        #expect(tool["tool"] as? String == "shell")
        let state = try #require(tool["state"] as? [String: Any])
        let output = try #require(state["output"] as? [[String: Any]])
        #expect(output.first?["text"] as? String == "inline tool result")
    }

    @Test("V2 bounds turns, parts, bytes and ignores foreign session parts")
    func boundsV2Source() throws {
        let fixture = try Fixture(v2: true)
        defer { fixture.close() }
        try fixture.insertSession("ses_target")
        try fixture.insertSession("ses_other")
        for index in 1...3 {
            try fixture.insertMessage(
                id: "msg_\(index)", sessionID: "ses_target", time: index,
                role: "assistant", partID: "part_0", part: ["type": "text", "text": String(repeating: "x", count: 300)]
            )
        }
        try fixture.insertForeignPart(
            id: "part_1", messageID: "msg_3", sessionID: "ses_other", time: 4,
            part: ["type": "text", "text": "not ours"]
        )
        let snapshot = try OpenCodeTranscriptDatabase.read(
            dataHome: fixture.dataHome, sessionID: "ses_target", maximumTurns: 2,
            maximumParts: 1, maximumSourceBytes: 500
        ).get()
        #expect(snapshot.messages.map(\.id) == ["msg_3"])
        #expect(snapshot.isTruncated)
        #expect(snapshot.messages.flatMap(\.parts).count == 1)
        let turns = try OpenCodeTranscriptDatabase.read(
            dataHome: fixture.dataHome, sessionID: "ses_target", maximumTurns: 1
        ).get()
        #expect(turns.messages.map(\.id) == ["msg_3"])
        #expect(turns.isTruncated)
        let bytes = try OpenCodeTranscriptDatabase.read(
            dataHome: fixture.dataHome, sessionID: "ses_target", maximumSourceBytes: 500
        ).get()
        #expect(bytes.messages.map(\.id) == ["msg_3"])
        #expect(bytes.isTruncated)

    }

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
    private let v2: Bool

    init(v2: Bool = false) throws {
        self.v2 = v2
        root = try TemporaryDirectory(prefix: "opencode-transcript-db")
        dataHome = root.url.appending(path: "opencode", directoryHint: .isDirectory)
        databaseURL = dataHome.appending(path: "opencode.db")
        try FileManager.default.createDirectory(at: dataHome, withIntermediateDirectories: true)
        try requireOK(sqlite3_open(databaseURL.path, &database))
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA wal_autocheckpoint=0")
        if v2 {
            try execute("CREATE TABLE session_v2 (id text PRIMARY KEY, time_created integer NOT NULL)")
            try execute(
                "CREATE TABLE session_message (id text PRIMARY KEY, session_id text NOT NULL, type text NOT NULL, seq integer NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL)"
            )
            try execute(
                "CREATE TABLE session_part (message_id text NOT NULL, session_id text NOT NULL, ordinal integer NOT NULL, type text NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL, PRIMARY KEY(message_id, ordinal))"
            )
            return
        }
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
        try execute("INSERT INTO \(v2 ? "session_v2" : "session")(id, time_created) VALUES ('\(id)', 1)")
    }

    func insertMessage(
        id: String,
        sessionID: String,
        time: Int,
        sequence: Int? = nil,
        role: String,
        partID: String,
        part: [String: Any]
    ) throws {
        if v2 {
            let message: [String: Any] = role == "user" ? ["text": part["text"] ?? ""] : [:]
            let data = try #require(String(data: JSONSerialization.data(withJSONObject: message), encoding: .utf8))
            try execute(
                "INSERT INTO session_message VALUES ('\(id)', '\(sessionID)', '\(role)', \(sequence ?? time), \(time), \(time), '\(data)')")
            if role != "user" {
                try insertPart(id: partID, messageID: id, sessionID: sessionID, time: time, part: part)
            }
            return
        }
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

    func insertInlineAssistant(
        id: String,
        sessionID: String,
        time: Int,
        content: [[String: Any]]
    ) throws {
        let message: [String: Any] = [
            "time": ["created": time], "agent": "build",
            "model": ["id": "fixture", "providerID": "awesomux-fixture"], "content": content,
        ]
        let data = try #require(String(data: JSONSerialization.data(withJSONObject: message), encoding: .utf8))
            .replacingOccurrences(of: "'", with: "''")
        try execute("INSERT INTO session_message VALUES ('\(id)', '\(sessionID)', 'assistant', \(time), \(time), \(time), '\(data)')")
    }

    func insertForeignPart(
        id: String,
        messageID: String,
        sessionID: String,
        time: Int,
        part: [String: Any]
    ) throws {
        try insertPart(id: id, messageID: messageID, sessionID: sessionID, time: time, part: part)
    }

    func insertPart(
        id: String,
        messageID: String,
        sessionID: String,
        time: Int,
        part: [String: Any]
    ) throws {
        let partJSON = try JSONSerialization.data(withJSONObject: part)
        let partData = try #require(String(data: partJSON, encoding: .utf8))
        if v2 {
            let ordinal = try #require(Int(id.split(separator: "_").last ?? ""))
            let type = try #require(part["type"] as? String)
            try execute(
                "INSERT INTO session_part VALUES ('\(messageID)', '\(sessionID)', \(ordinal), '\(type)', \(time), \(time), '\(partData)')")
            return
        }
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
