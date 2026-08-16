import AwesoMuxBridgeProtocol
import AwesoMuxConfig
import AwesoMuxTestSupport
import Foundation
import Testing

@testable import AwesoMuxCore
@testable import awesoMux

private let sessionUUID = "5C4B3A29-1817-4655-9443-2211FFEEDDCC"

private func transcriptIdentity(
    _ kind: AgentKind = .claudeCode
) -> AgentTranscriptIdentity {
    // Force-unwrapped: a fixture that stopped validating is a bug in the
    // fixture, not a case under test.
    AgentTranscriptIdentity(agentKind: kind, sessionID: sessionUUID)!
}

/// A transcript tab beside a local terminal, the shape every Resume runs in.
private func transcriptLayout(
    executionPlan: PaneExecutionPlan = .local
) -> (layout: TerminalPaneLayout, tabID: DocumentPane.ID, terminalID: TerminalPane.ID) {
    let terminal = TerminalPane(
        title: "zsh",
        workingDirectory: "/tmp/repo",
        executionPlan: executionPlan
    )
    let tab = DocumentPane(
        fileURL: URL(fileURLWithPath: "/tmp/cache/abc.transcript.md"),
        title: "Claude Code Transcript",
        associatedTerminalPaneID: terminal.id,
        agentTranscriptIdentity: transcriptIdentity()
    )
    let layout = TerminalPaneLayout.split(
        TerminalSplit(
            orientation: .vertical,
            first: .pane(terminal),
            second: .documentGroup(DocumentGroup(tabs: [tab], selectedTabID: tab.id))
        ))
    return (layout, tab.id, terminal.id)
}

/// Records every `sendText` and hands out a scripted sequence of foreground
/// process names, one per probe, so a test can make an agent appear mid-flight.
@MainActor
private final class StagingSpy {
    private var foregroundSequence: [String?]
    private(set) var foregroundProbeCount = 0
    private(set) var sent: [String] = []

    init(foreground: [String?]) {
        self.foregroundSequence = foreground
    }

    func foregroundComm(_: TerminalPane.ID) -> String? {
        defer { foregroundProbeCount += 1 }
        // The last entry repeats, so a two-probe script needs exactly two.
        return foregroundSequence[min(foregroundProbeCount, foregroundSequence.count - 1)]
    }

    func sendText(_ text: String, _: TerminalPane.ID) -> Bool {
        sent.append(text)
        return true
    }
}

@Suite("Agent transcript resume staging", .serialized)
@MainActor
struct AgentTranscriptResumeStagingTests {

    private func stage(
        identity: AgentTranscriptIdentity = transcriptIdentity(),
        layout: TerminalPaneLayout,
        tabID: DocumentPane.ID,
        spy: StagingSpy,
        sessionLogExists:
            @escaping @Sendable (AgentTranscriptIdentity, PaneExecutionPlan, URL) async ->
            Bool = { _, _, _ in true }
    ) async -> AgentTranscriptResumeStaging.Outcome {
        await AgentTranscriptResumeStaging.stage(
            identity: identity,
            documentID: tabID,
            layout: layout,
            integrations: AgentIntegrationsConfig(),
            foregroundComm: { spy.foregroundComm($0) },
            sendText: { spy.sendText($0, $1) },
            sessionLogExists: sessionLogExists
        )
    }

    // MARK: - Foreground recheck (the TOCTOU the detached probe opens)

    /// Detaching the session-log probe is what makes this reachable: the
    /// verdict is decided, a directory walk runs, and an agent can be launched
    /// in that window. A resume command staged at a live agent's prompt is
    /// pasted as CHAT, so eligibility has to be re-earned after the wait.
    @Test("an agent that takes the foreground during the probe blocks the send")
    func recheckDeniesWhenAnAgentTakesTheForegroundDuringTheProbe() async {
        let fixture = transcriptLayout()
        let spy = StagingSpy(foreground: ["-zsh", "claude"])

        let outcome = await stage(layout: fixture.layout, tabID: fixture.tabID, spy: spy)

        #expect(outcome == .unavailable(.agentRunning(.claudeCode)))
        #expect(spy.sent.isEmpty)
        #expect(spy.foregroundProbeCount == 2, "the foreground must be probed on both sides of the wait")
    }

