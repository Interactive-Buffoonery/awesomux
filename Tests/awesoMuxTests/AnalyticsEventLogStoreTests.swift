import AwesoMuxConfig
import Foundation
import Testing

@testable import awesoMux

@MainActor
@Suite("AnalyticsEventLogStore")
struct AnalyticsEventLogStoreTests {
    private static func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "analytics-log-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func entry(
        timestamp: Date = Date(timeIntervalSince1970: 1_700_000_000),
        name: AnalyticsEventName = .testPing
    ) -> AnalyticsLogEntry {
        AnalyticsLogEntry(
            id: UUID(),
            timestamp: timestamp,
            name: name,
            consentLevel: .errorReports,
            properties: [.schemaVersion: .integer(1), .consentLevel: .token("error_reports")],
            status: .dropped,
            dropReason: .deliveryUnavailable,
            provider: "posthog",
            schemaVersion: 1
        )
    }

    @Test("append and reload round-trip")
    func appendReload() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixedNow = Date(timeIntervalSince1970: 1_700_000_100)

        let store = AnalyticsEventLogStore(rootDirectoryURL: root, now: { fixedNow })
        let entry = Self.entry()
        store.append(entry)
        store.waitForPendingWrites()

        let reloaded = AnalyticsEventLogStore(rootDirectoryURL: root, now: { fixedNow })
        reloaded.loadIfNeeded()
        #expect(reloaded.entries == [entry])
    }

    @Test("numeric-looking versions round-trip with their wire tags")
    func numericVersionRoundTrip() throws {
        let entry = AnalyticsLogEntry(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            name: .appLaunched,
            consentLevel: .productUsage,
            properties: [
                .appVersion: .version("0"),
                .buildNumber: .version("1"),
                .macosVersionMajor: .integer(15),
                .macosVersionMinor: .integer(5),
                .cpuArch: .token("arm64"),
                .schemaVersion: .integer(analyticsSchemaVersion),
                .consentLevel: .token("product_usage"),
            ],
            status: .dropped,
            dropReason: .deliveryUnavailable,
            provider: "posthog",
            schemaVersion: analyticsSchemaVersion
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let encoded = try encoder.encode(entry)
        let decoded = try decoder.decode(AnalyticsLogEntry.self, from: encoded)

        #expect(decoded.properties[.appVersion] == .version("0"))
        #expect(decoded.properties[.buildNumber] == .version("1"))
    }

    @Test("prunes by age and count")
    func pruning() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

        let store = AnalyticsEventLogStore(rootDirectoryURL: root, now: { fixedNow })
        store.append(Self.entry(timestamp: fixedNow.addingTimeInterval(-31 * 86_400)))
        store.append(Self.entry(timestamp: fixedNow))
        #expect(store.entries.count == 1)

        for _ in 0..<(AnalyticsEventLogStore.maximumEntries + 10) {
            store.append(Self.entry(timestamp: fixedNow))
        }
        #expect(store.entries.count <= AnalyticsEventLogStore.maximumEntries)
        #expect(store.entries.count > AnalyticsEventLogStore.maximumEntries - AnalyticsEventLogStore.trimBatch - 11)
    }

    @Test("malformed lines are skipped on load")
    func malformedLineSkipped() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixedNow = Date(timeIntervalSince1970: 1_700_000_100)

        let store = AnalyticsEventLogStore(rootDirectoryURL: root, now: { fixedNow })
        store.append(Self.entry())
        store.waitForPendingWrites()

        let eventsURL = root.appending(path: "analytics/events.jsonl")
        let handle = try FileHandle(forWritingTo: eventsURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("not json\n".utf8))
        try handle.close()

        let reloaded = AnalyticsEventLogStore(rootDirectoryURL: root, now: { fixedNow })
        reloaded.loadIfNeeded()
        #expect(reloaded.entries.count == 1)
    }

    @Test("tampered line with non-allowlisted value is rejected on load")
    func tamperedLineRejected() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixedNow = Date(timeIntervalSince1970: 1_700_000_100)

        let store = AnalyticsEventLogStore(rootDirectoryURL: root, now: { fixedNow })
        store.append(Self.entry())
        store.waitForPendingWrites()

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var tampered = try #require(
            String(data: try encoder.encode(Self.entry()), encoding: .utf8)
        )
        tampered = tampered.replacingOccurrences(of: "error_reports", with: "/Users/example/secret")
        let eventsURL = root.appending(path: "analytics/events.jsonl")
        let handle = try FileHandle(forWritingTo: eventsURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((tampered + "\n").utf8))
        try handle.close()

        let reloaded = AnalyticsEventLogStore(rootDirectoryURL: root, now: { fixedNow })
        reloaded.loadIfNeeded()
        #expect(reloaded.entries.count == 1)
        let allValues = reloaded.entries.flatMap(\.properties.values).map(\.displayValue)
        #expect(!allValues.contains { $0.contains("/") })
    }

    @Test("tampered closed token is rejected on load")
    func tamperedClosedTokenRejected() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let analyticsDir = root.appending(path: "analytics", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: analyticsDir, withIntermediateDirectories: true)
        let tampered = AnalyticsLogEntry(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            name: .agentSessionStarted,
            consentLevel: .productUsage,
            properties: [
                .agentKind: .token("sarah"),
                .schemaVersion: .integer(analyticsSchemaVersion),
                .consentLevel: .token("product_usage"),
            ],
            status: .dropped,
            dropReason: .invalidPropertyValue,
            provider: "posthog",
            schemaVersion: analyticsSchemaVersion
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(tampered).write(
            to: analyticsDir.appending(path: "events.jsonl"),
            options: .atomic
        )

        let store = AnalyticsEventLogStore(rootDirectoryURL: root)
        store.loadIfNeeded()
        store.waitForPendingWrites()

        #expect(store.entries.isEmpty)
    }

    @Test("direct append cannot bypass property validation")
    func directAppendPrivacyGate() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AnalyticsEventLogStore(rootDirectoryURL: root)
        let unsafe = AnalyticsLogEntry(
            id: UUID(),
            timestamp: Date(),
            name: .testPing,
            consentLevel: .errorReports,
            properties: [.agentKind: .token("sarah")],
            status: .dropped,
            dropReason: .invalidPropertyValue,
            provider: "posthog",
            schemaVersion: analyticsSchemaVersion
        )

        store.append(unsafe)
        store.waitForPendingWrites()

        #expect(store.entries.isEmpty)
        #expect(
            !FileManager.default.fileExists(
                atPath: root.appending(path: "analytics/events.jsonl").path
            )
        )
    }

    @Test("tampered line with a value in the wrong property shape is rejected")
    func tamperedPropertyShapeRejected() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let analyticsDir = root.appending(path: "analytics", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: analyticsDir, withIntermediateDirectories: true)

        let tampered = AnalyticsLogEntry(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            name: .testPing,
            consentLevel: .errorReports,
            properties: [.schemaVersion: .token("wrong")],
            status: .dropped,
            dropReason: .invalidPropertyValue,
            provider: "posthog",
            schemaVersion: analyticsSchemaVersion
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(tampered).write(
            to: analyticsDir.appending(path: "events.jsonl"),
            options: .atomic
        )

        let store = AnalyticsEventLogStore(rootDirectoryURL: root)
        store.loadIfNeeded()
        store.waitForPendingWrites()
        #expect(store.entries.isEmpty)
    }

    @Test("deleteAll removes log and distinct id")
    func deleteAll() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = AnalyticsEventLogStore(rootDirectoryURL: root)
        store.append(Self.entry())
        let firstID = store.distinctID()
        #expect(UUID(uuidString: firstID) != nil)

        store.deleteAll()
        store.waitForPendingWrites()
        #expect(store.entries.isEmpty)
        let analyticsDir = root.appending(path: "analytics")
        #expect(!FileManager.default.fileExists(atPath: analyticsDir.appending(path: "events.jsonl").path))
        #expect(!FileManager.default.fileExists(atPath: analyticsDir.appending(path: "distinct_id").path))

        let secondID = store.distinctID()
        #expect(secondID != firstID)
    }

    @Test("distinct id is stable until deleted")
    func distinctIDStable() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = AnalyticsEventLogStore(rootDirectoryURL: root)
        #expect(store.distinctID() == store.distinctID())

        let reloaded = AnalyticsEventLogStore(rootDirectoryURL: root)
        #expect(reloaded.distinctID() == store.distinctID())
    }

    @Test("log, distinct id, and directory stay owner-only")
    func ownerOnlyPermissions() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = AnalyticsEventLogStore(rootDirectoryURL: root)
        store.append(Self.entry())
        store.waitForPendingWrites()
        _ = store.distinctID()

        let analyticsDir = root.appending(path: "analytics")
        func posixPermissions(_ url: URL) throws -> Int {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return try #require(attributes[.posixPermissions] as? Int)
        }
        #expect(try posixPermissions(analyticsDir) == 0o700)
        #expect(try posixPermissions(analyticsDir.appending(path: "events.jsonl")) == 0o600)
        #expect(try posixPermissions(analyticsDir.appending(path: "distinct_id")) == 0o600)
    }

    @Test("retain=false keeps entries in memory only")
    func retainOffWritesNothing() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = AnalyticsEventLogStore(
            rootDirectoryURL: root,
            retainToDisk: { false },
            now: { Date(timeIntervalSince1970: 1_700_000_100) }
        )
        store.append(Self.entry())
        store.waitForPendingWrites()
        #expect(store.entries.count == 1)
        #expect(
            !FileManager.default.fileExists(
                atPath: root.appending(path: "analytics/events.jsonl").path
            ))
    }

    @Test("retain=false removes a stale log instead of loading it")
    func retainOffRemovesStaleLog() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixedNow = Date(timeIntervalSince1970: 1_700_000_100)
        let retained = AnalyticsEventLogStore(rootDirectoryURL: root, now: { fixedNow })
        retained.append(Self.entry())
        retained.waitForPendingWrites()
        let eventsURL = root.appending(path: "analytics/events.jsonl")
        #expect(FileManager.default.fileExists(atPath: eventsURL.path))

        let memoryOnly = AnalyticsEventLogStore(
            rootDirectoryURL: root,
            retainToDisk: { false },
            now: { fixedNow }
        )
        memoryOnly.loadIfNeeded()

        #expect(memoryOnly.entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: eventsURL.path))
    }

    @Test("retention reconciliation removes stale disk state without loading it")
    func reconcileRetentionRemovesStaleLog() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixedNow = Date(timeIntervalSince1970: 1_700_000_100)
        let retained = AnalyticsEventLogStore(rootDirectoryURL: root, now: { fixedNow })
        retained.append(Self.entry())
        retained.waitForPendingWrites()

        var retain = false
        let store = AnalyticsEventLogStore(
            rootDirectoryURL: root,
            retainToDisk: { retain },
            now: { fixedNow }
        )
        store.reconcileRetention()
        store.waitForPendingWrites()

        let eventsURL = root.appending(path: "analytics/events.jsonl")
        #expect(store.entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: eventsURL.path))

        retain = true
        store.append(Self.entry())
        store.waitForPendingWrites()
        let reloaded = AnalyticsEventLogStore(rootDirectoryURL: root, now: { fixedNow })
        reloaded.loadIfNeeded()
        #expect(reloaded.entries.count == 1)
    }

    @Test("enabling retention flushes earlier in-memory entries")
    func retainToggleFlushesBacklog() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixedNow = Date(timeIntervalSince1970: 1_700_000_100)

        var retain = false
        let store = AnalyticsEventLogStore(
            rootDirectoryURL: root,
            retainToDisk: { retain },
            now: { fixedNow }
        )
        store.append(Self.entry())
        retain = true
        store.append(Self.entry())
        store.waitForPendingWrites()

        let reloaded = AnalyticsEventLogStore(rootDirectoryURL: root, now: { fixedNow })
        reloaded.loadIfNeeded()
        #expect(reloaded.entries.count == 2)
    }

    @Test("failed rewrite retries the full ledger on the next append")
    func failedRewriteRetries() async throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixedNow = Date(timeIntervalSince1970: 1_700_000_100)
        var retain = false
        let store = AnalyticsEventLogStore(
            rootDirectoryURL: root,
            retainToDisk: { retain },
            now: { fixedNow }
        )
        store.append(Self.entry())

        let analyticsDir = root.appending(path: "analytics", directoryHint: .isDirectory)
        let eventsURL = analyticsDir.appending(path: "events.jsonl", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: eventsURL, withIntermediateDirectories: true)
        retain = true
        store.append(Self.entry())
        store.waitForPendingWrites()
        await Task.yield()

        try FileManager.default.removeItem(at: eventsURL)
        store.append(Self.entry())
        store.waitForPendingWrites()

        let reloaded = AnalyticsEventLogStore(rootDirectoryURL: root, now: { fixedNow })
        reloaded.loadIfNeeded()
        #expect(reloaded.entries.count == 3)
    }

    @Test("oversized log file is discarded, not loaded")
    func oversizedFileDiscarded() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let analyticsDir = root.appending(path: "analytics", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: analyticsDir, withIntermediateDirectories: true)
        let eventsURL = analyticsDir.appending(path: "events.jsonl")
        let handle = try FileHandle(
            forWritingTo: {
                FileManager.default.createFile(atPath: eventsURL.path, contents: nil)
                return eventsURL
            }())
        try handle.truncate(atOffset: UInt64(AnalyticsEventLogStore.maximumFileBytes) + 1)
        try handle.close()

        let store = AnalyticsEventLogStore(rootDirectoryURL: root)
        store.loadIfNeeded()
        #expect(store.entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: eventsURL.path))
    }
}
