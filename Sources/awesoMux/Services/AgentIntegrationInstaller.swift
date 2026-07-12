import AwesoMuxConfig
import Foundation
import os

enum AgentIntegrationInstallProvider: String, Codable, CaseIterable, Hashable, Sendable {
    case openCode = "open_code"
    case pi

    var templateRelativePath: String {
        switch self {
        case .openCode:
            "AgentIntegrations/open_code/awesomux-opencode-status.js.template"
        case .pi:
            "AgentIntegrations/pi/awesomux-pi-status.ts.template"
        }
    }

    var renderedFileName: String {
        switch self {
        case .openCode:
            "awesomux-opencode-status.js"
        case .pi:
            "awesomux-pi-status.ts"
        }
    }

    func globalConfigHome(homeDirectory: URL) -> URL {
        switch self {
        case .openCode:
            homeDirectory
                .appending(path: ".config", directoryHint: .isDirectory)
                .appending(path: "opencode", directoryHint: .isDirectory)
        case .pi:
            homeDirectory
                .appending(path: ".pi", directoryHint: .isDirectory)
                .appending(path: "agent", directoryHint: .isDirectory)
        }
    }

    func globalExtensionDirectory(configHome: URL) -> URL {
        switch self {
        case .openCode:
            configHome.appending(path: "plugins", directoryHint: .isDirectory)
        case .pi:
            configHome.appending(path: "extensions", directoryHint: .isDirectory)
        }
    }

}

struct AgentIntegrationInstallRecord: Codable, Equatable, Sendable {
    var provider: AgentIntegrationInstallProvider
    var binaryPath: String?
    var configHome: String?
    var templatePath: String
    var renderedPath: String
    var installedPath: String?
}

struct AgentIntegrationInstallManifest: Codable, Equatable, Sendable {
    var version: Int
    var records: [AgentIntegrationInstallRecord]

    static let currentVersion = 1
    static let empty = AgentIntegrationInstallManifest(
        version: currentVersion,
        records: []
    )
}

struct AgentIntegrationRenderedInstall: Equatable, Sendable {
    var provider: AgentIntegrationInstallProvider
    var templateURL: URL
    var renderedURL: URL
    var manifestURL: URL
}

struct AgentIntegrationInstalledTemplate: Equatable, Sendable {
    var renderedInstall: AgentIntegrationRenderedInstall
    var installedURL: URL
}

enum AgentIntegrationInstallerError: Error, Equatable, Sendable {
    case providerDisabled(AgentIntegrationInstallProvider)
    case missingTemplate(URL)
    case invalidPath(String)
    case executableNotFound(URL)
    case executableIsDirectory(URL)
    case executableNotExecutable(URL)
    case configHomeIsNotDirectory(URL)
    case unsupportedManifestVersion(Int)
    case installedFileModified(URL)
    case installStateBusy
}

struct AgentIntegrationInstaller {
    private static let logger = Logger(
        subsystem: "com.interactivebuffoonery.awesomux",
        category: "AgentIntegrationInstaller"
    )

    var resourcesDirectoryURL: URL
    var supportDirectoryURL: URL
    var installStateDirectoryURL: URL
    var legacyInstallStateDirectoryURL: URL
    var fileManager: FileManager

    init(
        resourcesDirectoryURL: URL = Bundle.main.resourceURL ?? Bundle.main.bundleURL,
        supportDirectoryURL: URL? = nil,
        installStateDirectoryURL: URL? = nil,
        legacyInstallStateDirectoryURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        let resolvedSupportDirectoryURL = supportDirectoryURL ?? SessionPersistence.supportDirectoryURL
        let resolvedInstallStateDirectoryURL = installStateDirectoryURL
            ?? supportDirectoryURL?.appending(path: "AgentIntegrations", directoryHint: .isDirectory)
            ?? AgentIntegrationInstallStateLocation.canonicalDirectoryURL
        self.resourcesDirectoryURL = resourcesDirectoryURL
        self.supportDirectoryURL = resolvedSupportDirectoryURL
        self.installStateDirectoryURL = resolvedInstallStateDirectoryURL
        self.legacyInstallStateDirectoryURL = legacyInstallStateDirectoryURL
            ?? (supportDirectoryURL == nil && installStateDirectoryURL == nil
                ? AgentIntegrationInstallStateLocation.legacyDevelopmentDirectoryURL
                : resolvedInstallStateDirectoryURL)
        self.fileManager = fileManager
    }

    var rootDirectoryURL: URL {
        supportDirectoryURL.appending(path: "AgentIntegrations", directoryHint: .isDirectory)
    }

    var manifestURL: URL {
        installStateDirectoryURL.appending(path: "install-manifest.json")
    }

