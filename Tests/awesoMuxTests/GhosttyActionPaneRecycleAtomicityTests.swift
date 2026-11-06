import AwesoMuxCore
import Foundation
import Testing
@testable import awesoMux

/// Exercises title and progress writes across real cached-view repoints.
/// The native Ghostty callback itself still requires a live terminal surface.
@MainActor
@Suite("Ghostty actions survive a pane recycle", .serialized)
struct GhosttyActionPaneRecycleAtomicityTests {
    @Test("a bell cannot prevent remembering an already represented prompt")
    func representedPromptIsRemembered() throws {
        let harness = makeHarness()
        _ = harness.store.applyDetectedAgentState(
            id: harness.sessionA.id, paneID: harness.sharedPaneID, detectedState: .thinking, agentKind: .generic, clearsAttention: false)
        harness.store.recordOutputNotification(
            sessionID: harness.sessionA.id, paneID: harness.sharedPaneID,
            reason: .bell, observedAt: ProcessInfo.processInfo.systemUptime, canNotify: true)
        let detector = AgentOutputDetector()
        let prompt = "Muse Code v1.2.3\npermission needed\nCommand: swift test\n[y] yes [n] no"
        let cue = try #require(detector.attentionCue(in: prompt, liveAgentKind: .generic))
        let attention = try #require(detector.detectedOutput(in: prompt, liveAgentKind: .generic))
        harness.view.applyVisibleTextAgentOutput(attention, attentionCue: cue, now: 0)
        #expect(harness.store.session(id: harness.sessionA.id)?.unreadNotificationCount == 1)
        harness.store.markPaneSeen(sessionID: harness.sessionA.id, paneID: harness.sharedPaneID)
        harness.view.applyVisibleTextAgentOutput(attention, attentionCue: cue, now: 1)
        #expect(harness.store.session(id: harness.sessionA.id)?.unreadNotificationCount == 0)
        #expect(harness.store.session(id: harness.sessionA.id)?.attentionReason == nil)
    }

