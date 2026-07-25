#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
CONFIG_PATH="$ROOT_DIR/.swift-format"
FORMATTER_VERSION_PATH="$ROOT_DIR/.swift-format-version"

usage() {
    cat <<'EOF'
Usage:
  ./script/format.sh FILE.swift [FILE.swift ...]
  ./script/format.sh --lint

Write mode formats the explicitly named, first-party Swift files, restricted to
the lines they changed from main — matching what lint mode judges. A file with
no tracked history is formatted whole; a file with no changed lines is skipped.
Lint mode checks formatter findings on Swift lines changed from main without
modifying the working tree. Set FORMAT_LINT_BASE to override the comparison ref
for either mode.
EOF
}

if ! swift format --version >/dev/null 2>&1; then
    echo "error: the toolchain-integrated 'swift format' command is unavailable" >&2
    exit 1
fi
FORMATTER=(swift format)

case "$(uname -s)" in
    Darwin) formatter_platform="darwin" ;;
    Linux) formatter_platform="linux" ;;
    *)
        echo "error: unsupported formatter platform: $(uname -s)" >&2
        exit 1
        ;;
esac
expected_formatter_version="$(awk -F= -v platform="$formatter_platform" '$1 == platform { print $2 }' "$FORMATTER_VERSION_PATH")"
if [[ -z "$expected_formatter_version" ]]; then
    echo "error: no swift-format version is pinned for $formatter_platform" >&2
    exit 1
fi
actual_formatter_version="$("${FORMATTER[@]}" --version | tr -d '[:space:]')"
if [[ "$actual_formatter_version" != "$expected_formatter_version" ]]; then
    echo "error: swift-format $expected_formatter_version is required; found $actual_formatter_version" >&2
    echo "See docs/toolchain.md for installation and upgrade instructions." >&2
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

# Script scope, not function-local: the EXIT trap runs after the function has
# returned, so locals would be out of scope by then. `:-` guards the case where
# the script exits before either is assigned.
LINT_RANGES_FILE=""
LINT_DIAGNOSTICS_FILE=""

cleanup_lint_temp_files() {
    local paths=()
    [[ -n "${LINT_RANGES_FILE:-}" ]] && paths+=("$LINT_RANGES_FILE")
    [[ -n "${LINT_DIAGNOSTICS_FILE:-}" ]] && paths+=("$LINT_DIAGNOSTICS_FILE")
    [[ "${#paths[@]}" -gt 0 ]] || return 0
    cleanup_temp_files "${paths[@]}" 2>/dev/null || true
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

resolve_base_ref() {
    local base_ref="${FORMAT_LINT_BASE:-}"
    if [[ -z "$base_ref" ]]; then
        # Probes are silenced: outside a work tree they emit raw `fatal:` lines
        # that read as the real error when the actual message follows.
        if git show-ref --verify --quiet refs/remotes/origin/main 2>/dev/null; then
            base_ref="$(git merge-base origin/main HEAD 2>/dev/null)"
        else
            base_ref="HEAD"
        fi
    fi
    if [[ -z "$base_ref" ]] \
        || ! git rev-parse --verify --quiet "$base_ref^{commit}" >/dev/null 2>&1; then
        if [[ -n "${FORMAT_LINT_BASE:-}" ]]; then
            echo "error: FORMAT_LINT_BASE is not a commit: $FORMAT_LINT_BASE" >&2
        else
            # Do not name a variable the caller never set.
            echo "error: cannot resolve a base commit to diff against — this needs" >&2
            echo "a git repository with at least one commit. Set FORMAT_LINT_BASE" >&2
            echo "to override." >&2
        fi
        exit 2
    fi
    printf '%s\n' "$base_ref"
}

# `path<TAB>start<TAB>end` for every changed range in the whole diff.
#
# Deliberately repo-wide with no pathspec, and shared by both modes so the
# parity the docs claim is structural rather than two parsers staying in step.
# A per-path `git diff -- <path>` cannot detect a rename — that needs BOTH
# sides of the pair inside the pathspec — so a renamed file came back as an
# addition, `@@ -0,0 +1,N @@`, and write mode would reformat the entire file.
# On a drift-carrying file that is precisely the blast radius this script
# exists to prevent.
changed_line_ranges() {
    local base_ref="$1"

    git diff --src-prefix=a/ --dst-prefix=b/ --unified=0 --no-ext-diff \
        --diff-filter=ACMR --find-renames "$base_ref" -- \
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
                if (count > 0 && file != "") print file "\t" start "\t" start + count - 1
            }
        '
}

