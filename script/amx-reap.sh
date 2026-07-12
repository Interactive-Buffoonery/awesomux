#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/runtime-profile.sh"

# Safe reaper for awesoMux persistent-session daemons (INT-561 / ADR-0011).
#
# With the command-bridge on, each pane spawns an `amx` (zmx) daemon that
# SURVIVES app quit — that's the persistence feature, but it means daemons
# accumulate until something reaps them. This is the manual stopgap that
# previews the in-app daemon-GC follow-up.
#
# "Owned"  = a daemon whose session id appears in the persisted session-state
#            (a real pane can still reattach to it — do NOT kill).
# "Orphan" = a daemon with no matching persisted pane (nothing can reattach —
#            safe to kill).
#
# Profile (flag accepted anywhere on the command line; default production):
#   --dev     inspect/reap the development profile (awesoMux-dev + amx-dev)
#   --prod    inspect/reap the production profile (default)
#   --profile VALUE  select production, development, or development:<worktree-id>
#   AWESOMUX_PROFILE=VALUE   implicit selection inside an awesoMux pane only
#
# Modes:
#   list      (default) show owned vs orphan; kills nothing
#   orphans   kill only orphaned daemons (safe — never drops a live pane)
#   all       kill EVERY daemon (hard reset; ends live sessions too)
#
# For `orphans`/`all`, cleanest semantics are with awesoMux QUIT (so the
# persisted state is final and no pane is mid-create).

usage() {
  echo "usage: amx-reap.sh [--prod|--dev|--profile VALUE] [list|orphans|all]" >&2
  exit 2
}

# Parse flags and mode position-independently. `all --dev` must mean the same
# thing as `--dev all` — a destructive tool that silently ignores a misplaced
# profile flag would reap the OTHER profile's daemons.
PROFILE="production"
if [[ -n "${AWESOMUX_PANE_ID:-}" && -n "${AWESOMUX_PROFILE:-}" ]]; then
  PROFILE="$AWESOMUX_PROFILE"
fi
MODE=""
while (( $# > 0 )); do
  case "$1" in
    --dev|dev) PROFILE="development" ;;
    --prod|--production|prod|production) PROFILE="production" ;;
    --profile)
      (( $# >= 2 )) || usage
      PROFILE="$2"
      shift
      ;;
    list|orphans|all)
      [[ -z "$MODE" ]] || usage
      MODE="$1"
      ;;
    *) usage ;;
  esac
  shift
done
MODE="${MODE:-list}"
awesomux_resolve_profile "$PROFILE" || exit "$?"
PROFILE="$AWESOMUX_PROFILE_VALUE"
SUPPORT_NAME="$AWESOMUX_PROFILE_SUPPORT_NAME"
AMX_DIR_NAME="$AWESOMUX_PROFILE_SOCKET_NAME"

# awesoMux scopes its daemons to a dedicated per-user, profile-scoped socket dir
# (production: NSTemporaryDirectory()/amx, dev: NSTemporaryDirectory()/amx-dev).
# Point amx at the same dir so this stopgap sees exactly the daemons the in-app
# GC does — not a user's hand-run zmx sessions in zmx's default dir.
#
# Resolve it the way NSTemporaryDirectory() does — confstr(DARWIN_USER_TEMP_DIR)
# via `getconf` — so it stays aligned even when $TMPDIR is unset (launchd/cron),
# where a bare ${TMPDIR:-/tmp} would silently point at the wrong dir. Fall back
# to $TMPDIR, then /tmp.
ZMX_BASE="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || true)"
[ -n "$ZMX_BASE" ] || ZMX_BASE="${TMPDIR:-/tmp}"
export ZMX_DIR="${ZMX_BASE%/}/$AMX_DIR_NAME"
# Match the app's socket-dir mode (AmxBackend pins 0700; zmx's default is 0750,
# group-readable) so this stopgap can't create the dir outside that envelope.
export ZMX_DIR_MODE="700"

