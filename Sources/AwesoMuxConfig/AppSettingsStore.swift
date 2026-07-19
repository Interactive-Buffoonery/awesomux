import Foundation
import Observation

/// Persistence coordinator + per-section observable façade.
///
/// Holds one `@Observable` slice per section (general / appearance /
/// notifications / agents / keyboard / workspaces / advanced) so SwiftUI views can
/// depend on the section they actually read instead of invalidating
/// across the whole settings tree on any change. Coordinates file I/O
/// (bootstrap, save, watcher reload) and exposes the composed
/// `AwesoMuxConfig` as a computed property for back-compat with code that
/// wants the whole-tree view.
@MainActor
@Observable
public final class AppSettingsStore {
    public let general: GeneralStore
    public let appearance: AppearanceStore
    public let notifications: NotificationStore
    public let agents: AgentStore
    public let agentIntegrations: AgentIntegrationsStore
    public let keyboard: KeyboardStore
    public let terminal: TerminalStore
    public let workspaces: WorkspaceStore
    public let advanced: AdvancedStore
    public let analytics: AnalyticsStore

    public private(set) var loadSource: ConfigLoadSource?
    public private(set) var latestError: AppSettingsStoreError?
    public private(set) var isDiskConfigInvalid: Bool
    public private(set) var isExternalReloadPending: Bool

    public let configURL: URL

    private let fileStore: ConfigFileStore
    /// Test seam for the save path; production always writes through
    /// `fileStore.save`. Kept as a closure instead of a protocol because
    /// save failure is the only behavior tests need to fake.
    @ObservationIgnored var saveToDisk: (AwesoMuxConfig) throws(ConfigFileStoreError) -> Void
    private let legacySnapshotProvider: () -> LegacySettingsSnapshot?
    private let diagnosticEventHandler: (AppSettingsDiagnosticEvent) -> Void
    private let watchDebounceNanoseconds: UInt64
    @ObservationIgnored private var watcher: ConfigDirectoryWatcher?
    @ObservationIgnored private var watchedReloadTask: Task<Void, Never>?
    /// Tracks `unknownTopLevelTables` from the most recently observed
    /// disk state so persists from section updates round-trip extras.
    @ObservationIgnored private var unknownTopLevelTables: [String: String] = [:]
    /// Same pass-through for unknown owned-section body lines. Without this, a
    /// UI settings change rebuilds the config from the section stores with empty
    /// values here and silently drops a user's hand-written section keys — the
    /// codec preserves them on a direct round-trip, but the store is what the
    /// save path actually serializes.
    @ObservationIgnored private var unknownTerminalTableLines: String = ""
    @ObservationIgnored private var terminalTableLineLayout: [SectionLineLayout] = []
    @ObservationIgnored private var unknownAppearanceTableLines: String = ""
    @ObservationIgnored private var appearanceTableLineLayout: [SectionLineLayout] = []

    /// The composed `AwesoMuxConfig` snapshot. Reading this depends on
    /// every section store; views that want granular invalidation should
    /// read individual section stores instead (e.g.
    /// `appSettingsStore.appearance.value.theme`).
    public var config: AwesoMuxConfig {
        var snapshot = AwesoMuxConfig(
            general: general.value,
            appearance: appearance.value,
            notifications: notifications.value,
            agents: agents.value,
            agentIntegrations: agentIntegrations.value,
            keyboard: keyboard.value,
            terminal: terminal.value,
            workspaces: workspaces.value,
            advanced: advanced.value,
            analytics: analytics.value,
            unknownTopLevelTables: unknownTopLevelTables,
            unknownTerminalTableLines: unknownTerminalTableLines,
            unknownAppearanceTableLines: unknownAppearanceTableLines
        )
        snapshot.terminalTableLineLayout = terminalTableLineLayout
        snapshot.appearanceTableLineLayout = appearanceTableLineLayout
        return snapshot
    }

