#!/usr/bin/env bash
#
# Read-only smoke test for the installed Codex app-server and awesoMux plugin.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
    cat <<'EOF'
Usage: ./script/test_live_codex_plugin.sh

Runs a read-only hooks/list probe through awesoMux's production Codex
app-server client. The probe uses CODEX_HOME when set, otherwise ~/.codex,
and requires the awesoMux Codex plugin to be installed there.

Environment:
  CODEX_HOME                    Codex config home to inspect (default: ~/.codex)
  AWESOMUX_LIVE_CODEX_BINARY    Codex executable (default: codex from PATH)
EOF
}

case "${1:-}" in
    -h|--help|help)
        usage
        exit 0
        ;;
    "")
        ;;
    *)
        echo "Unexpected argument: $1" >&2
        usage >&2
        exit 2
        ;;
esac

codex_binary="${AWESOMUX_LIVE_CODEX_BINARY:-}"
if [[ -z "$codex_binary" ]]; then
    if ! codex_binary="$(command -v codex)"; then
        echo "test_live_codex_plugin: codex not found on PATH" >&2
        exit 1
    fi
fi

codex_home="${CODEX_HOME:-$HOME/.codex}"
if [[ ! -d "$codex_home" ]]; then
    echo "test_live_codex_plugin: CODEX_HOME is not a directory: $codex_home" >&2
    exit 1
fi

export AWESOMUX_LIVE_CODEX_BINARY="$codex_binary"
export AWESOMUX_LIVE_CODEX_HOME="$codex_home"

echo "test_live_codex_plugin: probing $codex_home with $codex_binary (read-only)"
exec "$ROOT_DIR/script/swift-test.sh" --filter ProcessCodexAppServerClientLiveTests
