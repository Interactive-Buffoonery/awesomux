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
./script/build_and_run.sh --stage-local-api-e2e > "$STAGE_LOG" 2>&1
# Build all helpers before launching so compilation cannot consume the pairing window.
swift build --product companion-pairing-e2e >> "$STAGE_LOG" 2>&1
swift build --product local-api-e2e >> "$STAGE_LOG" 2>&1
build_bin_path="$(swift build --show-bin-path)"
client="$build_bin_path/companion-pairing-e2e"
seed_client="$build_bin_path/local-api-e2e"
AMX_BINARY="$ROOT_DIR/dist/awesoMux.app/Contents/MacOS/amx"

if [[ ! -x "$APP_BINARY" ]]; then
  echo "error: staged development executable is missing: $APP_BINARY" >&2
  exit 1
fi

# Retain the real HOME/default Keychain; isolate the run through a unique
# app profile and private shell/XDG/working-directory fixtures instead.
runtime_profile="development:$(awesomux_worktree_id "$ARTIFACT_DIR")"
awesomux_resolve_profile "$runtime_profile"
runtime_home="$HOME"
fixture_snapshot="$ARTIFACT_DIR/native-fixture.json"
fixture_shell="$ARTIFACT_DIR/shell"
fixture_xdg="$ARTIFACT_DIR/xdg-config"
fixture_working_directory="$ARTIFACT_DIR/workspace"
fixture_support="$runtime_home/Library/Application Support/$AWESOMUX_PROFILE_SUPPORT_NAME"
fixture_config="$runtime_home/.config/$AWESOMUX_PROFILE_CONFIG_NAME"
fixture_defaults="$runtime_home/Library/Preferences/$AWESOMUX_PROFILE_BUNDLE_ID.plist"
fixture_tmp="$(getconf DARWIN_USER_TEMP_DIR)"
fixture_socket="${fixture_tmp%/}/$AWESOMUX_PROFILE_SOCKET_NAME"
profile_digest="$(printf '%s' "$runtime_profile" | shasum -a 256 | cut -c1-24)"
fixture_api="/private/tmp/awesomux-api-$(id -u)-$profile_digest"
app_pid=""
fixture_launched=0
fixture_profile_owned=0
fixture_restamped=0
owned_paths=()
owned_path_count=0

fixture_environment=(env -u ZMX_SESSION_PREFIX -u ZMX_SESSION -u ZMX_DIR -u CFFIXED_USER_HOME
  "XDG_CONFIG_HOME=$fixture_xdg" "ZDOTDIR=$fixture_shell"
  SHELL=/bin/zsh "TMPDIR=$fixture_tmp")
fixture_run() {
  "${fixture_environment[@]}" "$@"
}

preferences_count() {
  fixture_run defaults export "$AWESOMUX_PROFILE_BUNDLE_ID" - > "$ARTIFACT_DIR/preferences-export.plist" 2>> "$E2E_LOG" || return 1
  python3 - "$ARTIFACT_DIR/preferences-export.plist" <<'PYPREFERENCES'
import plistlib
import sys
from pathlib import Path

value = plistlib.loads(Path(sys.argv[1]).read_bytes())
if not isinstance(value, dict):
    raise ValueError("Owned preferences export must be a dictionary")
print(len(value))
PYPREFERENCES
}

cleanup_preferences() {
  local count
  count="$(preferences_count)" || return 1
  if [[ "$count" -ne 0 ]]; then
    fixture_run defaults delete "$AWESOMUX_PROFILE_BUNDLE_ID" >> "$E2E_LOG" 2>&1 || return 1
    count="$(preferences_count)" || return 1
    if [[ "$count" -ne 0 ]]; then
      echo "error: owned preferences remain after deletion" >> "$E2E_LOG"
      return 1
    fi
  fi
  # defaults read/export can succeed for an empty domain that delete rejects.
  # Only a verified empty export permits this idempotent cleanup.
  if [[ -e "$fixture_defaults" || -L "$fixture_defaults" ]]; then
    trash "$fixture_defaults" || return 1
  fi
}

