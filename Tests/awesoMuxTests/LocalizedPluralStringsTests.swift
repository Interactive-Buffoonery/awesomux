import Foundation
import Testing
@testable import awesoMux

@Suite("Localized plural strings")
struct LocalizedPluralStringsTests {
    @Test("English accessibility plurals resolve through stringsdict")
    func englishAccessibilityPluralsResolveThroughStringsdict() {
        #expect(
            LocalizedPluralStrings.dockBadgeSessionsNeedAttention(
                total: 1,
                bundle: Self.resourcesBundle
            ) == "1 session needs attention"
        )
        #expect(
            LocalizedPluralStrings.dockBadgeSessionsNeedAttention(
                total: 2,
                bundle: Self.resourcesBundle
            ) == "2 sessions need attention"
        )
        #expect(
            LocalizedPluralStrings.sidebarNotifications(
                count: 1,
                bundle: Self.resourcesBundle
            ) == "1 notification"
        )
        #expect(
            LocalizedPluralStrings.sidebarNotifications(
                count: 2,
                bundle: Self.resourcesBundle
            ) == "2 notifications"
        )
        #expect(
            LocalizedPluralStrings.keyboardCheatsheetMatchingShortcuts(
                count: 1,
                bundle: Self.resourcesBundle
            ) == "1 matching shortcut"
        )
        #expect(
            LocalizedPluralStrings.keyboardCheatsheetMatchingShortcuts(
                count: 2,
                bundle: Self.resourcesBundle
            ) == "2 matching shortcuts"
        )
        #expect(
            LocalizedPluralStrings.documentTaskProgress(
                done: 1,
                total: 1,
                bundle: Self.resourcesBundle
            ) == "1 of 1 task complete"
        )
        #expect(
            LocalizedPluralStrings.documentTaskProgress(
                done: 2,
                total: 5,
                bundle: Self.resourcesBundle
            ) == "2 of 5 tasks complete"
        )
        #expect(
            LocalizedPluralStrings.documentRevisionIndicator(
                added: 1,
                removed: 0,
                bundle: Self.resourcesBundle
            ) == "Plan revised: +1 / −0 line"
        )
        #expect(
            LocalizedPluralStrings.documentRevisionIndicator(
                added: 3,
                removed: 2,
                bundle: Self.resourcesBundle
            ) == "Plan revised: +3 / −2 lines"
        )
        #expect(LocalizedPluralStrings.diagnosticsProcesses(count: 1, bundle: Self.resourcesBundle) == "1 process")
        #expect(LocalizedPluralStrings.diagnosticsProcesses(count: 2, bundle: Self.resourcesBundle) == "2 processes")
        #expect(LocalizedPluralStrings.diagnosticsEvents(count: 2, bundle: Self.resourcesBundle) == "2 events")
        #expect(LocalizedPluralStrings.diagnosticsSamples(count: 2, bundle: Self.resourcesBundle) == "2 samples")
        #expect(LocalizedPluralStrings.diagnosticsMatchingEvents(count: 2, bundle: Self.resourcesBundle) == "2 matching diagnostic events")
        #expect(
            LocalizedPluralStrings.commandPaletteResults(
                count: 1,
                bundle: Self.resourcesBundle
            ) == "1 result"
        )
        #expect(
            LocalizedPluralStrings.commandPaletteResults(
                count: 4,
                bundle: Self.resourcesBundle
            ) == "4 results"
        )
        #expect(
            LocalizedPluralStrings.pathbarUncommittedChanges(
                count: 1,
                bundle: Self.resourcesBundle
            ) == "1 uncommitted change"
        )
        #expect(
            LocalizedPluralStrings.pathbarUncommittedChanges(
                count: 3,
                bundle: Self.resourcesBundle
            ) == "3 uncommitted changes"
        )
        #expect(
            LocalizedPluralStrings.sessionManagerDaemons(
                count: 1,
                bundle: Self.resourcesBundle
            ) == "1 daemon"
        )
        #expect(
            LocalizedPluralStrings.sessionManagerDaemons(
                count: 2,
                bundle: Self.resourcesBundle
            ) == "2 daemons"
        )
        #expect(
            LocalizedPluralStrings.sessionManagerSessions(
                count: 1,
                bundle: Self.resourcesBundle
            ) == "1 session"
        )
        #expect(
            LocalizedPluralStrings.sessionManagerSessions(
                count: 2,
                bundle: Self.resourcesBundle
            ) == "2 sessions"
        )
        #expect(
            LocalizedPluralStrings.sessionManagerClients(
                count: 1,
                bundle: Self.resourcesBundle
            ) == "1 client"
        )
        #expect(
            LocalizedPluralStrings.sessionManagerClients(
                count: 2,
                bundle: Self.resourcesBundle
            ) == "2 clients"
        )
        #expect(
            LocalizedPluralStrings.sessionManagerAutoCleanupDays(
                count: 1,
                bundle: Self.resourcesBundle
            ) == "Auto-cleanup after 1 day idle. Configure in Preferences."
        )
        #expect(
            LocalizedPluralStrings.sessionManagerAutoCleanupDays(
                count: 7,
                bundle: Self.resourcesBundle
            ) == "Auto-cleanup after 7 days idle. Configure in Preferences."
        )
        #expect(
            LocalizedPluralStrings.settingsFontSizePoints(
                count: 1,
                bundle: Self.resourcesBundle
            ) == "1 point"
        )
        #expect(
            LocalizedPluralStrings.settingsFontSizePoints(
                count: 12,
                bundle: Self.resourcesBundle
            ) == "12 points"
        )
        #expect(
            LocalizedPluralStrings.terminalCapDays(
                count: 1,
                bundle: Self.resourcesBundle
            ) == "1 day"
        )
        #expect(
            LocalizedPluralStrings.terminalCapDays(
                count: 3,
                bundle: Self.resourcesBundle
            ) == "3 days"
        )
        #expect(
            LocalizedPluralStrings.sidebarGroupWorkspaces(
                count: 1,
                bundle: Self.resourcesBundle
            ) == "1 workspace"
        )
        #expect(
            LocalizedPluralStrings.sidebarGroupWorkspaces(
                count: 2,
                bundle: Self.resourcesBundle
            ) == "2 workspaces"
        )
        #expect(
            LocalizedPluralStrings.sidebarAgentsNeedInput(
                count: 1,
                bundle: Self.resourcesBundle
            ) == "1 needs input"
        )
        #expect(
            LocalizedPluralStrings.sidebarAgentsNeedInput(
                count: 2,
                bundle: Self.resourcesBundle
            ) == "2 need input"
        )
        #expect(
            LocalizedPluralStrings.sidebarErrors(
                count: 1,
                bundle: Self.resourcesBundle
            ) == "1 error"
        )
        #expect(
            LocalizedPluralStrings.sidebarErrors(
                count: 2,
                bundle: Self.resourcesBundle
            ) == "2 errors"
        )
    }

    @Test("missing bundle re-resolves through the canonical stringsdict bundle")
    func missingBundleFallsBackToEnglishAccessibilityPlurals() throws {
        let bundle = try Self.emptyBundle()

        LocalizedPluralStrings.withCanonicalBundle(Self.resourcesBundle) {
            #expect(
                LocalizedPluralStrings.dockBadgeSessionsNeedAttention(
                    total: 1,
                    bundle: bundle
                ) == "1 session needs attention"
            )
            #expect(
                LocalizedPluralStrings.dockBadgeSessionsNeedAttention(
                    total: 3,
                    bundle: bundle
                ) == "3 sessions need attention"
            )
            #expect(
                LocalizedPluralStrings.sidebarNotifications(
                    count: 1,
                    bundle: bundle
                ) == "1 notification"
            )
            #expect(
                LocalizedPluralStrings.sidebarNotifications(
                    count: 3,
                    bundle: bundle
                ) == "3 notifications"
            )
            #expect(
                LocalizedPluralStrings.fontSizeApplied(
                    points: 1,
                    bundle: bundle
                ) == "Font size updated to 1 point. Open terminal panes refreshed."
            )
            #expect(
                LocalizedPluralStrings.fontSizeApplied(
                    points: 16,
                    bundle: bundle
                ) == "Font size updated to 16 points. Open terminal panes refreshed."
            )
            #expect(
                LocalizedPluralStrings.keyboardCheatsheetMatchingShortcuts(
                    count: 1,
                    bundle: bundle
                ) == "1 matching shortcut"
            )
            #expect(
                LocalizedPluralStrings.keyboardCheatsheetMatchingShortcuts(
                    count: 3,
                    bundle: bundle
                ) == "3 matching shortcuts"
            )
            #expect(
                LocalizedPluralStrings.documentTaskProgress(
                    done: 1,
                    total: 1,
                    bundle: bundle
                ) == "1 of 1 task complete"
            )
            #expect(
                LocalizedPluralStrings.documentTaskProgress(
                    done: 2,
                    total: 5,
                    bundle: bundle
                ) == "2 of 5 tasks complete"
            )
            #expect(
                LocalizedPluralStrings.documentRevisionIndicator(
                    added: 1,
                    removed: 0,
                    bundle: bundle
                ) == "Plan revised: +1 / −0 line"
            )
            #expect(
                LocalizedPluralStrings.documentRevisionIndicator(
                    added: 3,
                    removed: 2,
                    bundle: bundle
                ) == "Plan revised: +3 / −2 lines"
            )
        }
    }

    @Test("footer agent plurals resolve through stringsdict and fall back")
    func footerAgentPluralsResolveAndFallBack() throws {
        #expect(
            LocalizedPluralStrings.footerAgentsInState(
                count: 1,
                stateLabel: "thinking",
                bundle: Self.resourcesBundle
            ) == "1 thinking agent"
        )
        #expect(
            LocalizedPluralStrings.footerAgentsInState(
                count: 2,
                stateLabel: "thinking",
                bundle: Self.resourcesBundle
            ) == "2 thinking agents"
        )
        #expect(
            LocalizedPluralStrings.footerAgentsTotal(
                count: 1,
                bundle: Self.resourcesBundle
            ) == "1 agent"
        )
        #expect(
            LocalizedPluralStrings.footerAgentsTotal(
                count: 3,
                bundle: Self.resourcesBundle
            ) == "3 agents"
        )

        let empty = try Self.emptyBundle()
        LocalizedPluralStrings.withCanonicalBundle(Self.resourcesBundle) {
            #expect(
                LocalizedPluralStrings.footerAgentsInState(
                    count: 2,
                    stateLabel: "needs input",
                    bundle: empty
                ) == "2 needs input agents"
            )
            #expect(
                LocalizedPluralStrings.footerAgentsTotal(
                    count: 0,
                    bundle: empty
                ) == "0 agents"
            )
        }
    }

    @Test("English font-size-applied plural resolves through stringsdict")
    func englishFontSizeAppliedPluralResolvesThroughStringsdict() {
        #expect(
            LocalizedPluralStrings.fontSizeApplied(
                points: 1,
                bundle: Self.resourcesBundle
            ) == "Font size updated to 1 point. Open terminal panes refreshed."
        )
        #expect(
            LocalizedPluralStrings.fontSizeApplied(
                points: 16,
                bundle: Self.resourcesBundle
            ) == "Font size updated to 16 points. Open terminal panes refreshed."
        )
    }

    @Test("English stringsdict entries cover required plural categories")
    func englishStringsdictEntriesCoverRequiredPluralCategories() throws {
        let stringsdict = try Self.loadStringsdict(language: "en")
        for key in [
            "accessibility.dockBadge.sessionsNeedAttention",
            "accessibility.sidebar.notifications",
            "keyboard.cheatsheet.matchingShortcuts",
            "accessibility.footer.agentsInState",
            "accessibility.footer.agentsTotal",
            "accessibility.diagnostics.processes",
            "accessibility.diagnostics.events",
            "accessibility.diagnostics.samples",
            "accessibility.diagnostics.matchingEvents",
            "document.revisionIndicator",
        ] {
            let forms = try Self.pluralForms(in: stringsdict, key: key)
            for category in ["one", "other"] {
                #expect(forms[category] != nil)
            }
        }

        // The quit-dialog keys exist only in en so far; sessionsAtRisk uses a
        // positional embedded plural (%3$#@sessions@) with structurally
        // different one/other sentences, so pin the positional specifiers to
        // the Swift call's argument order (title, noun, count, suffix).
        let english = try Self.loadStringsdict(language: "en")
        let overflow = try Self.pluralForms(in: english, key: "alert.quit.overflowSuffix")
        let atRisk = try Self.pluralForms(in: english, key: "alert.quit.sessionsAtRisk")
        for category in ["one", "other"] {
            #expect(overflow[category]?.contains("%lld") == true)
        }
        #expect(atRisk["one"]?.contains("%1$@") == true)
        #expect(atRisk["one"]?.contains("%2$@") == true)
        for specifier in ["%1$@", "%2$@", "%3$lld", "%4$@"] {
            #expect(atRisk["other"]?.contains(specifier) == true)
        }
    }

    @Test("English close-group risky-workspaces plural resolves through stringsdict")
    func englishCloseGroupRiskyWorkspacesPluralResolvesThroughStringsdict() {
        #expect(
            LocalizedPluralStrings.closeGroupRiskyWorkspaces(
                count: 1,
                bundle: Self.resourcesBundle
            ) == "1 workspace in this group has running activity that will be interrupted. Closing will terminate its running process."
        )
        #expect(
            LocalizedPluralStrings.closeGroupRiskyWorkspaces(
                count: 3,
                bundle: Self.resourcesBundle
            )
                == "3 workspaces in this group have running activity that will be interrupted. Closing will terminate their running processes."
        )
    }

    @Test("missing bundle re-resolves the close-group plural through the canonical bundle")
    func missingBundleFallsBackToEnglishCloseGroupPlural() throws {
        let bundle = try Self.emptyBundle()
        LocalizedPluralStrings.withCanonicalBundle(Self.resourcesBundle) {
            #expect(
                LocalizedPluralStrings.closeGroupRiskyWorkspaces(
                    count: 1,
                    bundle: bundle
                ) == "1 workspace in this group has running activity that will be interrupted. Closing will terminate its running process."
            )
            #expect(
                LocalizedPluralStrings.closeGroupRiskyWorkspaces(
                    count: 2,
                    bundle: bundle
                )
                    == "2 workspaces in this group have running activity that will be interrupted. Closing will terminate their running processes."
            )
        }
    }

    @Test("close-group closed-count plural resolves and falls back")
    func closeGroupWorkspacesClosedPluralResolvesAndFallsBack() throws {
        #expect(
            LocalizedPluralStrings.closeGroupWorkspacesClosed(
                count: 1,
                bundle: Self.resourcesBundle
            ) == "Closed 1 workspace in the group"
        )
        #expect(
            LocalizedPluralStrings.closeGroupWorkspacesClosed(
                count: 2,
                bundle: Self.resourcesBundle
            ) == "Closed 2 workspaces in the group"
        )
        let empty = try Self.emptyBundle()
        LocalizedPluralStrings.withCanonicalBundle(Self.resourcesBundle) {
            #expect(
                LocalizedPluralStrings.closeGroupWorkspacesClosed(
                    count: 2,
                    bundle: empty
                ) == "Closed 2 workspaces in the group"
            )
        }
    }

    @Test("quit-dialog plurals resolve through stringsdict")
    func quitDialogPluralsResolveThroughStringsdict() {
        #expect(
            LocalizedPluralStrings.quitOverflowSuffix(
                count: 2,
                bundle: Self.resourcesBundle
            ) == " and 2 more"
        )
        #expect(
            LocalizedPluralStrings.quitSessionsAtRisk(
                titlePreview: "“build”",
                activityNoun: "agent activity",
                count: 1,
                overflowSuffix: "",
                bundle: Self.resourcesBundle
            ) == "“build” has agent activity that may be interrupted."
        )
        #expect(
            LocalizedPluralStrings.quitSessionsAtRisk(
                titlePreview: "“build”, “deploy”",
                activityNoun: "agent activity",
                count: 4,
                overflowSuffix: " and 2 more",
                bundle: Self.resourcesBundle
            ) == "4 sessions have agent activity that may be interrupted: “build”, “deploy” and 2 more."
        )
    }

    @Test("missing bundle re-resolves quit-dialog plurals through the canonical bundle")
    func missingBundleFallsBackToEnglishQuitDialogPlurals() throws {
        let bundle = try Self.emptyBundle()
        LocalizedPluralStrings.withCanonicalBundle(Self.resourcesBundle) {
            #expect(
                LocalizedPluralStrings.quitOverflowSuffix(
                    count: 1,
                    bundle: bundle
                ) == " and 1 more"
            )
            #expect(
                LocalizedPluralStrings.quitSessionsAtRisk(
                    titlePreview: "“build”",
                    activityNoun: "a running shell process",
                    count: 1,
                    overflowSuffix: "",
                    bundle: bundle
                ) == "“build” has a running shell process that may be interrupted."
            )
        }
    }

    private static var packageResourcesURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Resources", directoryHint: .isDirectory)
    }

    private static var resourcesBundle: Bundle {
        Bundle(url: packageResourcesURL) ?? .main
    }

    private static func emptyBundle() throws -> Bundle {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "awesomux-empty-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appendingPathExtension("bundle")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return try #require(Bundle(url: url))
    }

    private static func loadStringsdict(language: String) throws -> [String: Any] {
        let url =
            packageResourcesURL
            .appending(path: "\(language).lproj", directoryHint: .isDirectory)
            .appending(path: "Localizable.stringsdict")
        let data = try Data(contentsOf: url)
        return try #require(
            PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        )
    }

    private static func pluralForms(
        in stringsdict: [String: Any],
        key: String
    ) throws -> [String: String] {
        let entry = try #require(stringsdict[key] as? [String: Any])
        let formatKey = try #require(entry["NSStringLocalizedFormatKey"] as? String)
        // Handles both plain (%#@var@) and positional (%3$#@var@) embedded
        // plural variables; naive character trimming misparses the latter.
        let match = try #require(formatKey.firstMatch(of: /%(?:\d+\$)?#@(.+?)@/))
        return try #require(entry[String(match.1)] as? [String: String])
    }
}
