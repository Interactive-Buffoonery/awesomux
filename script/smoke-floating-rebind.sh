#!/usr/bin/env bash
#
# smoke-floating-rebind.sh — scripted GUI smoke for the per-workspace floating
# rebind (INT-799 finding H: pre-fix, switching workspaces while the floating
# panel was open could leave it showing the previous workspace's stale
# terminal). Summons on workspace A, switches to B, summons on B, then
# switches BACK to A via a menu command that never touches the floating-panel
# toggle — that last switch is the one `activeWorkspaceDidChange` drives
# automatically, and it's the path finding H was actually about; summoning
# manually on every workspace would only prove `floatingShow`'s own
# unconditional rebind-on-explicit-show, which was never the broken part.
#
# Scripted menu interaction needs a macOS Accessibility grant for the calling
# process (Terminal/osascript). This machine does not have one right now, so
# this script probes for it first and refuses to fake a pass: no AX means
# SKIPPED (exit 3), never exit 0. Re-run after granting Accessibility in
# System Settings -> Privacy & Security -> Accessibility.
#
# Exit 4: a dev instance sharing this checkout's binary path is already
# running, so isolating the profile would corrupt live state — refuses
# rather than moving it aside. Quit the instance and re-run.
#
# Disposable dev-profile state: this script drives real app commands (new
# workspace, floating panel, workspace switch) against whatever dev profile
# this checkout resolves to (script/runtime-profile.sh). Driving those for
# real would mutate the actual session-state.json, config.toml, and defaults
# domain that profile owns, and leave the mutation behind — a rerun would
# then start from however many workspaces the LAST run left open, not zero,
# so "switch to previous workspace" could land somewhere other than
# workspace A even though the code under test is unchanged. Before touching
# anything, this script moves that profile's Application Support dir,
# config dir, and defaults domain aside and restores them in `cleanup()`
# (same EXIT trap as the process kill, so a crash mid-run still restores).
# The app then launches against nothing — zero workspaces, zero config
# overrides — and the script itself creates both workspaces it drives
# (A then B), so the "exactly two workspaces" invariant `previousWorkspace`
# depends on holds by construction instead of by assumption. Zero config
# overrides keep other launch behavior deterministic. The flow clicks named
# menu commands instead of sending shortcut chords, so user remapping cannot
# change what the smoke invokes.
set -euo pipefail
# Never die silently: the whole point of this script is explicit verdicts.
trap 'echo "FAIL: unexpected error at line $LINENO (exit $?)" >&2' ERR

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
source "$ROOT_DIR/script/runtime-profile.sh"

APP_NAME="awesoMux"
APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

TARGET_PID=""
LOG_STREAM_PID=""
LOG_CAPTURE=""

# Populated by isolate_profile_state (called only once the AX probe below
# passes and the EXIT trap is armed), read by cleanup()'s restore step.
SUPPORT_DIR=""
CONFIG_DIR=""
DEFAULTS_DOMAIN=""
STATE_BACKUP_DIR=""
DEFAULTS_HAD_DOMAIN=0

# Moves this checkout's dev-profile Application Support dir, config dir, and
# defaults domain aside so the app launches into a disposable, empty-by-
# construction profile. Mirrors script/build_and_run.sh's own profile
# resolution exactly (same awesomux_checkout_profile call) so the bundle it
# stages and launches shares this profile's identity.
isolate_profile_state() {
    awesomux_resolve_profile "$(awesomux_checkout_profile "$ROOT_DIR")"
    SUPPORT_DIR="$HOME/Library/Application Support/$AWESOMUX_PROFILE_SUPPORT_NAME"
    CONFIG_DIR="$HOME/.config/$AWESOMUX_PROFILE_CONFIG_NAME"
    DEFAULTS_DOMAIN="$AWESOMUX_PROFILE_BUNDLE_ID"

    # Fail closed: an app from a previous failed run (or an intentional user
    # session) that shares this exact binary path is still writing this
    # profile. Moving its state aside now would corrupt live data and race the
    # running process. Name the PIDs and bail — don't auto-kill, it may be the
    # user's session. Distinct exit 4 (3 is the AX skip).
    local running
    running="$(exact_path_pids)"
    if [[ -n "$running" ]]; then
        echo "FAIL: an awesoMux dev instance ($APP_BINARY) is already running (PIDs: $(printf '%s' "$running" | tr '\n' ' ')). Quit it before running this smoke test." >&2
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
}