    @Test("retained prompts stay seen; changed payloads and renewed requests remain eligible")
    func retainedPromptDoesNotReturnAfterThinking() throws {
        let harness = makeHarness()
        let detector = AgentOutputDetector()
        let prompt = "Hermes\npermission needed\nCommand: swift test\n[y] yes [n] no"
        let cue = try #require(detector.attentionCue(in: prompt, liveAgentKind: .hermes))
        let attention = try #require(detector.detectedOutput(in: prompt, liveAgentKind: .hermes))
        harness.view.applyVisibleTextAgentOutput(attention, attentionCue: cue, now: 0)
        #expect(harness.store.session(id: harness.sessionA.id)?.unreadNotificationCount == 1)
        harness.store.markPaneSeen(sessionID: harness.sessionA.id, paneID: harness.sharedPaneID)

        let working = prompt + "\nRuminating…"
        let thinking = try #require(detector.detectedOutput(in: working, liveAgentKind: .hermes))
        #expect(thinking.state == .thinking)
        harness.view.applyVisibleTextAgentOutput(
            thinking, attentionCue: detector.attentionCue(in: working, liveAgentKind: .hermes), now: 1)
        harness.view.applyVisibleTextAgentOutput(attention, attentionCue: cue, now: 2)
        #expect(harness.store.session(id: harness.sessionA.id)?.unreadNotificationCount == 0)
        #expect(harness.store.session(id: harness.sessionA.id)?.attentionReason == nil)

        harness.view.applyVisibleTextAgentOutput(nil, attentionCue: nil, now: 3)
        harness.view.applyVisibleTextAgentOutput(attention, attentionCue: cue, now: 4)
        #expect(harness.store.session(id: harness.sessionA.id)?.unreadNotificationCount == 1)
        harness.store.markPaneSeen(sessionID: harness.sessionA.id, paneID: harness.sharedPaneID)
        let changed = prompt.replacingOccurrences(of: "swift test", with: "swift build")
        harness.view.applyVisibleTextAgentOutput(
            detector.detectedOutput(in: changed, liveAgentKind: .hermes),
            attentionCue: detector.attentionCue(in: changed, liveAgentKind: .hermes), now: 5)
        #expect(harness.store.session(id: harness.sessionA.id)?.unreadNotificationCount == 1)
        harness.store.markPaneSeen(sessionID: harness.sessionA.id, paneID: harness.sharedPaneID)
        let noChoices = prompt.replacingOccurrences(of: "\n[y] yes [n] no", with: "")
        let noChoiceCue = try #require(detector.attentionCue(in: noChoices, liveAgentKind: .hermes))
        harness.view.applyVisibleTextAgentOutput(
            detector.detectedOutput(in: noChoices, liveAgentKind: .hermes), attentionCue: noChoiceCue, now: 6)
        #expect(harness.store.session(id: harness.sessionA.id)?.unreadNotificationCount == 1)
        harness.store.markPaneSeen(sessionID: harness.sessionA.id, paneID: harness.sharedPaneID)
        let changedWithoutChoices = noChoices.replacingOccurrences(of: "swift test", with: "swift build")
        harness.view.applyVisibleTextAgentOutput(
            detector.detectedOutput(in: changedWithoutChoices, liveAgentKind: .hermes),
            attentionCue: detector.attentionCue(in: changedWithoutChoices, liveAgentKind: .hermes), now: 7)
        #expect(harness.store.session(id: harness.sessionA.id)?.unreadNotificationCount == 1)
        for (offset, pair) in [
            (
                "Hermes\npermission needed\nCommand: printf 'A'\n[y] yes [n] no",
                "Hermes\npermission needed\nCommand: printf 'a'\n[y] yes [n] no"
            ),
            ("Hermes\nCommand: swift test\nProceed? [y/n]", "Hermes\nCommand: swift build\nProceed? [y/n]"),
        ].enumerated() {
            harness.store.markPaneSeen(sessionID: harness.sessionA.id, paneID: harness.sharedPaneID)
            harness.view.applyVisibleTextAgentOutput(
                detector.detectedOutput(in: pair.0, liveAgentKind: .hermes),
                attentionCue: detector.attentionCue(in: pair.0, liveAgentKind: .hermes), now: Double(8 + offset * 2))
            #expect(harness.store.session(id: harness.sessionA.id)?.unreadNotificationCount == 1)
            harness.store.markPaneSeen(sessionID: harness.sessionA.id, paneID: harness.sharedPaneID)
            harness.view.applyVisibleTextAgentOutput(
                detector.detectedOutput(in: pair.1, liveAgentKind: .hermes),
                attentionCue: detector.attentionCue(in: pair.1, liveAgentKind: .hermes), now: Double(9 + offset * 2))
            #expect(harness.store.session(id: harness.sessionA.id)?.unreadNotificationCount == 1)
        }
        harness.store.markPaneSeen(sessionID: harness.sessionA.id, paneID: harness.sharedPaneID)
        let mixed = "Hermes\nrun package upgrade step 1\nProceed with swift test? [y] yes\n[n] no"
        harness.view.applyVisibleTextAgentOutput(
            detector.detectedOutput(in: mixed, liveAgentKind: .hermes),
            attentionCue: detector.attentionCue(in: mixed, liveAgentKind: .hermes), now: 20)
        harness.store.markPaneSeen(sessionID: harness.sessionA.id, paneID: harness.sharedPaneID)
        let progressed = mixed.replacingOccurrences(of: "step 1", with: "step 2")
        harness.view.applyVisibleTextAgentOutput(
            detector.detectedOutput(in: progressed, liveAgentKind: .hermes),
            attentionCue: detector.attentionCue(in: progressed, liveAgentKind: .hermes), now: 21)
        #expect(harness.store.session(id: harness.sessionA.id)?.unreadNotificationCount == 0)
        let olderHeading = "Hermes\npermission needed\nCommand: previous task\n\nDownloading 1%\n\nProceed with swift test? [y] yes\n[n] no"
        harness.view.applyVisibleTextAgentOutput(
            detector.detectedOutput(in: olderHeading, liveAgentKind: .hermes),
            attentionCue: detector.attentionCue(in: olderHeading, liveAgentKind: .hermes), now: 22)
        harness.store.markPaneSeen(sessionID: harness.sessionA.id, paneID: harness.sharedPaneID)
        let olderProgress = olderHeading.replacingOccurrences(of: "1%", with: "99%")
        harness.view.applyVisibleTextAgentOutput(
            detector.detectedOutput(in: olderProgress, liveAgentKind: .hermes),
            attentionCue: detector.attentionCue(in: olderProgress, liveAgentKind: .hermes), now: 23)
        #expect(harness.store.session(id: harness.sessionA.id)?.unreadNotificationCount == 0)
        _ = harness.store.applyDetectedAgentState(
            id: harness.sessionA.id, paneID: harness.sharedPaneID, detectedState: .thinking,
            agentKind: .codex, clearsAttention: false)
        let codexMenu =
            "Would you like to run the following command?\nswift test\n› 1. Yes, proceed\n  2. No, and tell Codex what to do differently\n\nStatus: yes, proceed label rendered; tick 1"
        harness.view.applyVisibleTextAgentOutput(
            detector.detectedOutput(in: codexMenu, liveAgentKind: .codex),
            attentionCue: detector.attentionCue(in: codexMenu, liveAgentKind: .codex), now: 24)
        harness.store.markPaneSeen(sessionID: harness.sessionA.id, paneID: harness.sharedPaneID)
        let codexStatus = codexMenu.replacingOccurrences(of: "tick 1", with: "tick 2")
        harness.view.applyVisibleTextAgentOutput(
            detector.detectedOutput(in: codexStatus, liveAgentKind: .codex),
            attentionCue: detector.attentionCue(in: codexStatus, liveAgentKind: .codex), now: 25)
        #expect(harness.store.session(id: harness.sessionA.id)?.unreadNotificationCount == 0)
        _ = harness.store.applyDetectedAgentState(
            id: harness.sessionA.id, paneID: harness.sharedPaneID, detectedState: .thinking,
            agentKind: .hermes, clearsAttention: false)
        let questionMarkArgument = "Hermes\nrun swift test\n--filter Parser?\n[y] yes [n] no"
        harness.view.applyVisibleTextAgentOutput(
            detector.detectedOutput(in: questionMarkArgument, liveAgentKind: .hermes),
            attentionCue: detector.attentionCue(in: questionMarkArgument, liveAgentKind: .hermes), now: 26)
        harness.store.markPaneSeen(sessionID: harness.sessionA.id, paneID: harness.sharedPaneID)
        let parallelRequest = questionMarkArgument.replacingOccurrences(of: "run swift test", with: "run swift test --parallel")
        harness.view.applyVisibleTextAgentOutput(
            detector.detectedOutput(in: parallelRequest, liveAgentKind: .hermes),
            attentionCue: detector.attentionCue(in: parallelRequest, liveAgentKind: .hermes), now: 27)
        #expect(harness.store.session(id: harness.sessionA.id)?.unreadNotificationCount == 1)
        for (offset, choices) in ["", "\n[y] yes [n] no"].enumerated() {
            let quotedPermission = "Hermes\npermission needed\nCommand: swift test\n--message \"permission required\"" + choices
            harness.store.markPaneSeen(sessionID: harness.sessionA.id, paneID: harness.sharedPaneID)
            harness.view.applyVisibleTextAgentOutput(
                detector.detectedOutput(in: quotedPermission, liveAgentKind: .hermes),
                attentionCue: detector.attentionCue(in: quotedPermission, liveAgentKind: .hermes), now: Double(28 + offset * 2))
            #expect(harness.store.session(id: harness.sessionA.id)?.unreadNotificationCount == 1)
            harness.store.markPaneSeen(sessionID: harness.sessionA.id, paneID: harness.sharedPaneID)
            let changedCommand = quotedPermission.replacingOccurrences(of: "swift test", with: "swift build")
            harness.view.applyVisibleTextAgentOutput(
                detector.detectedOutput(in: changedCommand, liveAgentKind: .hermes),
                attentionCue: detector.attentionCue(in: changedCommand, liveAgentKind: .hermes), now: Double(29 + offset * 2))
            #expect(harness.store.session(id: harness.sessionA.id)?.unreadNotificationCount == 1)
        }
        let negativeFirst = "Hermes\nrun package upgrade step 1\nProceed with swift test? [n] no\n[y] yes"
        harness.store.markPaneSeen(sessionID: harness.sessionA.id, paneID: harness.sharedPaneID)
        harness.view.applyVisibleTextAgentOutput(
            detector.detectedOutput(in: negativeFirst, liveAgentKind: .hermes),
            attentionCue: detector.attentionCue(in: negativeFirst, liveAgentKind: .hermes), now: 32)
        #expect(harness.store.session(id: harness.sessionA.id)?.unreadNotificationCount == 1)
        harness.store.markPaneSeen(sessionID: harness.sessionA.id, paneID: harness.sharedPaneID)
        let negativeProgress = negativeFirst.replacingOccurrences(of: "step 1", with: "step 2")
        harness.view.applyVisibleTextAgentOutput(
            detector.detectedOutput(in: negativeProgress, liveAgentKind: .hermes),
            attentionCue: detector.attentionCue(in: negativeProgress, liveAgentKind: .hermes), now: 33)
        #expect(harness.store.session(id: harness.sessionA.id)?.unreadNotificationCount == 0)
        let negativeChanged = negativeProgress.replacingOccurrences(of: "swift test", with: "swift build")
        harness.view.applyVisibleTextAgentOutput(
            detector.detectedOutput(in: negativeChanged, liveAgentKind: .hermes),
            attentionCue: detector.attentionCue(in: negativeChanged, liveAgentKind: .hermes), now: 34)
        #expect(harness.store.session(id: harness.sessionA.id)?.unreadNotificationCount == 1)
        let introductoryHeading = "Hermes\nThis tool needs permission\nCommand: swift test\n\nDownloading 1%"
        harness.store.markPaneSeen(sessionID: harness.sessionA.id, paneID: harness.sharedPaneID)
        harness.view.applyVisibleTextAgentOutput(
            detector.detectedOutput(in: introductoryHeading, liveAgentKind: .hermes),
            attentionCue: detector.attentionCue(in: introductoryHeading, liveAgentKind: .hermes), now: 35)
        #expect(harness.store.session(id: harness.sessionA.id)?.unreadNotificationCount == 1)
        harness.store.markPaneSeen(sessionID: harness.sessionA.id, paneID: harness.sharedPaneID)
        let introductoryProgress = introductoryHeading.replacingOccurrences(of: "1%", with: "99%")
        harness.view.applyVisibleTextAgentOutput(
            detector.detectedOutput(in: introductoryProgress, liveAgentKind: .hermes),
            attentionCue: detector.attentionCue(in: introductoryProgress, liveAgentKind: .hermes), now: 36)
        #expect(harness.store.session(id: harness.sessionA.id)?.unreadNotificationCount == 0)
        let oneLineCommand = "Hermes\nThis tool needs permission\nCommand: printf 'permission required'\n\nDownloading 1%"
        harness.view.applyVisibleTextAgentOutput(
            detector.detectedOutput(in: oneLineCommand, liveAgentKind: .hermes),
            attentionCue: detector.attentionCue(in: oneLineCommand, liveAgentKind: .hermes), now: 36.1)
        harness.store.markPaneSeen(sessionID: harness.sessionA.id, paneID: harness.sharedPaneID)
        let oneLineProgress = oneLineCommand.replacingOccurrences(of: "1%", with: "99%")
        harness.view.applyVisibleTextAgentOutput(
            detector.detectedOutput(in: oneLineProgress, liveAgentKind: .hermes),
            attentionCue: detector.attentionCue(in: oneLineProgress, liveAgentKind: .hermes), now: 36.2)
        #expect(harness.store.session(id: harness.sessionA.id)?.unreadNotificationCount == 0)
        let politeQuestion = "Hermes\nWould you like to run swift test?\n--configuration debug\n[y] yes [n] no"
        harness.view.applyVisibleTextAgentOutput(
            detector.detectedOutput(in: politeQuestion, liveAgentKind: .hermes),
            attentionCue: detector.attentionCue(in: politeQuestion, liveAgentKind: .hermes), now: 36.3)
        harness.store.markPaneSeen(sessionID: harness.sessionA.id, paneID: harness.sharedPaneID)
        let changedPolite = politeQuestion.replacingOccurrences(of: "swift test", with: "swift build")
        harness.view.applyVisibleTextAgentOutput(
            detector.detectedOutput(in: changedPolite, liveAgentKind: .hermes),
            attentionCue: detector.attentionCue(in: changedPolite, liveAgentKind: .hermes), now: 36.4)
        #expect(harness.store.session(id: harness.sessionA.id)?.unreadNotificationCount == 1)
        let optionPhrase = "Hermes\npermission needed\nrun swift test\n--message 'permission required'\n\nDownloading 1%"
        harness.store.markPaneSeen(sessionID: harness.sessionA.id, paneID: harness.sharedPaneID)
        harness.view.applyVisibleTextAgentOutput(
            detector.detectedOutput(in: optionPhrase, liveAgentKind: .hermes),
            attentionCue: detector.attentionCue(in: optionPhrase, liveAgentKind: .hermes), now: 36.5)
        harness.store.markPaneSeen(sessionID: harness.sessionA.id, paneID: harness.sharedPaneID)
        let optionChanged = optionPhrase.replacingOccurrences(of: "swift test", with: "swift build")
        harness.view.applyVisibleTextAgentOutput(
            detector.detectedOutput(in: optionChanged, liveAgentKind: .hermes),
            attentionCue: detector.attentionCue(in: optionChanged, liveAgentKind: .hermes), now: 36.6)
        #expect(harness.store.session(id: harness.sessionA.id)?.unreadNotificationCount == 1)
        for (offset, oldChoices) in ["", "\n[y] yes [n] no"].enumerated() {
            let retainedOldBlock = "Hermes\npermission needed\nCommand: previous task" + oldChoices + "\n\n" + introductoryHeading
            harness.store.markPaneSeen(sessionID: harness.sessionA.id, paneID: harness.sharedPaneID)
            harness.view.applyVisibleTextAgentOutput(
                detector.detectedOutput(in: retainedOldBlock, liveAgentKind: .hermes),
                attentionCue: detector.attentionCue(in: retainedOldBlock, liveAgentKind: .hermes), now: Double(37 + offset * 3))
            harness.store.markPaneSeen(sessionID: harness.sessionA.id, paneID: harness.sharedPaneID)
            let onlyProgress = retainedOldBlock.replacingOccurrences(of: "1%", with: "99%")
            harness.view.applyVisibleTextAgentOutput(
                detector.detectedOutput(in: onlyProgress, liveAgentKind: .hermes),
                attentionCue: detector.attentionCue(in: onlyProgress, liveAgentKind: .hermes), now: Double(38 + offset * 3))
            #expect(harness.store.session(id: harness.sessionA.id)?.unreadNotificationCount == 0)
            let changedCurrent = onlyProgress.replacingOccurrences(of: "swift test", with: "swift build")
            harness.view.applyVisibleTextAgentOutput(
                detector.detectedOutput(in: changedCurrent, liveAgentKind: .hermes),
                attentionCue: detector.attentionCue(in: changedCurrent, liveAgentKind: .hermes), now: Double(39 + offset * 3))
            #expect(harness.store.session(id: harness.sessionA.id)?.unreadNotificationCount == 1)
        }
    }

