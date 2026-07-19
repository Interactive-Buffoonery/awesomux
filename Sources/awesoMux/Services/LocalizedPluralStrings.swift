import Foundation

enum LocalizedPluralStrings {
    private static let dockBadgeSessionsNeedAttentionKey = "accessibility.dockBadge.sessionsNeedAttention"
    private static let sidebarNotificationsKey = "accessibility.sidebar.notifications"
    private static let fontSizeAppliedKey = "accessibility.appearance.fontSizeApplied"
    private static let keyboardCheatsheetMatchingShortcutsKey = "keyboard.cheatsheet.matchingShortcuts"
    private static let closeGroupRiskyWorkspacesKey = "alert.closeGroup.riskyWorkspaces"
    private static let closeGroupWorkspacesClosedKey = "accessibility.closeGroup.workspacesClosed"
    private static let quitOverflowSuffixKey = "alert.quit.overflowSuffix"
    private static let quitSessionsAtRiskKey = "alert.quit.sessionsAtRisk"
    private static let footerAgentsInStateKey = "accessibility.footer.agentsInState"
    private static let footerAgentsTotalKey = "accessibility.footer.agentsTotal"
    private static let documentTaskProgressKey = "accessibility.document.taskProgress"
    private static let branchMenuMoreBranchesKey = "pathbar.branchMenu.moreBranches"
    private static let documentRevisionIndicatorKey = "document.revisionIndicator"
    private static let diagnosticsProcessesKey = "accessibility.diagnostics.processes"
    private static let diagnosticsEventsKey = "accessibility.diagnostics.events"
    private static let diagnosticsSamplesKey = "accessibility.diagnostics.samples"
    private static let diagnosticsMatchingEventsKey = "accessibility.diagnostics.matchingEvents"
    private static let diagnosticsShowingMatchingEventsKey = "diagnostics.showingMatchingEvents"
    private static let diagnosticsShowingRecordedAnalyticsEventsKey = "diagnostics.showingRecordedAnalyticsEvents"
    private static let bridgePermissionQueuedCountKey = "accessibility.bridge.permissionQueued"
    private static let commandPaletteResultsKey = "accessibility.commandPalette.results"
    private static let pathbarUncommittedChangesKey = "accessibility.pathbar.uncommittedChanges"
    private static let sessionManagerDaemonsKey = "accessibility.sessionManager.daemons"
    private static let sessionManagerSessionsKey = "accessibility.sessionManager.sessions"
    private static let sessionManagerClientsKey = "accessibility.sessionManager.clients"
    private static let sessionManagerAutoCleanupDaysKey = "accessibility.sessionManager.autoCleanupDays"
    private static let settingsFontSizePointsKey = "accessibility.settings.fontSizePoints"
    private static let terminalCapDaysKey = "settings.terminal.capDays"
    private static let sidebarGroupWorkspacesKey = "accessibility.sidebar.groupWorkspaces"
    private static let sidebarAgentsNeedInputKey = "accessibility.sidebar.agentsNeedInput"
    private static let sidebarErrorsKey = "accessibility.sidebar.errors"

    /// Bundle used to re-resolve a plural format when the caller's bundle does
    /// not contain `Localizable.stringsdict`. In a shipped app the localization
    /// resources are staged into `Bundle.main` (the build hard-fails otherwise),
    /// so `.main` is the single source of truth for every plural form and there
    /// is no hand-rolled English table to drift from the stringsdict. Tests that
    /// exercise the missing-bundle path point this at the package `Resources`
    /// bundle via `withCanonicalBundle(_:)`; production never mutates it.
    nonisolated(unsafe) static var canonicalBundle: Bundle = .main

    private static let canonicalBundleLock = NSLock()

    /// The lock spans `body` so concurrent callers (test suites run in
    /// parallel) cannot interleave their save/set/restore and leak an
    /// injected bundle past their own scope.
    static func withCanonicalBundle<Result>(_ bundle: Bundle, _ body: () -> Result) -> Result {
        canonicalBundleLock.lock()
        defer { canonicalBundleLock.unlock() }
        let previous = canonicalBundle
        canonicalBundle = bundle
        defer { canonicalBundle = previous }
        return body()
    }

