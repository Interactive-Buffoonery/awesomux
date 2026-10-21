import AwesoMuxCompanionProtocol
import AwesoMuxCore
import AwesoMuxLocalAPI
import AwesoMuxLocalAPIAccess
import Foundation

@MainActor
func verifyAlertPreferenceStorageAndJournal() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "companion-alerts-\(UUID())")
    let fingerprint = Data(repeating: 19, count: 32)
    let store = LocalAPIAccessStore(profile: "development", supportDirectoryURL: directory)
    let grant = try store.registerCompanion(phoneName: "Alert fixture", certificateFingerprint: fingerprint, transport: .lan, port: 1234)
    func lease() throws -> LocalAPIAuthorizationLease {
        try store.runtimeAuthority.authorizeCompanion(
            connectionID: grant.id, certificateFingerprint: fingerprint, operation: .attentionEvents
        ).get()
    }
    let original = try lease()
    guard original.companionAlertPreferences == CompanionAlertPreferences() else {
        throw E2EFailure("legacy preferences did not default to all")
    }
    try store.updateCompanionAlertPreferences(connectionID: grant.id, preferences: CompanionAlertPreferences())
    guard try lease() == original else { throw E2EFailure("identical preferences rotated authority") }
    var journal = LocalAPIAttentionJournal(instanceID: UUID())
    let pane = UUID(), workspace = UUID(), version = UUID(), attention = UUID()
    func event(_ reason: String, change: LocalAPIAttentionChange = .raised) -> LocalAPIAttentionEvent {
        LocalAPIAttentionEvent(
            attentionID: attention, change: change, paneID: pane, workspaceID: workspace, provider: "claude", providerSessionID: nil,
            targetVersion: version, occurredAt: Date(), reason: reason,
            exitCode: reason == "commandFailed" ? 1 : reason == "commandFinished" ? 0 : nil)
    }
    let cursor = try journal.page(cursor: nil, limit: 100, lease: original, liveTargetVersions: [:]).nextCursor
    try store.updateCompanionAlertPreferences(connectionID: grant.id, preferences: .init(categories: []))
    let changed = try lease()
    guard changed != original,
        try journal.page(cursor: cursor, limit: 100, lease: changed, liveTargetVersions: [:]).cursorStatus == .accessChanged
    else { throw E2EFailure("preference change did not invalidate cursor") }
    do {
        _ = try store.runtimeAuthority.commitCompanion(connectionID: grant.id, certificateFingerprint: fingerprint, lease: original) { 0 }
        throw E2EFailure("old lease remained valid")
    } catch LocalAPIError.permissionDenied {}
    for reason in [
        "permissionPrompt", "userInputRequired", "waitingForInput", "processError", "agentError", "commandFailed", "commandFinished",
    ] { journal.append(event(reason)) }
    let empty = try journal.page(cursor: nil, limit: 100, lease: changed, liveTargetVersions: [:], includeCommandEvents: true)
    guard empty.events.isEmpty, !empty.hasMore else { throw E2EFailure("category-filtered page was not empty") }
    journal.append(event("bell"), companionSuppressed: true)
    journal.append(event("permissionPrompt", change: .resolved))
    for reason in ["bell", "desktopNotification", "unknown"] { journal.append(event(reason)) }
    let page = try journal.page(cursor: empty.nextCursor, limit: 100, lease: changed, liveTargetVersions: [:], includeCommandEvents: true)
    guard page.events.map(\.reason) == ["permissionPrompt", "bell", "desktopNotification", "unknown"],
        page.events.first?.change == .resolved
    else { throw E2EFailure("resolution or generic eligibility changed") }
    let bearer = LocalAPIAuthorizationLease(
        connectionID: UUID(), globalRevision: UUID(), connectionRevision: UUID(), statusScope: .allWorkspaces)
    guard try journal.page(cursor: nil, limit: 100, lease: bearer, liveTargetVersions: [:], includeCommandEvents: true).events.count == 12
    else { throw E2EFailure("companion filtering altered bearer journal") }
    let allCategories = LocalAPIAuthorizationLease(
        connectionID: UUID(), globalRevision: UUID(), connectionRevision: UUID(), statusScope: .allWorkspaces,
        companionAlertPreferences: CompanionAlertPreferences())
    guard try journal.page(cursor: nil, limit: 100, lease: allCategories, liveTargetVersions: [:]).events.count == 9 else {
        throw E2EFailure("preferences opted into command events or lost presence suppression")
    }
    let other = try store.registerCompanion(
        phoneName: "Second fixture", certificateFingerprint: Data(repeating: 20, count: 32), transport: .lan, port: 1234)
    guard store.state.connections.first(where: { $0.id == other.id })?.companion?.alertPreferences == nil else {
        throw E2EFailure("preferences leaked to another device")
    }
    let accessFile = directory.appending(path: "LocalAPI/access.json")
    let saved = try Data(contentsOf: accessFile)
    try FileManager.default.moveItem(at: accessFile, to: directory.appending(path: "saved-access.json"))
    try FileManager.default.createDirectory(at: accessFile, withIntermediateDirectories: false)
    do {
        try store.updateCompanionAlertPreferences(connectionID: grant.id, preferences: CompanionAlertPreferences())
        throw E2EFailure("failed-save fixture unexpectedly saved")
    } catch LocalAPIAccessFailure.persistenceFailed {}
    guard try lease() == changed else { throw E2EFailure("failed save changed authority") }
    store.relinquishAuthority()
    // Restore the saved file through a new path; keep fixture artifacts for diagnosis.
    let reloadDirectory = directory.appending(path: "reload")
    let initial = LocalAPIAccessStore(profile: "development", supportDirectoryURL: reloadDirectory)
    initial.relinquishAuthority()
    try saved.write(to: reloadDirectory.appending(path: "LocalAPI/access.json"))
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: reloadDirectory.appending(path: "LocalAPI/access.json").path)
    let reloaded = LocalAPIAccessStore(profile: "development", supportDirectoryURL: reloadDirectory)
    guard reloaded.loadFailure == nil, reloaded.state.connections.first?.companion?.alertPreferences == .init(categories: []) else {
        throw E2EFailure("preferences did not survive reload")
    }
    try reloaded.revoke(connectionID: grant.id)
    guard
        case .failure(.permissionDenied) = reloaded.runtimeAuthority.authorizeCompanion(
            connectionID: grant.id, certificateFingerprint: fingerprint, operation: .attentionEvents)
    else {
        throw E2EFailure("revocation retained preference authority")
    }
    reloaded.relinquishAuthority()
    print("alert_preferences_storage_journal=passed cases=11 artifacts=\(directory.path)")
}