AMX="${AWESOMUX_AMX:-}"
if [[ -n "$AMX" && ! -x "$AMX" ]]; then
  echo "AWESOMUX_AMX is not executable: $AMX" >&2
  exit 1
fi
for candidate in \
  "$HOME/Applications/awesoMux.app/Contents/MacOS/amx" \
  "$ROOT_DIR/.build/amx/amx"; do
  [[ -n "$AMX" ]] && break
  [[ -x "$candidate" ]] && { AMX="$candidate"; break; }
done
[[ -n "$AMX" ]] || { echo "amx binary not found (install the app or run script/build_amx.sh)." >&2; exit 1; }

STATE="$HOME/Library/Application Support/$SUPPORT_NAME/session-state.json"

owned_ids() {
  [[ -f "$STATE" ]] || return 0
  # Every terminalSessionID in the persisted layout = a pane that can reattach.
  # Path goes in via argv, not interpolated into the Python source — a quote in
  # $HOME would otherwise break out of the string literal.
  /usr/bin/python3 -c '
import sys,re
try: raw = open(sys.argv[1]).read()
except OSError: sys.exit(0)
print("\n".join(sorted(set(re.findall(r"\"terminalSessionID\"\s*:\s*\"([^\"]+)\"", raw)))))
' "$STATE"
}

live_ids() { "$AMX" list --short 2>/dev/null | sed '/^$/d'; }

OWNED="$(owned_ids || true)"
LIVE="$(live_ids || true)"

is_owned() { grep -qxF "$1" <<<"$OWNED"; }

case "$MODE" in
  list)
    printf '%-38s %s\n' "SESSION ID" "STATUS"
    owned_count=0; orphan_count=0
    while IFS= read -r id; do
      [[ -n "$id" ]] || continue
      if is_owned "$id"; then printf '%-38s %s\n' "$id" "owned (in use — keep)"; owned_count=$((owned_count + 1));
      else printf '%-38s %s\n' "$id" "ORPHAN (safe to reap)"; orphan_count=$((orphan_count + 1)); fi
    done <<<"$LIVE"
    echo "---"
    echo "profile: $PROFILE  |  zmx dir: $ZMX_DIR"
    # Count in the loop (which already skips blank lines) so an empty daemon list
    # reports 0/0, not a phantom "owned: 1" from an empty-line pattern match.
    echo "owned: $owned_count  |  orphan: $orphan_count"
    # Carry the profile flag into the copy-paste hint — a dev-profile `list`
    # must not steer the user into reaping production.
    FLAG="--profile $PROFILE "
    if [[ "$PROFILE" == "production" ]]; then FLAG="--prod "; fi
    if [[ "$PROFILE" == "development" ]]; then FLAG="--dev "; fi
    echo "Run: amx-reap.sh ${FLAG}orphans   (kill strays, safe)   |   amx-reap.sh ${FLAG}all   (nuke everything)"
    ;;
  orphans)
    echo "profile: $PROFILE  |  zmx dir: $ZMX_DIR"
    n=0
    while IFS= read -r id; do
      [[ -n "$id" ]] || continue
      if ! is_owned "$id"; then echo "reaping orphan $id"; "$AMX" kill "$id" --force >/dev/null 2>&1 || true; n=$((n+1)); fi
    done <<<"$LIVE"
    echo "reaped $n orphan daemon(s); left owned daemons untouched."
    ;;
  all)
    echo "profile: $PROFILE  |  zmx dir: $ZMX_DIR"
    n=0
    while IFS= read -r id; do
      [[ -n "$id" ]] || continue
      echo "killing $id"; "$AMX" kill "$id" --force >/dev/null 2>&1 || true; n=$((n+1))
    done <<<"$LIVE"
    echo "killed $n daemon(s). (If awesoMux is open, its panes are now in the recoverable-error state.)"
    ;;
  *)
    usage ;;
esac
