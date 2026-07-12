import AwesoMuxCore
import Foundation
import Testing
@testable import awesoMux

/// Verifies `BridgeAgentStatusAdapter` translates `awesomux-bridge-v1` frames
/// into the local read model with the exact consent / dedupe / rename / handoff
/// semantics the spec requires. The adapter deliberately reuses the local
/// `AgentRuntimeEventReducer` (behind `SessionStore.applyAgentRuntimeEvent`), so
/// these tests drive a real store and assert on the resulting pane row — proving
/// the wiring, not a re-implementation.
@MainActor
@Suite("Bridge agent-status adapter")
struct BridgeAgentStatusAdapterTests {
    /// Mutable settings the live-consent closure reads on every event, so a test
    /// can flip provider enablement mid-stream and prove the read is live.
    private final class ConsentBox: @unchecked Sendable {
        var sources: Set<AgentRuntimeSource>
        init(_ sources: Set<AgentRuntimeSource>) { self.sources = sources }
    }

    private final class HandoffBox: @unchecked Sendable {
        var records: [(HandoffNotify, String)] = []
    }

    private struct Harness {
        let store: SessionStore
        let sessionID: TerminalSession.ID
        let paneID: TerminalPane.ID
        let consentBox: ConsentBox
        let handoffBox: HandoffBox
        let adapter: BridgeAgentStatusAdapter

        @MainActor var pane: TerminalPane? {
            store.session(id: sessionID)?.layout.pane(id: paneID)
        }
    }

    private func makeHarness(
        kind: AgentKind = .shell,
        enabledSources: Set<AgentRuntimeSource> = []
    ) -> Harness {
        let session = TerminalSession(
            title: "workspace",
            workingDirectory: "~",
            agentKind: kind,
            agentState: .running
        )
        let store = SessionStore(groups: [SessionGroup(name: "main", sessions: [session])])
        let consentBox = ConsentBox(enabledSources)
        let handoffBox = HandoffBox()
        let sessionID = session.id
        let paneID = session.activePaneID

        let adapter = BridgeAgentStatusAdapter(
            consent: { AgentRuntimeConsent(enabledFileDropSources: consentBox.sources) },
            applyEvent: { event, _ in
                _ = store.applyAgentRuntimeEvent(event, to: sessionID, paneID: paneID)
            },
            surfaceHandoff: { notify, session in
                handoffBox.records.append((notify, session))
            }
        )

        return Harness(
            store: store,
            sessionID: sessionID,
            paneID: paneID,
            consentBox: consentBox,
            handoffBox: handoffBox,
            adapter: adapter
        )
    }

    private func agentStatusFrame(
        session: String,
        id: String = UUID().uuidString,
        ts: Double,
        source: AgentRuntimeSource,
        kind: AgentKind? = nil,
        execution: AgentExecutionState? = nil,
        attentionReason: AttentionReason? = nil,
        phase: AgentRuntimePhase? = nil,
        providerSessionID: String? = nil,
        eventID: String?
    ) -> BridgeEnvelope {
        BridgeEnvelope(
            token: "t", session: session, id: id, ts: ts,
            message: .agentStatus(AgentStatus(
                source: source,
                kind: kind,
                execution: execution,
                attentionReason: attentionReason,
                phase: phase,
                providerSessionID: providerSessionID,
                eventID: eventID
            ))
        )
    }

    // MARK: - Consent (live, at apply time)

    @Test("execution/attention/phase subset drives the correct rollup rows")
    func agentStatusSubsetMapsToRollupRows() async {
        let h = makeHarness()

        // Kind inference from source on a shell pane + a thinking execution.
        await h.adapter.apply(agentStatusFrame(
            session: h.sessionID.uuidString, ts: 1, source: .claudeCode,
            execution: .thinking, eventID: "a"
        ))
        #expect(h.pane?.agentKind == .claudeCode)
        #expect(h.pane?.agentExecutionState == .thinking)

        // Attention reason → needsAttention row.
        await h.adapter.apply(agentStatusFrame(
            session: h.sessionID.uuidString, ts: 2, source: .claudeCode,
            attentionReason: .permissionPrompt, eventID: "b"
        ))
        #expect(h.pane?.attentionReason == .permissionPrompt)
        #expect(h.pane?.agentState == .needsAttention)

        // sessionEnd phase → full reset to shell/idle.
        await h.adapter.apply(agentStatusFrame(
            session: h.sessionID.uuidString, ts: 3, source: .claudeCode,
            phase: .sessionEnd, eventID: "c"
        ))
        #expect(h.pane?.agentKind == .shell)
        #expect(h.pane?.agentExecutionState == .idle)
        #expect(h.pane?.attentionReason == nil)
    }

