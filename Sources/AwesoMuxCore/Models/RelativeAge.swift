import Foundation

/// Pure relative-age formatter for the session manager's daemon age column.
/// Renders the largest whole unit ("14m" / "2h" / "3d"), matching the design's
/// compact single-token style. Kept pure (epoch + now in, string out) so the
/// session-manager view can render it without date math and it stays unit-tested.
public enum RelativeAge {
    /// Format the span between `createdEpoch` and `now` (both Unix seconds) as a
    /// single compact token. Seconds under a minute, minutes under an hour, hours
    /// under a day, days beyond. A future or equal timestamp clamps to `"0s"` —
    /// a daemon can't legitimately be created in the future, so we show the floor
    /// rather than a negative token.
    public static func string(sinceEpoch createdEpoch: Int, now: Int) -> String {
        let seconds = max(0, now - createdEpoch)
        switch seconds {
        case ..<60:
            return "\(seconds)s"
        case ..<3_600:
            return "\(seconds / 60)m"
        case ..<86_400:
            return "\(seconds / 3_600)h"
        default:
            return "\(seconds / 86_400)d"
        }
    }
}