# Restores exactly what isolate_profile_state moved aside, run from
# cleanup() after the launched process is gone. `[[ -n ]]` guards make this a
# no-op if isolate_profile_state never ran (e.g. the AX probe skipped first).
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

# Exact-path match, not a bare `pgrep -x`/`pkill -x`: this machine can have
# other awesoMux processes running at the same time — the installed
# daily-driver app (a different CFBundleName, e.g. "awesoMux (dev ...)" vs
# plain "awesoMux" per script/runtime-profile.sh, so AppleScript's `process
# "awesoMux"` can resolve to the WRONG one) or another worktree's dev build.
# Matching by name alone would let this script drive menu actions into, or
# read smoke logs from, a process it never launched — including someone's
# live terminal session. Resolve and target everything by PID instead.
exact_path_pids() {
    local pid comm
    for pid in $(pgrep -x "$APP_NAME" 2>/dev/null || true); do
        comm="$(ps -p "$pid" -o comm= 2>/dev/null || true)"
        [[ "$comm" == "$APP_BINARY" ]] && printf '%s\n' "$pid"
    done
    # A trailing failed [[ ]] && must not become the function's status: under
    # set -e that killed the whole script (silently, exit 1) whenever another
    # same-named awesoMux (the installed app) was running but no dev instance
    # was — the exact situation every real run starts from.
    return 0
}

cleanup() {
    if [[ -n "$LOG_STREAM_PID" ]]; then
        kill "$LOG_STREAM_PID" 2>/dev/null || true
        wait "$LOG_STREAM_PID" 2>/dev/null || true
    fi
    [[ -n "$LOG_CAPTURE" ]] && rm -f "$LOG_CAPTURE"
    if [[ -n "$TARGET_PID" ]]; then
        kill -TERM "$TARGET_PID" 2>/dev/null || true
        for _ in $(seq 1 20); do
            kill -0 "$TARGET_PID" 2>/dev/null || break
            sleep 0.25
        done
        kill -KILL "$TARGET_PID" 2>/dev/null || true
    fi
    # Restore dev-profile state last, after the process this run launched is
    # confirmed gone — restoring underneath a still-running instance would
    # race its own writes back into the real profile.
    restore_profile_state
}

# `count processes` only needs System Events to be scriptable, which is true
# even without an Accessibility grant — it does not fail here, so it cannot
# tell us whether menu clicks below will work. `UI elements enabled` reflects
# the actual UI-scripting permission and returns cleanly either way.
if [[ "$(osascript -e 'tell application "System Events" to UI elements enabled' 2>/dev/null)" != "true" ]]; then
    echo "SKIPPED: needs Accessibility grant — run manually (System Settings > Privacy & Security > Accessibility, grant Terminal/osascript's caller, then re-run this script)."
    exit 3
fi

# Only ever signals $TARGET_PID/$LOG_STREAM_PID (set once we've confirmed
# which process WE launched, below) — never a bare name-match, so a build
# failure before that point cannot kill an unrelated pre-existing process.
trap cleanup EXIT

# Move real dev-profile state aside before anything below launches the app —
# including build_and_run.sh --verify's own launch-and-kill, which targets
# the same profile identity. See the header comment for why.
isolate_profile_state

# `--verify` builds, stages, signs, confirms the bundle launches, then kills
# it — leaving dist/awesoMux.app staged and guaranteed not running. `run`
# mode's default Swift build is `-c release` (script/build_and_run.sh:422,
# "Default to release for daily-driving"), which strips every `#if DEBUG`
# block — including the floating-rebind log line this script reads back —
# so build_and_run.sh alone can never make the assertion below observable.
# Swap in a debug-configured executable after staging so the log line
# actually compiles, then re-sign with the same ad-hoc command
# build_and_run.sh uses (script/build_and_run.sh:616) since replacing the
# binary invalidates the bundle's existing signature.
./script/build_and_run.sh --verify

OLD_PIDS="$(exact_path_pids)"

