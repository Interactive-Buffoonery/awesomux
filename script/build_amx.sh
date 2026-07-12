#!/usr/bin/env bash
set -euo pipefail

# Build the vendored zmx (INT-561 / ADR-0011) and stage it as `amx`, the
# awesoMux-owned persistent-session command. zmx is the backend; `amx` is the
# branded name the app spawns (`amx attach <id>`) and the seam where awesoMux
# subcommands can be added later. Building under `amx` also gives process-tree
# terminal detection (fastfetch et al.) the awesoMux identity instead of `zmx`.
#
# zmx links NONE of our vendor/ghostty: it pins its own ghostty via the Zig
# package manager and ships a standalone binary that talks to our surface over a
# PTY byte stream. So this build is independent of build_ghostty_xcframework.sh
# beyond needing the same Zig toolchain (both pin 0.15.x).

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZMX_DIR="$ROOT_DIR/vendor/zmx"
OUT_DIR="$ROOT_DIR/.build/amx"
AMX_BINARY="$OUT_DIR/amx"

if [[ ! -d "$ZMX_DIR/.git" && ! -f "$ZMX_DIR/.git" ]]; then
  echo "Initializing vendor/zmx for this worktree..." >&2
  git -C "$ROOT_DIR" submodule update --init --recursive -- vendor/zmx
fi

if [[ ! -d "$ZMX_DIR/.git" && ! -f "$ZMX_DIR/.git" ]]; then
  echo "vendor/zmx submodule is missing after initialization." >&2
  exit 1
fi

# vendor/zmx's checked-out commit can drift from the superproject's pin: a
# `git pull` on main moves the gitlink, but nothing forces `git submodule
# update` to follow it, so the submodule worktree silently keeps building
# whatever it already had checked out. A plain source-mtime staleness check
# (build_and_run.sh) can't catch this — the stale files just sit there with
# old mtimes and never look "newer" than an already-staged binary — so this
# exact drift once shipped the fixed superproject pin while every local
# rebuild kept producing the OLD, pre-fix zmx (INT-523: the mouse-report-leak
# fix + hot-path debug-log removal never reached the bundle on a checkout
# that had pulled the fix but never re-synced the submodule).
check_submodule_pin() {
  local pinned_sha checked_out_sha
  pinned_sha="$(git -C "$ROOT_DIR" rev-parse HEAD:vendor/zmx 2>/dev/null || echo "")"
  checked_out_sha="$(git -C "$ZMX_DIR" rev-parse HEAD 2>/dev/null || echo "")"
  [[ -n "$pinned_sha" && -n "$checked_out_sha" ]] || return 0
  [[ "$pinned_sha" != "$checked_out_sha" ]] || return 0

  echo "warning: vendor/zmx is checked out at $checked_out_sha but HEAD pins $pinned_sha." >&2

  # The pinned commit may not exist in the submodule's local object database
  # yet — e.g. a plain `git pull` on the superproject moves the gitlink
  # without fetching the submodule at all. Without this, the ancestor check
  # below would fail closed (exit 128, unknown object) on exactly the drift
  # case this guard exists to auto-heal, and the diagnostic `git log` in the
  # error message wouldn't resolve either.
  git -C "$ZMX_DIR" cat-file -e "$pinned_sha" 2>/dev/null || git -C "$ZMX_DIR" fetch --quiet origin

  # Only tracked-file edits block an auto-sync (checkout would need to merge
  # or clobber them). Untracked files don't — zmx's build lands zig-out/,
  # .zig-cache/, etc. inside the submodule worktree by design, and most of
  # them are gitignored, but not all local Zig cache dirs are (e.g.
  # .zig-global/), so untracked cruft is normal here, not a reason to refuse.
  #
  # A clean working tree is NOT enough on its own: a committed-but-unpushed
  # local commit in vendor/zmx also passes `git diff --quiet`, and
  # `git submodule update` would silently detach past it with no warning
  # (verified: the discarded commit becomes unreachable except via the
  # submodule's own reflog). Require the checked-out commit to be an
  # ancestor of the pin — i.e. we're strictly behind, not diverged — before
  # trusting a plain checkout to be lossless.
  if ! git -C "$ZMX_DIR" diff --quiet || ! git -C "$ZMX_DIR" diff --cached --quiet \
      || ! git -C "$ZMX_DIR" merge-base --is-ancestor "$checked_out_sha" "$pinned_sha"; then
    cat >&2 <<EOF
error: vendor/zmx can't be re-synced to the pin automatically (local edits, or a
       local commit not reachable from the pin — a plain checkout could discard it).
       Resolve manually, then run:
         git -C vendor/zmx status
         git -C vendor/zmx log $pinned_sha..$checked_out_sha  # anything here would be discarded
         git submodule update -- vendor/zmx
EOF
    exit 1
  fi

  echo "Syncing vendor/zmx to the pinned commit..." >&2
  git -C "$ROOT_DIR" submodule update -- vendor/zmx
}

