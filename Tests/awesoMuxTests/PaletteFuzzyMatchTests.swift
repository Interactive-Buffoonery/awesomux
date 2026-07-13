import AwesoMuxCore
import Foundation
import Testing
@testable import awesoMux

@Suite("Palette fuzzy match")
struct PaletteFuzzyMatchTests {
    @Test("Subsequence matches, contiguous run scores higher")
    func contiguousRunWins() throws {
        let exact = try #require(PaletteSearch.score("split", in: "Split Right"))
        let scattered = try #require(PaletteSearch.score("slt", in: "Split Right"))

        #expect(exact > scattered)
    }

    @Test("No match returns nil")
    func noMatch() {
        #expect(PaletteSearch.score("zzz", in: "Split Right") == nil)
    }

    @Test("> prefix switches to actions-only mode")
    func actionPrefix() {
        let (mode, query) = PaletteSearch.mode(for: "> tog")

        #expect(mode == .actionsOnly)
        #expect(query == "tog")
    }

    @Test("> prefix is actions-only even for shell-like queries")
    func actionPrefixOwnsShellLikeQueries() {
        let (mode, query) = PaletteSearch.mode(for: "> npm test")

        #expect(mode == .actionsOnly)
        #expect(query == "npm test")
    }

    @Test("quick-run detects executable leading token")
    @MainActor
    func quickRunDetectsExecutableLeadingToken() throws {
        let fixture = try QuickRunFixture(executable: "amx-test")
        defer { fixture.cleanup() }
        let result = try #require(PaletteQuickRunDetector.quickRun(
            for: "amx-test --version",
            searchPath: fixture.directory.path,
            homeDirectoryURL: fixture.directory
        ))

        #expect(result.command == "amx-test --version")
        #expect(result.executable == "amx-test")
        #expect(result.resolvedExecutablePath == fixture.executable.path)
    }

    @Test("quick-run refuses reserved palette prefixes")
    func quickRunRefusesReservedPrefixes() throws {
        let fixture = try QuickRunFixture(executable: "npm")
        defer { fixture.cleanup() }

        for query in ["> npm test", "@ npm test", "? npm test"] {
            #expect(PaletteQuickRunDetector.quickRun(
                for: query,
                searchPath: fixture.directory.path,
                homeDirectoryURL: fixture.directory
            ) == nil)
        }
    }

    @Test("quick-run mode suppresses sessions and actions")
    @MainActor
    func quickRunModeSuppressesOtherResults() throws {
        let fixture = try QuickRunFixture(executable: "npm")
        defer { fixture.cleanup() }
        let store = SessionStore(groups: [
            SessionGroup(name: "Code", sessions: [
                TerminalSession(title: "npm workspace", workingDirectory: "/tmp", agentKind: .shell, agentState: .idle)
            ])
        ])

        let results = PaletteSearch.results(
            groups: store.groups,
            commands: PaletteCommandRegistry.commands(
                sessionStore: store,
                availability: .init(),
                actions: .noop
            ),
            rawQuery: "npm test",
            quickRunSearchPath: fixture.directory.path
        )

        #expect(results.mode == .quickRun)
        #expect(results.groups.map(\.title) == ["Quick Run"])
        guard case .quickRun(let result)? = results.flattened.first else {
            Issue.record("Expected quick-run result")
            return
        }
        #expect(result.command == "npm test")
    }

    @Test("Bare query stays unified")
    func unifiedDefault() {
        let (mode, query) = PaletteSearch.mode(for: "rev")

        #expect(mode == .unified)
        #expect(query == "rev")
    }

    @Test("Diacritic- and case-insensitive")
    func folding() {
        #expect(PaletteSearch.score("cafe", in: "Café Workspace") != nil)
        #expect(PaletteSearch.score("SPLIT", in: "split right") != nil)
    }

    @Test("Unified query returns sessions before actions")
    @MainActor
    func unifiedGroupsSessionsBeforeActions() {
        let workspace = TerminalSession(
            title: "Review Branch",
            workingDirectory: "/Users/example/Development/awesomux",
            agentKind: .shell,
            agentState: .idle
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "Code", sessions: [workspace])
        ])
        let commands = PaletteCommandRegistry.commands(
            sessionStore: store,
            availability: .init(),
            actions: .noop
        )

        let results = PaletteSearch.results(
            groups: store.groups,
            commands: commands,
            rawQuery: "review"
        )

        #expect(results.groups.first?.title == "Sessions")
        #expect(results.defaultSelectionIndex == 0)
        guard case .session(let sessionResult)? = results.flattened.first else {
            Issue.record("Expected session result first")
            return
        }
        #expect(sessionResult.sessionID == workspace.id)
    }

    @Test("> mode suppresses sessions")
    @MainActor
    func actionsModeSuppressesSessions() {
        let store = SessionStore(groups: [
            SessionGroup(name: "Code", sessions: [
                TerminalSession(title: "Toggle Work", workingDirectory: "/tmp", agentKind: .shell, agentState: .idle)
            ])
        ])
        let commands = PaletteCommandRegistry.commands(
            sessionStore: store,
            availability: .init(),
            actions: .noop
        )

        let results = PaletteSearch.results(
            groups: store.groups,
            commands: commands,
            rawQuery: "> tog"
        )

        #expect(results.groups.map(\.title) == ["Actions"])
        #expect(results.flattened.allSatisfy { result in
            if case .command = result { return true }
            return false
        })
    }

    @Test("Bare empty query has no default selection")
    @MainActor
    func emptyQueryHasNoDefaultSelection() {
        let store = SessionStore(groups: [
            SessionGroup(name: "Code", sessions: [
                TerminalSession(title: "Main", workingDirectory: "/tmp", agentKind: .shell, agentState: .idle)
            ])
        ])
        let commands = PaletteCommandRegistry.commands(
            sessionStore: store,
            availability: .init(),
            actions: .noop
        )

        let results = PaletteSearch.results(
            groups: store.groups,
            commands: commands,
            rawQuery: ""
        )

        // The bare query shows the session plus the onboarding "Suggested"
        // group, but the core product rule holds: no implicit selection, so a
        // bare Return never jumps a workspace or fires an action.
        #expect(results.groups.contains { $0.title == "Sessions" })
        #expect(results.groups.contains { $0.title == "Suggested" })
        #expect(results.defaultSelectionIndex == nil)
    }

    @Test("Bare actions mode query selects the first action")
    @MainActor
    func bareActionsModeSelectsFirstAction() {
        let store = SessionStore(groups: [])
        let commands = PaletteCommandRegistry.commands(
            sessionStore: store,
            availability: .init(),
            actions: .noop
        )

        let results = PaletteSearch.results(
            groups: store.groups,
            commands: commands,
            rawQuery: ">"
        )

        #expect(results.groups.first?.title == "Actions")
        #expect(results.defaultSelectionIndex == 0)
    }

    @Test("Session results sort by score then original order")
    @MainActor
    func sessionRankingStableTiebreak() {
        let first = TerminalSession(title: "Alpha", workingDirectory: "/tmp/one", agentKind: .shell, agentState: .idle)
        let second = TerminalSession(title: "Apricot", workingDirectory: "/tmp/two", agentKind: .shell, agentState: .idle)
        let stronger = TerminalSession(title: "Project Alpha", workingDirectory: "/tmp/three", agentKind: .shell, agentState: .idle)
        let store = SessionStore(groups: [
            SessionGroup(name: "Code", sessions: [first, second, stronger])
        ])
        let results = PaletteSearch.results(
            groups: store.groups,
            commands: [],
            rawQuery: "al"
        )
        let sessionIDs = results.flattened.compactMap { result -> TerminalSession.ID? in
            if case .session(let session) = result {
                return session.sessionID
            }
            return nil
        }

        #expect(sessionIDs == [first.id, stronger.id])
    }

    @Test("Query matches a parent-folder segment, not just the last path component")
    @MainActor
    func sessionSearchMatchesFullPath() {
        // Regression for a divergence from the sidebar's own inline search:
        // the palette used to score only the session title, the *last*
        // working-directory path component, and the group name — so "dev"
        // never matched a `~/Development/*` workspace unless "dev" also
        // happened to appear in one of those three fields.
        let alpha = TerminalSession(
            title: "Alpha",
            workingDirectory: "/Users/example/Development/alpha",
            agentKind: .shell,
            agentState: .idle
        )
        let beta = TerminalSession(
            title: "Beta",
            workingDirectory: "/Users/example/Development/beta",
            agentKind: .shell,
            agentState: .idle
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "Code", sessions: [alpha, beta])
        ])
        let results = PaletteSearch.results(
            groups: store.groups,
            commands: [],
            rawQuery: "dev"
        )
        let sessionIDs = results.flattened.compactMap { result -> TerminalSession.ID? in
            if case .session(let session) = result {
                return session.sessionID
            }
            return nil
        }

        #expect(Set(sessionIDs) == Set([alpha.id, beta.id]))
    }

    @Test("Empty query respects session limit")
    @MainActor
    func emptyQueryRespectsSessionLimit() {
        let sessions = (1...60).map { index in
            TerminalSession(
                title: "Workspace \(index)",
                workingDirectory: "/tmp/workspace-\(index)",
                agentKind: .shell,
                agentState: .idle
            )
        }
        let store = SessionStore(groups: [
            SessionGroup(name: "Code", sessions: sessions)
        ])
        let results = PaletteSearch.results(
            groups: store.groups,
            commands: [],
            rawQuery: "",
            sessionLimit: 5
        )
        let sessionIDs = results.flattened.compactMap { result -> TerminalSession.ID? in
            if case .session(let session) = result {
                return session.sessionID
            }
            return nil
        }

        #expect(sessionIDs == sessions.prefix(5).map(\.id))
    }
}

private struct QuickRunFixture {
    let directory: URL
    let executable: URL

    init(executable name: String) throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "awesomux-quick-run-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        executable = directory.appending(path: name)
        try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}
