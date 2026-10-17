#!/usr/bin/env bash
#
# smoke-companion-shell-exit.sh — scripted GUI smoke for #721: the Terminal
# Companion closes once its hosted shell exits.
#
# Drives the real exit lifecycle in a launched build: summon the companion,
# type `Exit` (zsh: command not found, so the shell keeps running and the
# window must stay), then `exit` (the shell process really ends, so the window
# must close). Finally re-summons the companion to prove the next summon gets a
# fresh shell rather than the "Terminal session unavailable" placeholder, and
# closes it with its close button.
#
# Usage: script/smoke-companion-shell-exit.sh [ARTIFACT_DIR]
# Exit codes: 0 pass, 1 fail, 3 skipped (no Accessibility grant),
#             4 this checkout's dev instance is already running.
#
# Profile isolation follows script/smoke-floating-rebind.sh: this checkout's
# dev profile is moved aside and restored on exit, and every process is
# targeted by PID so no other awesoMux instance is touched. Command-bridge
# daemons that survive app quit are reaped for this profile only.
set -euo pipefail
trap 'echo "FAIL: unexpected error at line $LINENO (exit $?)" >&2' ERR

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
source "$ROOT_DIR/script/runtime-profile.sh"

APP_NAME="awesoMux"
APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
ARTIFACT_DIR="${1:-$ROOT_DIR/.build/smoke-companion-shell-exit}"
mkdir -p "$ARTIFACT_DIR"
TIMELINE="$ARTIFACT_DIR/timeline.log"
: > "$TIMELINE"

TARGET_PID=""
PROFILE=""
SUPPORT_DIR=""
CONFIG_DIR=""
DEFAULTS_DOMAIN=""
STATE_BACKUP_DIR=""
DEFAULTS_HAD_DOMAIN=0

note() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*" | tee -a "$TIMELINE"; }

exact_path_pids() {
    local pid comm
    for pid in $(pgrep -x "$APP_NAME" 2>/dev/null || true); do
        comm="$(ps -p "$pid" -o comm= 2>/dev/null || true)"
        [[ "$comm" == "$APP_BINARY" ]] && printf '%s\n' "$pid"
    done
    return 0
}

isolate_profile_state() {
    PROFILE="$(awesomux_checkout_profile "$ROOT_DIR")"
    awesomux_resolve_profile "$PROFILE"
    SUPPORT_DIR="$HOME/Library/Application Support/$AWESOMUX_PROFILE_SUPPORT_NAME"
    CONFIG_DIR="$HOME/.config/$AWESOMUX_PROFILE_CONFIG_NAME"
    DEFAULTS_DOMAIN="$AWESOMUX_PROFILE_BUNDLE_ID"
    if [[ -n "$(exact_path_pids)" ]]; then
        echo "FAIL: a dev instance of $APP_BINARY is already running; quit it first." >&2
        exit 4
    fi
    STATE_BACKUP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/awesomux-smoke-state.XXXXXX")"
    [[ -e "$SUPPORT_DIR" ]] && mv "$SUPPORT_DIR" "$STATE_BACKUP_DIR/support"
    [[ -e "$CONFIG_DIR" ]] && mv "$CONFIG_DIR" "$STATE_BACKUP_DIR/config"
    if defaults read "$DEFAULTS_DOMAIN" >/dev/null 2>&1; then
        DEFAULTS_HAD_DOMAIN=1
        defaults export "$DEFAULTS_DOMAIN" "$STATE_BACKUP_DIR/defaults.plist"
        defaults delete "$DEFAULTS_DOMAIN" >/dev/null 2>&1 || true
    fi
    return 0
}

