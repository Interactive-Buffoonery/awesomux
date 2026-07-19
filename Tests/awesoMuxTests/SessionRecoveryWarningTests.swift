import AppKit
import AwesoMuxCore
import Foundation
import Testing
@testable import awesoMux

@MainActor
@Suite("SessionRecoveryWarning")
struct SessionRecoveryWarningTests {
    @Test("oversized recovery replacement defers retry until state can change")
    func oversizedReplacementDefersRetry() {
        #expect(
            recoveryReplacementFailurePresentation(for: .snapshotTooLarge)
                == .reviewAfterStateChange
        )
        #expect(
            recoveryReplacementFailurePresentation(for: .writeFailed)
                == .retryOrKeep
        )
    }

    @Test("persistent recovery action reopens a previously presented warning")
    func persistentRecoveryActionReopensWarning() {
        #expect(
            RecoveryWarningPresentationPolicy.didPresentAfterReviewRequest(
                hasWarning: true
            ) == false
        )
        #expect(
            RecoveryWarningPresentationPolicy.didPresentAfterReviewRequest(
                hasWarning: false
            ) == nil
        )
    }

    @Test("informational recovery actions return to the explicit keep-or-replace decision")
    func informationalActionsReturnToRecoveryDecision() {
        let fourthButtonResponse = NSApplication.ModalResponse(
            rawValue: NSApplication.ModalResponse.alertThirdButtonReturn.rawValue + 1
        )
        var responses: [NSApplication.ModalResponse] = [
            .alertThirdButtonReturn,
            fourthButtonResponse,
            .alertSecondButtonReturn,
        ]
        var showArchiveCount = 0
        var copyPathCount = 0

        let decision = resolveBlockedRecoveryWarningDecision(
            runModal: { responses.removeFirst() },
            showArchive: { showArchiveCount += 1 },
            copyPath: { copyPathCount += 1 }
        )

        #expect(decision == .replaceSavedFile)
        #expect(showArchiveCount == 1)
        #expect(copyPathCount == 1)
        #expect(responses.isEmpty)
    }

    @Test("archive warnings prevent initial save")
    func archiveWarningsPreventInitialSave() {
        let warning = SessionPersistence.SessionRecoveryWarning(
            kind: .archivedSnapshot(
                archivedSnapshotURL: nil,
                archiveError: "read failed"
            )
        )

        #expect(warning.preventsInitialSave)
    }

    @Test("sanitized restore with a successful archive allows initial save")
    func sanitizedRestoreWithArchiveAllowsInitialSave() {
        let warning = SessionPersistence.SessionRecoveryWarning(
            kind: .sanitizedRestore(
                summary: SessionRestoreSanitizationSummary(groupNameAdjustments: 1),
                archivedSnapshotURL: URL(filePath: "/tmp/session-state.sanitized-test.json"),
                archiveError: nil
            )
        )

        #expect(!warning.preventsInitialSave)
    }

    @Test("sanitized restore without an archive prevents initial save")
    func sanitizedRestoreWithoutArchivePreventsInitialSave() {
        // If the dirty original couldn't be archived, the on-disk file is the
        // only remaining copy — the cleaned state must not overwrite it.
        let warning = SessionPersistence.SessionRecoveryWarning(
            kind: .sanitizedRestore(
                summary: SessionRestoreSanitizationSummary(groupNameAdjustments: 1),
                archivedSnapshotURL: nil,
                archiveError: "write failed"
            )
        )

        #expect(warning.preventsInitialSave)
    }

    @Test("sanitized restore warnings expose archived snapshot URL")
    func sanitizedRestoreWarningsExposeArchivedSnapshotURL() {
        let url = URL(filePath: "/tmp/session-state.sanitized-test.json")
        let warning = SessionPersistence.SessionRecoveryWarning(
            kind: .sanitizedRestore(
                summary: SessionRestoreSanitizationSummary(groupNameAdjustments: 1),
                archivedSnapshotURL: url,
                archiveError: nil
            )
        )

        #expect(warning.archivedSnapshotURL == url)
    }

    @Test("sanitized restore warnings expose archive error")
    func sanitizedRestoreWarningsExposeArchiveError() {
        let warning = SessionPersistence.SessionRecoveryWarning(
            kind: .sanitizedRestore(
                summary: SessionRestoreSanitizationSummary(groupNameAdjustments: 1),
                archivedSnapshotURL: nil,
                archiveError: "copy failed"
            )
        )

        #expect(warning.archiveError == "copy failed")
    }
}
