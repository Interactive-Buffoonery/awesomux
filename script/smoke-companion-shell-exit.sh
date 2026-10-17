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
# Stage without launching, then copy/reidentify the bundle using the supported
# development:<12-hex> runtime profile. Each run has a fresh daemon namespace;
# existing checkout daemons are never launched into or reaped. Profile files
# are reversibly backed up, and app cleanup checks the owned PID's executable.
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
ARTIFACT_DIR="$(cd "$ARTIFACT_DIR" && pwd -P)"
TIMELINE="$ARTIFACT_DIR/timeline.log"
: > "$TIMELINE"

TARGET_PID=""
PROFILE=""
SUPPORT_DIR=""
CONFIG_DIR=""
DEFAULTS_DOMAIN=""
STATE_BACKUP_DIR=""
DEFAULTS_HAD_DOMAIN=0
SUPPORT_ISOLATED=0
CONFIG_ISOLATED=0
DEFAULTS_ISOLATED=0
RUN_BUNDLE_DIR=""
RUN_STARTED=0

note() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*" | tee -a "$TIMELINE"; }

exact_path_pids() {
    local output pid comm
    output="$(ps -axo pid=,comm=)" || return 1
    while read -r pid comm; do
        [[ "$comm" == "$APP_BINARY" ]] && printf '%s\n' "$pid"
    done <<< "$output"
    return 0
}

isolate_profile_state() {
    local running socket_base
    running="$(exact_path_pids)" || { note "FAIL: cannot enumerate app processes"; return 1; }
    if [[ -n "$running" ]]; then
        echo "FAIL: a dev instance of $APP_BINARY is already running; quit it first." >&2
        exit 4
    fi
    RUN_BUNDLE_DIR="$(mktemp -d "$ARTIFACT_DIR/run.XXXXXX")"
    PROFILE="development:$(awesomux_worktree_id "$RUN_BUNDLE_DIR")"
    awesomux_resolve_profile "$PROFILE"
    SUPPORT_DIR="$HOME/Library/Application Support/$AWESOMUX_PROFILE_SUPPORT_NAME"
    CONFIG_DIR="$HOME/.config/$AWESOMUX_PROFILE_CONFIG_NAME"
    DEFAULTS_DOMAIN="$AWESOMUX_PROFILE_BUNDLE_ID"
    socket_base="$(getconf DARWIN_USER_TEMP_DIR)"
    [[ -n "$socket_base" ]] || { note "FAIL: cannot resolve daemon socket root"; return 1; }
    ZMX_DIR="${socket_base%/}/$AWESOMUX_PROFILE_SOCKET_NAME"
    # The socket namespace uses only nine hash digits. Refuse even an empty
    # existing directory rather than assume the full profile hash is unique.
    if [[ -e "$ZMX_DIR" || -L "$ZMX_DIR" ]]; then
        note "FAIL: run daemon namespace already exists: $ZMX_DIR"
        return 1
    fi
    STATE_BACKUP_DIR="$(mktemp -d "$ARTIFACT_DIR/state.XXXXXX")"
    if [[ -e "$SUPPORT_DIR" || -L "$SUPPORT_DIR" ]]; then
        mv "$SUPPORT_DIR" "$STATE_BACKUP_DIR/support"
    fi
    SUPPORT_ISOLATED=1
    if [[ -e "$CONFIG_DIR" || -L "$CONFIG_DIR" ]]; then
        mv "$CONFIG_DIR" "$STATE_BACKUP_DIR/config"
    fi
    CONFIG_ISOLATED=1
    if defaults read "$DEFAULTS_DOMAIN" >/dev/null 2>&1; then
        defaults export "$DEFAULTS_DOMAIN" "$STATE_BACKUP_DIR/defaults.plist"
        DEFAULTS_HAD_DOMAIN=1
        DEFAULTS_ISOLATED=1
        defaults delete "$DEFAULTS_DOMAIN"
    else
        DEFAULTS_ISOLATED=1
    fi
}

