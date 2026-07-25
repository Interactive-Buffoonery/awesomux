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

# awesomux#207: unbounded waitUntilExit() is rejected everywhere, including the
# system-test directory that the sleep rule exempts. The bounded
# waitUntilExitEventually() and an implicit-self call must be told apart.
git -C "$ROOT_DIR" reset --quiet -- "$SYSTEM_FIXTURE"
printf 'func a(p: Process) { p.waitUntilExit() }\nfunc b(p: Process) { waitUntilExit() }\n' \
    > "$SYSTEM_FIXTURE"
git -C "$ROOT_DIR" add -N "$SYSTEM_FIXTURE"
if output="$(TEST_WAIT_BASE=HEAD "$ROOT_DIR/script/check_test_waits.sh" 2>&1)"; then
    echo "error: test wait guard accepted an unbounded waitUntilExit" >&2
    exit 1
fi
expected=$'Tests/awesoMuxTests/TestWaitGuardFixture.swift:1:func a(p: Process) { p.waitUntilExit() }\nTests/awesoMuxTests/TestWaitGuardFixture.swift:2:func b(p: Process) { waitUntilExit() }'
if [[ "$(printf '%s\n' "$output" | head -n 2)" != "$expected" ]]; then
    echo "error: test wait guard missed an unbounded waitUntilExit diagnostic" >&2
    exit 1
fi

git -C "$ROOT_DIR" reset --quiet -- "$SYSTEM_FIXTURE"
printf 'func ok(p: Process) throws { try p.waitUntilExitEventually() }\n// never call p.waitUntilExit() directly\n' \
    > "$SYSTEM_FIXTURE"
git -C "$ROOT_DIR" add -N "$SYSTEM_FIXTURE"
TEST_WAIT_BASE=HEAD "$ROOT_DIR/script/check_test_waits.sh" >/dev/null

# An unbounded shell fixture wait orphans a busy-loop to launchd. Every spelling
# below is the SAME defect; the first rule shipped catching only the first one,
# so each alternative gets a case. The last is the loop assembled across Swift
# string-concatenation lines, which no single line renders as `while [ ! -e`.
while IFS= read -r spelling; do
    [[ -z "$spelling" ]] && continue
    git -C "$ROOT_DIR" reset --quiet -- "$SYSTEM_FIXTURE"
    printf 'let script = "%s"\n' "$spelling" > "$SYSTEM_FIXTURE"
    git -C "$ROOT_DIR" add -N "$SYSTEM_FIXTURE"
    if TEST_WAIT_BASE=HEAD "$ROOT_DIR/script/check_test_waits.sh" >/dev/null 2>&1; then
        echo "error: test wait guard accepted an unbounded shell wait: $spelling" >&2
        exit 1
    fi
done <<'SPELLINGS'
while [ ! -e $s ]; do sleep 0.01; done
until [ -e $s ]; do sleep 0.01; done
while [[ ! -e $s ]]; do sleep 0.01; done
while ! [ -e $s ]; do sleep 0.01; done
while test ! -e $s; do sleep 0.01; done
do sleep 0.01; done
SPELLINGS

# The counter-name-only bypass: a copied helper body with the -lt comparison
# trimmed off. This is the most likely regression, and the first version of the
# rule exempted it because the line still mentioned the counter.
git -C "$ROOT_DIR" reset --quiet -- "$SYSTEM_FIXTURE"
printf 'let s = "amx_wait_i=0; while [ ! -e $x ]; do sleep 0.01; amx_wait_i=1; done"\n' \
    > "$SYSTEM_FIXTURE"
git -C "$ROOT_DIR" add -N "$SYSTEM_FIXTURE"
if TEST_WAIT_BASE=HEAD "$ROOT_DIR/script/check_test_waits.sh" >/dev/null 2>&1; then
    echo "error: test wait guard accepted a counter-named but unbounded shell wait" >&2
    exit 1
fi

# The sanctioned emitter must pass — both by call and by the bound it emits.
git -C "$ROOT_DIR" reset --quiet -- "$SYSTEM_FIXTURE"
printf 'let a = ShellWait.untilExists(path: p)\nlet b = ShellWait.untilExists(variable: "R")\n' \
    > "$SYSTEM_FIXTURE"
git -C "$ROOT_DIR" add -N "$SYSTEM_FIXTURE"
TEST_WAIT_BASE=HEAD "$ROOT_DIR/script/check_test_waits.sh" >/dev/null

echo "Test wait guard tests passed"
