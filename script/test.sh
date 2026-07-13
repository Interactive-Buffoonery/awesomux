#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
    cat <<'EOF'
Usage: ./script/test.sh <unit|adapter|system|all> [swift test arguments]
EOF
}

group="${1:-}"
if [[ -z "$group" ]]; then
    usage >&2
    exit 2
fi
shift

case "$group" in
    unit)
        filter='^(AwesoMuxCoreTests|AwesoMuxConfigTests|AwesoMuxTestSupportTests|DesignSystemTests|UnicodeHygieneTests|SecureFileIOTests)\.'
        ;;
    adapter)
        filter='^(AwesoMuxAgentHookSupportTests|AwesoMuxBridgeHelperSupportTests)\.'
        ;;
    system)
        filter='^awesoMuxTests\.'
        ;;
    all)
        exec "$ROOT_DIR/script/swift-test.sh" "$@"
        ;;
    -h|--help|help)
        usage
        exit 0
        ;;
    *)
        echo "Unknown test group: $group" >&2
        usage >&2
        exit 2
        ;;
esac

exec "$ROOT_DIR/script/swift-test.sh" --filter "$filter" "$@"