restore_profile_state() {
    [[ -n "$STATE_BACKUP_DIR" ]] || return 0
    local failed=0
    if [[ "$SUPPORT_ISOLATED" == 1 ]]; then
        if { [[ ! -e "$SUPPORT_DIR" && ! -L "$SUPPORT_DIR" ]] || trash "$SUPPORT_DIR"; } &&
            { [[ ! -e "$STATE_BACKUP_DIR/support" && ! -L "$STATE_BACKUP_DIR/support" ]] || mv "$STATE_BACKUP_DIR/support" "$SUPPORT_DIR"; }; then
            SUPPORT_ISOLATED=0
        else
            failed=1
        fi
    fi
    if [[ "$CONFIG_ISOLATED" == 1 ]]; then
        if { [[ ! -e "$CONFIG_DIR" && ! -L "$CONFIG_DIR" ]] || trash "$CONFIG_DIR"; } &&
            { [[ ! -e "$STATE_BACKUP_DIR/config" && ! -L "$STATE_BACKUP_DIR/config" ]] || mv "$STATE_BACKUP_DIR/config" "$CONFIG_DIR"; }; then
            CONFIG_ISOLATED=0
        else
            failed=1
        fi
    fi
    if [[ "$DEFAULTS_ISOLATED" == 1 ]]; then
        if [[ "$DEFAULTS_HAD_DOMAIN" == 1 ]]; then
            defaults import "$DEFAULTS_DOMAIN" "$STATE_BACKUP_DIR/defaults.plist" || failed=1
        elif defaults read "$DEFAULTS_DOMAIN" >/dev/null 2>&1; then
            defaults delete "$DEFAULTS_DOMAIN" || failed=1
        fi
        [[ "$failed" == 1 ]] || DEFAULTS_ISOLATED=0
    fi
    if [[ "$failed" == 1 ]]; then
        note "FAIL: restoration incomplete; retain backups at $STATE_BACKUP_DIR"
        return 1
    fi
    trash "$STATE_BACKUP_DIR" || return 1
    STATE_BACKUP_DIR=""
}

cleanup() {
    local comm
    if [[ -n "$TARGET_PID" ]]; then
        if kill -0 "$TARGET_PID" 2>/dev/null; then
            comm="$(ps -p "$TARGET_PID" -o comm=)" || return 1
            [[ "$comm" == "$APP_BINARY" ]] || { note "FAIL: cleanup PID identity changed"; return 1; }
            kill -TERM "$TARGET_PID" || return 1
            for _ in $(seq 1 20); do
                kill -0 "$TARGET_PID" 2>/dev/null || break
                sleep 0.25
            done
            if kill -0 "$TARGET_PID" 2>/dev/null; then
                comm="$(ps -p "$TARGET_PID" -o comm=)" || return 1
                [[ "$comm" == "$APP_BINARY" ]] || return 1
                kill -KILL "$TARGET_PID" || return 1
            fi
        fi
        wait "$TARGET_PID" 2>/dev/null || true
        TARGET_PID=""
    fi
    if [[ "$RUN_STARTED" == 1 ]]; then
        env -u ZMX_SESSION_PREFIX -u ZMX_SESSION AWESOMUX_AMX="$APP_BUNDLE/Contents/MacOS/amx" \
            "$ROOT_DIR/script/amx-reap.sh" --profile "$PROFILE" all >>"$TIMELINE" 2>&1 || {
                note "FAIL: run daemon cleanup failed; retain bundle/state at $RUN_BUNDLE_DIR / $STATE_BACKUP_DIR"
                return 1
            }
        local live
        for _ in $(seq 1 20); do
            live="$(env -u ZMX_SESSION_PREFIX -u ZMX_SESSION ZMX_DIR="$ZMX_DIR" ZMX_DIR_MODE=700 \
                "$APP_BUNDLE/Contents/MacOS/amx" list --short)" || return 1
            [[ -n "$live" ]] || break
            sleep 0.25
        done
        [[ -z "$live" ]] || { note "FAIL: run daemons remain: $live"; return 1; }
        note "cleanup: owned app exited and run daemon list is empty"
        RUN_STARTED=0
    fi
    restore_profile_state
}

finish() {
    local status="$?"
    trap - EXIT
    if ! cleanup; then
        note "FAIL: cleanup incomplete; inspect $RUN_BUNDLE_DIR / $STATE_BACKUP_DIR"
        status=1
    fi
    if [[ "$status" == 0 ]]; then note "PASS (including cleanup)"; fi
    exit "$status"
}

ax() {
    osascript -e "tell application \"System Events\" to tell (first process whose unix id is $TARGET_PID) to $1" 2>>"$ARTIFACT_DIR/ax-errors.log"
}

window_names() { ax "get name of every window"; }

companion_open() {
    local names
    names="$(window_names)" || return 2
    [[ "$names" == *"Terminal Companion"* ]]
}

wait_for() {
    local want="$1" seconds="$2"
    for _ in $(seq 1 $((seconds * 4))); do
        local status=0
        companion_open || status="$?"
        [[ "$status" != 2 ]] || { note "FAIL: AX window query failed"; return 1; }
        if [[ "$want" == open && "$status" == 0 ]]; then return 0; fi
        if [[ "$want" == closed && "$status" == 1 ]]; then return 0; fi
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
        { terminal_text || echo "(terminal AX unavailable)"; } | tail -c 600
    } >>"$ARTIFACT_DIR/ax-dump.txt"
}

terminal_text() { ax "get value of text area 1 of group 1 of group 1 of window \"Terminal Companion\""; }

