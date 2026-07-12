#!/usr/bin/env bash
set -euo pipefail

APP_NAME="awesoMux"
BUNDLE_ID="com.interactivebuffoonery.awesomux"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LABEL="manual"
PID=""
SAMPLE_SECONDS="${AWESOMUX_HANG_SAMPLE_SECONDS:-8}"
SAMPLE_INTERVAL_MS="${AWESOMUX_HANG_SAMPLE_INTERVAL_MS:-2}"
LOG_WINDOW="${AWESOMUX_HANG_LOG_WINDOW:-10m}"
CAPTURE_VMMAP=1
ARTIFACT_ROOT="${AWESOMUX_HANG_CAPTURE_DIR:-$ROOT_DIR/docs/debugging/perf-traces/hang-captures}"

cd "$ROOT_DIR"

usage() {
  cat >&2 <<'USAGE'
usage: script/capture-awesomux-hang.sh [options]

Captures a small evidence bundle while awesoMux is beachballing or visibly
stalled. Run this from a separate terminal while the app is still stuck.

Options:
  --pid PID              Capture a specific awesoMux PID.
  --label LABEL          Add a short label to the artifact directory.
  --duration SECONDS     sample(1) duration. Default: 8.
  --interval-ms MS       sample(1) interval. Default: 2.
  --log-window WINDOW    log show window. Default: 10m.
  --root DIR             Artifact root. Default: docs/debugging/perf-traces/hang-captures.
  --no-vmmap             Skip vmmap summary capture.
  --help, -h             Show this help.

Example:
  script/capture-awesomux-hang.sh --label 7-panes-5-llms
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pid)
      if [[ $# -lt 2 ]]; then usage; exit 2; fi
      PID="$2"
      shift 2
      ;;
    --label)
      if [[ $# -lt 2 ]]; then usage; exit 2; fi
      LABEL="$2"
      shift 2
      ;;
    --duration)
      if [[ $# -lt 2 ]]; then usage; exit 2; fi
      SAMPLE_SECONDS="$2"
      shift 2
      ;;
    --interval-ms)
      if [[ $# -lt 2 ]]; then usage; exit 2; fi
      SAMPLE_INTERVAL_MS="$2"
      shift 2
      ;;
    --log-window)
      if [[ $# -lt 2 ]]; then usage; exit 2; fi
      LOG_WINDOW="$2"
      shift 2
      ;;
    --root)
      if [[ $# -lt 2 ]]; then usage; exit 2; fi
      ARTIFACT_ROOT="$2"
      shift 2
      ;;
    --no-vmmap)
      CAPTURE_VMMAP=0
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

validate_positive_number() {
  local name="$1"
  local value="$2"
  if ! awk -v value="$value" 'BEGIN { exit (value ~ /^[0-9]+([.][0-9]+)?$/ && value > 0) ? 0 : 1 }'; then
    echo "error: $name must be a positive number." >&2
    exit 2
  fi
}

safe_label() {
  printf '%s' "$1" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_'
}

capture_command() {
  local output_path="$1"
  shift

  {
    printf '$'
    printf ' %q' "$@"
    printf '\n\n'
    "$@"
  } >"$output_path" 2>&1 || {
    local status="$?"
    printf '\ncommand exited with status %s\n' "$status" >>"$output_path"
  }
}

validate_positive_number "--duration" "$SAMPLE_SECONDS"
validate_positive_number "--interval-ms" "$SAMPLE_INTERVAL_MS"

if [[ -z "$PID" ]]; then
  PID="$(pgrep -x "$APP_NAME" | tail -n 1 || true)"
fi

if [[ -z "$PID" ]]; then
  echo "error: no running $APP_NAME process found." >&2
  exit 1
fi

if ! ps -p "$PID" >/dev/null 2>&1; then
  echo "error: PID $PID is not running." >&2
  exit 1
fi

timestamp="$(date -u +"%Y%m%dT%H%M%SZ")"
artifact_dir="$ARTIFACT_ROOT/${timestamp}-$(safe_label "$LABEL")"
mkdir -p "$artifact_dir"
chmod 700 "$ARTIFACT_ROOT" 2>/dev/null || true
chmod 700 "$artifact_dir" 2>/dev/null || true

metadata_path="$artifact_dir/metadata.txt"
sample_path="$artifact_dir/sample.txt"
sample_command_path="$artifact_dir/sample-command.txt"
ps_path="$artifact_dir/ps.txt"
top_path="$artifact_dir/top.txt"
threads_path="$artifact_dir/threads.txt"
vm_stat_path="$artifact_dir/vm_stat.txt"
system_path="$artifact_dir/system.txt"
memory_pressure_path="$artifact_dir/memory_pressure.txt"
log_path="$artifact_dir/recent-awesomux.log"
vmmap_path="$artifact_dir/vmmap-summary.txt"

{
  printf 'created_at_utc=%s\n' "$timestamp"
  printf 'app_name=%s\n' "$APP_NAME"
  printf 'bundle_id=%s\n' "$BUNDLE_ID"
  printf 'pid=%s\n' "$PID"
  printf 'label=%s\n' "$(safe_label "$LABEL")"
  printf 'sample_seconds=%s\n' "$SAMPLE_SECONDS"
  printf 'sample_interval_ms=%s\n' "$SAMPLE_INTERVAL_MS"
  printf 'log_window=%s\n' "$LOG_WINDOW"
  printf 'artifact_dir=%s\n' "$artifact_dir"
  printf 'git_commit=%s\n' "$(git rev-parse --short HEAD 2>/dev/null || printf 'unavailable')"
  printf 'git_branch=%s\n' "$(git branch --show-current 2>/dev/null || printf 'unavailable')"
  printf 'note=%s\n' 'Raw hang captures may contain local paths and terminal text; keep them out of commits.'
} >"$metadata_path"

capture_command "$ps_path" ps -p "$PID" -o pid,ppid,%cpu,%mem,rss,vsz,stat,etime,command
capture_command "$top_path" top -l 1 -pid "$PID" -stats pid,cpu,threads,ports,mem,command
capture_command "$threads_path" ps -M -p "$PID"
capture_command "$vm_stat_path" vm_stat
capture_command "$system_path" sysctl hw.memsize hw.ncpu machdep.cpu.brand_string vm.loadavg

if command -v memory_pressure >/dev/null 2>&1; then
  capture_command "$memory_pressure_path" memory_pressure
fi

capture_command "$log_path" /usr/bin/log show --last "$LOG_WINDOW" --style compact --predicate "process == \"$APP_NAME\" OR subsystem == \"$BUNDLE_ID\""

if [[ "$CAPTURE_VMMAP" -eq 1 ]]; then
  capture_command "$vmmap_path" vmmap -summary "$PID"
fi

if command -v sample >/dev/null 2>&1; then
  capture_command "$sample_command_path" sample "$PID" "$SAMPLE_SECONDS" "$SAMPLE_INTERVAL_MS" -mayDie -file "$sample_path"
else
  printf 'sample command unavailable\n' >"$sample_path"
fi

cat <<EOF
Wrote awesoMux hang capture:
  $artifact_dir

Most useful files:
  $sample_path
  $metadata_path
  $top_path
  $log_path

Keep this directory local unless you scrub it first.
EOF
