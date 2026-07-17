import Foundation

protocol AgentInstallManifest: Codable {
    static var currentVersion: Int { get }
    static var empty: Self { get }

    var version: Int { get set }
}

enum AgentInstallManifestLoadError: Error, Equatable {
    case unreadable
    case corrupt
    case busy
    case unavailable
    case recoverableUnsupportedVersion(Int)
    case unsupportedVersion(Int)
}

enum AgentInstallManifestLoadState<Manifest> {
    case missing
    case loaded(Manifest)
    case failed(AgentInstallManifestLoadError)
}

struct AgentInstallManifestStore<Manifest: AgentInstallManifest> {
    var manifestURL: URL
    var legacyManifestURL: URL
    var fileManager: FileManager

    var directoryURL: URL {
        manifestURL.deletingLastPathComponent()
    }

    func loadState() -> AgentInstallManifestLoadState<Manifest> {
        do {
            try importLegacyIfNeeded()
            return readState(at: manifestURL)
        } catch AgentIntegrationInstallStateLockError.busy {
            return .failed(.busy)
        } catch {
            return .failed(.unavailable)
        }
    }

    func loadCurrent() throws -> Manifest {
        try importLegacyIfNeeded()
        return try currentManifest(from: readState(at: manifestURL))
    }

    func loadForMutationRecoveringEmptyUnsupported() throws -> Manifest {
        let state = readState(at: manifestURL)
        guard case .failed(.recoverableUnsupportedVersion(let version)) = state else {
            return try currentManifest(from: state)
        }

        try backUpUnsupportedManifest(version: version)
        try importLegacyIfNeededAssumingLock()
        return try currentManifest(from: readState(at: manifestURL))
    }

    func save(_ manifest: Manifest) throws {
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(manifest)
        try writePrivateFile(data, to: manifestURL)
    }

    func importLegacyIfNeeded() throws {
        guard !fileManager.fileExists(atPath: manifestURL.path),
            legacyManifestURL != manifestURL,
            fileManager.fileExists(atPath: legacyManifestURL.path)
        else {
            return
        }

        let lock = try AgentIntegrationInstallStateLock.acquire(
            in: directoryURL,
            fileManager: fileManager
        )
        defer { lock.release() }
        try importLegacyIfNeededAssumingLock()
    }

    func importLegacyIfNeededAssumingLock() throws {
        guard !fileManager.fileExists(atPath: manifestURL.path),
            legacyManifestURL != manifestURL,
            fileManager.fileExists(atPath: legacyManifestURL.path)
        else {
            return
        }
        // Legacy state is a best-effort migration from development profiles,
        // never the canonical ownership source. Invalid legacy files must not
        // poison a clean production install state.
        guard case .loaded = readState(at: legacyManifestURL) else {
            return
        }

        let data = try Data(contentsOf: legacyManifestURL)
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try writePrivateFile(data, to: manifestURL)
    }

    private func readState(at url: URL) -> AgentInstallManifestLoadState<Manifest> {
        guard fileManager.fileExists(atPath: url.path) else {
            return .missing
        }
        guard let data = try? Data(contentsOf: url) else {
            return .failed(.unreadable)
        }
        guard let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else {
            return .failed(.corrupt)
        }
        guard manifest.version <= Manifest.currentVersion else {
            return .failed(
                isRecognizedEmptyFutureManifest(data, version: manifest.version)
                    ? .recoverableUnsupportedVersion(manifest.version)
                    : .unsupportedVersion(manifest.version)
            )
        }
        return .loaded(manifest)
    }

    private func isRecognizedEmptyFutureManifest(_ data: Data, version: Int) -> Bool {
        guard version == Manifest.currentVersion + 1,
            let object = try? JSONSerialization.jsonObject(with: data),
            let dictionary = object as? [String: Any],
            Set(dictionary.keys) == ["records", "version"],
            let encodedVersion = dictionary["version"] as? NSNumber,
            encodedVersion.intValue == version,
            let records = dictionary["records"] as? [Any]
        else {
            return false
        }
        return records.isEmpty
    }

    private func currentManifest(
        from state: AgentInstallManifestLoadState<Manifest>
    ) throws -> Manifest {
        switch state {
        case .missing:
            return .empty
        case .loaded(let manifest):
            return manifest
        case .failed(let error):
            throw error
        }
    }

    private func backUpUnsupportedManifest(version: Int) throws {
        let stem =
            manifestURL.deletingPathExtension().lastPathComponent
            + ".unsupported-v\(version).backup"
        var backupURL = directoryURL.appending(path: "\(stem).json")
        if fileManager.fileExists(atPath: backupURL.path) {
            backupURL = directoryURL.appending(path: "\(stem)-\(UUID().uuidString).json")
        }
        try fileManager.moveItem(at: manifestURL, to: backupURL)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: backupURL.path
        )
    }

    private func writePrivateFile(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic])
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }
}
