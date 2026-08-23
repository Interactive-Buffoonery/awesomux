import AppKit
import AwesoMuxCore
import Foundation
import Testing
@testable import awesoMux

/// Behavioral coverage for the `insertText` keyDown accumulation path: while
/// `inputState.keyTextAccumulator` is active (the system IME resolving inside
/// `interpretKeyEvents`), inserted text must append to the pending buffer
/// rather than commit straight to the surface. Runs headlessly — no window is
/// mounted, so no native libghostty surface spawns.
@MainActor
@Suite("GhosttySurfaceTextInputClient key text accumulator")
struct GhosttySurfaceTextInputAccumulatorTests {
    @Test("insertText appends into an active accumulation")
    func insertTextAppendsToActiveAccumulator() throws {
        let fixture = try makeFixture()
        let runtime = GhosttyRuntime()
        defer { runtime.discardAllSurfaces() }
        let view = makeSurfaceView(runtime: runtime, fixture: fixture)

        view.inputState.keyTextAccumulator = ["a"]
        view.insertText("b", replacementRange: NSRange(location: 0, length: 1))

        #expect(view.inputState.keyTextAccumulator == ["a", "b"])
    }

    @Test("repeated inserts accumulate in order")
    func repeatedInsertsAccumulateInOrder() throws {
        let fixture = try makeFixture()
        let runtime = GhosttyRuntime()
        defer { runtime.discardAllSurfaces() }
        let view = makeSurfaceView(runtime: runtime, fixture: fixture)

        view.inputState.keyTextAccumulator = []
        view.insertText("h", replacementRange: NSRange(location: 0, length: 0))
        view.insertText("i", replacementRange: NSRange(location: 0, length: 0))

        #expect(view.inputState.keyTextAccumulator == ["h", "i"])
    }

    // MARK: - Fixture

    private func makeFixture() throws -> AccumulatorFixture {
        let pane = TerminalPane(
            title: "accumulator",
            workingDirectory: "/tmp",
            executionPlan: .local
        )
        let session = TerminalSession(
            title: "accumulator",
            workingDirectory: "/tmp",
            layout: .pane(pane)
        )
        let store = SessionStore(
            groups: [SessionGroup(name: "awesoMux", sessions: [session])],
            selectedSessionID: session.id
        )
        return AccumulatorFixture(session: session, pane: pane, store: store)
    }

    private func makeSurfaceView(
        runtime: GhosttyRuntime,
        fixture: AccumulatorFixture
    ) -> GhosttySurfaceNSView {
        runtime.surfaceView(
            sessionStore: fixture.store,
            session: fixture.session,
            pane: fixture.pane,
            enabledAgentRuntimeFileDropSources: [],
            grokIconEnabled: false
        )
    }

    private struct AccumulatorFixture {
        let session: TerminalSession
        let pane: TerminalPane
        let store: SessionStore
    }
}
