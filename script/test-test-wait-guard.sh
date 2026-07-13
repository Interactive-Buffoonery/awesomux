#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UNIT_FIXTURE="$ROOT_DIR/Tests/AwesoMuxCoreTests/TestWaitGuardFixture.swift"
SYSTEM_FIXTURE="$ROOT_DIR/Tests/awesoMuxTests/TestWaitGuardFixture.swift"

cleanup() {
    git -C "$ROOT_DIR" reset --quiet -- "$UNIT_FIXTURE" "$SYSTEM_FIXTURE" 2>/dev/null || true
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
if output="$(TEST_WAIT_BASE=HEAD "$ROOT_DIR/script/check_test_waits.sh" 2>&1)"; then
    echo "error: test wait guard accepted a unit-test sleep" >&2
    exit 1
fi
expected='Tests/AwesoMuxCoreTests/TestWaitGuardFixture.swift:1:func testWaitGuardFixture() async throws { try await Task.sleep(for: .seconds(1)) }'
if [[ "$(printf '%s\n' "$output" | head -n 1)" != "$expected" ]]; then
    echo "error: test wait guard emitted an unexpected diagnostic" >&2
    exit 1
fi

mv "$UNIT_FIXTURE" "$SYSTEM_FIXTURE"
TEST_WAIT_BASE=HEAD "$ROOT_DIR/script/check_test_waits.sh" >/dev/null

mv "$SYSTEM_FIXTURE" "$UNIT_FIXTURE"
printf 'func bare() { nanosleep(nil, nil) }\nfunc darwin() { Darwin.nanosleep(nil, nil) }\nfunc glibc() { Glibc.nanosleep(nil, nil) }\n' \
    > "$UNIT_FIXTURE"
git -C "$ROOT_DIR" add -N "$UNIT_FIXTURE"
if output="$(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=diff.noprefix GIT_CONFIG_VALUE_0=true \
    TEST_WAIT_BASE=HEAD "$ROOT_DIR/script/check_test_waits.sh" 2>&1)"; then
    echo "error: test wait guard accepted nanosleep with diff.noprefix enabled" >&2
    exit 1
fi
expected=$'Tests/AwesoMuxCoreTests/TestWaitGuardFixture.swift:1:func bare() { nanosleep(nil, nil) }\nTests/AwesoMuxCoreTests/TestWaitGuardFixture.swift:2:func darwin() { Darwin.nanosleep(nil, nil) }\nTests/AwesoMuxCoreTests/TestWaitGuardFixture.swift:3:func glibc() { Glibc.nanosleep(nil, nil) }'
if [[ "$(printf '%s\n' "$output" | head -n 3)" != "$expected" ]]; then
    echo "error: test wait guard missed a nanosleep diagnostic" >&2
    exit 1
fi

git -C "$ROOT_DIR" reset --quiet -- "$UNIT_FIXTURE"
mv "$UNIT_FIXTURE" "$SYSTEM_FIXTURE"
git -C "$ROOT_DIR" add -N "$SYSTEM_FIXTURE"
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=diff.noprefix GIT_CONFIG_VALUE_0=true \
    TEST_WAIT_BASE=HEAD "$ROOT_DIR/script/check_test_waits.sh" >/dev/null

echo "Test wait guard tests passed"
