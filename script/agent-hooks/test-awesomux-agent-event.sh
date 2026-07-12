#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HELPER="$ROOT_DIR/script/agent-hooks/awesomux-agent-event"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# If the helper cannot encode an event, it reports the failure on stderr and
# silently drops the event. INT-421 keeps that failure mode so this side channel
# only carries adapter runtime events, not helper self-reporting events.

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

assert_eq() {
  local actual="$1"
  local expected="$2"
  local message="$3"

  if [[ "$actual" != "$expected" ]]; then
    printf 'not ok - %s\nexpected: %s\nactual:   %s\n' "$message" "$expected" "$actual" >&2
    exit 1
  fi
}

assert_file_empty() {
  local path="$1"
  local message="$2"

  if [[ -s "$path" ]]; then
    fail "$message"
  fi
}

assert_valid_json_line() {
  local line="$1"

  printf '%s\n' "$line" | /usr/bin/perl -MJSON::PP -0 -e 'JSON::PP->new->utf8->decode(<STDIN>)' \
    || fail "expected valid JSON: $line"
}

read_only_line() {
  local path="$1"

  IFS= read -r line < "$path"
  printf '%s' "$line"
}

run_helper() {
  AWESOMUX_AGENT_EVENT_FILE="$1" "$HELPER" "${@:2}"
}

test_no_event_file_configured() {
  local output="$TMP_DIR/no-event-file.jsonl"

  env -u AWESOMUX_AGENT_EVENT_FILE "$HELPER" --source claude-code

  if [[ -e "$output" && -s "$output" ]]; then
    fail "expected no output when event file is unset"
  fi
}

test_missing_source() {
  local output="$TMP_DIR/missing-source.jsonl"
  : > "$output"

  run_helper "$output" --kind "Claude Code" --state thinking --timestamp 1700000000

  assert_file_empty "$output" "expected no output when source is missing"
}

test_unknown_argument() {
  local output="$TMP_DIR/unknown-argument.jsonl"
  local stderr="$TMP_DIR/unknown-argument.stderr"
  local status=0
  : > "$output"

  run_helper "$output" --bad 2> "$stderr" || status=$?

  assert_eq "$status" "2" "unknown argument exits 2"
  grep -q 'unknown argument' "$stderr" || fail "expected unknown argument on stderr"
}

test_well_formed_event_parity() {
  local output="$TMP_DIR/parity.jsonl"
  local line
  : > "$output"

  run_helper "$output" \
    --source claude-code \
    --kind "Claude Code" \
    --state thinking \
    --phase toolStart \
    --eventID abc123 \
    --timestamp 1700000000

  line="$(read_only_line "$output")"
  assert_eq "$line" '{"v":1,"source":"claude-code","kind":"Claude Code","state":"thinking","phase":"toolStart","eventID":"abc123","timestamp":1700000000}' "well-formed event parity"
}

test_iso_timestamp_parity() {
  local output="$TMP_DIR/iso-timestamp.jsonl"
  local line
  : > "$output"

  run_helper "$output" --source claude-code --timestamp 2026-05-15T17:34:37.123Z

  line="$(read_only_line "$output")"
  assert_eq "$line" '{"v":1,"source":"claude-code","timestamp":"2026-05-15T17:34:37.123Z"}' "ISO timestamp remains quoted"
  assert_valid_json_line "$line"
}

test_malformed_numeric_timestamp_transport_json() {
  local output="$TMP_DIR/malformed-numeric-timestamp.jsonl"
  local line
  : > "$output"

  run_helper "$output" --source claude-code --timestamp .123

  line="$(read_only_line "$output")"
  [[ "$line" == *'"timestamp":".123"'* ]] \
    || fail "expected malformed numeric-like timestamp to be quoted"
  assert_valid_json_line "$line"

  : > "$output"
  run_helper "$output" --source claude-code --timestamp 1.

  line="$(read_only_line "$output")"
  [[ "$line" == *'"timestamp":"1."'* ]] \
    || fail "expected trailing-dot timestamp to be quoted"
  assert_valid_json_line "$line"

  : > "$output"
  run_helper "$output" --source claude-code --timestamp 01

  line="$(read_only_line "$output")"
  [[ "$line" == *'"timestamp":"01"'* ]] \
    || fail "expected leading-zero timestamp to be quoted"
  assert_valid_json_line "$line"

  # Swift still rejects this non-ISO timestamp value; the JSONL transport
  # now stays valid so the bad value is drop-safe at the parser boundary.
}

