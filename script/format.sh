#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_PATH="$ROOT_DIR/.swift-format"

usage() {
    cat <<'EOF'
Usage:
  ./script/format.sh FILE.swift [FILE.swift ...]
  ./script/format.sh --lint

Write mode formats only the explicitly named, first-party Swift files.
Lint mode checks formatter findings on Swift lines changed from main without
modifying the working tree. Set FORMAT_LINT_BASE to override the comparison ref.
EOF
}

if command -v swift-format >/dev/null 2>&1; then
    FORMATTER=(swift-format)
elif swift format --version >/dev/null 2>&1; then
    FORMATTER=(swift format)
else
    echo "error: swift-format is unavailable; install a Swift toolchain that includes it" >&2
    exit 1
fi

run_formatter() {
    "${FORMATTER[@]}" "$@"
}

cleanup_temp_files() {
    if command -v trash >/dev/null 2>&1; then
        trash "$@"
        return
    fi
    local path
    for path in "$@"; do
        unlink "$path"
    done
}

relative_swift_path() {
    local supplied_path="$1"
    local absolute_path

    if [[ "$supplied_path" = /* ]]; then
        absolute_path="$supplied_path"
    else
        absolute_path="$PWD/$supplied_path"
    fi

    local directory
    directory="$(cd "$(dirname "$absolute_path")" 2>/dev/null && pwd -P)" || return 1
    absolute_path="$directory/$(basename "$absolute_path")"

    case "$absolute_path" in
        "$ROOT_DIR/Package.swift") printf '%s\n' "Package.swift" ;;
        "$ROOT_DIR/Sources/"*.swift) printf '%s\n' "${absolute_path#"$ROOT_DIR/"}" ;;
        "$ROOT_DIR/Tests/"*.swift) printf '%s\n' "${absolute_path#"$ROOT_DIR/"}" ;;
        *) return 1 ;;
    esac
}

format_explicit_files() {
    if [[ "$#" -eq 0 ]]; then
        echo "error: write mode requires at least one explicit .swift file" >&2
        usage >&2
        exit 2
    fi

    local files=()
    local supplied_path relative_path
    for supplied_path in "$@"; do
        if [[ ! -f "$supplied_path" || -L "$supplied_path" || "$supplied_path" != *.swift ]]; then
            echo "error: not a Swift source file: $supplied_path" >&2
            exit 2
        fi
        if ! relative_path="$(relative_swift_path "$supplied_path")"; then
            echo "error: format only Package.swift or files under Sources/ and Tests/: $supplied_path" >&2
            exit 2
        fi
        files+=("$ROOT_DIR/$relative_path")
    done

    run_formatter format --in-place --parallel --configuration "$CONFIG_PATH" "${files[@]}"
}

lint_changed_lines() {
    cd "$ROOT_DIR"

    # Parse the configuration even when a change contains no Swift files.
    printf 'struct FormatterConfigurationProbe {}\n' \
        | run_formatter lint --strict --configuration "$CONFIG_PATH" - >/dev/null

    local base_ref="${FORMAT_LINT_BASE:-}"
    if [[ -z "$base_ref" ]]; then
        if git show-ref --verify --quiet refs/remotes/origin/main; then
            base_ref="$(git merge-base origin/main HEAD)"
        else
            base_ref="HEAD"
        fi
    fi
    if ! git rev-parse --verify --quiet "$base_ref^{commit}" >/dev/null; then
        echo "error: FORMAT_LINT_BASE is not a commit: $base_ref" >&2
        exit 2
    fi

    local ranges_file diagnostics_file
    ranges_file="$(mktemp "${TMPDIR:-/tmp}/awesomux-format-ranges.XXXXXX")"
    diagnostics_file="$(mktemp "${TMPDIR:-/tmp}/awesomux-format-diagnostics.XXXXXX")"
    trap "cleanup_temp_files '$ranges_file' '$diagnostics_file' 2>/dev/null || true" EXIT

    git diff --unified=0 --no-ext-diff --diff-filter=ACMR "$base_ref" -- \
        Package.swift ':(glob)Sources/**/*.swift' ':(glob)Tests/**/*.swift' \
        | awk '
            /^\+\+\+ b\// { file = substr($0, 7); next }
            /^@@ / {
                header = $0
                sub(/^@@ -[^ ]+ \+/, "", header)
                sub(/ @@.*/, "", header)
                split(header, range, ",")
                start = range[1] + 0
                count = (range[2] == "" ? 1 : range[2] + 0)
                if (count > 0) print file "\t" start "\t" start + count - 1
            }
        ' > "$ranges_file"

    local untracked_path line_count
    while IFS= read -r untracked_path; do
        line_count="$(wc -l < "$untracked_path" | tr -d ' ')"
        if [[ "$line_count" -gt 0 ]]; then
            printf '%s\t1\t%s\n' "$untracked_path" "$line_count" >> "$ranges_file"
        fi
    done < <(git ls-files --others --exclude-standard -- \
        Package.swift ':(glob)Sources/**/*.swift' ':(glob)Tests/**/*.swift')

    if [[ ! -s "$ranges_file" ]]; then
        echo "Swift format lint: no changed Swift lines"
        return
    fi

    local file
    while IFS= read -r file; do
        if ! run_formatter lint --configuration "$CONFIG_PATH" "$file" \
            >> "$diagnostics_file" 2>&1; then
            echo "error: swift-format could not lint $file" >&2
            cat "$diagnostics_file" >&2
            exit 1
        fi
    done < <(cut -f1 "$ranges_file" | sort -u)

    local new_findings
    new_findings="$(awk -F: '
        NR == FNR {
            split($0, changed_range, "\t")
            ranges[changed_range[1]] = ranges[changed_range[1]] " " changed_range[2] "-" changed_range[3]
            next
        }
        {
            file = $1
            line = $2 + 0
            count = split(ranges[file], candidates, " ")
            for (candidate = 1; candidate <= count; candidate++) {
                split(candidates[candidate], bounds, "-")
                if (line >= bounds[1] && line <= bounds[2]) {
                    print
                    break
                }
            }
        }
    ' "$ranges_file" "$diagnostics_file")"

    if [[ -n "$new_findings" ]]; then
        echo "$new_findings" >&2
        echo "error: swift-format found issues on changed Swift lines" >&2
        echo "Format only the intended files, then inspect git diff before continuing." >&2
        exit 1
    fi

    echo "Swift format lint: changed Swift lines conform"
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
elif [[ "${1:-}" == "--lint" ]]; then
    if [[ "$#" -ne 1 ]]; then
        echo "error: --lint does not accept file arguments" >&2
        usage >&2
        exit 2
    fi
    lint_changed_lines
else
    format_explicit_files "$@"
fi