# swift-format's `--offsets` takes UTF-8 BYTE offsets, not line numbers, so the
# ranges have to be converted against the file's actual bytes.
#
# LC_ALL=C pins awk's length() to bytes. This is a no-op on macOS — BSD awk
# counts bytes in every locale — but GNU awk in a UTF-8 locale counts
# CHARACTERS, so on the Linux lane any line holding a multi-byte glyph (this
# repo has plenty: `—`, `→`, `naïve`) would shift every subsequent offset and
# the formatter would rewrite the wrong region. Do not drop it because the
# macOS tests still pass without it; they cannot exercise this.
line_ranges_to_byte_offsets() {
    local file="$1"
    shift

    LC_ALL=C awk -v spec="$*" '
        BEGIN {
            # offset MUST be initialised. An unset awk variable is 0 in
            # arithmetic but the EMPTY STRING in concatenation, and the print
            # below concatenates. Without this, a range starting at line 1
            # emitted ":17" instead of "0:17"; swift-format rejects that
            # ("The value :17 is invalid for --offsets") and exits 64, killing
            # the script under set -e. It fired on the most ordinary edit there
            # is — adding an import at the top of a file.
            offset = 0
            count = split(spec, items, " ")
            for (i = 1; i <= count; i++) {
                split(items[i], bounds, "-")
                first[i] = bounds[1] + 0
                last[i] = bounds[2] + 0
            }
        }
        {
            line_start = offset + 0
            offset += length($0) + 1
            # Last content byte of the final record, for the EOF clamp below.
            last_content_end = line_start + length($0)
            for (i = 1; i <= count; i++) {
                if (NR == first[i]) { start_byte[i] = line_start; seen[i] = 1 }
                # End at the last CONTENT byte, excluding the line terminator.
                # Including it makes swift-format consume the trailing newline
                # outright when the range reaches EOF, which then trips its own
                # [AddLines] rule: the formatter emits a file that its own
                # linter rejects. Verified on a 70-byte fixture — end offset 70
                # (past the newline) strips it, 69 does not.
                # NOTE: no apostrophes in this awk body; it is single-quoted.
                if (NR == last[i]) end_byte[i] = line_start + length($0)
            }
        }
        END {
            for (i = 1; i <= count; i++) {
                if (!seen[i]) continue
                # A range naming lines past EOF never sets end_byte. Clamp to
                # the last CONTENT byte, not to offset — offset is the file
                # length, which for a newline-terminated file is exactly the
                # poison value the comment above warns about. A guard that
                # reintroduces the bug it guards is worse than no guard.
                print start_byte[i] + 0 ":" (i in end_byte ? end_byte[i] : last_content_end)
            }
        }
    ' "$file"
}

# Range-scoped formatting deliberately stops before each range's line
# terminator, which also means it can never ADD a missing final newline. That
# left a file whose last line lacks one permanently unfixable: write mode
# reported success, `--lint` failed [AddLines], and re-running changed nothing.
# Appending the terminator is outside any formatting decision the range owns, so
# it is safe to do unconditionally after the range pass.
ensure_trailing_newline() {
    local file="$1"
    [[ -s "$file" ]] || return 0
    # Command substitution strips trailing newlines, so a non-empty result here
    # IS the missing-newline case. No `xxd` dependency, which the Linux CI
    # image does not guarantee.
    if [[ -n "$(tail -c 1 "$file")" ]]; then
        printf '\n' >> "$file"
    fi
}

