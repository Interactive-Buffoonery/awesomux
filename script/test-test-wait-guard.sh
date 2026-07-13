#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UNIT_FIXTURE="$ROOT_DIR/Tests/AwesoMuxCoreTests/TestWaitGuardFixture.swift"
SYSTEM_FIXTURE="$ROOT_DIR/Tests/awesoMuxTests/TestWaitGuardFixture.swift"

cleanup() {
    unlink "$UNIT_FIXTURE" 2>/dev/null || true
    unlink "$SYSTEM_FIXTURE" 2>/dev/null || true
}
trap cleanup EXIT

if [[ -e "$UNIT_FIXTURE" || -e "$SYSTEM_FIXTURE" ]]; then
    echo "error: test wait guard fixture already exists" >&2
    exit 1
fi

printf 'func testWaitGuardFixture() async throws { try await Task.sleep(for: .seconds(1)) }\n' \
    > "$UNIT_FIXTURE"
if TEST_WAIT_BASE=HEAD "$ROOT_DIR/script/check_test_waits.sh" >/dev/null 2>&1; then
    echo "error: test wait guard accepted a unit-test sleep" >&2
    exit 1
fi

mv "$UNIT_FIXTURE" "$SYSTEM_FIXTURE"
TEST_WAIT_BASE=HEAD "$ROOT_DIR/script/check_test_waits.sh" >/dev/null

echo "Test wait guard tests passed"