    public init(
        fileStore: ConfigFileStore = ConfigFileStore(),
        initialConfig: AwesoMuxConfig = .defaultValue,
        watchDebounceNanoseconds: UInt64 = 200_000_000,
        diagnosticEventHandler: @escaping (AppSettingsDiagnosticEvent) -> Void = { _ in },
        legacySnapshotProvider: @escaping () -> LegacySettingsSnapshot? = {
            LegacySettingsSnapshot(persistedUserDefaults: .standard)
        }
    ) {
        self.general = SectionSlice(initialConfig.general, keyPath: \.general)
        self.appearance = SectionSlice(initialConfig.appearance, keyPath: \.appearance)
        self.notifications = SectionSlice(initialConfig.notifications, keyPath: \.notifications)
        self.agents = SectionSlice(initialConfig.agents, keyPath: \.agents)
        self.agentIntegrations = SectionSlice(initialConfig.agentIntegrations, keyPath: \.agentIntegrations)
        self.keyboard = SectionSlice(initialConfig.keyboard, keyPath: \.keyboard)
        self.terminal = SectionSlice(initialConfig.terminal, keyPath: \.terminal)
        self.workspaces = SectionSlice(initialConfig.workspaces, keyPath: \.workspaces)
        self.advanced = SectionSlice(initialConfig.advanced, keyPath: \.advanced)
        self.analytics = SectionSlice(initialConfig.analytics, keyPath: \.analytics)
        self.unknownTopLevelTables = initialConfig.unknownTopLevelTables
        self.unknownTerminalTableLines = initialConfig.unknownTerminalTableLines
        self.terminalTableLineLayout = initialConfig.terminalTableLineLayout
        self.unknownAppearanceTableLines = initialConfig.unknownAppearanceTableLines
        self.appearanceTableLineLayout = initialConfig.appearanceTableLineLayout
        self.fileStore = fileStore
        self.saveToDisk = fileStore.save
        self.loadSource = nil
        self.latestError = nil
        self.isDiskConfigInvalid = false
        self.isExternalReloadPending = false
        self.configURL = fileStore.configURL
        self.legacySnapshotProvider = legacySnapshotProvider
        self.diagnosticEventHandler = diagnosticEventHandler
        self.watchDebounceNanoseconds = watchDebounceNanoseconds
        self.general.coordinator = self
        self.appearance.coordinator = self
        self.notifications.coordinator = self
        self.agents.coordinator = self
        self.agentIntegrations.coordinator = self
        self.keyboard.coordinator = self
        self.terminal.coordinator = self
        self.workspaces.coordinator = self
        self.advanced.coordinator = self
        self.analytics.coordinator = self
    }

    deinit {
        watcher?.cancel()
        watchedReloadTask?.cancel()
    }

    public func bootstrap() {
        do {
            applyLoadResult(try fileStore.bootstrap(legacySnapshot: legacySnapshotProvider()))
        } catch {
            loadSource = nil
            latestError = .save(error)
            isDiskConfigInvalid = false
        }
    }

    /// Whole-tree mutation entrypoint kept for back-compat. New code
    /// should prefer per-section `appSettingsStore.appearance.update { ... }`
    /// which gives finer-grained invalidation.
    ///
    /// Transactional: the in-memory section stores are updated only after
    /// the candidate config saves successfully. A validation error in
    /// `fileStore.save` does NOT leak a bad value into in-memory state,
    /// which keeps the next reload-from-disk a clean fallback rather than
    /// a silent diverger.
    public func update(_ transform: (inout AwesoMuxConfig) -> Void) {
        var working = config
        transform(&working)
        guard attemptPersist(working) else { return }
        apply(working)
    }

    /// Called by section stores with a CANDIDATE composed config. Returns
    /// true when the section store should commit its new value (save
    /// succeeded, or persistence is currently disabled because the disk
    /// file is invalid). Returns false when save failed validation — the
    /// section store keeps its old value so memory and disk stay
    /// consistent.
    func attemptPersist(_ candidate: AwesoMuxConfig) -> Bool {
        guard !isDiskConfigInvalid else {
            // Disk is currently flagged invalid; UI still allows tweaks
            // (they'll persist once the user clears the invalid-file
            // banner via Replace). Permit the section-store mutation
            // through without writing to disk.
            return true
        }

        // Bump the schema marker to the current supported version on
        // every save. A v1 TOML loaded then re-written used to keep
        // declaring schema=1 even though we'd just added v2-only keys
        // — future migrations would misread that as "still on v1, run
        // migration steps again." Whatever this binary writes IS the
        // current schema version, by definition.
        var withCurrentSchema = candidate
        withCurrentSchema.advanced.configSchemaVersion = AdvancedConfig.supportedConfigSchemaVersion

        do {
            try saveToDisk(withCurrentSchema)
            if advanced.value.configSchemaVersion != AdvancedConfig.supportedConfigSchemaVersion {
                advanced.value = withCurrentSchema.advanced
            }
            latestError = nil
            return true
        } catch {
            latestError = .save(error)
            return false
        }
    }

    public func reloadFromDisk() {
        reloadFromDisk(trigger: .manual)
    }

    private func reloadFromDisk(trigger: AppSettingsDiagnosticTrigger) {
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            // Manual deletion of the config file is an unambiguous
            // "I want this gone" gesture — reset to defaults rather
            // than re-writing the user's in-memory state to disk.
            diagnosticEventHandler(
                resetToDefaultsAndWriteFile()
                    ? .resetAfterDeletion
                    : .resetAfterDeletionRejected
            )
            return
        }