wait_for_text() {
    local pattern="$1" seconds="$2"
    for _ in $(seq 1 $((seconds * 4))); do
        local text
        text="$(terminal_text)" || { note "FAIL: AX terminal query failed"; return 1; }
        grep -qE "$pattern" <<< "$text" && return 0
        sleep 0.25
    done
    return 1
}

type_line() {
    # Re-sending frontmost to an already-active app re-keys the workspace
    # window, so only activate when needed, then raise the companion.
    [[ "$(ax "get frontmost")" == true ]] || ax "set frontmost to true" >/dev/null
    ax "perform action \"AXRaise\" of window \"Terminal Companion\"" >/dev/null
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

trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
isolate_profile_state
note "commit=$(git rev-parse HEAD) profile=$PROFILE"
{
    git status --porcelain=v1
    git diff --binary HEAD
    git ls-files -z Sources script Package.swift Package.resolved | xargs -0 shasum -a 256
} >"$ARTIFACT_DIR/source-manifest.txt"
shasum -a 256 "${BASH_SOURCE[0]}" >"$ARTIFACT_DIR/script.sha256"

# The existing staging mode does not launch into the checkout profile. Only
# the copied bundle below is launched, after adopting the isolated identity.
./script/build_and_run.sh --stage-local-api-e2e >"$ARTIFACT_DIR/build.log" 2>&1
cp -R "$APP_BUNDLE" "$RUN_BUNDLE_DIR/$APP_NAME.app"
APP_BUNDLE="$RUN_BUNDLE_DIR/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $DEFAULTS_DOMAIN" "$APP_BUNDLE/Contents/Info.plist"
codesign --force --deep --sign - "$APP_BUNDLE" >>"$ARTIFACT_DIR/build.log" 2>&1
codesign --verify --deep --strict "$APP_BUNDLE"
{
    printf 'bundle=%s\nprofile=%s\n' "$APP_BUNDLE" "$PROFILE"
    shasum -a 256 "$APP_BINARY" "$APP_BUNDLE/Contents/Info.plist"
    codesign -dvv "$APP_BUNDLE" 2>&1
} >"$ARTIFACT_DIR/bundle-identity.txt"
[[ -x "$APP_BUNDLE/Contents/MacOS/amx" ]] || { note "FAIL: bundled amx required for owned daemon cleanup"; exit 1; }
RUN_STARTED=1
env -u ZMX_SESSION_PREFIX -u ZMX_SESSION "$APP_BINARY" >"$ARTIFACT_DIR/app.log" 2>&1 &
TARGET_PID="$!"
note "launched pid=$TARGET_PID executable=$APP_BINARY"

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
# The expected output is not present verbatim in the input, so PTY echo
# cannot satisfy this assertion. Each run uses a different marker.
MARKER_TOKEN="$(uuidgen | tr -d '-')"
wait_for_text '[^[:space:]]' 20 || { note "FAIL: replacement shell never drew a prompt"; exit 1; }
type_line "printf '%s%s' 'amx721_' '$MARKER_TOKEN'"
wait_for_text "amx721_$MARKER_TOKEN" 10 || { dump_companion "no replacement output"; note "FAIL: replacement shell did not execute marker"; exit 1; }
companion_open || { note "FAIL: replacement companion did not remain open"; exit 1; }
dump_companion "after re-summon"
note "re-summoned companion executed unique marker and remains open"

CLOSE_RESULT="$(osascript -e "tell application \"System Events\"
tell (first process whose unix id is $TARGET_PID)
    set matches to {}
    repeat with b in (buttons of group 1 of group 1 of window \"Terminal Companion\")
        set p to properties of b
        if help of p is \"Close\" then set end of matches to contents of b
    end repeat
    if (count matches) is not 1 then error \"Expected exactly one Close button\"
    set closeButton to item 1 of matches
    if not enabled of closeButton then error \"Close button disabled\"
    click closeButton
    return \"clicked\"
end tell
end tell")" || { note "FAIL: could not activate actual Close button"; exit 1; }
[[ "$CLOSE_RESULT" == clicked ]] || { note "FAIL: no Close activation acknowledgement"; exit 1; }
note "activated actual Close button"

# Existing companion close behavior requires confirmation. Require observing
# and activating it; an already-closed companion is never close-button proof.
CONFIRMED=no
for _ in $(seq 1 20); do
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
end tell")" || { note "FAIL: AX close confirmation query failed"; exit 1; }
    [[ "$CONFIRMED" != yes ]] || break
    sleep 0.25
done
[[ "$CONFIRMED" == yes ]] || { note "FAIL: close confirmation never appeared"; exit 1; }
note "close confirmation appeared and was confirmed"
if ! wait_for closed 5; then
    dump_companion "after close button"
    ax "get entire contents of every window" >"$ARTIFACT_DIR/all-windows-after-close.txt" 2>&1 || true
    note "FAIL: close button did not close the re-summoned companion"
    exit 1
fi
note "close button closed the companion; cleanup pending"
