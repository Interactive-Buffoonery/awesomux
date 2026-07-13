import Foundation

public final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    public init(_ start: Date = Date(timeIntervalSince1970: 1_000_000)) {
        current = start
    }

    public var now: Date {
        lock.withLock { current }
    }

    public func advance(by interval: TimeInterval) {
        lock.withLock { current += interval }
    }

    public func set(_ date: Date) {
        lock.withLock { current = date }
    }
}
