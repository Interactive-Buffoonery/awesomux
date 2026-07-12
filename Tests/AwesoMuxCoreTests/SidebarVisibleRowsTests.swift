import Testing
@testable import AwesoMuxCore

@Suite("Sidebar visible rows")
struct SidebarVisibleRowsTests {
    @Test("visible row walk includes groups and expanded sessions")
    func rowsIncludeGroupsAndExpandedSessions() {
        let fixture = makeEntries()

        let rows = SidebarVisibleRows.rows(
            for: fixture.entries,
            collapsedGroupIDs: [],
            isFiltering: false
        )

        #expect(rows.map(\.target) == [
            .group(fixture.firstGroup.id),
            .session(fixture.firstSession.id),
            .session(fixture.secondSession.id),
            .group(fixture.secondGroup.id),
            .session(fixture.thirdSession.id)
        ])
    }

    @Test("visible row walk hides sessions inside collapsed groups unless filtering")
    func collapsedGroupsHideSessionsUnlessFiltering() {
        let fixture = makeEntries()

        let collapsedRows = SidebarVisibleRows.rows(
            for: fixture.entries,
            collapsedGroupIDs: [fixture.firstGroup.id],
            isFiltering: false
        )
        #expect(collapsedRows.map(\.target) == [
            .group(fixture.firstGroup.id),
            .group(fixture.secondGroup.id),
            .session(fixture.thirdSession.id)
        ])

        let filteringRows = SidebarVisibleRows.rows(
            for: fixture.entries,
            collapsedGroupIDs: [fixture.firstGroup.id],
            isFiltering: true
        )
        #expect(filteringRows.contains { $0.target == .session(fixture.firstSession.id) })
    }

    @Test("keyboard walk clamps at the visible row boundaries")
    func keyboardWalkClamps() {
        let fixture = makeEntries()
        let rows = SidebarVisibleRows.rows(
            for: fixture.entries,
            collapsedGroupIDs: [],
            isFiltering: false
        )

        #expect(SidebarVisibleRows.target(after: nil, in: rows, offset: 1) == rows.first?.target)
        #expect(SidebarVisibleRows.target(after: nil, in: rows, offset: -1) == rows.last?.target)
        #expect(SidebarVisibleRows.target(after: rows.first?.target, in: rows, offset: -1) == rows.first?.target)
        #expect(SidebarVisibleRows.target(after: rows.last?.target, in: rows, offset: 1) == rows.last?.target)
        #expect(
            SidebarVisibleRows.target(
                after: .session(fixture.firstSession.id),
                in: rows,
                offset: 1
            ) == .session(fixture.secondSession.id)
        )
    }

    @Test("rotor entries include workspaces inside collapsed groups")
    func rotorEntriesIncludeCollapsedGroupSessions() {
        let fixture = makeEntries()

        let rotorEntries = SidebarVisibleRows.rotorEntries(for: fixture.entries)

        // Collapse-independent by construction (the function takes no collapse
        // input): every session enumerates, in source order.
        #expect(rotorEntries.map(\.id) == [
            fixture.firstSession.id,
            fixture.secondSession.id,
            fixture.thirdSession.id
        ])
    }

    @Test("rotor label carries title + agent + state, not just the title")
    func rotorLabelIncludesAgentAndState() {
        let session = TerminalSession(
            title: "Linear",
            workingDirectory: "~",
            agentKind: .claudeCode,
            agentState: .running
        )
        #expect(SidebarVisibleRows.rotorLabel(for: session) == "Linear, Claude, Running")

        // A shell reads through effectiveChromeState (idle when not busy).
        let shell = TerminalSession(title: "build", workingDirectory: "~", agentKind: .shell)
        #expect(SidebarVisibleRows.rotorLabel(for: shell) == "build, Shell, Idle")

        // needs-attention reads "Needs input" — the same wording the sidebar row
        // and peek card speak (the two label vocabularies are kept in sync; see
        // AgentStateDesignSystemTests).
        let needsInput = TerminalSession(
            title: "review",
            workingDirectory: "~",
            agentKind: .claudeCode,
            agentExecutionState: .idle,
            attentionReason: .permissionPrompt
        )
        #expect(SidebarVisibleRows.rotorLabel(for: needsInput) == "review, Claude, Needs input")
    }

    @Test("rotor label lets the selected locale reorder title, agent, and state")
    func rotorLabelUsesLocalizedGrammar() throws {
        let bundle = try #require(INT612LocalizationTestSupport.bundle)
        let shell = TerminalSession(
            title: "build",
            workingDirectory: "~",
            agentKind: .shell,
            shellActivity: .busy
        )

        #expect(SidebarVisibleRows.rotorLabel(
            for: shell,
            bundle: bundle,
            locale: INT612LocalizationTestSupport.french
        ) == "En cours — build — Terminal")
    }

    @Test("rotor label localizes a synthetic title with the selected locale")
    func rotorLabelUsesSelectedLocaleForSyntheticTitle() throws {
        let bundle = try #require(INT612LocalizationTestSupport.bundle)
        let syntheticTitle = SyntheticSessionTitle(agentKind: .shell, index: 2)
        let shell = TerminalSession(
            title: syntheticTitle.canonicalTitle,
            workingDirectory: "~",
            syntheticTitle: syntheticTitle,
            agentKind: .shell
        )

        #expect(SidebarVisibleRows.rotorLabel(
            for: shell,
            bundle: bundle,
            locale: INT612LocalizationTestSupport.french
        ) == "Inactif — 2 coquille — Terminal")
    }

    @Test("rotor enumerates exactly the filtered projection it is given")
    func rotorEntriesEnumerateFilteredProjection() {
        let fixture = makeEntries()

        // Simulate a search projection that matched only the second session in
        // the first group (the upstream filter already narrowed `entries`).
        let filtered = [
            SidebarGroupEntry(
                group: fixture.firstGroup,
                unfilteredIndex: 0,
                sessions: [SidebarSessionEntry(session: fixture.secondSession, match: nil)]
            )
        ]

        let rotorEntries = SidebarVisibleRows.rotorEntries(for: filtered)

        #expect(rotorEntries.map(\.id) == [fixture.secondSession.id])
        #expect(rotorEntries.first?.label == SidebarVisibleRows.rotorLabel(for: fixture.secondSession))
    }
}

private func makeEntries() -> (
    entries: [SidebarGroupEntry],
    firstGroup: SessionGroup,
    secondGroup: SessionGroup,
    firstSession: TerminalSession,
    secondSession: TerminalSession,
    thirdSession: TerminalSession
) {
    let firstSession = TerminalSession(title: "first", workingDirectory: "~", agentKind: .shell)
    let secondSession = TerminalSession(title: "second", workingDirectory: "~", agentKind: .shell)
    let thirdSession = TerminalSession(title: "third", workingDirectory: "~", agentKind: .shell)
    let firstGroup = SessionGroup(name: "main", sessions: [firstSession, secondSession])
    let secondGroup = SessionGroup(name: "scratch", sessions: [thirdSession])
    let entries = [
        SidebarGroupEntry(
            group: firstGroup,
            unfilteredIndex: 0,
            sessions: firstGroup.sessions.map { SidebarSessionEntry(session: $0, match: nil) }
        ),
        SidebarGroupEntry(
            group: secondGroup,
            unfilteredIndex: 1,
            sessions: secondGroup.sessions.map { SidebarSessionEntry(session: $0, match: nil) }
        )
    ]

    return (entries, firstGroup, secondGroup, firstSession, secondSession, thirdSession)
}