    /// Resolves `key` to its localized plural format string, retrying against
    /// `canonicalBundle` when `bundle` lacks the entry so English forms always
    /// come from `Localizable.stringsdict` rather than a hand-rolled table.
    private static func format(for key: String, bundle: Bundle, comment: StaticString) -> String {
        let format = String(localized: String.LocalizationValue(key), bundle: bundle, comment: comment)
        guard format == key, bundle !== canonicalBundle else { return format }
        return String(localized: String.LocalizationValue(key), bundle: canonicalBundle, comment: comment)
    }

    static func dockBadgeSessionsNeedAttention(
        total: Int,
        bundle: Bundle = .main
    ) -> String {
        localizedPlural(
            key: dockBadgeSessionsNeedAttentionKey,
            count: total,
            bundle: bundle,
            comment: "VoiceOver announcement; argument is the count of sessions awaiting attention."
        )
    }

    static func sidebarNotifications(
        count: Int,
        bundle: Bundle = .main
    ) -> String {
        localizedPlural(
            key: sidebarNotificationsKey,
            count: count,
            bundle: bundle,
            comment: "Accessibility label component; argument is the unread notification count."
        )
    }

    static func fontSizeApplied(
        points: Int,
        bundle: Bundle = .main
    ) -> String {
        localizedPlural(
            key: fontSizeAppliedKey,
            count: points,
            bundle: bundle,
            comment: "VoiceOver announcement after committing a terminal font size change; argument is the new point size."
        )
    }

    static func keyboardCheatsheetMatchingShortcuts(
        count: Int,
        bundle: Bundle = .main
    ) -> String {
        localizedPlural(
            key: keyboardCheatsheetMatchingShortcutsKey,
            count: count,
            bundle: bundle,
            comment: "Keyboard shortcuts overlay count; argument is the number of shortcuts matching the current search."
        )
    }

    static func closeGroupRiskyWorkspaces(
        count: Int,
        bundle: Bundle = .main
    ) -> String {
        localizedPlural(
            key: closeGroupRiskyWorkspacesKey,
            count: count,
            bundle: bundle,
            comment: "Body of the close-group confirmation dialog; argument is the count of workspaces with running activity."
        )
    }

    static func closeGroupWorkspacesClosed(
        count: Int,
        bundle: Bundle = .main
    ) -> String {
        localizedPlural(
            key: closeGroupWorkspacesClosedKey,
            count: count,
            bundle: bundle,
            comment:
                "VoiceOver announcement after a group close that closed the confirmed workspaces but left the group populated; argument is the closed-workspace count."
        )
    }

    static func quitOverflowSuffix(
        count: Int,
        bundle: Bundle = .main
    ) -> String {
        localizedPlural(
            key: quitOverflowSuffixKey,
            count: count,
            bundle: bundle,
            comment:
                "Suffix appended to the quit dialog body when more than three at-risk sessions exist. Argument is the count of sessions beyond the first three."
        )
    }

    /// Quit-dialog body. Unlike the other plural helpers this sentence's
    /// *shape* changes with count (singular names one session directly;
    /// plural leads with the count and appends a title-preview list), so the
    /// stringsdict "one"/"other" forms hold full sentences rather than just
    /// an inflected noun.
    static func quitSessionsAtRisk(
        titlePreview: String,
        activityNoun: String,
        count: Int,
        overflowSuffix: String,
        bundle: Bundle = .main
    ) -> String {
        let format = format(
            for: quitSessionsAtRiskKey,
            bundle: bundle,
            comment: "Body of the quit dialog. Arguments: quoted title previews, activity noun, at-risk session count, overflow suffix."
        )
        return String.localizedStringWithFormat(format, titlePreview, activityNoun, count, overflowSuffix)
    }

