import Darwin
import Foundation

enum AgentIntegrationInstallStateLockError: Error, Equatable, Sendable {
    case busy
}

final class AgentIntegrationInstallStateLock: @unchecked Sendable {
    private var descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        release()
    }

    static func acquire(
        in directoryURL: URL,
        fileManager: FileManager = .default
    ) throws -> AgentIntegrationInstallStateLock {
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let lockURL = directoryURL.appending(path: ".install-state.lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            if code == EWOULDBLOCK || code == EAGAIN {
                throw AgentIntegrationInstallStateLockError.busy
            }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        return AgentIntegrationInstallStateLock(descriptor: descriptor)
    }

    func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }
}

enum AgentIntegrationInstallStateLocation {
    static var canonicalDirectoryURL: URL {
        AppRuntimeProfile.production.supportDirectoryURL
            .appending(path: "AgentIntegrations", directoryHint: .isDirectory)
    }

    static var legacyDevelopmentDirectoryURL: URL {
        AppRuntimeProfile.development(worktreeID: nil).supportDirectoryURL
            .appending(path: "AgentIntegrations", directoryHint: .isDirectory)
    }
}
