import Darwin
import Foundation

struct BridgeListenerDirectory: Sendable {
    enum DirectoryError: Error, Equatable {
        case creationFailed
        case insecureDirectory
        case socketPathTooLong
    }

    let directoryPath: String
    let socketPath: String

    static func create(
        socketName: String = "bridge.sock",
        directoryTemplate: String = "/tmp/awesomux-bridge-XXXXXX"
    ) throws -> BridgeListenerDirectory {
        var template = Array(directoryTemplate.utf8CString)
        guard let directoryPath = template.withUnsafeMutableBufferPointer({ buffer -> String? in
            guard let base = buffer.baseAddress, mkdtemp(base) != nil else { return nil }
            return String(cString: base)
        }) else {
            throw DirectoryError.creationFailed
        }

        do {
            guard isSecureDirectory(at: directoryPath) else {
                throw DirectoryError.insecureDirectory
            }

            let socketPath = (directoryPath as NSString).appendingPathComponent(socketName)
            let address = sockaddr_un()
            let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
            guard !socketName.isEmpty,
                  !socketName.contains("/"),
                  socketPath.utf8.count < pathCapacity
            else {
                throw DirectoryError.socketPathTooLong
            }
            return BridgeListenerDirectory(directoryPath: directoryPath, socketPath: socketPath)
        } catch {
            _ = Darwin.rmdir(directoryPath)
            throw error
        }
    }

    static func isSecureDirectory(at path: String) -> Bool {
        var status = stat()
        return lstat(path, &status) == 0
            && status.st_uid == geteuid()
            && status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
            && status.st_mode & 0o777 == 0o700
    }
}
