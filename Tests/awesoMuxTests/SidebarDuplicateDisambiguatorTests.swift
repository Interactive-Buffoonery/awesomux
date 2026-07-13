import AwesoMuxCore
import Testing
@testable import awesoMux

@Suite("SidebarDuplicateDisambiguator")
struct SidebarDuplicateDisambiguatorTests {
    @Test("duplicate titles with different visible directories need no ordinal")
    func duplicateTitlesWithDifferentDirectoriesNeedNoOrdinal() {
        let first = makeSession(title: "agent", workingDirectory: "/tmp/awesomux")
        let second = makeSession(title: "agent", workingDirectory: "/tmp/ghostling")
        let entries = [makeEntry(sessions: [first, second])]

        let disambiguation = SidebarDuplicateDisambiguator
            .disambiguationBySessionID(for: entries)

        #expect(disambiguation.isEmpty)
    }

    @Test("exact duplicate visible identities in one group get stable ordinals")
    func exactDuplicateVisibleIdentitiesGetOrdinals() {
        let first = makeSession(title: "agent", workingDirectory: "/tmp/awesomux")
        let second = makeSession(title: "agent", workingDirectory: "/tmp/awesomux")
        let entries = [makeEntry(sessions: [first, second])]

        let disambiguation = SidebarDuplicateDisambiguator
            .disambiguationBySessionID(for: entries)

        #expect(disambiguation[first.id] == SidebarDuplicateDisambiguation(ordinal: 1, total: 2))
        #expect(disambiguation[second.id] == SidebarDuplicateDisambiguation(ordinal: 2, total: 2))
        #expect(disambiguation[second.id]?.visibleLabel == "2 of 2")
        #expect(disambiguation[second.id]?.accessibilitySuffix == "duplicate workspace, copy 2 of 2")
    }

    @Test("same title and directory in different groups get no ordinal")
    func crossGroupDuplicatesGetNoOrdinal() {
        // Identity is group-scoped: the group header already separates these
        // rows, and group-scoping is what stops a collapsed group from skewing a
        // visible group's count.
        let first = makeSession(title: "agent", workingDirectory: "/tmp/awesomux")
        let second = makeSession(title: "agent", workingDirectory: "/tmp/awesomux")
        let entries = [
            makeEntry(groupName: "Work", sessions: [first], unfilteredIndex: 0),
            makeEntry(groupName: "Scratch", sessions: [second], unfilteredIndex: 1)
        ]

        let disambiguation = SidebarDuplicateDisambiguator
            .disambiguationBySessionID(for: entries)

        #expect(disambiguation.isEmpty)
    }

    @Test("homoglyph title variants are treated as the same identity")
    func homoglyphTitleVariantsCollapseToSameIdentity() {
        // Zero-width space appended to one title; both sanitize to "agent", so
        // they're correctly recognized as duplicates rather than masquerading as
        // distinct rows.
        let first = makeSession(title: "agent", workingDirectory: "/tmp/awesomux")
        let second = makeSession(title: "agent\u{200B}", workingDirectory: "/tmp/awesomux")
        let entries = [makeEntry(sessions: [first, second])]

        let disambiguation = SidebarDuplicateDisambiguator
            .disambiguationBySessionID(for: entries)

        #expect(disambiguation[first.id]?.total == 2)
        #expect(disambiguation[second.id]?.total == 2)
    }

    @Test("same-title remote sessions on the same host get ordinals")
    func sameTitleRemoteSessionsOnSameHostGetOrdinals() {
        let first = makeSession(
            title: "agent",
            workingDirectory: "/tmp/local-before-ssh",
            remoteHost: "devbox"
        )
        let second = makeSession(
            title: "agent",
            workingDirectory: "/tmp/other-local-before-ssh",
            remoteHost: "devbox"
        )
        let entries = [makeEntry(sessions: [first, second])]

        let disambiguation = SidebarDuplicateDisambiguator
            .disambiguationBySessionID(for: entries)

        #expect(disambiguation[first.id] == SidebarDuplicateDisambiguation(ordinal: 1, total: 2))
        #expect(disambiguation[second.id] == SidebarDuplicateDisambiguation(ordinal: 2, total: 2))
    }

    @Test("same-title remote sessions on different hosts get no ordinal")
    func sameTitleRemoteSessionsOnDifferentHostsGetNoOrdinal() {
        let first = makeSession(
            title: "agent",
            workingDirectory: "/tmp/local-before-ssh",
            remoteHost: "devbox"
        )
        let second = makeSession(
            title: "agent",
            workingDirectory: "/tmp/local-before-ssh",
            remoteHost: "buildbox"
        )
        let entries = [makeEntry(sessions: [first, second])]

        let disambiguation = SidebarDuplicateDisambiguator
            .disambiguationBySessionID(for: entries)

        #expect(disambiguation.isEmpty)
    }

    @Test("local and remote matching display strings get no ordinal")
    func localAndRemoteMatchingDisplayStringsGetNoOrdinal() {
        let local = makeSession(title: "agent", workingDirectory: "devbox")
        let remote = makeSession(
            title: "agent",
            workingDirectory: "/tmp/local-before-ssh",
            remoteHost: "devbox"
        )
        let entries = [makeEntry(sessions: [local, remote])]

        let disambiguation = SidebarDuplicateDisambiguator
            .disambiguationBySessionID(for: entries)

        #expect(disambiguation.isEmpty)
    }

    private func makeEntry(
        groupName: String = "Work",
        sessions: [TerminalSession],
        unfilteredIndex: Int = 0
    ) -> SidebarGroupEntry {
        SidebarGroupEntry(
            group: SessionGroup(name: groupName, sessions: sessions),
            unfilteredIndex: unfilteredIndex,
            sessions: sessions.map { SidebarSessionEntry(session: $0, match: nil) }
        )
    }

    private func makeSession(
        title: String,
        workingDirectory: String,
        remoteHost: String? = nil
    ) -> TerminalSession {
        let pane = TerminalPane(
            title: title,
            workingDirectory: workingDirectory,
            remoteHost: remoteHost,
            executionPlan: .local
        )
        return TerminalSession(
            title: title,
            workingDirectory: workingDirectory,
            agentKind: .claudeCode,
            agentState: .running,
            layout: .pane(pane),
            activePaneID: pane.id
        )
    }
}
