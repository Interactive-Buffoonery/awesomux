#!/bin/bash

set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACT_ROOT="/tmp/companion-pairing-e2e"
if [[ -L "$ARTIFACT_ROOT" ]]; then
  echo "error: artifact root must not be a symbolic link: $ARTIFACT_ROOT" >&2
  exit 1
fi
mkdir -p "$ARTIFACT_ROOT"
chmod 700 "$ARTIFACT_ROOT"
ARTIFACT_DIR="$(mktemp -d "$ARTIFACT_ROOT/run.XXXXXX")"
LINK_FILE="$ARTIFACT_DIR/pairing-link.txt"
RESULT_FILE="$ARTIFACT_DIR/result.json"
STAGE_LOG="$ARTIFACT_DIR/stage.log"
APP_LOG="$ARTIFACT_DIR/app.log"
E2E_LOG="$ARTIFACT_DIR/e2e.log"
APP_BINARY="$ROOT_DIR/dist/awesoMux.app/Contents/MacOS/awesoMux"

firewall_preflight() {
  local firewall=/usr/libexec/ApplicationFirewall/socketfilterfw
  local state block_all apps
  [[ -e "$firewall" ]] || return 0

  if ! state="$("$firewall" --getglobalstate)"; then
    echo "error: could not query macOS firewall state" >&2
    return 1
  fi
  case "$state" in
    "Firewall is disabled. (State = 0)") return 0 ;;
    "Firewall is enabled. (State = 1)") ;;
    *) echo "error: unrecognized macOS firewall state: $state" >&2; return 1 ;;
  esac
  if ! block_all="$("$firewall" --getblockall)"; then
    echo "error: could not query macOS firewall block-all state" >&2
    return 1
  fi
  case "$block_all" in
    "Firewall has block all state set to disabled.") ;;
    "Firewall has block all state set to enabled.")
      echo "error: turn off Block all incoming connections in System Settings > Network > Firewall > Options before running pairing E2E." >&2
      return 1
      ;;
    *) echo "error: unrecognized macOS firewall block-all state: $block_all" >&2; return 1 ;;
  esac
  if ! apps="$("$firewall" --listapps)"; then
    echo "error: could not query macOS firewall applications" >&2
    return 1
  fi
  if ! AWESOMUX_FIREWALL_BINARY="$APP_BINARY" awk '
    /^[0-9]+ : / {
      path = $0
      sub(/^[0-9]+ : /, "", path)
      sub(/[[:space:]]+$/, "", path)
      matches = (path == ENVIRON["AWESOMUX_FIREWALL_BINARY"])
      next
    }
    matches {
      sub(/^[[:space:]]+/, "")
      sub(/[[:space:]]+$/, "")
      if ($0 == "(Allow incoming connections)") allowed = 1
      else denied = 1
      matches = 0
    }
    END { exit !(allowed && !denied) }
  ' <<< "$apps"; then
    echo "error: macOS firewall must allow incoming connections for: $APP_BINARY" >&2
    printf '  sudo %q --add %q\n' "$firewall" "$APP_BINARY" >&2
    printf '  sudo %q --unblockapp %q\n' "$firewall" "$APP_BINARY" >&2
    return 1
  fi
}

mkdir -p "$ARTIFACT_DIR"
: > "$LINK_FILE"
: > "$RESULT_FILE"
: > "$STAGE_LOG"
: > "$APP_LOG"
: > "$E2E_LOG"

cd "$ROOT_DIR"
source "$ROOT_DIR/script/runtime-profile.sh"
runtime_profile="$(awesomux_checkout_profile "$ROOT_DIR")"
./script/build_and_run.sh --stage-local-api-e2e > "$STAGE_LOG" 2>&1
# Build the client now so compiling it can't eat into the pairing window.
swift build --product companion-pairing-e2e >> "$STAGE_LOG" 2>&1

if [[ ! -x "$APP_BINARY" ]]; then
  echo "error: staged development executable is missing: $APP_BINARY" >&2
  exit 1
fi

firewall_preflight

AWESOMUX_COMPANION_AUTO_ALLOW=1 \
  AWESOMUX_COMPANION_E2E_LINK_FILE="$LINK_FILE" \
  AWESOMUX_COMPANION_E2E_RESET_IDENTITY=1 \
  "$APP_BINARY" > "$APP_LOG" 2>&1 &
app_pid=$!
cleanup_complete=0

cleanup() {
  : > "$LINK_FILE"
  if [[ -n "${app_pid:-}" ]] && kill -0 "$app_pid" 2>/dev/null; then
    kill "$app_pid"
    wait "$app_pid" 2>/dev/null || true
  fi
  if [[ "$cleanup_complete" -eq 0 && -s "$RESULT_FILE" ]]; then
    swift run companion-pairing-e2e --cleanup-result "$RESULT_FILE" >> "$E2E_LOG" 2>&1 || true
    cleanup_complete=1
  fi
}
trap cleanup EXIT INT TERM

for _ in $(seq 1 200); do
  if [[ -s "$LINK_FILE" ]]; then
    break
  fi
  if ! kill -0 "$app_pid" 2>/dev/null; then
    echo "error: worktree development app exited before producing a pairing link" >&2
    exit 1
  fi
  sleep 0.1
done

if [[ ! -s "$LINK_FILE" ]]; then
  echo "error: timed out waiting for the pairing link" >&2
  exit 1
fi

if ! swift run companion-pairing-e2e \
  --link-file "$LINK_FILE" \
  --result-file "$RESULT_FILE" \
  --profile "$runtime_profile" 2>&1 | tee "$E2E_LOG"; then
  if grep -q "TLS connection timed out" "$E2E_LOG"; then
    echo "note: the TLS connection did not become ready within 10 seconds." >&2
    echo "  A pending macOS permission prompt can cause this." >&2
    echo "  Check for a pending macOS prompt and Privacy & Security settings for" >&2
    echo "  the dev app, then rebuild and relaunch before debugging the code." >&2
  fi
  exit 1
fi

kill "$app_pid"
wait "$app_pid" 2>/dev/null || true
app_pid=""
swift run companion-pairing-e2e --cleanup-result "$RESULT_FILE" 2>&1 | tee -a "$E2E_LOG"
cleanup_complete=1

echo "E2E log: $E2E_LOG"
echo "App log: $APP_LOG"
echo "Stage log: $STAGE_LOG"