restore_profile_state() {
    [[ -n "$STATE_BACKUP_DIR" ]] || return 0
    rm -rf "$SUPPORT_DIR"
    [[ -e "$STATE_BACKUP_DIR/support" ]] && mv "$STATE_BACKUP_DIR/support" "$SUPPORT_DIR"
    rm -rf "$CONFIG_DIR"
    [[ -e "$STATE_BACKUP_DIR/config" ]] && mv "$STATE_BACKUP_DIR/config" "$CONFIG_DIR"
    if [[ "$DEFAULTS_HAD_DOMAIN" == 1 ]]; then
        defaults import "$DEFAULTS_DOMAIN" "$STATE_BACKUP_DIR/defaults.plist" 2>/dev/null || true
    else
        defaults delete "$DEFAULTS_DOMAIN" >/dev/null 2>&1 || true
    fi
    rm -rf "$STATE_BACKUP_DIR"
}

cleanup() {
    if [[ -n "$TARGET_PID" ]]; then
        kill -TERM "$TARGET_PID" 2>/dev/null || true
        for _ in $(seq 1 20); do
            kill -0 "$TARGET_PID" 2>/dev/null || break
            sleep 0.25
        done
        kill -KILL "$TARGET_PID" 2>/dev/null || true
    fi
    # Bridge daemons outlive the app by design; reap this profile's only.
    if [[ -n "$PROFILE" ]]; then
        "$ROOT_DIR/script/amx-reap.sh" --profile "$PROFILE" all >>"$TIMELINE" 2>&1 || true
    fi
    restore_profile_state
}

ax() {
    osascript -e "tell application \"System Events\" to tell (first process whose unix id is $TARGET_PID) to $1" 2>/dev/null
}

window_names() { ax "get name of every window" || true; }

companion_open() { [[ "$(window_names)" == *"Terminal Companion"* ]]; }

wait_for() {
    local want="$1" seconds="$2"
    for _ in $(seq 1 $((seconds * 4))); do
        if [[ "$want" == open ]] && companion_open; then return 0; fi
        if [[ "$want" == closed ]] && ! companion_open; then return 0; fi
        sleep 0.25
    done
    return 1
}

# Raw AX tree of the companion window: names its static texts, so the
# "Terminal session unavailable" placeholder is visible when present.
dump_companion() {
    {
        echo "== $1 =="
        echo "windows: $(window_names)"
        ax "get entire contents of window \"Terminal Companion\"" || echo "(no companion window)"
        echo "-- terminal text tail --"
        terminal_text | tail -c 600
    } >>"$ARTIFACT_DIR/ax-dump.txt"
}

terminal_text() { ax "get value of text area 1 of group 1 of group 1 of window \"Terminal Companion\"" || true; }

wait_for_text() {
    local pattern="$1" seconds="$2"
    for _ in $(seq 1 $((seconds * 4))); do
        terminal_text | grep -qE "$pattern" && return 0
        sleep 0.25
    done
    return 1
}

type_line() {
    # Re-sending frontmost to an already-active app re-keys the workspace
    # window, so only activate when needed, then raise the companion.
    [[ "$(ax "get frontmost" || true)" == true ]] || ax "set frontmost to true" >/dev/null || true
    ax "perform action \"AXRaise\" of window \"Terminal Companion\"" >/dev/null || true
    sleep 0.5
    # Typing into the workspace window instead would exit the wrong shell and
    # fake a reproduction, so refuse unless the companion holds focus.
    local focused
    focused="$(ax "get name of (value of attribute \"AXFocusedWindow\")" || true)"
    note "focused window before typing '$1': $focused"
    if [[ "$focused" != "Terminal Companion" ]]; then
        note "FAIL: companion is not the focused window; refusing to type"
        exit 1
    fi
    osascript -e "tell application \"System Events\" to keystroke \"$1\"" -e 'tell application "System Events" to key code 36'
}

if [[ "$(osascript -e 'tell application "System Events" to UI elements enabled' 2>/dev/null)" != "true" ]]; then
    echo "SKIPPED: needs Accessibility grant for the calling process."
    exit 3
fi

trap cleanup EXIT
isolate_profile_state
note "commit=$(git rev-parse HEAD) dirty=$(git status --porcelain -- Sources | wc -l | tr -d ' ') profile=$PROFILE"