    @Test("queued attention is rejected after A to B to A binding reuse")
    func queuedAttentionDoesNotSurviveBindingReuse() async {
        let harness = makeHarness()
        harness.view.enqueueTerminalAttentionEvent { view in
            view.sessionStore.markSessionNeedsAttention(id: view.sessionID, paneID: view.paneID)
        }
        _ = recycle(harness)
        _ = repointBackToA(harness)
        await harness.view.terminalEventState.terminalAttentionDrainTask?.value
        #expect(harness.store.session(id: harness.sessionA.id)?.unreadNotificationCount == 0)
        #expect(harness.store.session(id: harness.sessionB.id)?.unreadNotificationCount == 0)
    }

    @Test("attention and completion operations drain in arrival order")
    func queuedAttentionPreservesArrivalOrder() async {
        let harness = makeHarness()
        harness.view.enqueueTerminalAttentionEvent { view in
            view.sessionStore.markSessionNeedsAttention(id: view.sessionID, paneID: view.paneID)
        }
        harness.view.enqueueTerminalAttentionEvent { view in
            view.sessionStore.acknowledgeSession(id: view.sessionID)
        }
        harness.view.enqueueTerminalAttentionEvent { view in
            view.sessionStore.markSessionNeedsAttention(id: view.sessionID, paneID: view.paneID)
        }
        await harness.view.terminalEventState.terminalAttentionDrainTask?.value
        #expect(harness.store.session(id: harness.sessionA.id)?.unreadNotificationCount == 1)
    }

