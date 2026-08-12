#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
    cat <<'EOF'
Usage: ./script/test.sh <unit|adapter|system|timing|sidebar|nontiming|all> [swift test arguments]
EOF
}

# Suites that make real, synchronous, blocking OS calls (raw Unix-socket
# recv()/read() with multi-second SO_RCVTIMEO, real child-process spawn/wait
# with short timeouts, real file-system watchers, real file-lock contention).
# Each occupies an actual OS thread in Swift Concurrency's process-wide
# cooperative thread pool for the full blocking duration. Under `all`, they
# share one `swift test` process with ~4600 other tests; enough of them
# firing concurrently on a CPU-constrained hosted runner starves that pool
# for the whole binary (see issue #162). `timing`/`nontiming` split them into
# their own process so they stop contending with everything else and with
# each other in bulk. AppKit-heavy Sidebar suites also get their own process:
# concurrent NSAnimation waits can independently exhaust the dispatch thread
# soft limit even after the real-blocking suites are removed.
timing_pattern='awesoMuxTests\.(ProcessCommandRunnerTests|BoundedCommandRunnerTests|BoundedProcessRunnerTests|BridgeConnectionActorTests|BridgeConnectionSupervisorTests|BridgeExecChannelTests|BridgeAttachPreflightTests|BridgeAttachAssemblyTests|BridgeGenerationRegistryTests|AgentIntegrationInstallerTests|AgentPluginRunnerTests|DocumentFileWatcherTests|DocumentRevisionMonitorTests|RemoteHandoffTests)|AwesoMuxBridgeHelperSupportTests\.HelperConnectionTests|AwesoMuxTestSupportTests\.(EventRecorderTests|ProcessBoundedWaitTests)'
sidebar_pattern='awesoMuxTests\.Sidebar[^/]*'

group="${1:-}"
if [[ -z "$group" ]]; then
    usage >&2
    exit 2
fi
shift

filter=''
skip=''
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
    timing)
        filter="^($timing_pattern)/"
        ;;
    sidebar)
        filter="^($sidebar_pattern)/"
        ;;
    nontiming)
        skip="^($timing_pattern|$sidebar_pattern)/"
        ;;
    all)
        if [[ "$#" -eq 0 ]]; then
            "$ROOT_DIR/script/test.sh" timing
            "$ROOT_DIR/script/test.sh" sidebar --skip-build
            exec "$ROOT_DIR/script/test.sh" nontiming --skip-build
        fi
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

args=()
[[ -n "$filter" ]] && args+=(--filter "$filter")
[[ -n "$skip" ]] && args+=(--skip "$skip")
exec "$ROOT_DIR/script/swift-test.sh" "${args[@]}" "$@"