./script/build_and_run.sh --verify >"$ARTIFACT_DIR/build.log" 2>&1
OLD_PIDS="$(exact_path_pids)"
open -n "$APP_BUNDLE"
for _ in $(seq 1 40); do
    TARGET_PID="$(comm -13 <(printf '%s\n' "$OLD_PIDS" | sort) <(exact_path_pids | sort) | head -1)"
    [[ -n "$TARGET_PID" ]] && break
    sleep 0.25
done
[[ -n "$TARGET_PID" ]] || { note "FAIL: app did not start"; exit 1; }
note "launched pid=$TARGET_PID"

for _ in $(seq 1 40); do
    [[ "$(ax "count menu bars" || echo 0)" -gt 0 ]] && break
    sleep 0.25
done
ax "set frontmost to true" >/dev/null
ax "click menu item \"New Workspace\" of menu \"File\" of menu bar 1" >/dev/null
for _ in $(seq 1 40); do
    [[ "$(ax "count windows" || echo 0)" -gt 0 ]] && break
    sleep 0.25
done

ax "click menu item \"Show Terminal Companion\" of menu \"View\" of menu bar 1" >/dev/null
wait_for open 10 || { dump_companion "summon failed"; note "FAIL: companion never opened"; exit 1; }
# Typing before the shell has drawn its first prompt can be dropped.
wait_for_text '[^[:space:]]' 20 || { dump_companion "no prompt"; note "FAIL: shell never drew a prompt"; exit 1; }
sleep 2
dump_companion "after summon"
note "companion open"

type_line "Exit"
# Proves the keystrokes reached this shell, so a later non-close is real.
wait_for_text 'command not found: Exit' 10 || { dump_companion "after Exit"; note "FAIL: 'Exit' never reached the companion shell"; exit 1; }
sleep 1
if ! companion_open; then
    dump_companion "after Exit"
    note "FAIL: typing 'Exit' (not a shell exit) closed the companion"
    exit 1
fi
note "typed 'Exit': companion still open (expected; zsh keeps running)"

type_line "exit"
if ! wait_for closed 10; then
    dump_companion "after exit"
    note "FAIL: companion still open 10s after the shell exited (#721 reproduced)"
    exit 1
fi
dump_companion "after exit"
note "typed 'exit': companion closed"

ax "click menu item \"Show Terminal Companion\" of menu \"View\" of menu bar 1" >/dev/null
wait_for open 10 || { note "FAIL: companion did not reopen after shell exit"; exit 1; }
sleep 3
dump_companion "after re-summon"
if sed -n '/== after re-summon ==/,$p' "$ARTIFACT_DIR/ax-dump.txt" | grep -q "Terminal session unavailable"; then
    note "FAIL: re-summoned companion shows the unavailable placeholder"
    exit 1
fi
note "re-summoned companion has a live session"

CLOSE_RESULT="$(osascript -e "tell application \"System Events\"
tell (first process whose unix id is $TARGET_PID)
    set out to {}
    repeat with b in (buttons of group 1 of group 1 of window \"Terminal Companion\")
        set p to properties of b
        set d to (name of p as text) & \"|\" & (description of p as text) & \"|\" & (help of p as text)
        set end of out to d
        if help of p is \"Close\" then click b
    end repeat
    return out
end tell
end tell" 2>&1 || true)"
note "companion buttons (pressed the close one): $CLOSE_RESULT"
# close() confirms first when the shell is not provably idle; that dialog is
# existing behavior, so confirm it and record that it appeared.
sleep 1
CONFIRMED="$(osascript -e "tell application \"System Events\"
tell (first process whose unix id is $TARGET_PID)
    repeat with w in windows
        if exists button \"Close Terminal\" of w then
            click button \"Close Terminal\" of w
            return \"yes\"
        end if
    end repeat
    return \"no\"
end tell
end tell" 2>&1 || true)"
note "close confirmation appeared and was confirmed: $CONFIRMED"
if ! wait_for closed 5; then
    dump_companion "after close button"
    ax "get entire contents of every window" >"$ARTIFACT_DIR/all-windows-after-close.txt" 2>&1 || true
    note "FAIL: close button did not close the re-summoned companion"
    exit 1
fi
note "close button closed the companion"
note "PASS"
