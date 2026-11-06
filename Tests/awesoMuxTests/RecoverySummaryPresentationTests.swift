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
                    "1 workspace group couldn't be restored.",
                    "1 workspace layout was reset.",
                    "1 document tab couldn't be reopened.",
                    "Some names or titles were changed.",
                    "1 duplicate workspace group was merged.",
                    "1 working directory was reset to home.",
                    "The saved pane selection was reset in 1 workspace.",
                    "The selected workspace couldn't be restored.",
                ]
                : [
                    "2 workspace groups couldn't be restored.",
                    "2 workspace layouts were reset.",
                    "2 document tabs couldn't be reopened.",
                    "Some names or titles were changed.",
                    "2 duplicate workspace groups were merged.",
                    "2 working directories were reset to home.",
                    "The saved pane selection was reset in 2 workspaces.",
                    "The selected workspace couldn't be restored.",
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
                    "Some names or titles were changed.",
                    "3 working directories were reset to home.",
                ])
        }
    }

    @Test("Repeated name adjustments and workspace selection fallbacks are described truthfully")
    func restoredStateExplainsCounterMeaning() throws {
        let duplicateID = UUID()
        let firstPane = TerminalPane(id: duplicateID, title: "first", workingDirectory: "~", executionPlan: .local)
        let secondPane = TerminalPane(id: duplicateID, title: "second", workingDirectory: "~", executionPlan: .local)
        let first = TerminalSession(
            title: "first", workingDirectory: "~",
            layout: .split(TerminalSplit(orientation: .horizontal, first: .pane(firstPane), second: .pane(secondPane))),
            activePaneID: duplicateID
        )
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
        #expect(restored.sanitizationSummary.activePaneFallbacks == 1)
        #expect(restored.sanitizationSummary.selectedSessionFallbacks == 1)
        let restoredFirst = try #require(restored.store.groups.first?.sessions.first)
        var restoredPanes: [TerminalPane] = []
        restoredFirst.layout.forEachPane { restoredPanes.append($0) }
        #expect(restoredPanes.count == 2)
        #expect(restoredFirst.activePaneID == restoredFirst.layout.firstPane?.id)
        try withEnglishBundle { bundle in
            #expect(
                LocalizedPluralStrings.recoverySummaryLines(restored.sanitizationSummary, bundle: bundle) == [
                    "Some names or titles were changed.",
                    "The saved pane selection was reset in 1 workspace.",
                    "The selected workspace couldn't be restored.",
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