    func templateURL(provider: AgentIntegrationInstallProvider) -> URL {
        resourcesDirectoryURL.appending(path: provider.templateRelativePath)
    }

    func renderedFileURL(
        provider: AgentIntegrationInstallProvider,
        setup: AgentIntegrationSetup
    ) -> URL {
        rootDirectoryURL
            .appending(path: "rendered", directoryHint: .isDirectory)
            .appending(path: provider.rawValue, directoryHint: .isDirectory)
            .appending(path: stableSetupID(provider: provider, setup: setup), directoryHint: .isDirectory)
            .appending(path: provider.renderedFileName)
    }

    func render(
        provider: AgentIntegrationInstallProvider,
        setup: AgentIntegrationSetup
    ) throws -> AgentIntegrationRenderedInstall {
        guard setup.enabled else {
            throw AgentIntegrationInstallerError.providerDisabled(provider)
        }

        let templateURL = templateURL(provider: provider)
        guard fileManager.fileExists(atPath: templateURL.path) else {
            throw AgentIntegrationInstallerError.missingTemplate(templateURL)
        }

        try createPrivateDirectory(rootDirectoryURL)
        let renderedURL = renderedFileURL(provider: provider, setup: setup)
        try createPrivateDirectory(renderedURL.deletingLastPathComponent())
        let data = try Data(contentsOf: templateURL)
        try writePrivateFile(data, to: renderedURL)

        return AgentIntegrationRenderedInstall(
            provider: provider,
            templateURL: templateURL,
            renderedURL: renderedURL,
            manifestURL: manifestURL
        )
    }

    func install(
        provider: AgentIntegrationInstallProvider,
        setup: AgentIntegrationSetup,
        homeDirectory: URL
    ) throws -> AgentIntegrationInstalledTemplate {
        guard setup.enabled else {
            throw AgentIntegrationInstallerError.providerDisabled(provider)
        }

        _ = try validateExecutablePath(setup.binaryPath)

        try importLegacyManifestIfNeeded()
        let renderedInstall = try render(provider: provider, setup: setup)
        let installedURL = try destinationFileURL(
            provider: provider,
            homeDirectory: homeDirectory,
            configuredConfigHome: setup.configHome
        )
        let lock = try acquireInstallStateLock()
        defer { lock.release() }

        var manifest = try loadManifestFile()
        let priorRecord = manifest.records.first { $0.matchesSetup(provider: provider) }
        let priorInstalledPath = priorRecord?.installedPath
        let priorRenderedPath = priorRecord?.renderedPath
        try createProviderDirectory(installedURL.deletingLastPathComponent())

        // A single Remove button tracks one installed file per setup, so when an
        // install lands at a new path (e.g. a changed config home moves the
        // global destination) the previously tracked file would otherwise be
        // orphaned beyond reach of uninstall. Remove the old managed file first,
        // honoring the same modified-file safety check, before recording the new
        // location.
        if let priorInstalledPath, let priorRenderedPath,
           priorInstalledPath != installedURL.path {
            try removeManagedFile(
                at: URL(fileURLWithPath: priorInstalledPath),
                renderedPath: priorRenderedPath
            )
        }

        let data = try Data(contentsOf: renderedInstall.renderedURL)
        try writePrivateFile(data, to: installedURL)

        let record = AgentIntegrationInstallRecord(
            provider: provider,
            binaryPath: normalizedOptional(setup.binaryPath),
            configHome: normalizedOptional(setup.configHome),
            templatePath: renderedInstall.templateURL.path,
            renderedPath: renderedInstall.renderedURL.path,
            installedPath: installedURL.path
        )
        manifest.upsert(record)
        try saveManifest(manifest)

        return AgentIntegrationInstalledTemplate(
            renderedInstall: renderedInstall,
            installedURL: installedURL
        )
    }

    @discardableResult
    func uninstall(provider: AgentIntegrationInstallProvider) throws -> URL? {
        try importLegacyManifestIfNeeded()
        let lock = try acquireInstallStateLock()
        defer { lock.release() }
        var manifest = try loadManifestFile()
        guard let index = manifest.records.firstIndex(where: {
            $0.matchesSetup(provider: provider)
        }) else {
            return nil
        }
        guard let installedPath = manifest.records[index].installedPath else {
            return nil
        }

        let installedURL = URL(fileURLWithPath: installedPath)
        try removeManagedFile(at: installedURL, renderedPath: manifest.records[index].renderedPath)

        manifest.records[index].installedPath = nil
        try saveManifest(manifest)
        return installedURL
    }

    /// Cap for status-time install/template reads (availability guard).
    static let maximumTemplateCompareByteCount = 512 * 1024