test_special_characters() {
  local output="$TMP_DIR/special-characters.jsonl"
  local source=$'quote" slash\\ newline\n tab\t return\r utf8 café'
  local kind=$'kind "value"'
  local state=$'state\\value'
  local phase=$'line\nphase'
  local event_id=$'tab\treturn\r'
  local line
  : > "$output"

  run_helper "$output" \
    --source "$source" \
    --kind "$kind" \
    --state "$state" \
    --phase "$phase" \
    --eventID "$event_id"

  line="$(read_only_line "$output")"
  printf '%s\n' "$line" | /usr/bin/perl -MJSON::PP -MEncode -0 -e '
    my $event = JSON::PP->new->utf8->decode(<STDIN>);
    my @expected = map { Encode::decode("UTF-8", $_, Encode::FB_DEFAULT) } @ARGV;
    die "source mismatch\n" unless $event->{source} eq $expected[0];
    die "kind mismatch\n" unless $event->{kind} eq $expected[1];
    die "state mismatch\n" unless $event->{state} eq $expected[2];
    die "phase mismatch\n" unless $event->{phase} eq $expected[3];
    die "eventID mismatch\n" unless $event->{eventID} eq $expected[4];
  ' "$source" "$kind" "$state" "$phase" "$event_id" \
    || fail "decoded special-character values did not match"

  [[ "$line" == *'quote\" slash'* ]] || fail "expected embedded quote escape in raw JSON"
  [[ "$line" == *'\\'* ]] || fail "expected backslash escape in raw JSON"
  [[ "$line" == *'\n'* ]] || fail "expected newline escape in raw JSON"
  [[ "$line" == *'\t'* ]] || fail "expected tab escape in raw JSON"
  [[ "$line" == *'\r'* ]] || fail "expected carriage return escape in raw JSON"

  local total_lines
  total_lines="$(wc -l < "$output" | tr -d ' ')"
  assert_eq "$total_lines" "1" "special-characters output stays single-line"
}

test_oversized_line_dropped() {
  local output="$TMP_DIR/oversized.jsonl"
  local stderr="$TMP_DIR/oversized.stderr"
  local huge
  huge="$(/usr/bin/perl -e 'print "x" x 5000')"
  : > "$output"

  run_helper "$output" --source claude-code --kind "$huge" 2> "$stderr"

  assert_file_empty "$output" "oversized event must not be appended"
  grep -q 'exceeds 4096 bytes' "$stderr" || fail "expected oversized-line warning on stderr"
}

test_event_throughput() {
  local output="$TMP_DIR/benchmark.jsonl"
  local default_event_count=100
  if [[ "${AWESOMUX_AGENT_EVENT_FULL_BENCHMARK:-}" == "1" ]]; then
    default_event_count=1000
  fi
  local event_count="${AWESOMUX_AGENT_EVENT_BENCHMARK_EVENTS:-$default_event_count}"
  local max_seconds="${AWESOMUX_AGENT_EVENT_BENCHMARK_MAX_SECONDS:-}"
  local elapsed
  local lines
  : > "$output"

  elapsed="$(
    /usr/bin/perl -MTime::HiRes=time -e 'print time, "\n"' \
      | {
        read -r start
        for index in $(seq 1 "$event_count"); do
          run_helper "$output" \
            --source claude-code \
            --kind "Claude Code" \
            --state thinking \
            --phase toolStart \
            --eventID "event-$index" \
            --timestamp 1700000000
        done
        end="$(/usr/bin/perl -MTime::HiRes=time -e 'print time')"
        /usr/bin/perl -e 'printf "%.6f", $ARGV[1] - $ARGV[0]' "$start" "$end"
      }
  )"

  lines="$(wc -l < "$output" | tr -d ' ')"
  assert_eq "$lines" "$event_count" "${event_count}-event line count"

  /usr/bin/perl -MJSON::PP -ne 'JSON::PP->new->utf8->decode($_)' "$output" \
    || fail "expected every benchmark line to decode as JSON"

  # Process-launch cost dominates this test on macOS, so elapsed time is
  # telemetry by default. Set AWESOMUX_AGENT_EVENT_BENCHMARK_MAX_SECONDS to
  # enforce a local ceiling when investigating helper performance.
  if [[ -n "$max_seconds" ]]; then
    /usr/bin/perl -e 'exit($ARGV[0] <= $ARGV[1] ? 0 : 1)' "$elapsed" "$max_seconds" \
      || fail "${event_count}-event throughput took ${elapsed}s, above ${max_seconds}s"
  fi

  printf '%s-event throughput: %ss\n' "$event_count" "$elapsed"
}

test_no_event_file_configured
test_missing_source
test_unknown_argument
test_well_formed_event_parity
test_iso_timestamp_parity
test_malformed_numeric_timestamp_transport_json
test_special_characters
test_oversized_line_dropped
test_event_throughput

printf 'ok - awesomux-agent-event shell tests passed\n'
