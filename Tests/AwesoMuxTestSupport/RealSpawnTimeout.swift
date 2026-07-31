import Dispatch

/// Ceiling for a real `posix_spawn` whose timeout is a hang guard rather than the
/// assertion under test.
///
/// A short bound here does not measure the child. `BoundedProcessRunner` races two of
/// our own mechanisms: the output cap trips on a stdout reader parked on a
/// `DispatchQueue.global` thread (three such threads per concurrent run), while the
/// timeout fires on an independent `DispatchSource` timer that contention cannot
/// starve. On a loaded hosted runner the timer wins and the test sees `.timedOut`
/// instead of the outcome it asserts — INT-819, run 30588368340.
///
/// A generous ceiling costs passing runs nothing: the work these tests wait on
/// completes in milliseconds once scheduled. Tests where the timeout *is* the subject
/// keep their short values.
public let realSpawnTimeout: DispatchTimeInterval = .seconds(30)
