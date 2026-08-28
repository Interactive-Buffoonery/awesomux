import Darwin
import Foundation
import SQLite3

/// Reads a bounded OpenCode session snapshot directly from its live SQLite store.
public enum OpenCodeTranscriptDatabase {
    static let databaseFileName = "opencode.db"
    public static let maximumTurns = 256
    public static let maximumParts = 4_096
    static let maximumPartBytes = 256 * 1_024
    static let maximumMessageBytes = 64 * 1_024

    public static func read(
        dataHome: URL,
        sessionID: String,
        maximumTurns: Int = maximumTurns,
        maximumParts: Int = maximumParts,
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

        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &database, flags, nil) == SQLITE_OK,
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

        switch sessionExists(database: database, sessionID: sessionID) {
        case .success(false): return .failure(.notFound)
        case .failure: return .failure(.databaseUnavailable)
        case .success(true): break
        }

        let turnLimit = min(max(1, maximumTurns), Int(Int32.max) - 1)
        let partLimit = min(max(1, maximumParts), Int(Int32.max) - 1)
        let renderablePart = """
            CASE WHEN json_valid(p.data) THEN
                CASE
                    WHEN json_extract(p.data, '$.type') IN ('text', 'reasoning')
                        THEN json_type(p.data, '$.text') = 'text'
                            AND length(json_extract(p.data, '$.text')) > 0
                    WHEN json_extract(p.data, '$.type') = 'tool'
                        THEN COALESCE(json_type(p.data, '$.state.output'), 'null') != 'null'
                            OR COALESCE(json_type(p.data, '$.state.input'), 'null') != 'null'
                    ELSE 0
                END
            ELSE 0 END
            """
        let sql = """
            WITH candidate_messages AS (
                SELECT m.id, m.time_created, m.data
                FROM message AS m
                WHERE m.session_id = ?1
                  AND EXISTS (
                      SELECT 1
                      FROM part AS p
                      WHERE p.message_id = m.id
                        AND p.session_id = m.session_id
                        AND \(renderablePart) = 1
                  )
                ORDER BY m.time_created DESC, m.id DESC
                LIMIT ?2
            ), ranked_messages AS (
                SELECT id, time_created, data,
                       ROW_NUMBER() OVER (ORDER BY time_created DESC, id DESC) AS turn_rank,
                       (SELECT COUNT(*) FROM candidate_messages) AS candidate_count
                FROM candidate_messages
            )
            SELECT r.id,
                   CASE WHEN length(r.data) <= ?4 THEN r.data ELSE NULL END,
                   CASE WHEN length(p.data) <= ?5 THEN p.data ELSE NULL END,
                   length(p.data),
                   r.candidate_count
            FROM ranked_messages AS r
            JOIN part AS p ON p.message_id = r.id
            WHERE r.turn_rank <= ?3
              AND \(renderablePart) = 1
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
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { return .failure(.databaseUnavailable) }
            rowCount += 1
            candidateCount = max(candidateCount, Int(sqlite3_column_int(statement, 4)))
            guard rowCount <= partLimit else { continue }

            let id = string(at: 0, in: statement)
            let messageData = data(at: 1, in: statement)
            let part = OpenCodeTranscriptSnapshot.Part(
                data: data(at: 2, in: statement),
                byteCount: Int(sqlite3_column_int64(statement, 3))
            )
            if descendingMessages.last?.id == id {
                var message = descendingMessages.removeLast()
                message = OpenCodeTranscriptSnapshot.Message(
                    id: message.id,
                    data: message.data,
                    parts: message.parts + [part]
                )
                descendingMessages.append(message)
            } else {
                descendingMessages.append(
                    OpenCodeTranscriptSnapshot.Message(id: id, data: messageData, parts: [part])
                )
            }
        }

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
            )
        )
    }

    private static func sessionExists(
        database: OpaquePointer,
        sessionID: String
    ) -> Result<Bool, AgentTranscriptUnavailable> {
        var statement: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                database, "SELECT 1 FROM session WHERE id = ?1 LIMIT 1", -1, &statement, nil
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