    /// Whether the installed extension body differs from the current bundled
    /// template. Used by Settings status so an app update that ships new
    /// OpenCode/Pi status code can offer Repair instead of looking current.
    /// Unreadable / oversize paths return `false` so a transient FS error does
    /// not flip a healthy install into "Update available".
    ///
    /// Results are cached by path + mtime + size so Settings body re-renders
    /// (path field typing) do not re-read the same files every frame.
    func installedContentDiffersFromTemplate(
        installedPath: String,
        templateURL: URL
    ) -> Bool {
        let cacheKey = "\(installedPath)\u{1F}\(templateURL.path)"
        let installedAttrs = try? fileManager.attributesOfItem(atPath: installedPath)
        let templateAttrs = try? fileManager.attributesOfItem(atPath: templateURL.path)
        let installedMTime = (installedAttrs?[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? -1
        let templateMTime = (templateAttrs?[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? -1
        let installedSize = (installedAttrs?[.size] as? NSNumber)?.intValue ?? -1
        let templateSize = (templateAttrs?[.size] as? NSNumber)?.intValue ?? -1
        let signature = "\(installedMTime)|\(installedSize)|\(templateMTime)|\(templateSize)"

        Self.compareCacheLock.lock()
        if let cached = Self.compareCache[cacheKey], cached.signature == signature {
            let differs = cached.differs
            Self.compareCacheLock.unlock()
            return differs
        }
        Self.compareCacheLock.unlock()

        guard fileManager.fileExists(atPath: installedPath),
              fileManager.fileExists(atPath: templateURL.path),
              installedSize >= 0,
              templateSize >= 0,
              installedSize <= Self.maximumTemplateCompareByteCount,
              templateSize <= Self.maximumTemplateCompareByteCount,
              let installedData = try? Data(contentsOf: URL(fileURLWithPath: installedPath)),
              let templateData = try? Data(contentsOf: templateURL)
        else {
            return false
        }
        let differs = installedData != templateData

        Self.compareCacheLock.lock()
        Self.compareCache[cacheKey] = (signature: signature, differs: differs)
        Self.compareCacheLock.unlock()
        return differs
    }

    private static let compareCacheLock = NSLock()
    nonisolated(unsafe) private static var compareCache: [String: (signature: String, differs: Bool)] = [:]

    /// Removes an awesoMux-managed installed file, refusing if the on-disk
    /// contents no longer match the rendered template (or the rendered copy is
    /// gone). A missing installed file is treated as already removed.
    private func removeManagedFile(at installedURL: URL, renderedPath: String) throws {
        guard fileManager.fileExists(atPath: installedURL.path) else {
            return
        }

        let renderedURL = URL(fileURLWithPath: renderedPath)
        guard fileManager.fileExists(atPath: renderedURL.path) else {
            throw AgentIntegrationInstallerError.installedFileModified(installedURL)
        }

        let installedData = try Data(contentsOf: installedURL)
        let renderedData = try Data(contentsOf: renderedURL)
        guard installedData == renderedData else {
            throw AgentIntegrationInstallerError.installedFileModified(installedURL)
        }

        try fileManager.removeItem(at: installedURL)
    }

    func destinationFileURL(
        provider: AgentIntegrationInstallProvider,
        homeDirectory: URL,
        configuredConfigHome: String? = nil
    ) throws -> URL {
        let configHome = try configHomeURL(
            configuredConfigHome,
            defaultURL: provider.globalConfigHome(homeDirectory: homeDirectory)
        )
        let directory = provider.globalExtensionDirectory(configHome: configHome)
        return directory.appending(path: provider.renderedFileName)
    }

    func validateExecutablePath(_ path: String?) throws -> URL? {
        guard let path = normalizedOptional(path) else {
            return nil
        }
        guard path.hasPrefix("/") else {
            throw AgentIntegrationInstallerError.invalidPath(path)
        }

        let url = URL(fileURLWithPath: path)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw AgentIntegrationInstallerError.executableNotFound(url)
        }
        guard !isDirectory.boolValue else {
            throw AgentIntegrationInstallerError.executableIsDirectory(url)
        }
        guard fileManager.isExecutableFile(atPath: url.path) else {
            throw AgentIntegrationInstallerError.executableNotExecutable(url)
        }

        return url
    }

    func validateConfigHomePath(_ path: String?) throws -> URL? {
        guard let path = normalizedOptional(path) else {
            return nil
        }
        return try configHomeURL(path, defaultURL: nil)
    }

    @discardableResult
    func prepareConfigHome(_ path: String?) throws -> URL? {
        guard let path = normalizedOptional(path) else {
            return nil
        }
        let url = try configHomeURL(path, defaultURL: nil)
        try createProviderDirectory(url)
        return url
    }

    func loadManifest() throws -> AgentIntegrationInstallManifest {
        try importLegacyManifestIfNeeded()
        return try loadManifestFile()
    }

    private func loadManifestFile() throws -> AgentIntegrationInstallManifest {
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            return .empty
        }

        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(AgentIntegrationInstallManifest.self, from: data)
        guard manifest.version <= AgentIntegrationInstallManifest.currentVersion else {
            throw AgentIntegrationInstallerError.unsupportedManifestVersion(manifest.version)
        }
        return manifest
    }

    private func saveManifest(_ manifest: AgentIntegrationInstallManifest) throws {
        try createPrivateDirectory(installStateDirectoryURL)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(manifest)
        try writePrivateFile(data, to: manifestURL)
    }

    private func importLegacyManifestIfNeeded() throws {
        guard !fileManager.fileExists(atPath: manifestURL.path) else { return }
        let legacyURL = legacyInstallStateDirectoryURL.appending(path: "install-manifest.json")
        guard legacyURL != manifestURL, fileManager.fileExists(atPath: legacyURL.path) else { return }

        let lock = try acquireInstallStateLock()
        defer { lock.release() }
        guard !fileManager.fileExists(atPath: manifestURL.path) else { return }
        let data = try Data(contentsOf: legacyURL)
        guard let manifest = try? JSONDecoder().decode(AgentIntegrationInstallManifest.self, from: data),
              manifest.version <= AgentIntegrationInstallManifest.currentVersion else {
            Self.logger.error(
                "ignoring unreadable legacy install manifest at \(legacyURL.path, privacy: .private)"
            )
            return
        }
        try createPrivateDirectory(installStateDirectoryURL)
        try writePrivateFile(data, to: manifestURL)
    }

    private func acquireInstallStateLock() throws -> AgentIntegrationInstallStateLock {
        do {
            return try AgentIntegrationInstallStateLock.acquire(
                in: installStateDirectoryURL,
                fileManager: fileManager
            )
        } catch AgentIntegrationInstallStateLockError.busy {
            throw AgentIntegrationInstallerError.installStateBusy
        }
    }

    private func configHomeURL(_ path: String?, defaultURL: URL?) throws -> URL {
        guard let path = normalizedOptional(path) else {
            if let defaultURL {
                return defaultURL
            }
            throw AgentIntegrationInstallerError.invalidPath("")
        }
        guard path.hasPrefix("/") else {
            throw AgentIntegrationInstallerError.invalidPath(path)
        }

        let url = URL(fileURLWithPath: path, isDirectory: true)
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
           !isDirectory.boolValue {
            throw AgentIntegrationInstallerError.configHomeIsNotDirectory(url)
        }
        return url
    }

    private func createPrivateDirectory(_ url: URL) throws {
        try createDirectory(url, preservesExistingPermissions: false)
    }

    private func createProviderDirectory(_ url: URL) throws {
        try createDirectory(url, preservesExistingPermissions: true)
    }

    private func createDirectory(_ url: URL, preservesExistingPermissions: Bool) throws {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw AgentIntegrationInstallerError.configHomeIsNotDirectory(url)
            }
            if !preservesExistingPermissions {
                setPrivatePermissions(0o700, on: url)
            }
        } else {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            setPrivatePermissions(0o700, on: url)
        }
    }