    /// Footer chip label, e.g. "2 thinking agents". Two-argument plural (count +
    /// lowercased state label) so it can't route through the count-only
    /// `localizedPlural`; modeled on `quitSessionsAtRisk`.
    static func footerAgentsInState(
        count: Int,
        stateLabel: String,
        bundle: Bundle = .main
    ) -> String {
        let format = format(
            for: footerAgentsInStateKey,
            bundle: bundle,
            comment: "Footer chip accessibility label. Arguments: agent count, lowercased state label (e.g. \"thinking\")."
        )
        return String.localizedStringWithFormat(format, count, stateLabel)
    }

    static func footerAgentsTotal(
        count: Int,
        bundle: Bundle = .main
    ) -> String {
        localizedPlural(
            key: footerAgentsTotalKey,
            count: count,
            bundle: bundle,
            comment: "Footer total accessibility label; argument is the total count of agent panes."
        )
    }

    static func documentTaskProgress(
        done: Int,
        total: Int,
        bundle: Bundle = .main
    ) -> String {
        let format = format(
            for: documentTaskProgressKey,
            bundle: bundle,
            comment: "Accessibility label component; arguments are completed task count and total task count."
        )
        return String.localizedStringWithFormat(format, done, total)
    }

    static func branchMenuMoreBranches(
        count: Int,
        bundle: Bundle = .main
    ) -> String {
        localizedPlural(
            key: branchMenuMoreBranchesKey,
            count: count,
            bundle: bundle,
            comment:
                "Non-clickable overflow row at the bottom of the branch foldout; argument is the count of branches beyond the visible cap."
        )
    }

    static func documentRevisionIndicator(
        added: Int,
        removed: Int,
        bundle: Bundle = .main
    ) -> String {
        let changed = added + removed
        let format = format(
            for: documentRevisionIndicatorKey,
            bundle: bundle,
            comment:
                "Document title-bar status after an external plan-file edit. Arguments are added lines, removed lines, and total changed lines."
        )
        return String.localizedStringWithFormat(format, added, removed, changed)
    }

    static func diagnosticsProcesses(count: Int, bundle: Bundle = .main) -> String {
        localizedPlural(
            key: diagnosticsProcessesKey,
            count: count,
            bundle: bundle,
            comment: "VoiceOver Diagnostics process count."
        )
    }

    static func diagnosticsEvents(count: Int, bundle: Bundle = .main) -> String {
        localizedPlural(
            key: diagnosticsEventsKey,
            count: count,
            bundle: bundle,
            comment: "VoiceOver Diagnostics event count."
        )
    }

    static func diagnosticsSamples(count: Int, bundle: Bundle = .main) -> String {
        localizedPlural(
            key: diagnosticsSamplesKey,
            count: count,
            bundle: bundle,
            comment: "VoiceOver Diagnostics history sample count."
        )
    }

    static func diagnosticsMatchingEvents(count: Int, bundle: Bundle = .main) -> String {
        localizedPlural(
            key: diagnosticsMatchingEventsKey,
            count: count,
            bundle: bundle,
            comment: "VoiceOver Diagnostics filtered event count."
        )
    }

    static func diagnosticsShowingMatchingEvents(
        visible: Int,
        total: Int,
        bundle: Bundle = .main
    ) -> String {
        let format = format(
            for: diagnosticsShowingMatchingEventsKey,
            bundle: bundle,
            comment: "Diagnostics truncation notice; arguments are visible and total matching event counts."
        )
        return String.localizedStringWithFormat(format, visible, total)
    }

    static func diagnosticsShowingRecordedAnalyticsEvents(
        visible: Int,
        total: Int,
        bundle: Bundle = .main
    ) -> String {
        let format = format(
            for: diagnosticsShowingRecordedAnalyticsEventsKey,
            bundle: bundle,
            comment: "Analytics truncation notice; arguments are visible and total recorded event counts."
        )
        return String.localizedStringWithFormat(format, visible, total)
    }

