#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

base_ref="${TEST_WAIT_BASE:-}"
if [[ -z "$base_ref" ]]; then
    if git show-ref --verify --quiet refs/remotes/origin/main; then
        base_ref="$(git merge-base origin/main HEAD)"
    else
        base_ref="HEAD"
    fi
fi
if ! git rev-parse --verify --quiet "$base_ref^{commit}" >/dev/null; then
    echo "error: TEST_WAIT_BASE is not a commit: $base_ref" >&2
    exit 2
fi

wait_pattern='((Task|Thread)\.sleep|Darwin\.poll)[[:space:]]*\(|(^|[^[:alnum:]_.])(((Darwin|Glibc)\.)?nanosleep|sleep|usleep|poll|eventually)[[:space:]]*\('
# Zero-argument waitUntilExit only; `waitUntilExitEventually(` cannot match
# because the bounded name has no `(` directly after `waitUntilExit`.
unbounded_wait_pattern='(^|[^[:alnum:]_])waitUntilExit[[:space:]]*\([[:space:]]*\)'
# The shell-fixture twin of the above. A bare `while [ ! -e … ]; do sleep 0.01;
# done` inside a fixture script spins at 100 Hz forever whenever the sentinel
# never arrives — the test aborts before writing it, or the suite's own
# `defer { removeItem(at: root) }` deletes the directory it would live in. The
# shell then reparents to launchd with nothing holding a reference to kill it.
# Bounding the Swift waiter (awesomux#207) does not help: that fix deliberately
# does not terminate() on timeout, so the child outliving its waiter is the
# expected path.
#
# TWO patterns, because matching only the condition syntax caught exactly one
# spelling of the mistake. `until [ -e … ]` is the more idiomatic phrasing and
# walked straight past the original rule, as did `[[ ]]`, `while ! [`, and
# `while test !`. The second pattern is the important one: it matches the
# busy-wait's PAYLOAD — a sub-second sleep inside a shell loop — which is the
# property that actually orphans CPU, and which survives the loop being
# assembled across several Swift string-concatenation lines (the line-oriented
# scan never sees `while [ ! -e` on any single line in that case, but it does
# see `do sleep 0.01; done`).
unbounded_shell_wait_pattern='(while|until)[[:space:]]+!?[[:space:]]*(\[\[?|test)[[:space:]]'
shell_busy_sleep_pattern='(do|;|&&)[[:space:]]*sleep[[:space:]]+0?\.[0-9]'
found=0
found_unbounded=0
found_unbounded_shell=0