    @Test("a shell prompt that stays idle across the probe stages the command")
    func stagesWhenTheForegroundStaysAShellPrompt() async {
        let fixture = transcriptLayout()
        let spy = StagingSpy(foreground: ["-zsh"])

        let outcome = await stage(layout: fixture.layout, tabID: fixture.tabID, spy: spy)

        #expect(outcome == .staged)
        #expect(spy.sent.count == 1)
        #expect(spy.foregroundProbeCount == 2)
    }

    // MARK: - Separator and in-flight guard

    /// `sendText` writes at the cursor, so without a separator a half-typed
    /// `git stat` composes `git statclaude --resume …` — one plausible-looking
    /// command in a monospace terminal.
    @Test("the staged command is separated from whatever is already at the cursor")
    func stagedCommandIsSeparatedFromWhateverIsAtTheCursor() async {
        let fixture = transcriptLayout()
        let spy = StagingSpy(foreground: ["-zsh"])

        _ = await stage(layout: fixture.layout, tabID: fixture.tabID, spy: spy)

        #expect(spy.sent == [" claude --resume '\(sessionUUID)'"])
        #expect(spy.sent.first?.hasPrefix(AgentTranscriptResumeStaging.cursorSeparator) == true)
    }

    /// Two rapid clicks — or a click plus the menu command, which is why the
    /// guard lives in the shared path rather than in either view's state.
    @Test("a second attempt while the first is still probing stages nothing")
    func aSecondAttemptWhileTheFirstIsProbingIsRefused() async {
        let fixture = transcriptLayout()
        let spy = StagingSpy(foreground: ["-zsh"])
        let gate = ProbeGate()

        async let first = stage(
            layout: fixture.layout,
            tabID: fixture.tabID,
            spy: spy,
            sessionLogExists: { _, _, _ in await gate.wait() }
        )
        await gate.waitUntilProbing()
        let second = await stage(layout: fixture.layout, tabID: fixture.tabID, spy: spy)
        await gate.release()
        let firstOutcome = await first

        #expect(second == .alreadyStaging)
        #expect(firstOutcome == .staged)
        #expect(spy.sent.count == 1, "the payload must reach the terminal exactly once")
    }

    @Test("the in-flight guard is released once the attempt finishes")
    func theInFlightGuardIsReleasedAfterAnAttempt() async {
        let fixture = transcriptLayout()
        let spy = StagingSpy(foreground: ["-zsh"])

        _ = await stage(layout: fixture.layout, tabID: fixture.tabID, spy: spy)
        #expect(!AgentTranscriptResumeStaging.isStaging(fixture.tabID))

        let second = await stage(layout: fixture.layout, tabID: fixture.tabID, spy: spy)
        #expect(second == .staged)
        #expect(spy.sent.count == 2)
    }

    // MARK: - Denials that must not reach the probe

    @Test("a missing session log denies before anything is staged")
    func aMissingSessionLogDeniesTheStage() async {
        let fixture = transcriptLayout()
        let spy = StagingSpy(foreground: ["-zsh"])

        let outcome = await stage(
            layout: fixture.layout,
            tabID: fixture.tabID,
            spy: spy,
            sessionLogExists: { _, _, _ in false }
        )

        #expect(outcome == .unavailable(.transcriptMissing))
        #expect(spy.sent.isEmpty)
    }

    @Test("a remote terminal is refused without probing the local filesystem")
    func aRemoteTerminalIsRefusedBeforeTheProbe() async throws {
        let target = try #require(RemoteTarget(user: "alice", host: "remote.example"))
        let fixture = transcriptLayout(executionPlan: .ssh(SSHExecution(target: target)))
        let spy = StagingSpy(foreground: ["-zsh"])
        let probed = Probed()

        let outcome = await stage(
            layout: fixture.layout,
            tabID: fixture.tabID,
            spy: spy,
            sessionLogExists: { _, _, _ in await probed.record() }
        )

        #expect(outcome == .unavailable(.requiresLocalTerminal))
        #expect(await probed.count == 0)
        #expect(spy.sent.isEmpty)
    }
}

// MARK: - Async helpers

/// Suspends the injected probe until the test releases it, so a second attempt
/// is guaranteed to land while the first is genuinely in flight.
private actor ProbeGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var probing = false
    private var probingWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async -> Bool {
        probing = true
        for waiter in probingWaiters { waiter.resume() }
        probingWaiters.removeAll()
        await withCheckedContinuation { continuation = $0 }
        return true
    }

    func waitUntilProbing() async {
        guard !probing else { return }
        await withCheckedContinuation { probingWaiters.append($0) }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor Probed {
    private(set) var count = 0

    func record() -> Bool {
        count += 1
        return true
    }
}
