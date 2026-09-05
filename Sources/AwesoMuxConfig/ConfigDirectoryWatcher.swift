import Darwin
import Dispatch
import Foundation

/// Owns observation of both the config entry and the resource behind it.
/// Descriptors only deliver hints; ConfigFileStore still validates every read.
final class ConfigDirectoryWatcher: @unchecked Sendable {
    private struct Observation {
        let device: dev_t
        let inode: ino_t
        let source: DispatchSourceFileSystemObject
    }

    private let lock = NSLock()
    private let fileStore: ConfigFileStore
    private let queue: DispatchQueue
    private let onChange: @Sendable () -> Void
    private var observations: [String: Observation] = [:]
    private var stopped = false

    init(
        fileStore: ConfigFileStore,
        queue: DispatchQueue = DispatchQueue(label: "dev.awesomux.config-directory-watcher"),
        onChange: @escaping @Sendable () -> Void
    ) {
        self.fileStore = fileStore
        self.queue = queue
        self.onChange = onChange
        lock.lock()
        refresh()
        lock.unlock()
    }

    /// Called under the lock. Keep existing identities armed while opening
    /// replacements, so an atomic save cannot leave us watching a dead inode.
    private func refresh() {
        let target = fileStore.resolvedConfigURL()
        let desiredPaths = Set([
            fileStore.configURL.deletingLastPathComponent().path,
            target.deletingLastPathComponent().path,
            target.path,
        ])
        var paths = Set<String>()
        for desiredPath in desiredPaths {
            guard let (path, descriptor) = openNearestExistingPath(desiredPath) else { continue }
            paths.insert(path)
            var info = stat()
            guard fstat(descriptor, &info) == 0,
                info.st_mode & S_IFMT == S_IFREG || info.st_mode & S_IFMT == S_IFDIR
            else {
                close(descriptor)
                continue
            }
            if let existing = observations[path], existing.device == info.st_dev, existing.inode == info.st_ino {
                close(descriptor)
                continue
            }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .extend, .attrib, .delete, .rename, .revoke],
                queue: queue
            )
            source.setEventHandler { [weak self] in self?.changed() }
            // Reconcile after kevent registration, including edits made while
            // the new descriptor was being armed.
            source.setRegistrationHandler { [weak self] in self?.changed() }
            source.setCancelHandler { close(descriptor) }
            let previous = observations.updateValue(
                Observation(device: info.st_dev, inode: info.st_ino, source: source), forKey: path
            )
            source.resume()
            previous?.source.cancel()
        }
        for path in observations.keys where !paths.contains(path) {
            observations.removeValue(forKey: path)?.source.cancel()
        }
    }

    /// A removed dotfiles directory needs an ancestor to announce its return.
    /// The walk is bounded by the path depth and does not poll.
    private func openNearestExistingPath(_ requestedPath: String) -> (String, Int32)? {
        var path = requestedPath
        while true {
            let descriptor = open(path, O_EVTONLY | O_CLOEXEC)
            if descriptor >= 0 { return (path, descriptor) }
            guard errno == ENOENT || errno == ENOTDIR else { return nil }
            let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
            guard parent != path else { return nil }
            path = parent
        }
    }

    private func changed() {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        refresh()
        lock.unlock()
        onChange()
    }

    func cancel() {
        lock.lock()
        stopped = true
        let sources = observations.values.map(\.source)
        observations.removeAll()
        lock.unlock()
        for source in sources { source.cancel() }
    }

    deinit { cancel() }
}