@MainActor
func verifyAlertPresenceSamplingInStore() throws {
    let pane = TerminalPane(title: "Presence fixture", workingDirectory: "/tmp", executionPlan: .local)
    let workspace = TerminalSession(title: "Presence", workingDirectory: "/tmp", layout: .pane(pane))
    let store = SessionStore(groups: [SessionGroup(name: "Presence", sessions: [workspace])])
    var presence = true
    var samples: [UUID] = []
    store.companionAlertIsSuppressed = { paneID in
        samples.append(paneID)
        return presence
    }
    store.bindLocalAPIInstance(UUID())
    let companion = LocalAPIAuthorizationLease(
        connectionID: UUID(), globalRevision: UUID(), connectionRevision: UUID(), statusScope: .allWorkspaces,
        companionAlertPreferences: CompanionAlertPreferences())
    let bearer = LocalAPIAuthorizationLease(
        connectionID: UUID(), globalRevision: UUID(), connectionRevision: UUID(), statusScope: .allWorkspaces)
    guard let completion = ShellCommandCompletion(exitCode: 1, durationNanoseconds: 40_000_000_000) else {
        throw E2EFailure("presence command fixture is invalid")
    }
    func finish() {
        store.recordCommandCompletion(
            sessionID: workspace.id, paneID: pane.id, terminalSessionID: pane.terminalSessionID,
            executionPlan: pane.executionPlan, completion: completion)
    }
    func read(_ lease: LocalAPIAuthorizationLease, cursor: String? = nil) throws -> LocalAPIAttentionPage {
        try store.localAPIAttentionEvents(cursor: cursor, limit: 100, lease: lease, includeCommandEvents: true)
    }
    finish()
    presence = false
    let empty = try read(companion)
    guard empty.events.isEmpty, !empty.hasMore, samples == [pane.id] else {
        throw E2EFailure("store did not sample presence once at event creation")
    }
    guard try read(bearer).events.count == 1, samples == [pane.id] else {
        throw E2EFailure("poll resampled presence or bearer lost suppressed event")
    }
    finish()
    presence = true
    let visible = try read(companion, cursor: empty.nextCursor)
    guard visible.events.count == 1, visible.events.first?.reason == "commandFailed", samples == [pane.id, pane.id] else {
        throw E2EFailure("store recomputed eligibility after presence changed")
    }
    guard try read(companion, cursor: visible.nextCursor).events.isEmpty,
        try read(bearer).events.count == 2, samples == [pane.id, pane.id]
    else { throw E2EFailure("suppressed positions replayed or bearer journal changed") }
    print("alert_presence_store=passed cases=4 native_window_focus=unverified")
}
