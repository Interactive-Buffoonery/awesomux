#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

required_commands=(rg)
for command_name in "${required_commands[@]}"; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "error: required command is missing: $command_name" >&2
        exit 1
    fi
done

# Exclusions must name a path that actually exists in this repo. An exclusion
# for a path that is absent (or that some other tool is assumed to strip before
# publication) is a blind spot waiting for that path to be recreated: until
# 2026-07-27 this list excluded docs/plans and docs/superpowers on the
# assumption a prepare_public_seed.sh would remove them, that script never
# existed, and those two directories were the only place in the tree where the
# patterns below actually matched.
private_globs=(
    --glob '!.git/**'
    --glob '!.git'
    --glob '!.claude/**'
    --glob '!script/internal-wording-patterns.txt'
    --glob '!script/check_public_seed_source.sh'
)

failed=0

check_pattern() {
    local message="$1"
    local pattern="$2"
    if rg -n --hidden --text "${private_globs[@]}" "$pattern" .; then
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
    if rg -n --hidden --text --pcre2 "${private_globs[@]}" "$pattern" .; then
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
    local purged_directory
    for purged_directory in docs/plans docs/superpowers; do
        if [[ -e "$purged_directory" ]]; then
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