    @Test("file-drop provider event is dropped when the provider is disabled")
    func consentBlocksDisabledFileDropProvider() async {
        let h = makeHarness(enabledSources: [])

        await h.adapter.apply(agentStatusFrame(
            session: h.sessionID.uuidString, ts: 1, source: .openCode,
            kind: .openCode, execution: .thinking, eventID: "a"
        ))

        // opencode disabled → event never applied, pane keeps its initial
        // shell/.running row (the frame would have set kind openCode / thinking).
        #expect(h.pane?.agentKind == .shell)
        #expect(h.pane?.agentExecutionState == .running)
    }

    @Test("consent is read live: disabling a provider after attach drops the next frame")
    func consentIsLiveNotSnapshot() async {
        let h = makeHarness(enabledSources: [.openCode])

        // Enabled at first frame → applies (kind becomes openCode).
        await h.adapter.apply(agentStatusFrame(
            session: h.sessionID.uuidString, ts: 1, source: .openCode,
            kind: .openCode, execution: .thinking, eventID: "a"
        ))
        #expect(h.pane?.agentKind == .openCode)
        #expect(h.pane?.agentExecutionState == .thinking)

        // Disable the provider AFTER attach; the next frame must be dropped.
        h.consentBox.sources = []
        await h.adapter.apply(agentStatusFrame(
            session: h.sessionID.uuidString, ts: 2, source: .openCode,
            kind: .openCode, execution: .waiting, eventID: "b"
        ))
        // Still thinking (the second frame was dropped by the live consent read).
        #expect(h.pane?.agentExecutionState == .thinking)
    }

    // MARK: - Dedupe / staleness

    @Test("equal (eventID, ts) is deduped; the second frame is dropped")
    func dedupeDropsRepeat() async {
        let h = makeHarness(kind: .claudeCode)

        await h.adapter.apply(agentStatusFrame(
            session: h.sessionID.uuidString, ts: 5, source: .claudeCode,
            execution: .thinking, eventID: "dup"
        ))
        #expect(h.pane?.agentExecutionState == .thinking)

        // Same (eventID, ts) but a different execution: reducer dedupe drops it.
        await h.adapter.apply(agentStatusFrame(
            session: h.sessionID.uuidString, ts: 5, source: .claudeCode,
            execution: .waiting, eventID: "dup"
        ))
        #expect(h.pane?.agentExecutionState == .thinking)
    }

    @Test("an older ts is dropped as stale")
    func olderTimestampIsStale() async {
        let h = makeHarness(kind: .claudeCode)

        await h.adapter.apply(agentStatusFrame(
            session: h.sessionID.uuidString, ts: 100, source: .claudeCode,
            execution: .thinking, eventID: "new"
        ))
        #expect(h.pane?.agentExecutionState == .thinking)

        await h.adapter.apply(agentStatusFrame(
            session: h.sessionID.uuidString, ts: 50, source: .claudeCode,
            execution: .waiting, eventID: "old"
        ))
        #expect(h.pane?.agentExecutionState == .thinking)
    }

    @Test("a future ts is clamped to now, so a later real-time frame still applies")
    func futureTimestampIsClampedToNow() async {
        let h = makeHarness(kind: .claudeCode)

        // Far-future ts. Without the clamp, lastApplied would sit an hour ahead
        // and block every subsequent frame; with the clamp it becomes ~now.
        let farFuture = Date().timeIntervalSince1970 + 3600
        await h.adapter.apply(agentStatusFrame(
            session: h.sessionID.uuidString, ts: farFuture, source: .claudeCode,
            execution: .thinking, eventID: "future"
        ))
        #expect(h.pane?.agentExecutionState == .thinking)

        // Slightly-future ts, still less than farFuture. Applies ONLY if the
        // first frame's ts was clamped down to now.
        let slightlyFuture = Date().timeIntervalSince1970 + 5
        await h.adapter.apply(agentStatusFrame(
            session: h.sessionID.uuidString, ts: slightlyFuture, source: .claudeCode,
            execution: .waiting, eventID: "later"
        ))
        #expect(h.pane?.agentExecutionState == .waiting)
    }

    // MARK: - pane-rename