check_line() {
    local file="$1"
    local line="$2"
    local content="$3"

    # The sanctioned bounded-wait primitives themselves. ProcessBoundedWait polls
    # a monotonic clock deliberately: a child's exit is only observable through
    # Foundation's own state, and the termination event that would let us wait on
    # a gate is exactly what goes missing in awesomux#207.
    [[ "$file" == Tests/AwesoMuxTestSupport/Wait.swift ]] && return
    [[ "$file" == Tests/AwesoMuxTestSupport/ProcessBoundedWait.swift ]] && return
    # Recursive on purpose, and not obvious: in `[[ ]]` pattern matching `*`
    # crosses `/`, so this exempts nested directories (`Bridge/`, …) as well as
    # direct children. That matches the rule's intent — the whole system-test
    # bucket is exempt — but the line reads as if it were scoped to one level.
    [[ "$file" == Tests/awesoMuxTests/*.swift ]] && return
    if [[ "$content" =~ $wait_pattern ]]; then
        printf '%s:%s:%s\n' "$file" "$line" "$content" >&2
        found=1
    fi
}

# awesomux#207: a dropped termination event leaves `waitUntilExit()` blocked
# forever. Checked on changed lines here so cheap CI rejects it before
# `swift test` starts; ProcessWaitBoundedGuardTests is the whole-tree net.
# Sources/ is in scope too — the one deliberate exemption is the app-quit sweep,
# whose caller already bounds it with `group.wait(timeout:)`.
check_unbounded_wait() {
    local file="$1"
    local line="$2"
    local content="$3"

    [[ "$file" == Tests/AwesoMuxTestSupport/ProcessBoundedWait.swift ]] && return
    [[ "$file" == Tests/awesoMuxTests/ProcessWaitBoundedGuardTests.swift ]] && return
    # BridgeGenerationRegistry's existing app-quit wait is deliberate and needs
    # no exemption: this check only sees changed lines, so the untouched call
    # never trips it — while a NEW bare wait added to that same file still does.
    # Skip comment lines, matching ProcessWaitBoundedGuardTests: prose warning
    # people off the bare call must not itself fail the guard.
    local trimmed="${content#"${content%%[![:space:]]*}"}"
    [[ "$trimmed" == //* ]] && return
    if [[ "$content" =~ $unbounded_wait_pattern ]]; then
        printf '%s:%s:%s\n' "$file" "$line" "$content" >&2
        found_unbounded=1
    fi
}

check_unbounded_shell_wait() {
    local file="$1"
    local line="$2"
    local content="$3"

    # The sanctioned emitter is exempted BY PATH, the way Wait.swift and
    # ProcessBoundedWait.swift are exempted for their own rules above. The
    # previous version exempted any line containing `amx_wait_i`, which let
    # through the single most likely regression: someone copies the helper
    # output and trims the `-lt` comparison, keeping the counter name. A
    # substring is not evidence of a bound.
    [[ "$file" == Tests/AwesoMuxTestSupport/ShellWait.swift ]] && return

    local trimmed="${content#"${content%%[![:space:]]*}"}"
    [[ "$trimmed" == //* ]] && return
    # Shell `#` comments reach this scanner as ordinary Swift source: the
    # fixture scripts live inside Swift multiline strings, so their `#!/bin/sh`
    # and `# …` lines arrive here verbatim.
    [[ "$trimmed" == \#* ]] && return

    # A bound must be VISIBLE on the line, not merely alluded to. Either an
    # explicit counter comparison, or a call into the sanctioned emitter.
    [[ "$content" =~ -lt[[:space:]] ]] && return
    [[ "$content" == *ShellWait.untilExists* ]] && return

    if [[ "$content" =~ $unbounded_shell_wait_pattern ]] \
        || [[ "$content" =~ $shell_busy_sleep_pattern ]]; then
        printf '%s:%s:%s\n' "$file" "$line" "$content" >&2
        found_unbounded_shell=1
    fi
}

while IFS=$'\t' read -r file line content; do
    check_line "$file" "$line" "$content"
    check_unbounded_wait "$file" "$line" "$content"
    check_unbounded_shell_wait "$file" "$line" "$content"
done < <(
    git diff --src-prefix=a/ --dst-prefix=b/ --unified=0 --no-ext-diff \
        --diff-filter=ACMR "$base_ref" -- \
        ':(glob)Sources/**/*.swift' ':(glob)Tests/**/*.swift' \
        | awk '
            /^\+\+\+ b\// { file = substr($0, 7); next }
            /^@@ / {
                header = $0
                sub(/^@@ -[^ ]+ \+/, "", header)
                sub(/ @@.*/, "", header)
                split(header, range, ",")
                line = range[1] + 0
                next
            }
            /^\+/ { print file "\t" line "\t" substr($0, 2); line++; next }
            /^-/ { next }
            file != "" { line++ }
        '
)

while IFS= read -r file; do
    while IFS=: read -r line content; do
        check_line "$file" "$line" "$content"
        check_unbounded_wait "$file" "$line" "$content"
        check_unbounded_shell_wait "$file" "$line" "$content"
    done < <(
        grep -nE "$wait_pattern|$unbounded_wait_pattern|$unbounded_shell_wait_pattern|$shell_busy_sleep_pattern" \
            "$file" || true
    )
done < <(
    git ls-files --others --exclude-standard -- \
        ':(glob)Sources/**/*.swift' ':(glob)Tests/**/*.swift'
)

if [[ "$found_unbounded" -ne 0 ]]; then
    echo "error: unbounded waitUntilExit() can hang the suite forever (awesomux#207)" >&2
    echo "Use try process.waitUntilExitEventually() from AwesoMuxTestSupport." >&2
    exit 1
fi

if [[ "$found_unbounded_shell" -ne 0 ]]; then
    echo "error: an unbounded shell wait orphans a 100 Hz busy-loop to launchd" >&2
    echo "Use ShellWait.untilExists(path:) / (variable:) from AwesoMuxTestSupport." >&2
    exit 1
fi

if [[ "$found" -ne 0 ]]; then
    echo "error: new sleeps and polling are allowed only in Tests/awesoMuxTests" >&2
    echo "Use a controlled clock or gate outside approved system tests." >&2
    exit 1
fi

echo "Test wait guard: clean"