    @Test("rapid terminal titles collapse to the latest trailing write")
    func rapidTerminalTitlesCollapseToLatestTrailingWrite() async throws {
        let harness = makeHarness()

        harness.view.updateTerminalTitle("⠋ awesomux")
        harness.view.updateTerminalTitle("⠙ awesomux")
        harness.view.updateTerminalTitle("⠹ awesomux")

        #expect(
            harness.store.session(id: harness.sessionA.id)?
                .layout.pane(id: harness.sharedPaneID)?.title == "⠋ awesomux"
        )

        try await Task.sleep(for: .seconds(GhosttySurfaceNSView.terminalTitleStoreWriteMinInterval * 3))

        #expect(
            harness.store.session(id: harness.sessionA.id)?
                .layout.pane(id: harness.sharedPaneID)?.title == "⠹ awesomux"
        )
    }

    @Test("a deferred terminal title never lands on the recycled-in pane")
    func deferredTerminalTitleNeverLandsOnRecycledInPane() async throws {
        let harness = makeHarness()

        harness.view.updateTerminalTitle("title written to A")
        harness.view.updateTerminalTitle("deferred title meant for A")
        let recycledView = recycle(harness)
        recycledView.updateTerminalTitle("title written to B")

        #expect(recycledView === harness.view)

        try await Task.sleep(for: .seconds(GhosttySurfaceNSView.terminalTitleStoreWriteMinInterval * 3))

        // A's deferred write must not reach B under any route — it is cancelled
        // when B supersedes the slot, and the guard would drop it regardless.
        #expect(
            harness.store.session(id: harness.sessionB.id)?
                .layout.pane(id: harness.sharedPaneID)?.title == "title written to B"
        )
        #expect(
            harness.store.session(id: harness.sessionA.id)?
                .layout.pane(id: harness.sharedPaneID)?.title == "title written to A"
        )
    }

    @Test("a flushed title does not fire again and clobber a newer title")
    func flushedTerminalTitleDoesNotRefireAfterFlush() async throws {
        let harness = makeHarness()

        harness.view.updateTerminalTitle("title written to A")
        harness.view.updateTerminalTitle("deferred title for A")
        harness.view.flushTerminalTitleThrottle()
        #expect(
            harness.store.session(id: harness.sessionA.id)?
                .layout.pane(id: harness.sharedPaneID)?.title == "deferred title for A"
        )
        harness.view.updateTerminalTitle("newest title for A")

        // Past the flushed item's original deadline: `perform()` alone does not
        // consume the pending `asyncAfter`, so without `cancel()` the stale
        // deferred title lands here and overwrites the newest one.
        try await Task.sleep(for: .seconds(GhosttySurfaceNSView.terminalTitleStoreWriteMinInterval * 3))

        #expect(
            harness.store.session(id: harness.sessionA.id)?
                .layout.pane(id: harness.sharedPaneID)?.title == "newest title for A"
        )
    }

    @Test("an orphaned pending title cannot land after the view returns to its pane")
    func orphanedPendingTitleDoesNotLandOnRepointBack() async throws {
        let harness = makeHarness()

        harness.view.updateTerminalTitle("title written to A")
        harness.view.updateTerminalTitle("orphaned title for A")

        // B supersedes the slot. Cancelling only a write this pane OWNS left A's
        // item queued but untracked, because B overwrites the slot regardless.
        let recycledView = recycle(harness)
        recycledView.updateTerminalTitle("title written to B")
        recycledView.updateTerminalTitle("deferred title for B")

        let restoredView = repointBackToA(harness)
        restoredView.updateTerminalTitle("newest title for A")
        #expect(restoredView === harness.view)

        try await Task.sleep(for: .seconds(GhosttySurfaceNSView.terminalTitleStoreWriteMinInterval * 3))

        // The orphan's guard passes again once the view points back at A, so an
        // uncancelled item commits a title two events stale over the newest one.
        #expect(
            harness.store.session(id: harness.sessionA.id)?
                .layout.pane(id: harness.sharedPaneID)?.title == "newest title for A"
        )
        #expect(
            harness.store.session(id: harness.sessionB.id)?
                .layout.pane(id: harness.sharedPaneID)?.title == "title written to B"
        )
    }

    @Test("a progress write after recycle targets the current session")
    func writeAfterRecycleTargetsCurrentSession() async throws {
        let harness = makeHarness()
        let initial = TerminalProgressReport(state: .set, progress: 42)
        let current = TerminalProgressReport(state: .set, progress: 7)
        harness.view.updateProgressReport(initial)
        #expect(harness.store.session(id: harness.sessionA.id)?.layout.pane(id: harness.sharedPaneID)?.progressReport == initial)
        harness.view.updateProgressReport(TerminalProgressReport(state: .set, progress: 43))
        let recycled = recycle(harness)
        #expect(recycled === harness.view)
        recycled.updateProgressReport(current)
        #expect(harness.store.session(id: harness.sessionB.id)?.layout.pane(id: harness.sharedPaneID)?.progressReport == current)
        #expect(harness.store.session(id: harness.sessionA.id)?.layout.pane(id: harness.sharedPaneID)?.progressReport == initial)
        #expect(repointBackToA(harness) === harness.view)
        // Cross the original trailing deadline so an orphan cannot false-pass before it fires.
        try await Task.sleep(for: .seconds(GhosttySurfaceNSView.progressReportStoreWriteMinInterval * 3))
        #expect(harness.store.session(id: harness.sessionA.id)?.layout.pane(id: harness.sharedPaneID)?.progressReport == initial)
        #expect(harness.store.session(id: harness.sessionB.id)?.layout.pane(id: harness.sharedPaneID)?.progressReport == current)
    }

    private func makeHarness() -> PaneRecycleHarness {
        let sharedPaneID = UUID()
        let paneInSessionA = TerminalPane(
            id: sharedPaneID,
            title: "session A pane",
            workingDirectory: "/tmp/a",
            executionPlan: .local
        )
        let sessionA = TerminalSession(
            title: "session A",
            workingDirectory: "/tmp/a",
            layout: .pane(paneInSessionA),
            activePaneID: paneInSessionA.id
        )
        let paneInSessionB = TerminalPane(
            id: sharedPaneID,
            title: "session B pane",
            workingDirectory: "/tmp/b",
            executionPlan: .local
        )
        let sessionB = TerminalSession(
            title: "session B",
            workingDirectory: "/tmp/b",
            layout: .pane(paneInSessionB),
            activePaneID: paneInSessionB.id
        )
        let store = SessionStore(
            groups: [SessionGroup(name: "awesoMux", sessions: [sessionA, sessionB])],
            selectedSessionID: sessionA.id
        )
        let runtime = GhosttyRuntime(initialCommandBridgeEnabled: true)
        let view = runtime.surfaceView(
            sessionStore: store,
            session: sessionA,
            pane: paneInSessionA,
            enabledAgentRuntimeFileDropSources: [],
            grokIconEnabled: false
        )

        return PaneRecycleHarness(
            sharedPaneID: sharedPaneID,
            paneInSessionA: paneInSessionA,
            paneInSessionB: paneInSessionB,
            sessionA: sessionA,
            sessionB: sessionB,
            store: store,
            runtime: runtime,
            view: view
        )
    }

    private func recycle(_ harness: PaneRecycleHarness) -> GhosttySurfaceNSView {
        repoint(harness, to: harness.sessionB, pane: harness.paneInSessionB)
    }

    private func repointBackToA(_ harness: PaneRecycleHarness) -> GhosttySurfaceNSView {
        repoint(harness, to: harness.sessionA, pane: harness.paneInSessionA)
    }

    private func repoint(
        _ harness: PaneRecycleHarness,
        to session: TerminalSession,
        pane: TerminalPane
    ) -> GhosttySurfaceNSView {
        harness.runtime.surfaceView(
            sessionStore: harness.store,
            session: session,
            pane: pane,
            enabledAgentRuntimeFileDropSources: [],
            grokIconEnabled: false
        )
    }
}

@MainActor
private struct PaneRecycleHarness {
    let sharedPaneID: UUID
    let paneInSessionA: TerminalPane
    let paneInSessionB: TerminalPane
    let sessionA: TerminalSession
    let sessionB: TerminalSession
    let store: SessionStore
    let runtime: GhosttyRuntime
    let view: GhosttySurfaceNSView
}