swift build -c debug
DEBUG_BIN="$(swift build -c debug --show-bin-path)/$APP_NAME"
cp "$DEBUG_BIN" "$APP_BINARY"
codesign --force --deep --sign - --options runtime "$APP_BUNDLE"
open -n "$APP_BUNDLE"

for _ in $(seq 1 40); do
    TARGET_PID="$(comm -13 <(printf '%s\n' "$OLD_PIDS" | sort) <(exact_path_pids | sort) | head -1)"
    [[ -n "$TARGET_PID" ]] && break
    sleep 0.25
done
if [[ -z "$TARGET_PID" ]]; then
    echo "FAIL: $APP_BINARY did not start a new process." >&2
    exit 1
fi

# `log stream` (not `log show`): plain `.debug`-level entries are typically
# never persisted to the store `log show` queries after the fact — this repo
# already reads its own diagnostic logs live via `log stream` in
# build_and_run.sh's stream_*_logs helpers, so match that pattern rather than
# risk a real rebind never showing up in a post-hoc `log show` query.
LOG_CAPTURE="$(mktemp)"
/usr/bin/log stream --debug --style compact \
    --predicate "subsystem == \"com.awesomux.smoke\" AND processIdentifier == $TARGET_PID" \
    > "$LOG_CAPTURE" 2>/dev/null &
LOG_STREAM_PID=$!
sleep 0.5

