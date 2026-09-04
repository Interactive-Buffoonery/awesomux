#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

usage() {
    cat <<'EOF'
Usage: ./script/test.sh <unit|adapter|system|timing|sidebar|nontiming|zmx|all> [swift test arguments]
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
timing_pattern='awesoMuxTests\.(ProcessCommandRunnerTests|BoundedCommandRunnerTests|BoundedProcessRunnerTests|BridgeConnectionActorTests|BridgeConnectionSupervisorTests|BridgeExecChannelTests|BridgeAttachPreflightTests|BridgeAttachAssemblyTests|BridgeGenerationRegistryTests|AgentIntegrationInstallerTests|AgentPluginRunnerTests|AgentTranscriptLiveRefreshWatchTests|DocumentFileWatcherTests|DocumentRevisionMonitorTests|RemoteHandoffTests)|AwesoMuxBridgeHelperSupportTests\.HelperConnectionTests|AwesoMuxTestSupportTests\.(EventRecorderTests|ProcessBoundedWaitTests)'
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
        export AWESOMUX_APPKIT_TEST_HOST=1
        ;;
    nontiming)
        skip="^($timing_pattern|$sidebar_pattern)/"
        ;;
    zmx)
        if [[ "$#" -ne 0 ]]; then
            echo "The zmx group does not accept Swift test arguments." >&2
            exit 2
        fi
        exec "$ROOT_DIR/script/build_amx.sh" test
        ;;
    all)
        if [[ "$#" -ne 0 ]]; then
            echo "The all group does not accept swift test arguments because that would collapse the isolated shards into one unsafe process." >&2
            echo "Run zmx, timing, sidebar, and nontiming explicitly when you need per-shard arguments or xUnit output." >&2
            exit 2
        fi
        "$ROOT_DIR/script/test.sh" zmx
        report_dir="$(mktemp -d "${TMPDIR:-/tmp}/awesomux-test-reports.XXXXXX")"
        echo "Swift test reports: $report_dir"
        "$ROOT_DIR/script/test.sh" timing --xunit-output "$report_dir/timing.xml"
        "$ROOT_DIR/script/test.sh" sidebar --skip-build --xunit-output "$report_dir/sidebar.xml"
        "$ROOT_DIR/script/test.sh" nontiming --skip-build --xunit-output "$report_dir/nontiming.xml"
        exit 0
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
case "$group" in
    timing|sidebar|nontiming)
        report_path=''
        expects_report_path=false
        for argument in "$@"; do
            case "$argument" in
                -h|--help|-l|--list-tests|list|--version)
                    exec "$ROOT_DIR/script/swift-test.sh" "${args[@]}" "$@"
                    ;;
            esac
            if [[ "$expects_report_path" == true ]]; then
                report_path="$argument"
                expects_report_path=false
            elif [[ "$argument" == --xunit-output ]]; then
                expects_report_path=true
            elif [[ "$argument" == --xunit-output=* ]]; then
                report_path="${argument#--xunit-output=}"
            fi
        done
        if [[ "$expects_report_path" == true ]]; then
            echo "--xunit-output requires a path." >&2
            exit 2
        fi
        if [[ -z "$report_path" ]]; then
            report_dir="$(mktemp -d "${TMPDIR:-/tmp}/awesomux-test-reports.XXXXXX")"
            report_path="$report_dir/$group.xml"
            args+=(--xunit-output "$report_path")
            echo "Swift test reports: $report_dir"
        fi
        "$ROOT_DIR/script/swift-test.sh" "${args[@]}" "$@"
        exec python3 "$ROOT_DIR/script/check_swift_test_report.py" --swiftpm-output "$report_path"
        ;;
    *)
        exec "$ROOT_DIR/script/swift-test.sh" "${args[@]}" "$@"
        ;;
esac
