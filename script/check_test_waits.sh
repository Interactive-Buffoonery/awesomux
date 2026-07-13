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

wait_pattern='((Task|Thread)\.sleep|Darwin\.poll)[[:space:]]*\(|(^|[^[:alnum:]_.])(sleep|usleep|poll|eventually)[[:space:]]*\('
found=0

check_line() {
    local file="$1"
    local line="$2"
    local content="$3"

    [[ "$file" == Tests/awesoMuxTests/*.swift ]] && return
    if [[ "$content" =~ $wait_pattern ]]; then
        printf '%s:%s:%s\n' "$file" "$line" "$content" >&2
        found=1
    fi
}

while IFS=$'\t' read -r file line content; do
    check_line "$file" "$line" "$content"
done < <(
    git diff --unified=0 --no-ext-diff --diff-filter=ACMR "$base_ref" -- \
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
    done < <(grep -nE "$wait_pattern" "$file" || true)
done < <(
    git ls-files --others --exclude-standard -- \
        ':(glob)Sources/**/*.swift' ':(glob)Tests/**/*.swift'
)

if [[ "$found" -ne 0 ]]; then
    echo "error: new sleeps and polling are allowed only in Tests/awesoMuxTests" >&2
    echo "Use a controlled clock or gate outside approved system tests." >&2
    exit 1
fi

echo "Test wait guard: clean"
