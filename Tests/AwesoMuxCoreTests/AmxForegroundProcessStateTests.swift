import Testing
@testable import AwesoMuxCore

@Suite("Authenticated foreground process state")
struct AmxForegroundProcessStateTests {
    private let daemon = AmxDaemonIncarnation(
        pid: 42,
        createdAt: 1_700_000_000,
        incarnation: 99
    )

    @Test("missing evidence is unknown")
    func missingIsUnknown() {
        let state = AmxForegroundProcessState()
        #expect(state.match(executable: "ssh") == .unknown)
    }

    @Test("fresh foreground evidence distinguishes matching from non-matching")
    func freshForegroundMatch() {
        var state = AmxForegroundProcessState()
        state.beginAttach(to: daemon)
        state.consume(publication(sequence: 1, executable: "ssh"))

        #expect(state.match(executable: "ssh") == .matching)
        #expect(state.match(executable: "zsh") == .notMatching)
    }

    @Test("first foreground publication completes an attached identity with an unknown nonce")
    func foregroundCompletesAttachedIdentity() {
        var state = AmxForegroundProcessState()
        state.beginAttach(
            to: AmxDaemonIncarnation(pid: daemon.pid, createdAt: daemon.createdAt)
        )
        state.consume(publication(sequence: 1, executable: "ssh"))
        #expect(state.match(executable: "ssh") == .matching)

        let wrongNonce = AmxDaemonIncarnation(
            pid: daemon.pid,
            createdAt: daemon.createdAt,
            incarnation: daemon.incarnation + 1
        )
        state.consume(
            AmxForegroundProcessPublication(
                daemon: wrongNonce,
                transitionSequence: 2,
                sampleSequence: 2,
                state: .foreground(processGroupID: 8, executable: "ssh")
            )
        )
        #expect(state.match(executable: "ssh") == .unknown)
    }

    @Test("fresh no-foreground is negative while unavailable is unknown")
    func explicitNonForegroundStates() {
        var state = AmxForegroundProcessState()
        state.beginAttach(to: daemon)
        state.consume(publication(sequence: 1, state: .noForeground))
        #expect(state.match(executable: "ssh") == .notMatching)

        state.consume(publication(sequence: 2, state: .unavailable))
        #expect(state.match(executable: "ssh") == .unknown)
    }

    @Test("stale and malformed publications clear older positive evidence")
    func degradationClearsEvidence() {
        var lifecycle = AmxForegroundProcessState()
        lifecycle.beginAttach(to: daemon)
        lifecycle.consume(publication(sequence: 1, executable: "ssh"))
        lifecycle.consume(publication(sequence: 1, state: .stale))
        #expect(lifecycle.match(executable: "ssh") == .unknown)

        lifecycle.beginAttach(to: daemon)
        lifecycle.consume(publication(sequence: 1, executable: "ssh"))
        lifecycle.consume(publication(sequence: 1, state: .malformed))
        #expect(lifecycle.match(executable: "ssh") == .unknown)
    }

    @Test("replay and sequence regression clear evidence without reopening the replay window")
    func replayAndRegressionFailClosed() {
        var state = AmxForegroundProcessState()
        state.beginAttach(to: daemon)
        state.consume(publication(sequence: 2, sample: 5, executable: "ssh"))
        state.consume(publication(sequence: 2, sample: 5, executable: "ssh"))
        #expect(state.match(executable: "ssh") == .unknown)

        state.consume(publication(sequence: 1, sample: 6, executable: "ssh"))
        #expect(state.match(executable: "ssh") == .unknown)

        state.consume(publication(sequence: 3, sample: 7, executable: "zsh"))
        #expect(state.match(executable: "ssh") == .notMatching)
    }

    @Test("identity mismatch clears evidence and a new attach resets watermarks")
    func incarnationReplacement() {
        var state = AmxForegroundProcessState()
        state.beginAttach(to: daemon)
        state.consume(publication(sequence: 4, executable: "ssh"))

        let replacement = AmxDaemonIncarnation(
            pid: 43,
            createdAt: 1_700_000_100,
            incarnation: 100
        )
        state.consume(
            AmxForegroundProcessPublication(
                daemon: replacement,
                transitionSequence: 5,
                sampleSequence: 5,
                state: .foreground(processGroupID: 8, executable: "ssh")
            )
        )
        #expect(state.match(executable: "ssh") == .unknown)

        state.beginAttach(to: replacement)
        state.consume(
            AmxForegroundProcessPublication(
                daemon: replacement,
                transitionSequence: 1,
                sampleSequence: 1,
                state: .foreground(processGroupID: 9, executable: "zsh")
            )
        )
        #expect(state.match(executable: "ssh") == .notMatching)
    }

    @Test("meaning cannot change without a transition advance")
    func transitionSequenceFencesMeaning() {
        var state = AmxForegroundProcessState()
        state.beginAttach(to: daemon)
        state.consume(publication(sequence: 1, sample: 1, executable: "ssh"))
        state.consume(publication(sequence: 1, sample: 1, executable: "ssh"))
        state.consume(publication(sequence: 1, sample: 2, executable: "zsh"))

        #expect(state.match(executable: "ssh") == .unknown)
    }

    @Test("session cleanup removes current evidence")
    func resetClearsEvidence() {
        var state = AmxForegroundProcessState()
        state.beginAttach(to: daemon)
        state.consume(publication(sequence: 1, executable: "ssh"))
        state.reset()

        #expect(state.match(executable: "ssh") == .unknown)
    }

    private func publication(
        sequence: UInt64,
        sample: UInt64? = nil,
        executable: String
    ) -> AmxForegroundProcessPublication {
        publication(
            sequence: sequence,
            sample: sample,
            state: .foreground(processGroupID: 7, executable: executable)
        )
    }

    private func publication(
        sequence: UInt64,
        sample: UInt64? = nil,
        state: AmxForegroundProcessPublication.State
    ) -> AmxForegroundProcessPublication {
        AmxForegroundProcessPublication(
            daemon: daemon,
            transitionSequence: sequence,
            sampleSequence: sample ?? sequence,
            state: state
        )
    }
}
