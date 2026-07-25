import Foundation

/// Bounded "wait for a sentinel file" fragments for shell fixtures — the
/// shell-side twin of `waitUntilExitEventually` and `waitForFile`.
///
/// A bare `while [ ! -e "$SENTINEL" ]; do sleep 0.01; done` spins at 100 Hz
/// forever when the sentinel never arrives: the test aborts before writing it,
/// or the suite's own `defer { removeItem(at: root) }` deletes the directory it
/// would have lived in. The shell then reparents to launchd with nothing
/// holding a reference to kill it. Six such orphans were found alive on a dev
/// machine, two of them 24 hours old, burning 26% CPU between them.
///
/// Bounding the Swift waiter (awesomux#207) does not cover this: that fix
/// deliberately never calls `terminate()` on timeout, so the child outliving
/// its waiter is the expected path, not the exceptional one.
public enum ShellWait {
    /// Deliberately under `waitUntilExitEventually`'s 30s deadline. The shell
    /// must die BEFORE the Swift waiter stops watching — the reverse ordering
    /// guarantees a window where nothing supervises the child, and the child
    /// spends that window forking `/bin/sleep` at exactly the rate that
    /// awesomux#207 blames for dropped termination events.
    public static let defaultSeconds = 15

    /// 50ms rather than 10ms: `sleep` is not a `/bin/sh` builtin, so every
    /// iteration costs a fork+exec (~1.7ms measured). At 10ms that overhead is
    /// 17% of the interval and ~3.5x the CPU for the same wall-clock bound; at
    /// 50ms it is ~3%, which also keeps `seconds` roughly honest. Matches the
    /// interval the production lock loop already uses in `AmxBackend`.
    private static let pollInterval = "0.05"
    private static let pollsPerSecond = 20

    /// Waits for `path`, quoting it internally.
    public static func untilExists(path: String, seconds: Int = defaultSeconds) -> String {
        fragment(word: quote(path), seconds: seconds)
    }

    /// Waits for the file named by shell variable `variable` (no `$`, no quotes
    /// — `untilExists(variable: "RACE_RELEASE")` emits `"$RACE_RELEASE"`).
    ///
    /// Two entry points rather than one raw-string parameter: a single
    /// `untilExists(_ word: String)` reads as "pass the path" at the call site,
    /// and the obvious `untilExists(url.path)` would land unquoted inside
    /// `[ ! -e … ]` in a script handed to `/bin/sh -c`. `$TMPDIR` holding a `;`
    /// or `$(…)` would then be command execution.
    public static func untilExists(variable: String, seconds: Int = defaultSeconds) -> String {
        fragment(word: "\"$\(variable)\"", seconds: seconds)
    }

    /// POSIX-quotes `value` for use as a single shell word.
    public static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The trailing `[ ! -e … ]` is what makes expiry observable. A `while`
    /// loop that ends because its condition went false exits 0, so without it a
    /// timeout is byte-identical to the sentinel arriving: the `rm` wrapper
    /// falls through to `exec /bin/rm` and deletes the file it was staged to
    /// block, and the lock script releases and exits 0. The test then fails
    /// somewhere downstream wearing a different bug's face.
    ///
    /// `amx_wait_i` is re-initialised per fragment, so sequential waits in one
    /// script are safe. Do NOT nest one inside another's body — the inner reset
    /// would make the outer loop unbounded again.
    private static func fragment(word: String, seconds: Int) -> String {
        let iterations = seconds * pollsPerSecond
        return "amx_wait_i=0;"
            + " while [ ! -e \(word) ] && [ \"$amx_wait_i\" -lt \(iterations) ];"
            + " do sleep \(pollInterval); amx_wait_i=$((amx_wait_i + 1)); done;"
            + " [ -e \(word) ]"
    }
}
