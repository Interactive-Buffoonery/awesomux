import Darwin
import Foundation
import SecureFileIO
import SQLite3

/// Reads a bounded OpenCode session snapshot directly from its live SQLite store.
public enum OpenCodeTranscriptDatabase {
    static let databaseFileName = "opencode.db"
    public static let maximumTurns = 256
    public static let maximumParts = 4_096
    /// Leaves expansion room above the rendered-document budget while bounding
    /// hostile SQLite payloads far below the independent row caps.
    public static let maximumSourceBytes = 8 * 1_024 * 1_024
    static let maximumPartBytes = 256 * 1_024
    static let maximumMessageBytes = 64 * 1_024

    public static func read(
        dataHome: URL,
        sessionID: String,
        maximumTurns: Int = maximumTurns,
        maximumParts: Int = maximumParts,
        maximumSourceBytes: Int = maximumSourceBytes,
        effectiveUID: uid_t = geteuid()
    ) -> Result<OpenCodeTranscriptSnapshot, AgentTranscriptUnavailable> {
        let databaseURL = dataHome.resolvingSymlinksInPath().appending(path: databaseFileName)
        let path = databaseURL.path
        var metadata = stat()
        guard lstat(path, &metadata) == 0 else {
            return .failure(errno == ENOENT ? .notFound : .databaseUnavailable)
        }
        guard metadata.st_uid == effectiveUID,
            metadata.st_mode & S_IFMT == S_IFREG
        else {
            return .failure(.databaseUnavailable)
        }

        let openPath: String
        do {
            let handle = try SecureFileReader.open(
                at: databaseURL,
                effectiveUID: effectiveUID,
                symlinkPolicy: .rejectFinalComponent
            )
            openPath = handle.resolvedURL.path
        } catch {
            return .failure(.databaseUnavailable)
        }

        let walPath = openPath + "-wal"
        let sharedMemoryPath = openPath + "-shm"
        let hasWALSidecars =
            FileManager.default.fileExists(atPath: walPath)
            || FileManager.default.fileExists(atPath: sharedMemoryPath)
        let sqlitePath: String
        var flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW
        if hasWALSidecars {
            sqlitePath = openPath
        } else {
            var components = URLComponents(
                url: URL(fileURLWithPath: openPath), resolvingAgainstBaseURL: false)
            components?.queryItems = [URLQueryItem(name: "immutable", value: "1")]
            guard let immutablePath = components?.string else {
                return .failure(.databaseUnavailable)
            }
            sqlitePath = immutablePath
            flags |= SQLITE_OPEN_URI
        }

        var database: OpaquePointer?
        guard sqlite3_open_v2(sqlitePath, &database, flags, nil) == SQLITE_OK,
            let database
        else {
            if let database { sqlite3_close(database) }
            return .failure(.databaseUnavailable)
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 1_000)
        guard sqlite3_exec(database, "PRAGMA query_only = ON", nil, nil, nil) == SQLITE_OK else {
            return .failure(.databaseUnavailable)
        }

        let isV2 = tableExists("session_v2", database: database)
        let sessionTable = isV2 ? "session_v2" : "session"
        switch sessionExists(database: database, sessionID: sessionID, table: sessionTable) {
        case .success(false): return .failure(.notFound)
        case .failure: return .failure(.databaseUnavailable)
        case .success(true): break
        }

        let turnLimit = min(max(1, maximumTurns), Int(Int32.max) - 1)
        let partLimit = min(max(1, maximumParts), Int(Int32.max) - 1)
        let sourceByteLimit = max(1, maximumSourceBytes)
        let outputField = isV2 ? "content" : "output"
        let renderablePart = """
            CASE WHEN json_valid(p.data) THEN
                CASE
                    WHEN json_extract(p.data, '$.type') IN ('text', 'reasoning')
                        THEN json_type(p.data, '$.text') = 'text'
                            AND length(json_extract(p.data, '$.text')) > 0
                    WHEN json_extract(p.data, '$.type') = 'tool'
                        THEN COALESCE(json_type(p.data, '$.state.\(outputField)'), 'null') != 'null'
                            OR COALESCE(json_type(p.data, '$.state.input'), 'null') != 'null'
                    ELSE 0
                END
            ELSE 0 END
            """
        let inlinePart = renderablePart.replacingOccurrences(of: "p.data", with: "content.value")
        let candidateMessages =
            isV2
            ? """
            SELECT m.id, m.seq AS time_created, json_object('role', m.type) AS data
            FROM session_message AS m
            WHERE m.session_id = ?1 AND (
                CASE WHEN json_valid(m.data) THEN
                    (m.type IN ('user', 'synthetic', 'system')
                     AND json_type(m.data, '$.text') = 'text'
                     AND length(json_extract(m.data, '$.text')) > 0)
                    OR (m.type = 'assistant' AND EXISTS (
                        SELECT 1 FROM json_each(m.data, '$.content') AS content
                        WHERE content.type = 'object' AND \(inlinePart) = 1
                    ))
                ELSE 0 END
                OR EXISTS (
                    SELECT 1 FROM session_part AS p
                    WHERE p.message_id = m.id AND p.session_id = m.session_id
                      AND \(renderablePart) = 1
                )
            )
            ORDER BY m.seq DESC, m.id DESC LIMIT ?2
            """
            : """
            SELECT m.id, m.time_created, m.data FROM message AS m
            WHERE m.session_id = ?1 AND EXISTS (
                SELECT 1 FROM part AS p
                WHERE p.message_id = m.id AND p.session_id = m.session_id
                  AND \(renderablePart) = 1
            )
            ORDER BY m.time_created DESC, m.id DESC LIMIT ?2
            """
        // Choose the bounded message window before expanding parts. V2 may store
        // content inline, in ordinal rows, or as ordinal rows followed by inline
        // content after a downgrade/re-upgrade. Normalize only retained bytes below.
        let sources =
            isV2
            ? """
            SELECT m.id AS message_id, m.session_id, -1 AS id, -1 AS time_created,
                   json_object('type', 'text', 'text', json_extract(m.data, '$.text')) AS data
            FROM ranked_messages AS r CROSS JOIN session_message AS m ON m.id = r.id
            WHERE r.turn_rank <= ?3 AND m.session_id = ?1
              AND m.type IN ('user', 'synthetic', 'system') AND json_valid(m.data)
            UNION ALL
            SELECT p.message_id, p.session_id, p.ordinal AS id, p.ordinal AS time_created, p.data
            FROM ranked_messages AS r CROSS JOIN session_part AS p ON p.message_id = r.id
            WHERE r.turn_rank <= ?3 AND p.session_id = ?1
            UNION ALL
            SELECT m.id AS message_id, m.session_id, CAST(content.key AS INTEGER) AS id,
                   (SELECT COALESCE(MAX(ordinal) + 1, 0) FROM session_part
                    WHERE message_id = m.id AND session_id = ?1) + CAST(content.key AS INTEGER) AS time_created,
                   content.value AS data
            FROM ranked_messages AS r CROSS JOIN session_message AS m ON m.id = r.id
            JOIN json_each(CASE WHEN json_valid(m.data) THEN m.data ELSE '{}' END, '$.content') AS content
            WHERE r.turn_rank <= ?3 AND m.session_id = ?1 AND m.type = 'assistant'
              AND content.type = 'object'
            """
            : "SELECT id, message_id, session_id, time_created, data FROM part WHERE session_id = ?1"
        // V2's UNION must stream as a coroutine. V1's simple table source must
        // stay behind the ranked window so its session index bounds the lookup.
        let partJoin =
            isV2
            ? "source_parts AS p CROSS JOIN ranked_messages AS r"
            : "ranked_messages AS r JOIN part AS p"
        let sql = """
            WITH candidate_messages AS (\(candidateMessages)), ranked_messages AS (
                SELECT id, time_created, data,
                       ROW_NUMBER() OVER (ORDER BY time_created DESC, id DESC) AS turn_rank,
                       (SELECT COUNT(*) FROM candidate_messages) AS candidate_count
                FROM candidate_messages
            ), source_parts AS (\(sources))
            SELECT r.id,
                   CASE WHEN octet_length(r.data) <= ?4 THEN r.data ELSE NULL END,
                   CASE WHEN octet_length(p.data) <= ?5 THEN p.data ELSE NULL END,
                   octet_length(p.data),
                   r.candidate_count
            FROM \(partJoin) ON p.message_id = r.id AND p.session_id = ?1
            WHERE r.turn_rank <= ?3 AND \(renderablePart) = 1
            ORDER BY r.time_created DESC, r.id DESC, p.time_created DESC, p.id DESC
            LIMIT ?6
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else {
            return .failure(.databaseUnavailable)
        }
        defer { sqlite3_finalize(statement) }
        guard bind(sessionID, to: 1, in: statement) == SQLITE_OK,
            sqlite3_bind_int(statement, 2, Int32(clamping: turnLimit + 1)) == SQLITE_OK,
            sqlite3_bind_int(statement, 3, Int32(clamping: turnLimit)) == SQLITE_OK,
            sqlite3_bind_int(statement, 4, Int32(clamping: maximumMessageBytes)) == SQLITE_OK,
            sqlite3_bind_int(statement, 5, Int32(clamping: maximumPartBytes)) == SQLITE_OK,
            sqlite3_bind_int(statement, 6, Int32(clamping: partLimit + 1)) == SQLITE_OK
        else {
            return .failure(.databaseUnavailable)
        }

        var descendingMessages: [OpenCodeTranscriptSnapshot.Message] = []
        var rowCount = 0
        var candidateCount = 0
        var sourceByteCount = 0
        var sourceBudgetExceeded = false
        var currentID: String?
        var currentData: Data?
        var currentParts: [OpenCodeTranscriptSnapshot.Part] = []

        func flushCurrentMessage() {
            guard let currentID else { return }
            descendingMessages.append(
                OpenCodeTranscriptSnapshot.Message(id: currentID, data: currentData, parts: currentParts)
            )
        }
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { return .failure(.databaseUnavailable) }
            rowCount += 1
            candidateCount = max(candidateCount, Int(sqlite3_column_int(statement, 4)))
            guard rowCount <= partLimit else { continue }

            let id = string(at: 0, in: statement)
            let isNewMessage = currentID != id
            let retainedRowBytes =
                Int(sqlite3_column_bytes(statement, 2))
                + (isNewMessage ? Int(sqlite3_column_bytes(statement, 1)) : 0)
            guard retainedRowBytes <= sourceByteLimit - sourceByteCount else {
                sourceBudgetExceeded = true
                break
            }
            sourceByteCount += retainedRowBytes

            let part = OpenCodeTranscriptSnapshot.Part(
                data: normalizedPart(data(at: 2, in: statement), isV2: isV2),
                byteCount: Int(sqlite3_column_int64(statement, 3))
            )
            if currentID == id {
                currentParts.append(part)
            } else {
                flushCurrentMessage()
                currentID = id
                currentData = data(at: 1, in: statement)
                currentParts = [part]
            }
        }
        flushCurrentMessage()

        let messages = descendingMessages.reversed().map { message in
            OpenCodeTranscriptSnapshot.Message(
                id: message.id,
                data: message.data,
                parts: message.parts.reversed()
            )
        }
        return .success(
            OpenCodeTranscriptSnapshot(
                databaseURL: databaseURL,
                messages: messages,
                isTruncated: candidateCount > turnLimit || rowCount > partLimit
                    || sourceBudgetExceeded
            )
        )
    }

    private static func normalizedPart(_ data: Data?, isV2: Bool) -> Data? {
        guard isV2, let data,
            var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            object["type"] as? String == "tool"
        else { return data }
        object["tool"] = object.removeValue(forKey: "name")
        if var state = object["state"] as? [String: Any] {
            state["output"] = state.removeValue(forKey: "content")
            object["state"] = state
        }
        return try? JSONSerialization.data(withJSONObject: object)
    }

    private static func tableExists(_ name: String, database: OpaquePointer) -> Bool {
        var statement: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                database, "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?1", -1, &statement, nil
            ) == SQLITE_OK, let statement
        else { return false }
        defer { sqlite3_finalize(statement) }
        guard bind(name, to: 1, in: statement) == SQLITE_OK else { return false }
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private static func sessionExists(
        database: OpaquePointer,
        sessionID: String,
        table: String
    ) -> Result<Bool, AgentTranscriptUnavailable> {
        var statement: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                database, "SELECT 1 FROM \(table) WHERE id = ?1 LIMIT 1", -1, &statement, nil
            ) == SQLITE_OK,
            let statement
        else {
            return .failure(.databaseUnavailable)
        }
        defer { sqlite3_finalize(statement) }
        guard bind(sessionID, to: 1, in: statement) == SQLITE_OK else {
            return .failure(.databaseUnavailable)
        }
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return .success(true)
        case SQLITE_DONE: return .success(false)
        default: return .failure(.databaseUnavailable)
        }
    }

    private static func bind(_ value: String, to index: Int32, in statement: OpaquePointer) -> Int32 {
        value.withCString { pointer in
            sqlite3_bind_text(
                statement,
                index,
                pointer,
                -1,
                unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            )
        }
    }

    private static func string(at index: Int32, in statement: OpaquePointer) -> String {
        guard let text = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: text)
    }

    private static func data(at index: Int32, in statement: OpaquePointer) -> Data? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
            let bytes = sqlite3_column_blob(statement, index)
        else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index)))
    }
}
