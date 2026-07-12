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

private_globs=(
    --glob '!.git/**'
    --glob '!.git'
    --glob '!.claude/**'
    --glob '!.codex/**'
    --glob '!.deepsec/**'
    --glob '!docs/agents/**'
    --glob '!docs/audits/**'
    --glob '!docs/design/**'
    --glob '!docs/plans/**'
    --glob '!docs/superpowers/**'
    --glob '!openwiki/**'
    --glob '!plans/**'
    --glob '!script/cockpit/**'
    --glob '!script/internal-wording-patterns.txt'
    --glob '!script/check_public_seed_source.sh'
    --glob '!script/prepare_public_seed.sh'
    --glob '!docs/awesomux-awesomeness-publishing.md'
    --glob '!.github/workflows/openwiki-update.yml'
)

failed=0

check_pattern() {
    local message="$1"
    local pattern="$2"
    if rg -n --hidden --text "${private_globs[@]}" "$pattern" .; then
        echo "error: $message" >&2
        failed=1
    fi
}

check_pattern \
    "private URL, repository name, or cockpit token remains in the public seed surface" \
    '(linear\.app/interactive-buffoonery|contact@interactivebuffoonery\.app|awesomux-(private|internal)|COCKPIT_[A-Z_]+|script/cockpit/)'
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