    /// Accessibility label for the banner's queue badge — how many remote
    /// permission prompts wait behind the active one. The visible badge is just
    /// the number; assistive tech gets the counted noun via the stringsdict
    /// plural (never a `count == 1 ? …` switch).
    static func bridgePermissionQueuedCount(
        count: Int,
        bundle: Bundle = .main
    ) -> String {
        localizedPlural(
            key: bridgePermissionQueuedCountKey,
            count: count,
            bundle: bundle,
            comment:
                "Accessibility label for the remote permission banner's queue badge; argument is the number of prompts waiting behind the active one."
        )
    }

    static func commandPaletteResults(count: Int, bundle: Bundle = .main) -> String {
        localizedPlural(
            key: commandPaletteResultsKey,
            count: count,
            bundle: bundle,
            comment: "VoiceOver prefix when the command palette announces a selected result; argument is the match count."
        )
    }

    static func pathbarUncommittedChanges(count: Int, bundle: Bundle = .main) -> String {
        localizedPlural(
            key: pathbarUncommittedChangesKey,
            count: count,
            bundle: bundle,
            comment: "Path-bar dirty-chip help and accessibility label; argument is the uncommitted change count."
        )
    }

    static func sessionManagerDaemons(count: Int, bundle: Bundle = .main) -> String {
        localizedPlural(
            key: sessionManagerDaemonsKey,
            count: count,
            bundle: bundle,
            comment: "Session Manager header summary; argument is the daemon row count."
        )
    }

    static func sessionManagerSessions(count: Int, bundle: Bundle = .main) -> String {
        localizedPlural(
            key: sessionManagerSessionsKey,
            count: count,
            bundle: bundle,
            comment: "Session Manager lifecycle group accessibility label; argument is the session count."
        )
    }

    static func sessionManagerClients(count: Int, bundle: Bundle = .main) -> String {
        localizedPlural(
            key: sessionManagerClientsKey,
            count: count,
            bundle: bundle,
            comment: "Session Manager client-count label; argument is the attached client count."
        )
    }

    static func sessionManagerAutoCleanupDays(count: Int, bundle: Bundle = .main) -> String {
        localizedPlural(
            key: sessionManagerAutoCleanupDaysKey,
            count: count,
            bundle: bundle,
            comment: "Session Manager footer accessibility policy sentence; argument is the idle-cap day count."
        )
    }

    static func settingsFontSizePoints(count: Int, bundle: Bundle = .main) -> String {
        localizedPlural(
            key: settingsFontSizePointsKey,
            count: count,
            bundle: bundle,
            comment: "Appearance settings font-size slider accessibility value; argument is the point size."
        )
    }

    static func terminalCapDays(count: Int, bundle: Bundle = .main) -> String {
        localizedPlural(
            key: terminalCapDaysKey,
            count: count,
            bundle: bundle,
            comment: "Terminal settings daemon idle-cap label; argument is the day count."
        )
    }

    static func sidebarGroupWorkspaces(count: Int, bundle: Bundle = .main) -> String {
        localizedPlural(
            key: sidebarGroupWorkspacesKey,
            count: count,
            bundle: bundle,
            comment: "Sidebar group header accessibility label component; argument is the workspace count in the group."
        )
    }

    static func sidebarAgentsNeedInput(count: Int, bundle: Bundle = .main) -> String {
        localizedPlural(
            key: sidebarAgentsNeedInputKey,
            count: count,
            bundle: bundle,
            comment: "Collapsed group accessibility phrase; argument is the needs-input agent count."
        )
    }

    static func sidebarErrors(count: Int, bundle: Bundle = .main) -> String {
        localizedPlural(
            key: sidebarErrorsKey,
            count: count,
            bundle: bundle,
            comment: "Collapsed group accessibility phrase; argument is the error-state agent count."
        )
    }

    private static func localizedPlural(
        key: String,
        count: Int,
        bundle: Bundle,
        comment: StaticString
    ) -> String {
        String.localizedStringWithFormat(format(for: key, bundle: bundle, comment: comment), count)
    }
}
