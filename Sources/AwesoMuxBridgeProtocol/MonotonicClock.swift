#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif
import Foundation

/// Shared `CLOCK_MONOTONIC` reader for bridge and transport deadline math.
public enum MonotonicClock {
    /// Current monotonic instant, carried as a synthetic `Date`.
    ///
    /// Reads `CLOCK_MONOTONIC` via `clock_gettime` and returns
    /// `Date(timeIntervalSinceReferenceDate:)` from `tv_sec`/`tv_nsec`. The
    /// return type stays `Date` (not `ContinuousClock.Instant`) so existing
    /// call sites keep using `addingTimeInterval` / `timeIntervalSince`
    /// without a type migration.
    ///
    /// This value is **not** wall-clock time. Do not format it, log it as a
    /// calendar instant, or compare it against `Date()` / other wall-clock
    /// dates — those mix incompatible timelines and produce nonsense. Use it
    /// only for elapsed-time and relative-deadline math against other
    /// monotonic readings from this helper (or an injected test clock that
    /// speaks the same timeline).
    public static func now() -> Date {
        var time = timespec()
        clock_gettime(CLOCK_MONOTONIC, &time)
        return Date(timeIntervalSinceReferenceDate: Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000)
    }
}