# Target System Events by unix id, not by process name: with the resolved
# PID pinned, both the frontmost activation and the menu clicks below can
# only ever reach the instance this script just launched.
osascript -e "tell application \"System Events\" to tell (first process whose unix id is $TARGET_PID) to set frontmost to true"
# A process existing is not enough: a cold SwiftUI + Ghostty launch can accept
# frontmost state before its command surface is in the accessibility tree.
# Invoking New Workspace in that gap silently does nothing and the smoke later
# reports zero rebinds. The disposable profile intentionally starts with no workspace
# window, so poll for the exact PID's menu bar rather than a window.
WINDOW_READY=0
for _ in $(seq 1 40); do
    if [[ "$(osascript -e "tell application \"System Events\" to tell (first process whose unix id is $TARGET_PID) to count menu bars" 2>/dev/null)" -gt 0 ]]; then
        WINDOW_READY=1
        break
    fi
    sleep 0.25
done
if [[ "$WINDOW_READY" != 1 ]]; then
    echo "FAIL: $APP_BINARY started as PID $TARGET_PID but never exposed its command menu for scripted input." >&2
    exit 1
fi
osascript -e "tell application \"System Events\" to tell (first process whose unix id is $TARGET_PID) to set frontmost to true"
for _ in $(seq 1 40); do
    [[ "$(osascript -e "tell application \"System Events\" to tell (first process whose unix id is $TARGET_PID) to get frontmost" 2>/dev/null)" == "true" ]] && break
    sleep 0.25
done
if [[ "$(osascript -e "tell application \"System Events\" to tell (first process whose unix id is $TARGET_PID) to get frontmost" 2>/dev/null)" != "true" ]]; then
    echo "FAIL: $APP_BINARY exposed its command menu but did not become frontmost." >&2
    exit 1
fi

# The disposable profile launches with zero workspaces (no session-state.json
# to restore), so workspace A does not exist yet — create it through the File
# menu. Menu invocation is independent of user shortcut remapping.
osascript -e "tell application \"System Events\" to tell (first process whose unix id is $TARGET_PID) to click menu item \"New Workspace\" of menu \"File\" of menu bar 1"
for _ in $(seq 1 40); do
    [[ "$(osascript -e "tell application \"System Events\" to tell (first process whose unix id is $TARGET_PID) to count windows" 2>/dev/null)" -gt 0 ]] && break
    sleep 0.25
done
if [[ "$(osascript -e "tell application \"System Events\" to tell (first process whose unix id is $TARGET_PID) to count windows" 2>/dev/null)" -eq 0 ]]; then
    echo "FAIL: New Workspace reached the frontmost app but no workspace window appeared." >&2
    exit 1
fi

# Summon the floating panel on workspace A. Default binding Cmd+'"'"'
# through the Workspace menu. This also marks A's slot "open".
osascript -e "tell application \"System Events\" to tell (first process whose unix id is $TARGET_PID) to click menu item \"Show Floating Panel\" of menu \"Workspace\" of menu bar 1"
sleep 1

# New Workspace again creates and switches to workspace B. Its slot
# isn't open yet, so this alone hides the panel rather than rebinding it.
osascript -e "tell application \"System Events\" to tell (first process whose unix id is $TARGET_PID) to click menu item \"New Workspace\" of menu \"File\" of menu bar 1"
sleep 1

# Summon on B — marks B's slot open too, and rebinds to B's session.
osascript -e "tell application \"System Events\" to tell (first process whose unix id is $TARGET_PID) to click menu item \"Show Floating Panel\" of menu \"Workspace\" of menu bar 1"
sleep 1

# Previous Workspace switches back to A
# WITHOUT touching the floating-panel toggle. Because A's slot is already
# open, `activeWorkspaceDidChange` calls `show()` on its own here — this is
# the automatic rebind finding H is actually about; everything above it only
# proves the toggle keystroke's own always-worked rebind-on-explicit-summon.
# "Previous workspace" landing on A is guaranteed here, not assumed: A and B
# are the only two workspaces this run has, both created above in the
# disposable profile — there is no leftover workspace history to land on
# instead.
osascript -e "tell application \"System Events\" to tell (first process whose unix id is $TARGET_PID) to click menu item \"Previous Workspace\" of menu \"Workspace\" of menu bar 1"
sleep 1

kill "$LOG_STREAM_PID" 2>/dev/null || true
wait "$LOG_STREAM_PID" 2>/dev/null || true
LOG_STREAM_PID=""
REBINDS="$(grep 'floating-rebind' "$LOG_CAPTURE" || true)"
echo "$REBINDS"

COUNT="$(printf '%s\n' "$REBINDS" | grep -c 'floating-rebind' || true)"
if [[ "$COUNT" -lt 3 ]]; then
    echo "FAIL: expected >=3 floating-rebind log lines (summon A, summon B, auto-switch back to A), got $COUNT" >&2
    exit 1
fi

# Fails closed (empty, not the raw line) when a field is missing, so a
# malformed match can't read as a comparable "value" and pass by accident.
first_field() {
    local line="$1" field="$2"
    printf '%s\n' "$line" | sed -nE "s/.*${field}=([^ ]+).*/\\1/p"
}

LINE_A1="$(printf '%s\n' "$REBINDS" | sed -n '1p')"
LINE_B="$(printf '%s\n' "$REBINDS" | sed -n '2p')"
LINE_A2="$(printf '%s\n' "$REBINDS" | tail -1)"

WORKSPACE_A1="$(first_field "$LINE_A1" workspace)"
SESSION_A1="$(first_field "$LINE_A1" session)"
WORKSPACE_B="$(first_field "$LINE_B" workspace)"
SESSION_B="$(first_field "$LINE_B" session)"
WORKSPACE_A2="$(first_field "$LINE_A2" workspace)"
SESSION_A2="$(first_field "$LINE_A2" session)"

for value in "$WORKSPACE_A1" "$SESSION_A1" "$WORKSPACE_B" "$SESSION_B" "$WORKSPACE_A2" "$SESSION_A2"; do
    if [[ -z "$value" ]]; then
        echo "FAIL: could not parse workspace=/session= fields out of the rebind log lines" >&2
        exit 1
    fi
done

if [[ "$WORKSPACE_B" == "$WORKSPACE_A1" || "$SESSION_B" == "$SESSION_A1" ]]; then
    echo "FAIL: workspace B's rebind still names workspace A — new-workspace switch never rebound (workspace $WORKSPACE_A1 -> $WORKSPACE_B, session $SESSION_A1 -> $SESSION_B)" >&2
    exit 1
fi

if [[ "$WORKSPACE_A2" != "$WORKSPACE_A1" || "$SESSION_A2" != "$SESSION_A1" ]]; then
    echo "FAIL: switching back to A did not automatically rebind to A's own content — stale-terminal regression (expected workspace $WORKSPACE_A1/session $SESSION_A1, got workspace $WORKSPACE_A2/session $SESSION_A2)" >&2
    exit 1
fi

echo "PASS: summon A ($WORKSPACE_A1/$SESSION_A1) -> summon B ($WORKSPACE_B/$SESSION_B) -> auto-switch back to A rebound correctly ($WORKSPACE_A2/$SESSION_A2)"
