import CoreServices
import Foundation

/// Watches a provider transcript hierarchy recursively while exact-identity
/// discovery is waiting for a source to appear or move.
///
/// `DocumentFileWatcher` deliberately follows one inode. That is the right
/// contract after discovery pins a transcript, but not before it: Claude and
/// Codex place logs below project/date subdirectories, and a vnode watch on
/// `projects` or `sessions` does not observe changes in existing descendants.
/// FSEvents is the macOS hierarchy-level notification API, and `watchRoot`
/// also reports changes along an initially absent root's path.
@MainActor
final class AgentTranscriptDirectoryWatcher {
    private final class CallbackBox {
        let onChange: @MainActor () -> Void
        let matchesPath: @Sendable (String) -> Bool

        init(
            matchesPath: @Sendable @escaping (String) -> Bool,
            onChange: @MainActor @escaping () -> Void
        ) {
            self.matchesPath = matchesPath
            self.onChange = onChange
        }
    }

    private let rootURL: URL
    private let matchesPath: @Sendable (String) -> Bool
    private let onChange: @MainActor () -> Void
    private var stream: FSEventStreamRef?
    private var stopped = false

    init(
        rootURL: URL,
        matchesPath: @Sendable @escaping (String) -> Bool,
        onChange: @MainActor @escaping () -> Void
    ) {
        self.rootURL = rootURL
        self.matchesPath = matchesPath
        self.onChange = onChange
    }

    isolated deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    func start() -> Bool {
        guard !stopped, stream == nil else { return false }

        let callbackBox = CallbackBox(matchesPath: matchesPath, onChange: onChange)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(callbackBox).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<CallbackBox>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<CallbackBox>.fromOpaque(info).release()
            },
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = {
            _, callbackInfo, eventCount, eventPaths, eventFlags, _ in
            guard eventCount > 0, let callbackInfo else { return }
            let box = Unmanaged<CallbackBox>.fromOpaque(callbackInfo).takeUnretainedValue()
            let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
            let rescanFlags = FSEventStreamEventFlags(
                kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                    | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged
            )
            let isRelevant = (0..<min(Int(eventCount), paths.count)).contains { index in
                eventFlags[index] & rescanFlags != 0 || box.matchesPath(paths[index])
            }
            guard isRelevant else { return }
            MainActor.assumeIsolated { box.onChange() }
        }
        guard
            let created = FSEventStreamCreate(
                nil,
                callback,
                &context,
                [rootURL.standardizedFileURL.path] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                0.05,
                FSEventStreamCreateFlags(
                    kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot
                        | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
                )
            )
        else {
            return false
        }

        FSEventStreamSetDispatchQueue(created, .main)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return false
        }
        stream = created
        return true
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