    private func writePrivateFile(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic])
        setPrivatePermissions(0o600, on: url)
    }

    private func setPrivatePermissions(_ permissions: Int, on url: URL) {
        do {
            try fileManager.setAttributes(
                [.posixPermissions: permissions],
                ofItemAtPath: url.path
            )
        } catch {
            Self.logger.error(
                "failed to set private permissions on \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func stableSetupID(
        provider: AgentIntegrationInstallProvider,
        setup: AgentIntegrationSetup
    ) -> String {
        let key = [
            provider.rawValue,
            normalizedOptional(setup.binaryPath) ?? "",
            normalizedOptional(setup.configHome) ?? ""
        ].joined(separator: "\u{1F}")
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }

    func normalizedOptional(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension AgentIntegrationInstallManifest {
    mutating func upsert(_ record: AgentIntegrationInstallRecord) {
        version = Self.currentVersion
        if let index = records.firstIndex(where: { $0.provider == record.provider }) {
            records[index] = record
        } else {
            records.append(record)
        }
    }
}

private extension AgentIntegrationInstallRecord {
    // Installs are global-only and one-per-provider, so the provider alone is
    // the manifest identity. Binary path and config home are attributes of that
    // single record; changing the config home moves the install rather than
    // creating a second record, which keeps the prior file reachable by the
    // orphan-removal step in `install`.
    func matchesSetup(provider: AgentIntegrationInstallProvider) -> Bool {
        self.provider == provider
    }
}
