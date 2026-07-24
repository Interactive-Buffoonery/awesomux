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
found=0
found_unbounded=0

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
    [[ "$file" == Sources/awesoMux/Services/BridgeGenerationRegistry.swift ]] && return
    # Skip comment lines, matching ProcessWaitBoundedGuardTests: prose warning
    # people off the bare call must not itself fail the guard.
    local trimmed="${content#"${content%%[![:space:]]*}"}"
    [[ "$trimmed" == //* ]] && return
    if [[ "$content" =~ $unbounded_wait_pattern ]]; then
        printf '%s:%s:%s\n' "$file" "$line" "$content" >&2
        found_unbounded=1
    fi
}

while IFS=$'\t' read -r file line content; do
    check_line "$file" "$line" "$content"
    check_unbounded_wait "$file" "$line" "$content"
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
    done < <(grep -nE "$wait_pattern|$unbounded_wait_pattern" "$file" || true)
done < <(
    git ls-files --others --exclude-standard -- \
        ':(glob)Sources/**/*.swift' ':(glob)Tests/**/*.swift'
)

if [[ "$found_unbounded" -ne 0 ]]; then
    echo "error: unbounded waitUntilExit() can hang the suite forever (awesomux#207)" >&2
    echo "Use try process.waitUntilExitEventually() from AwesoMuxTestSupport." >&2
    exit 1
fi

if [[ "$found" -ne 0 ]]; then
    echo "error: new sleeps and polling are allowed only in Tests/awesoMuxTests" >&2
    echo "Use a controlled clock or gate outside approved system tests." >&2
    exit 1
fi

echo "Test wait guard: clean"
