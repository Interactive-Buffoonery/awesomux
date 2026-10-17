#!/usr/bin/env bash
set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAPER="${1:-$ROOT_DIR/script/amx-reap.sh}"
FIXTURE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/awesomux-amx-reap-e2e.XXXXXX")"
trap 'rm -rf "$FIXTURE_ROOT"' EXIT

FAKE_AMX="$FIXTURE_ROOT/amx"
cat > "$FAKE_AMX" <<'EOF'
#!/usr/bin/env bash
set -u

case "${1:-}" in
  list)
    case "$AMX_FIXTURE_SCENARIO" in
      escaped-owned) printf '%s\n' 'abc-def' ;;
      valid-mixed) printf '%s\n' 'owned-1' 'orphan-1' ;;
      malformed-state|state-unreadable) printf '%s\n' 'owned-1' ;;
      list-failure) echo 'fixture list failure' >&2; exit 23 ;;
      kill-failure|all-kill-failure) printf '%s\n' 'orphan-1' ;;
    esac
    ;;
  kill)
    printf '%s\n' "$2" >> "$AMX_FIXTURE_KILL_LOG"
    case "$AMX_FIXTURE_SCENARIO" in
      kill-failure|all-kill-failure) exit 17 ;;
    esac
    ;;
  *)
    echo "unexpected fake amx command: ${1:-}" >&2
    exit 64
    ;;
esac
EOF
chmod 700 "$FAKE_AMX"

failures=0

run_case() {
  local name="$1"
  local mode="$2"
  local state_payload="$3"
  local expected_status="$4"
  local expected_output="$5"
  local expected_kills="$6"
  local fixture_home="$FIXTURE_ROOT/home-$name"
  local state_dir="$fixture_home/Library/Application Support/awesoMux"
  local kill_log="$FIXTURE_ROOT/$name-kills.log"
  local output_file="$FIXTURE_ROOT/$name-output.log"
  local status

  mkdir -p "$state_dir"
  : > "$kill_log"
  case "$state_payload" in
    ABSENT) ;;
    DIRECTORY) mkdir "$state_dir/session-state.json" ;;
    FIFO) mkfifo "$state_dir/session-state.json" ;;
    DANGLING) ln -s "$fixture_home/missing-state.json" "$state_dir/session-state.json" ;;
    UNREADABLE)
      printf '%s' '{"terminalSessionID":"owned-1"}' > "$state_dir/session-state.json"
      chmod 000 "$state_dir/session-state.json"
      ;;
    *) printf '%s' "$state_payload" > "$state_dir/session-state.json" ;;
  esac

  env -u AWESOMUX_PANE_ID -u AWESOMUX_PROFILE \
    HOME="$fixture_home" \
    AWESOMUX_AMX="$FAKE_AMX" \
    AMX_FIXTURE_SCENARIO="$name" \
    AMX_FIXTURE_KILL_LOG="$kill_log" \
    PATH="$PATH" \
    /bin/bash "$REAPER" --prod "$mode" > "$output_file" 2>&1
  status=$?

  local actual_kills
  actual_kills="$(paste -sd, "$kill_log")"
  if [[ "$expected_status" == "nonzero" ]]; then
    [[ "$status" -ne 0 ]] || {
      echo "FAIL $name: expected nonzero status, got 0"
      failures=$((failures + 1))
    }
  elif [[ "$status" -ne "$expected_status" ]]; then
    echo "FAIL $name: expected status $expected_status, got $status"
    failures=$((failures + 1))
  fi
  if ! grep -qF "$expected_output" "$output_file"; then
    echo "FAIL $name: missing output: $expected_output"
    failures=$((failures + 1))
  fi
  if [[ "$actual_kills" != "$expected_kills" ]]; then
    echo "FAIL $name: expected kills '$expected_kills', got '$actual_kills'"
    failures=$((failures + 1))
  fi

  echo "CASE $name status=$status kills=${actual_kills:-none}"
  sed 's/^/  | /' "$output_file"
}

run_case \
  escaped-owned \
  orphans \
  '{"terminalSessionID":"abc\u002ddef"}' \
  0 \
  'reaped 0 orphan daemon(s)' \
  ''

run_case \
  valid-mixed \
  orphans \
  '{"terminalSessionID":"owned-1"}' \
  0 \
  'reaped 1 orphan daemon(s)' \
  'orphan-1'

run_case \
  malformed-state \
  orphans \
  '{"terminalSessionID":' \
  nonzero \
  'could not read owned session ids' \
  ''

if [[ "$(id -u)" -eq 0 ]]; then
  echo 'SKIP state-unreadable: root can read mode-000 files'
else
  run_case \
    state-unreadable \
    orphans \
    UNREADABLE \
    nonzero \
    'could not read owned session ids' \
    ''
fi

run_case \
  state-directory \
  orphans \
  DIRECTORY \
  nonzero \
  'could not read owned session ids' \
  ''

run_case \
  state-fifo \
  orphans \
  FIFO \
  nonzero \
  'could not read owned session ids' \
  ''

run_case \
  state-dangling-link \
  orphans \
  DANGLING \
  nonzero \
  'could not read owned session ids' \
  ''

run_case \
  list-failure \
  orphans \
  ABSENT \
  nonzero \
  'could not list live amx sessions' \
  ''

run_case \
  kill-failure \
  orphans \
  ABSENT \
  nonzero \
  'reaped 0 orphan daemon(s); 1 failed.' \
  'orphan-1'

run_case \
  all-kill-failure \
  all \
  ABSENT \
  nonzero \
  'killed 0 daemon(s); 1 failed.' \
  'orphan-1'

if (( failures > 0 )); then
  echo "RESULT FAIL failures=$failures"
  exit 1
fi

echo 'RESULT PASS'
