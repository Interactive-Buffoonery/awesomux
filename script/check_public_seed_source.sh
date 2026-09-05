#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

required_commands=(git rg)
for command_name in "${required_commands[@]}"; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "error: required command is missing: $command_name" >&2
        exit 1
    fi
done

# Scan tracked files plus untracked files Git does not ignore. Local-only files
# must not affect whether the public source is safe to publish. The explicit
# exclusions match paths intentionally omitted from the public seed.
public_surface_paths=()
while IFS= read -r -d '' public_surface_path; do
    case "$public_surface_path" in
        .git | .git/* | .build | .build/* | .claude | .claude/* | \
            vendor/ghostty | vendor/ghostty/* | vendor/zmx | vendor/zmx/* | \
            script/internal-wording-patterns.txt | script/check_public_seed_source.sh)
            continue
            ;;
    esac
    public_surface_paths+=("$public_surface_path")
done < <(git ls-files --cached --others --exclude-standard -z)

if [[ "${#public_surface_paths[@]}" -eq 0 ]]; then
    echo "error: public seed source scan found no candidate files" >&2
    exit 1
fi

failed=0

check_pattern() {
    local message="$1"
    local pattern="$2"
    if rg --files-with-matches --hidden --text "$pattern" "${public_surface_paths[@]}"; then
        echo "error: $message" >&2
        failed=1
    else
        local status=$?
        if [[ "$status" -gt 1 ]]; then
            echo "error: public seed source scan failed for pattern: $pattern" >&2
            failed=1
        fi
    fi
}

check_pcre2_pattern() {
    local message="$1"
    local pattern="$2"
    if rg --files-with-matches --hidden --text --pcre2 "$pattern" "${public_surface_paths[@]}"; then
        echo "error: $message" >&2
        failed=1
    else
        local status=$?
        if [[ "$status" -gt 1 ]]; then
            echo "error: public seed source scan failed for PCRE2 pattern: $pattern" >&2
            failed=1
        fi
    fi
}

check_purged_directories() {
    # These directories were removed from this repo and purged from its history
    # on 2026-07-27; their contents carried local worktree paths and private
    # repository references. Only 5 of the 15 removed files actually matched the
    # string patterns below, so a content scan alone would let the other 10 back
    # in unnoticed — this checks existence directly. A stale clone predating the
    # purge that merges or pushes will fail here rather than silently
    # republishing them.
    # `-e` alone is false for a dangling symlink, so a tracked
    # `docs/superpowers -> nowhere` link would reintroduce the path while
    # passing this check. `-L` catches every link variant regardless of target.
    local purged_directory
    for purged_directory in docs/plans docs/superpowers; do
        if [[ -e "$purged_directory" || -L "$purged_directory" ]]; then
            echo "error: $purged_directory was purged from this repository and must not be reintroduced" >&2
            failed=1
        fi
    done
}

check_purged_directories

check_pcre2_pattern \
    "non-issue Linear workspace URL remains in the public seed surface" \
    'linear\.app/interactive-buffoonery/(?!issue/INT-[0-9]+(?:/|[?#[:space:]"'"'"']|$))'

check_pattern \
    "private contact, repository name, or cockpit token remains in the public seed surface" \
    '(contact@interactivebuffoonery\.app|awesomux-(private|internal)|COCKPIT_[A-Z_]+|script/cockpit/)'
check_pattern \
    "real maintainer fixture path or host remains in the public seed surface" \
    '(/Users/(sarah|ed|edequalsawesome)(/|["'"'"'[:space:]]|$)|(sarah|serabi|edequalsawesome)@|purple-imac|JiggyBrain)'
check_pattern \
    "a public file refers to an excluded private path" \
    '(^|[[:space:](`"'"'"'\[]|\.\./)(openwiki/|docs/(agents|audits|design|plans|superpowers)/|script/cockpit/)'

if [[ "$failed" -ne 0 ]]; then
    exit 1
fi

echo "check_public_seed_source: clean."