cleanup() {
  local result=$? cleanup_failed=0
  trap - EXIT INT TERM
  : > "$LINK_FILE"
  if [[ -n "$app_pid" ]] && kill -0 "$app_pid" 2>/dev/null; then
    kill "$app_pid" || cleanup_failed=1
    wait "$app_pid" 2>/dev/null || true
  fi
  if [[ -s "$RESULT_FILE" ]]; then
    fixture_run "$client" --cleanup-result "$RESULT_FILE" >> "$E2E_LOG" 2>&1 || cleanup_failed=1
  fi
  if [[ "$fixture_launched" -eq 1 ]]; then
    fixture_run env AWESOMUX_AMX="$AMX_BINARY" \
      "$ROOT_DIR/script/amx-reap.sh" --profile "$runtime_profile" all >> "$E2E_LOG" 2>&1 || cleanup_failed=1
    local remaining
    if ! remaining="$(fixture_run env ZMX_DIR="$fixture_socket" ZMX_DIR_MODE=700 "$AMX_BINARY" list --short 2>> "$E2E_LOG")"; then
      cleanup_failed=1
    elif [[ -n "$remaining" ]]; then
      echo "error: owned fixture daemons remain after cleanup" >> "$E2E_LOG"
      cleanup_failed=1
    fi
  fi
  if [[ "$fixture_profile_owned" -eq 1 ]]; then
    fixture_run "$client" --fixture-run "$ARTIFACT_DIR" --home "$runtime_home" --profile "$runtime_profile" --cleanup-identity \
      >> "$E2E_LOG" 2>&1 || cleanup_failed=1
    cleanup_preferences || cleanup_failed=1
  fi
  if [[ "$cleanup_failed" -eq 0 && "$owned_path_count" -gt 0 ]]; then
    local owned
    for owned in "${owned_paths[@]}"; do
      trash "$owned" || cleanup_failed=1
    done
  fi
  if [[ "$cleanup_failed" -ne 0 ]]; then
    echo "error: owned fixture cleanup failed; retained artifacts at $ARTIFACT_DIR" >&2
    result=1
  fi
  echo "fixture_cleanup=$cleanup_failed" >> "$E2E_LOG"
  echo "E2E log: $E2E_LOG"
  echo "App log: $APP_LOG"
  echo "Stage log: $STAGE_LOG"
  if [[ "$fixture_restamped" -eq 1 ]]; then
    echo "note: dist uses the disposable fixture identity; restage with ./script/build_and_run.sh --stage-local-api-e2e before reusing it."
  fi
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

for owned in "$fixture_support" "$fixture_config" "$fixture_socket" "$fixture_api" "$fixture_defaults"; do
  if [[ -e "$owned" || -L "$owned" ]]; then
    echo "error: disposable profile path already exists; refusing to reuse: $owned" >&2
    exit 1
  fi
done
# Verify real HOME/Foundation paths and absence of this run's exact key names
# before claiming anything outside the artifact directory.
fixture_run "$client" --fixture-run "$ARTIFACT_DIR" --home "$runtime_home" --profile "$runtime_profile" >> "$STAGE_LOG" 2>&1
preference_count="$(preferences_count)"
if [[ "$preference_count" -ne 0 ]]; then
  echo "error: disposable preferences domain already exists; refusing to reuse it" >&2
  exit 1
fi
fixture_profile_owned=1
for owned in "$fixture_support" "$fixture_config" "$fixture_socket" "$fixture_api"; do
  mkdir -m 700 "$owned"
  owned_paths+=("$owned")
  owned_path_count=$((owned_path_count + 1))
  printf 'fixture_claimed=%s\n' "$owned" >> "$STAGE_LOG"
done
printf 'fixture_preferences=%s\nfixture_key_label=awesoMux Companion %s\n' "$fixture_defaults" "$profile_digest" >> "$STAGE_LOG"
for owned in "$fixture_shell" "$fixture_xdg" "$fixture_working_directory"; do
  mkdir -m 700 "$owned"
  owned_paths+=("$owned")
  owned_path_count=$((owned_path_count + 1))
  printf 'fixture_claimed=%s\n' "$owned" >> "$STAGE_LOG"
done
mkdir -m 700 "$fixture_xdg/ghostty"
# Prevent Ghostty from creating a default config outside the private XDG tree.
: > "$fixture_xdg/ghostty/config.ghostty"
fixture_run "$seed_client" --seed-native "$fixture_working_directory" > "$fixture_snapshot" 2>> "$STAGE_LOG"
cp "$fixture_snapshot" "$fixture_support/session-state.json"
cat > "$fixture_config/config.toml" <<'EOF'
[general]
restore_workspaces = true
[terminal]
command_bridge_enabled = true
[notifications]
muted = true
EOF
cat > "$fixture_shell/.zshrc" <<'EOF'
PS1='COMPANION_E2E_READY '
RPS1=''
EOF

# Staging owns dist; retain its executable path for the firewall allowlist while
# giving this launch a run-specific identity, as the native lifecycle harness does.
fixture_restamped=1
python3 - "$ROOT_DIR/dist/awesoMux.app/Contents/Info.plist" "$AWESOMUX_PROFILE_BUNDLE_ID" "$AWESOMUX_PROFILE_DISPLAY_NAME" <<'PYPLIST'
import plistlib
import sys
from pathlib import Path

path = Path(sys.argv[1])
metadata = plistlib.loads(path.read_bytes())
metadata.update(CFBundleIdentifier=sys.argv[2], CFBundleDisplayName=sys.argv[3], CFBundleName=sys.argv[3])
path.write_bytes(plistlib.dumps(metadata))
PYPLIST
codesign --force --deep --sign - "$ROOT_DIR/dist/awesoMux.app" >> "$STAGE_LOG" 2>&1
codesign --verify --deep --strict "$ROOT_DIR/dist/awesoMux.app" >> "$STAGE_LOG" 2>&1
firewall_preflight

fixture_launched=1
"${fixture_environment[@]}" AWESOMUX_COMPANION_AUTO_ALLOW=1 \
  AWESOMUX_COMPANION_E2E_LINK_FILE="$LINK_FILE" \
  "$APP_BINARY" > "$APP_LOG" 2>&1 &
app_pid=$!

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

if ! fixture_run "$client" \
  --link-file "$LINK_FILE" \
  --result-file "$RESULT_FILE" \
  --profile "$runtime_profile" \
  --fixture-snapshot "$fixture_snapshot" 2>&1 | tee "$E2E_LOG"; then
  if grep -q "TLS connection timed out" "$E2E_LOG"; then
    echo "note: the TLS connection did not become ready within 10 seconds." >&2
    echo "  A pending macOS permission prompt can cause this." >&2
    echo "  Check for a pending macOS prompt and Privacy & Security settings for" >&2
    echo "  the dev app, then rebuild and relaunch before debugging the code." >&2
  fi
  exit 1
fi

# The EXIT trap owns teardown on both success and failure.