    @Test("non-empty title pins the pane title; empty title resets it")
    func renamePinsThenResets() async {
        let h = makeHarness(kind: .claudeCode)

        await h.adapter.apply(BridgeEnvelope(
            token: "t", session: h.sessionID.uuidString, id: "r1", ts: 1,
            message: .paneRename(title: "My Backend")
        ))
        #expect(h.pane?.title == "My Backend")
        #expect(h.pane?.isTitleUserEdited == true)

        await h.adapter.apply(BridgeEnvelope(
            token: "t", session: h.sessionID.uuidString, id: "r2", ts: 2,
            message: .paneRename(title: "")
        ))
        #expect(h.pane?.isTitleUserEdited == false)
    }

    @Test("an absent title is dropped at parse and never reaches the adapter")
    func absentTitleDroppedAtParse() {
        // A pane-rename frame with no `title` field is not a valid envelope.
        let line = #"{"v":1,"type":"pane-rename","token":"t","session":"s","id":"i","ts":1}"#
        #expect(BridgeEnvelope.parse(line: line) == nil)
    }

    // MARK: - Scalar-safety fence (enforced at parse, upstream of the adapter)

    @Test("hostile title scalars are rejected at parse so the adapter never sees them")
    func hostileTitleRejectedAtParse() {
        for hostile in ["a\u{202E}b", "a\u{200B}b", "a\u{0000}b"] {
            let escaped = hostile.unicodeScalars
                .map { String(format: "\\u%04x", $0.value) }
                .joined()
            let line = #"{"v":1,"type":"pane-rename","token":"t","session":"s","id":"i","ts":1,"title":"#
                + "\"\(escaped)\"}"
            #expect(BridgeEnvelope.parse(line: line) == nil)
        }
    }

    @Test("hostile handoff path scalars are rejected at parse")
    func hostileHandoffPathRejectedAtParse() {
        for hostile in ["/tmp/a\u{202E}b", "/tmp/a\u{200B}b", "/tmp/a\u{0000}b"] {
            let escaped = hostile.unicodeScalars
                .map { scalar -> String in
                    scalar.value == 0x2F ? "/" : String(format: "\\u%04x", scalar.value)
                }
                .joined()
            let line = #"{"v":1,"type":"handoff-notify","token":"t","session":"s","id":"i","ts":1,"mediaKind":"file","path":"#
                + "\"\(escaped)\"}"
            #expect(BridgeEnvelope.parse(line: line) == nil)
        }
    }

    // MARK: - handoff-notify

    @Test("a relative handoff path is rejected at parse")
    func relativeHandoffPathRejectedAtParse() {
        let line = #"{"v":1,"type":"handoff-notify","token":"t","session":"s","id":"i","ts":1,"mediaKind":"file","path":"relative/clip.png"}"#
        #expect(BridgeEnvelope.parse(line: line) == nil)
    }

    @Test("a valid handoff frame is surfaced verbatim, never touching the filesystem")
    func handoffIsSurfacedNotOpened() async {
        let h = makeHarness()
        let notify = HandoffNotify(path: "/home/user/.awesomux-inbox/clip.png", name: "clip.png", mediaKind: .image, bytes: 2048)

        await h.adapter.apply(BridgeEnvelope(
            token: "t", session: h.sessionID.uuidString, id: "h1", ts: 1,
            message: .handoffNotify(notify)
        ))

        #expect(h.handoffBox.records.count == 1)
        #expect(h.handoffBox.records.first?.0 == notify)
        #expect(h.handoffBox.records.first?.1 == h.sessionID.uuidString)
    }

    /// The "never touches the filesystem" guarantee is by construction: the
    /// adapter source references no filesystem API. Asserting on the source keeps
    /// a future edit that reaches for `FileManager`/`open`/`fileURLWithPath` from
    /// silently turning a notify into a read.
    @Test("adapter source contains no filesystem access")
    func adapterHasNoFilesystemAccess() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Bridge/
            .deletingLastPathComponent() // awesoMuxTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("Sources/awesoMux/Services/BridgeAgentStatusAdapter.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        // Cover the filesystem/exec surfaces a "surface only" adapter must never
        // reach for: high-level (FileManager/URL loaders), stream/handle APIs,
        // POSIX open/fopen, and process spawning.
        let forbidden = [
            "FileManager", "fileURLWithPath", "URL(", "contentsOf", "Data(contentsOf",
            "FileHandle", "InputStream", "OutputStream", "Pipe", "Process",
            "open(", "fopen", "read(", "mmap"
        ]
        for symbol in forbidden {
            #expect(!source.contains(symbol), "adapter must not reference \(symbol)")
        }
    }
}
