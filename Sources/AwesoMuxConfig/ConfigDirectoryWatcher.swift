import Dispatch
import Foundation

#if canImport(Darwin)
import Darwin
#endif

final class ConfigDirectoryWatcher: @unchecked Sendable {
    private let lock = NSLock()
    private var source: DispatchSourceFileSystemObject?

    init?(
        directoryURL: URL,
        queue: DispatchQueue = DispatchQueue(label: "dev.awesomux.config-directory-watcher"),
        onChange: @escaping @Sendable () -> Void
    ) {
        #if canImport(Darwin)
        let descriptor = open(directoryURL.path, O_EVTONLY)
        guard descriptor >= 0 else {
            return nil
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .revoke],
            queue: queue
        )
        source.setEventHandler(handler: onChange)
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()
        self.source = source
        #else
        return nil
        #endif
    }

    func cancel() {
        lock.lock()
        let source = self.source
        self.source = nil
        lock.unlock()

        source?.cancel()
    }

    deinit {
        cancel()
    }
}