check_submodule_pin

read_required_zig_version() {
  local version
  version="$(sed -nE 's/.*\.minimum_zig_version[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$ZMX_DIR/build.zig.zon" | head -n 1)"
  if [[ -z "$version" ]]; then
    echo "Could not read zmx's minimum_zig_version from $ZMX_DIR/build.zig.zon." >&2
    exit 1
  fi
  echo "$version"
}

# Compatible == same major.minor and patch >= required. zmx and ghostty both pin
# 0.15.x today; keeping this independent avoids coupling the two build scripts.
zig_is_compatible() {
  local candidate="$1" required="$2" version
  [[ -x "$candidate" ]] || return 1
  version="$("$candidate" version 2>/dev/null | head -n 1)" || return 1
  local r_major r_minor r_patch c_major c_minor c_patch
  IFS='.' read -r r_major r_minor r_patch <<<"$required"; r_patch="${r_patch%%[^0-9]*}"
  IFS='.' read -r c_major c_minor c_patch <<<"$version"; c_patch="${c_patch%%[^0-9]*}"
  [[ "$r_major" =~ ^[0-9]+$ && "$r_minor" =~ ^[0-9]+$ && "$r_patch" =~ ^[0-9]+$ ]] || return 1
  [[ "$c_major" =~ ^[0-9]+$ && "$c_minor" =~ ^[0-9]+$ && "$c_patch" =~ ^[0-9]+$ ]] || return 1
  [[ "$c_major" -eq "$r_major" && "$c_minor" -eq "$r_minor" && "$c_patch" -ge "$r_patch" ]]
}

select_zig() {
  local required="$1" major minor formula candidate
  IFS='.' read -r major minor _ <<<"$required"
  formula="zig@$major.$minor"

  if [[ -n "${AWESOMUX_ZIG:-}" ]]; then
    candidate="${AWESOMUX_ZIG}"
    [[ "$candidate" == */* ]] || candidate="$(command -v "$candidate" 2>/dev/null || echo "$candidate")"
    if zig_is_compatible "$candidate" "$required"; then echo "$candidate"; return 0; fi
    echo "AWESOMUX_ZIG ('$AWESOMUX_ZIG') is not compatible with zmx (needs $major.$minor.x >= $required)." >&2
    exit 1
  fi

  local candidates=()
  command -v zig >/dev/null 2>&1 && candidates+=("$(command -v zig)")
  if command -v brew >/dev/null 2>&1; then
    local brew_prefix; brew_prefix="$(brew --prefix "$formula" 2>/dev/null || true)"
    [[ -n "$brew_prefix" ]] && candidates+=("$brew_prefix/bin/zig")
  fi
  candidates+=("/opt/homebrew/opt/$formula/bin/zig" "/usr/local/opt/$formula/bin/zig")

  for candidate in "${candidates[@]}"; do
    [[ -n "$candidate" ]] || continue
    if zig_is_compatible "$candidate" "$required"; then echo "$candidate"; return 0; fi
  done

  cat >&2 <<EOF
zmx requires Zig $major.$minor.x (>= $required), but no compatible Zig was found.
Install it with:  brew install $formula
Or set AWESOMUX_ZIG=/path/to/zig before running the build.
EOF
  exit 1
}

REQUIRED_ZIG_VERSION="$(read_required_zig_version)"
ZIG_BIN="$(select_zig "$REQUIRED_ZIG_VERSION")"

echo "Building amx (vendored zmx) with $ZIG_BIN (zig $("$ZIG_BIN" version))..."
# Build out-of-tree so the submodule worktree stays clean (ignore = dirty still
# applies, but no need to litter it). zmx's own zig-out lands under the submodule;
# point --prefix there, then stage the renamed binary into .build/amx.
#
# -Doptimize=ReleaseSafe is load-bearing, not a style choice: with no
# -Doptimize flag, Zig defaults to Debug, which zmx's build.zig propagates
# into its vendored ghostty_vt dependency. Debug enables Ghostty's
# `slow_runtime_safety` (expensive per-print/per-cell terminal-state
# integrity assertions, `vendor/ghostty/src/build/Config.zig`) — measured at
# up to ~4 SECONDS per ~1KB PTY-output chunk in the bundled daemon (INT-523
# investigation, 2026-06-30/07-01). ReleaseSafe disables it; same fix
# brought the worst case down to ~2ms in testing.
"$ZIG_BIN" build --build-file "$ZMX_DIR/build.zig" --prefix "$ZMX_DIR/zig-out" -Doptimize=ReleaseSafe

BUILT_BINARY="$ZMX_DIR/zig-out/bin/zmx"
if [[ ! -x "$BUILT_BINARY" ]]; then
  echo "zmx build did not produce $BUILT_BINARY" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
cp "$BUILT_BINARY" "$AMX_BINARY"
chmod +x "$AMX_BINARY"
echo "Staged amx -> $AMX_BINARY"
"$AMX_BINARY" version | sed 's/^/  /'
