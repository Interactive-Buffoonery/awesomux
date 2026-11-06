import AwesoMuxCore
import Foundation
import Testing
@testable import awesoMux

@MainActor
@Suite("Recovery summary presentation")
struct RecoverySummaryPresentationTests {
    @Test("Each recorded category reaches the localized explanation", arguments: [1, 2])
    func categories(count: Int) throws {
        try withEnglishBundle { bundle in
            let summary = SessionRestoreSanitizationSummary(
                groupNameAdjustments: count,
                droppedGroups: count,
                mergedGroups: count,
                paneWorkingDirectoryAdjustments: count,
                collapsedLayouts: count,
                activePaneFallbacks: count,
                selectedSessionFallbacks: count,
                droppedDocumentTabs: count,
                idReassignments: 99
            )
            let expected =
                count == 1
                ? [
                    "Removed 1 workspace group that could not be restored.",
                    "Replaced 1 saved workspace layout.",
                    "Skipped 1 document tab that could not be restored.",
                    "Made 1 adjustment to saved names or titles.",
                    "Merged 1 duplicate workspace group.",
                    "Reset the saved working directory for 1 pane or workspace to home.",
                    "Replaced 1 saved pane selection.",
                    "Replaced 1 saved workspace selection.",
                ]
                : [
                    "Removed 2 workspace groups that could not be restored.",
                    "Replaced 2 saved workspace layouts.",
                    "Skipped 2 document tabs that could not be restored.",
                    "Made 2 adjustments to saved names or titles.",
                    "Merged 2 duplicate workspace groups.",
                    "Reset saved working directories for 2 panes or workspaces to home.",
                    "Replaced 2 saved pane selections.",
                    "Replaced 2 saved workspace selections.",
                ]
            #expect(LocalizedPluralStrings.recoverySummaryLines(summary, bundle: bundle) == expected)
        }
    }

    @Test("Zero and structural-only repairs have no visible categories", arguments: [0, 3])
    func structuralRepairsStaySilent(idReassignments: Int) throws {
        try withEnglishBundle { bundle in
            #expect(
                LocalizedPluralStrings.recoverySummaryLines(
                    SessionRestoreSanitizationSummary(idReassignments: idReassignments), bundle: bundle
                ).isEmpty)
        }
    }

    @Test("Workspace and pane adjustments contribute to their shared categories")
    func aggregatesRecordedAdjustments() throws {
        try withEnglishBundle { bundle in
            let summary = SessionRestoreSanitizationSummary(
                groupNameAdjustments: 1,
                sessionTitleAdjustments: 2,
                sessionWorkingDirectoryAdjustments: 1,
                paneTitleAdjustments: 3,
                paneWorkingDirectoryAdjustments: 2
            )
            #expect(
                LocalizedPluralStrings.recoverySummaryLines(summary, bundle: bundle) == [
                    "Made 6 adjustments to saved names or titles.",
                    "Reset saved working directories for 3 panes or workspaces to home.",
                ])
        }
    }

    @Test("Repeated name adjustments and final workspace fallback are described truthfully")
    func restoredStateExplainsCounterMeaning() throws {
        let first = TerminalSession(title: "first", workingDirectory: "~", agentKind: .shell)
        let second = TerminalSession(title: "second", workingDirectory: "~", agentKind: .shell)
        let target = try #require(RemoteTarget(user: "fixture", host: "example.invalid"))
        let snapshot = SessionSnapshot(
            groups: [
                SessionGroup(name: "awesoMux", sessions: [first]),
                SessionGroup(name: "awes\u{043E}Mux", remote: target, sessions: [second]),
            ],
            selectedSessionID: UUID()
        )
        let restored = SessionStore.restore(from: snapshot)
        #expect(restored.store.groups.count == 2)
        #expect(restored.store.selectedSessionID == first.id)
        #expect(restored.sanitizationSummary.groupNameAdjustments == 2)
        #expect(restored.sanitizationSummary.selectedSessionFallbacks == 1)
        try withEnglishBundle { bundle in
            #expect(
                LocalizedPluralStrings.recoverySummaryLines(restored.sanitizationSummary, bundle: bundle) == [
                    "Made 2 adjustments to saved names or titles.",
                    "Replaced 1 saved workspace selection.",
                ])
        }
    }

    private func withEnglishBundle(_ body: (Bundle) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).bundle")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("en.lproj"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try FileManager.default.copyItem(
            at: root.appendingPathComponent("Resources/en.lproj/Localizable.stringsdict"),
            to: directory.appendingPathComponent("en.lproj/Localizable.stringsdict")
        )
        let info = ["CFBundleIdentifier": "app.awesomux.recovery-test", "CFBundleDevelopmentRegion": "en"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: directory.appendingPathComponent("Info.plist"))
        try body(#require(Bundle(url: directory)))
    }
}