format_explicit_files() {
    if [[ "$#" -eq 0 ]]; then
        echo "error: write mode requires at least one explicit .swift file" >&2
        usage >&2
        exit 2
    fi

    # Validation runs BEFORE the cd: `relative_swift_path` resolves a relative
    # argument against $PWD, so changing directory first silently re-anchors
    # every relative path to the repo root. That turned `cd Sources/Deep &&
    # format.sh A.swift` into "not a Swift source file" — and worse, a path
    # that happened to also exist under the root got formatted in the WRONG
    # checkout while the caller was told it succeeded.
    local paths=()
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
        paths+=("$relative_path")
    done

    cd "$ROOT_DIR"

    # Resolved lazily, on the first TRACKED path. An all-untracked batch takes
    # the whole-file branch and needs no base ref at all — demanding one made
    # write mode fail in a repo with no commits, and outside a repo entirely,
    # both of which worked before this change.
    local base_ref="" ranges_all=""
    local formatted=0 skipped=0 whole=0
    local failed=()

    for relative_path in "${paths[@]}"; do
        if ! git ls-files --error-unmatch -- ":(literal)$relative_path" >/dev/null 2>&1; then
            # No tracked history to diff against — the whole file is new.
            if run_formatter format --in-place --configuration "$CONFIG_PATH" "$relative_path"; then
                whole=$((whole + 1))
            else
                failed+=("$relative_path")
            fi
            continue
        fi

        if [[ -z "$base_ref" ]]; then
            base_ref="$(resolve_base_ref)"
            ranges_all="$(changed_line_ranges "$base_ref")"
        fi

        local ranges
        ranges="$(printf '%s\n' "$ranges_all" \
            | awk -F'\t' -v want="$relative_path" '$1 == want { print $2 "-" $3 }' \
            | tr '\n' ' ')"
        if [[ -z "${ranges// /}" ]]; then
            skipped=$((skipped + 1))
            continue
        fi

        # Command substitution, not a process substitution: `set -euo pipefail`
        # cannot observe a process substitution's exit status, so a failing
        # conversion silently produced an empty array and got counted as
        # "unchanged" — the tool affirmatively claiming the file needed no work.
        local offsets offset
        offsets="$(line_ranges_to_byte_offsets "$relative_path" $ranges)"
        local offset_args=()
        while IFS= read -r offset; do
            [[ -n "$offset" ]] && offset_args+=(--offsets "$offset")
        done <<<"$offsets"

        if [[ "${#offset_args[@]}" -eq 0 ]]; then
            echo "error: no byte offsets for changed ranges in $relative_path" >&2
            failed+=("$relative_path")
            continue
        fi

        # One invocation per file rather than `--parallel`: `--offsets` applies
        # to every path in a single invocation, so each file needs its own.
        # A failure records the file and continues — aborting mid-loop left the
        # rest of a batch silently unformatted with no summary printed.
        if run_formatter format --in-place --configuration "$CONFIG_PATH" \
            "${offset_args[@]}" "$relative_path"; then
            ensure_trailing_newline "$relative_path"
            formatted=$((formatted + 1))
        else
            failed+=("$relative_path")
        fi
    done

    echo "Swift format: $formatted changed-range, $whole whole-file, $skipped with no formattable lines"
    if [[ "${#failed[@]}" -gt 0 ]]; then
        printf 'error: swift-format failed on %s\n' "${failed[@]}" >&2
        exit 1
    fi
}

lint_changed_lines() {
    cd "$ROOT_DIR"

    # Parse the configuration even when a change contains no Swift files.
    printf 'struct FormatterConfigurationProbe {}\n' \
        | run_formatter lint --strict --configuration "$CONFIG_PATH" - >/dev/null

    local base_ref
    base_ref="$(resolve_base_ref)"

    LINT_RANGES_FILE="$(mktemp "${TMPDIR:-/tmp}/awesomux-format-ranges.XXXXXX")"
    LINT_DIAGNOSTICS_FILE="$(mktemp "${TMPDIR:-/tmp}/awesomux-format-diagnostics.XXXXXX")"
    local ranges_file="$LINT_RANGES_FILE"
    local diagnostics_file="$LINT_DIAGNOSTICS_FILE"
    # A trap that interpolates paths into its body turns $TMPDIR into
    # shell source text; calling a function keeps data as data.
    trap cleanup_lint_temp_files EXIT

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
