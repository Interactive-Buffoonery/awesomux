import Foundation

/// A TTL cache over an async lookup, sized for the Path Bar's resolvers. The Path
/// Bar re-resolves on every terminal-title change (starship/p10k emit those
/// constantly), so each subprocess-backed lookup must be cache-gated.
///
/// - Concurrent callers for the same key coalesce onto one in-flight `Task`.
/// - Entries evict least-recently-used past `cacheCap`.
/// - `ttl(Value)` decides each result's lifetime, so a hit and a miss can expire
///   on different schedules (the PR resolver does; git-status uses a flat value).
/// - Completion is guarded by entry identity: if an entry is LRU-evicted while in
///   flight and its key refetched, the stale completion must not stamp the new
///   entry's result/clock.
actor CachedAsyncResolver<Key: Hashable & Sendable, Value: Sendable> {
    private final class Entry {
        let id: UUID
        let task: Task<Value, Never>
        /// Set once the lookup finishes; nil while in flight.
        var resolved: (at: Date, value: Value)?

        init(id: UUID, task: Task<Value, Never>) {
            self.id = id
            self.task = task
        }
    }

    private let fetch: @Sendable (Key) async -> Value
    private let ttl: @Sendable (Value) -> TimeInterval
    private let cacheCap: Int
    private let now: @Sendable () -> Date

    private var cache: [Key: Entry] = [:]
    private var lru: [Key] = [] // least-recent first, most-recent last

    init(
        cacheCap: Int = 64,
        now: @escaping @Sendable () -> Date = Date.init,
        ttl: @escaping @Sendable (Value) -> TimeInterval,
        fetch: @escaping @Sendable (Key) async -> Value
    ) {
        self.cacheCap = cacheCap
        self.now = now
        self.ttl = ttl
        self.fetch = fetch
    }

    func value(for key: Key) async -> Value {
        if let entry = cache[key], !isExpired(entry) {
            touch(key)
            return await entry.task.value
        }

        let fetch = self.fetch
        let entryID = UUID()
        let task = Task<Value, Never> { [weak self] in
            let result = await fetch(key)
            await self?.complete(key: key, entryID: entryID, value: result)
            return result
        }

        let entry = Entry(id: entryID, task: task)
        cache[key] = entry
        touch(key)
        evictIfNeeded()
        return await task.value
    }

    /// Stamps an entry's completion time + value so TTL is measured from
    /// completion. The `entryID` guard is load-bearing: if this entry was evicted
    /// (LRU overflow) while in flight and the key refetched, `cache[key]` now holds
    /// a *different* entry — without the id check this stale completion would
    /// clobber the live one's value and TTL clock.
    private func complete(key: Key, entryID: UUID, value: Value) {
        guard let entry = cache[key], entry.id == entryID, entry.resolved == nil else {
            return
        }
        entry.resolved = (now(), value)
    }

    private func isExpired(_ entry: Entry) -> Bool {
        guard let resolved = entry.resolved else {
            return false // in flight — reuse it
        }
        return now().timeIntervalSince(resolved.at) > ttl(resolved.value)
    }

    private func touch(_ key: Key) {
        lru.removeAll { $0 == key }
        lru.append(key)
    }

    private func evictIfNeeded() {
        while lru.count > cacheCap, let oldest = lru.first {
            lru.removeFirst()
            cache.removeValue(forKey: oldest)?.task.cancel()
        }
    }
}
