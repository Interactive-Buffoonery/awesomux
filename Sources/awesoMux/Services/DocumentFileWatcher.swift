import Darwin
import Dispatch
import Foundation

// MARK: - DocumentFileWatcher

/// Watches a file for changes using a vnode-based `DispatchSourceFileSystemObject`.
///
/// Atomic writes (and most text-editor saves) replace the inode via rename, which
/// fires `.rename` / `.delete` events on the original fd and leaves the old fd
/// watching a now-unlinked inode. `DocumentFileWatcher` handles this by
/// cancelling the current source, closing the fd, reopening the path, and
/// re-arming on the new inode — the rename-replace re-arm path.
///
/// A brief ENOENT between unlink and the new inode's creation is tolerated via a
/// short retry loop. Multiple rapid events in the same write cycle are debounced
/// to one `onChange` callback delivered on the main actor.
///
/// Usage (from a SwiftUI view's `.onAppear`/`.task`):
/// ```swift
/// let watcher = DocumentFileWatcher(url: fileURL) { /* reload — @MainActor */ }
/// watcher.start()
/// // …later (in .onDisappear):
/// watcher.stop()   // idempotent
/// ```
///
/// ## Swift 6 isolation
/// `DocumentFileWatcher` is `@MainActor`. The `DispatchSourceFileSystemObject` uses
/// `DispatchQueue.main` as its target queue so event handlers fire on the main actor
/// without crossing isolation boundaries (following the same pattern as
/// `AgentRuntimeEventBridge`). Handlers use `MainActor.assumeIsolated` to access
/// instance state safely.
@MainActor
final class DocumentFileWatcher {

    // MARK: - State (all @MainActor)

    private let url: URL
    private let onChange: @MainActor () -> Void

    private var source: DispatchSourceFileSystemObject?
    private var debounceTask: Task<Void, Never>?
    private var stopped = false

    // MARK: - Lifecycle

    init(url: URL, onChange: @escaping @MainActor () -> Void) {
        self.url = url
        self.onChange = onChange
    }

    deinit {
        // Cancel the source so its cancel handler runs and closes the fd.
        // `cancel()` is safe to call from any context; it enqueues the
        // cancel handler on the source's own queue.
        //
        // Swift 6 isolation note: `DocumentFileWatcher` is `@MainActor` and the
        // source target queue IS DispatchQueue.main, so `source?.cancel()` here
        // is isolation-safe (cancel() is a non-isolated DispatchSource call).
        // The project builds WARNING-FREE under Swift 6 — no refactor needed.
        // Normal teardown is via `stop()`/`onDisappear`; deinit is a backstop.
        source?.cancel()
        // Fix I4: also cancel the pending debounce task so it does not linger
        // ~100 ms after the watcher is released.
        debounceTask?.cancel()
    }

    /// Start watching. Idempotent if already watching.
    func start() {
        guard !stopped else { return }
        arm()
    }

    /// Stop watching and release all resources. Idempotent.
    func stop() {
        stopped = true
        debounceTask?.cancel()
        debounceTask = nil
        source?.cancel()
        source = nil
    }

    // MARK: - Internal (@MainActor)

    /// Arm (or re-arm) the vnode watch on the file's current inode.
    ///
    /// If the file is momentarily absent (ENOENT — transient during atomic replace),
    /// schedule a brief retry.
    private func arm(retryBudget: Int = 20) {
        // Bail if stop() fired while a retry was sleeping — otherwise the retry path
        // would re-arm a live source after teardown, leaking the fd/source until deinit.
        guard !stopped else { return }
        // Tear down any existing source before re-arming.
        source?.cancel()
        source = nil

        let path = url.path
        let fd = Darwin.open(path, O_EVTONLY | O_CLOEXEC)

        guard fd != -1 else {
            guard retryBudget > 0 else { return }
            // Tolerate a transient ENOENT: the file may be briefly absent between the
            // unlink and the creation of the replacement inode during an atomic write.
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 10_000_000)  // 10 ms
                self?.arm(retryBudget: retryBudget - 1)
            }
            return
        }

        // Use DispatchQueue.main as the target queue so the event handler runs on
        // the main actor without any isolation crossing. This matches the pattern
        // used by AgentRuntimeEventBridge and avoids the vnode-source-on-background-
        // queue crash that occurs in the test environment.
        let newSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend],
            queue: .main
        )

        // The cancel handler runs on the main queue after cancel(). It closes the fd.
        // `fd` is captured by value (Int32 is Sendable) — no shared mutable state.
        newSource.setCancelHandler {
            Darwin.close(fd)
        }

        // The event handler fires on the main queue. Use assumeIsolated so we can
        // access @MainActor state without an async hop (no Task overhead here).
        newSource.setEventHandler { [weak self, weak newSource] in
            guard let self, let data = newSource?.data else { return }
            MainActor.assumeIsolated {
                // Pin to this source generation: after a rename-replace re-arm,
                // the stored source is a new instance; stale fires from the old
                // source must be no-ops.
                guard self.source === newSource else { return }
                let isReplacement = data.contains(.delete) || data.contains(.rename)
                self.handleEvent(isReplacement: isReplacement)
            }
        }

        newSource.resume()
        source = newSource
    }

    /// Handle a vnode event (main actor).
    private func handleEvent(isReplacement: Bool) {
        guard !stopped else { return }

        if isReplacement {
            // Atomic replace: the watched inode is gone. Tear down the source and
            // re-arm on the new inode after a brief filesystem-settle delay.
            source?.cancel()
            source = nil
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 20_000_000)  // 20 ms settle
                guard let self, !self.stopped else { return }
                self.arm()
                self.scheduleOnChange()
            }
        } else {
            scheduleOnChange()
        }
    }

    /// Schedule a debounced `onChange` call (~100 ms coalescence window).
    private func scheduleOnChange() {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000)  // 100 ms
            guard let self, !self.stopped, !Task.isCancelled else { return }
            self.onChange()
        }
    }
}