        let result = fileStore.load()
        applyLoadResult(result)
        diagnosticEventHandler(
            result.config == nil
                ? .reloadRejected(trigger: trigger)
                : .reloadSucceeded(trigger: trigger)
        )
    }

    public func replaceInvalidFileWithCurrentConfig() {
        do {
            try saveToDisk(config)
            latestError = nil
            isDiskConfigInvalid = false
            loadSource = .existingFile
        } catch {
            latestError = .save(error)
        }
    }

    public func startWatching() {
        guard watcher == nil else {
            return
        }

        watcher = ConfigDirectoryWatcher(
            directoryURL: configURL.deletingLastPathComponent(),
            onChange: { [weak self] in
                Task { @MainActor in
                    self?.scheduleWatchedReload()
                }
            }
        )
    }

    public func stopWatching() {
        watcher?.cancel()
        watcher = nil
        watchedReloadTask?.cancel()
        watchedReloadTask = nil
        isExternalReloadPending = false
    }

    func handleWatchedConfigDirectoryChange() {
        isExternalReloadPending = false

        // Echo-loop suppression now lives in `apply` via per-section
        // Equatable short-circuits. The previous file-attribute signature
        // gate had a same-second-collision race window and was vulnerable
        // to in-place writes with matching size. Reloading and comparing
        // each section is cheap and removes the whole class.
        reloadFromDisk(trigger: .watcher)
    }

    private func applyLoadResult(_ result: ConfigLoadResult) {
        loadSource = result.source

        if let loadedConfig = result.config {
            apply(loadedConfig)
            latestError = nil
            isDiskConfigInvalid = false
            return
        }

        isDiskConfigInvalid = result.source == .invalidExistingFile
        latestError = result.error.map(AppSettingsStoreError.load)
    }

    /// Distributes a whole `AwesoMuxConfig` to the section stores,
    /// skipping equal-valued assignments so SwiftUI only invalidates the
    /// sections that actually changed.
    private func apply(_ newConfig: AwesoMuxConfig) {
        if general.value != newConfig.general { general.value = newConfig.general }
        if appearance.value != newConfig.appearance { appearance.value = newConfig.appearance }
        if notifications.value != newConfig.notifications { notifications.value = newConfig.notifications }
        if agents.value != newConfig.agents { agents.value = newConfig.agents }
        if agentIntegrations.value != newConfig.agentIntegrations {
            agentIntegrations.value = newConfig.agentIntegrations
        }
        if keyboard.value != newConfig.keyboard { keyboard.value = newConfig.keyboard }
        if terminal.value != newConfig.terminal { terminal.value = newConfig.terminal }
        if workspaces.value != newConfig.workspaces { workspaces.value = newConfig.workspaces }
        if advanced.value != newConfig.advanced { advanced.value = newConfig.advanced }
        if analytics.value != newConfig.analytics { analytics.value = newConfig.analytics }
        unknownTopLevelTables = newConfig.unknownTopLevelTables
        unknownTerminalTableLines = newConfig.unknownTerminalTableLines
        terminalTableLineLayout = newConfig.terminalTableLineLayout
        unknownAppearanceTableLines = newConfig.unknownAppearanceTableLines
        appearanceTableLineLayout = newConfig.appearanceTableLineLayout
    }

    private func scheduleWatchedReload() {
        watchedReloadTask?.cancel()
        isExternalReloadPending = true
        watchedReloadTask = Task { @MainActor [watchDebounceNanoseconds] in
            do {
                try await Task.sleep(nanoseconds: watchDebounceNanoseconds)
            } catch {
                isExternalReloadPending = false
                return
            }

            handleWatchedConfigDirectoryChange()
        }
    }

    /// Writes the default config to disk AND replaces the in-memory
    /// section values with defaults. Triggered when the watcher notices
    /// a file deletion: the user removed config.toml from
    /// Finder/terminal, and that gesture means "factory reset" —
    /// preserving the current in-memory state would violate the user's
    /// intent.
    private func resetToDefaultsAndWriteFile() -> Bool {
        let defaults: AwesoMuxConfig = .defaultValue
        do {
            try saveToDisk(defaults)
            apply(defaults)
            latestError = nil
            isDiskConfigInvalid = false
            loadSource = .createdDefault
            return true
        } catch {
            latestError = .save(error)
            return false
        }
    }
}

public enum AppSettingsDiagnosticTrigger: Equatable, Sendable {
    case manual
    case watcher
}

public enum AppSettingsDiagnosticEvent: Equatable, Sendable {
    case reloadSucceeded(trigger: AppSettingsDiagnosticTrigger)
    case reloadRejected(trigger: AppSettingsDiagnosticTrigger)
    case resetAfterDeletion
    case resetAfterDeletionRejected
}

public enum AppSettingsStoreError: Error, Equatable, Sendable {
    case load(ConfigLoadError)
    case save(ConfigFileStoreError)

    public var displayText: String {
        switch self {
        case .load(let error): return error.displayText
        case .save(let error): return error.displayText
        }
    }
}
