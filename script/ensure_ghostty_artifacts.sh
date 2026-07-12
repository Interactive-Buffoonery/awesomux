#!/usr/bin/env bash
#
# ensure_ghostty_artifacts.sh — make .build/ghostty available before swift build
#
# Order of preference:
#   1. Local .build/ghostty already has every required artifact for the
#      expected Zig optimize mode → reuse it when its source SHA also matches
#      in exact-pin mode.
#   2. We're in a git worktree AND the parent main checkout has every required
#      artifact → symlink <worktree>/.build/ghostty -> <main>/.build/ghostty.
#      If the worktree's vendor/ghostty gitlink differs from the revision the
#      parent's artifacts were built against (recorded in
#      .build/ghostty/.built-from-sha by build_ghostty_xcframework.sh), warn in
#      development mode or fall through to rebuild in exact-pin mode.
#   3. Fall through to script/build_ghostty_xcframework.sh.
#
# Idempotent. Stale symlinks (pointing at incomplete artifacts) are removed
# and re-evaluated rather than trusted.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACT_DIR="$ROOT_DIR/.build/ghostty"
EXPECTED_GHOSTTY_OPTIMIZE="${AWESOMUX_GHOSTTY_OPTIMIZE:-ReleaseFast}"
REQUIRE_GHOSTTY_PIN_MATCH="${AWESOMUX_GHOSTTY_REQUIRE_PIN_MATCH:-0}"

usage() {
  cat <<'USAGE'
Usage: script/ensure_ghostty_artifacts.sh

Ensure .build/ghostty contains complete artifacts for the requested optimize
mode. Reuse valid local artifacts, link compatible parent-worktree artifacts,
or build Ghostty from the pinned submodule when needed.

Arguments:
  --help, -h                           Show this help and exit.

Environment:
  AWESOMUX_GHOSTTY_OPTIMIZE            Required Zig optimize mode: Debug,
                                       ReleaseSafe, ReleaseFast (default),
                                       or ReleaseSmall.
  AWESOMUX_GHOSTTY_REQUIRE_PIN_MATCH    Set to 1 to rebuild artifacts whose
                                       source SHA differs from HEAD's pin.
  AWESOMUX_ZIG                         Compatible Zig binary used only if a
                                       fallback Ghostty build is required.

See docs/ghostty-integration.md#build-the-xcframework for prerequisites and details.
USAGE
}

case "${1:-}" in
  --help|-h)
    usage
    exit 0
    ;;
esac

# shellcheck source=script/ghostty_link_archives.sh
source "$ROOT_DIR/script/ghostty_link_archives.sh"

case "$EXPECTED_GHOSTTY_OPTIMIZE" in
  Debug|ReleaseSafe|ReleaseFast|ReleaseSmall) ;;
  *)
    echo "AWESOMUX_GHOSTTY_OPTIMIZE='$EXPECTED_GHOSTTY_OPTIMIZE' is invalid; must be one of: Debug, ReleaseSafe, ReleaseFast, ReleaseSmall." >&2
    exit 2
    ;;
esac

case "$REQUIRE_GHOSTTY_PIN_MATCH" in
  0|1) ;;
  *)
    echo "AWESOMUX_GHOSTTY_REQUIRE_PIN_MATCH='$REQUIRE_GHOSTTY_PIN_MATCH' is invalid; must be 0 or 1." >&2
    exit 2
    ;;
esac

# Where the expected optimize mode came from — used in log messages so a
# contributor seeing "expected ReleaseFast" can tell whether that was their
# env or just the default.
if [[ -n "${AWESOMUX_GHOSTTY_OPTIMIZE:-}" ]]; then
  EXPECTED_GHOSTTY_OPTIMIZE_SOURCE="env"
else
  EXPECTED_GHOSTTY_OPTIMIZE_SOURCE="default"
fi

# Validates that a candidate .build/ghostty directory has every artifact the
# Swift build and link actually consume: the modulemap header, the xcframework
# fat archive, every -force_load static archive in Package.swift, and the
# runtime share resources copied into the .app bundle.
_ghostty_artifacts_present() {
  local dir="$1"
  [[ -f "$dir/GhosttyKit.xcframework/macos-arm64/Headers/ghostty.h" ]] || return 1
  local archive
  for archive in "${GHOSTTY_LINK_ARCHIVES[@]}"; do
    [[ -f "$dir/$(ghostty_link_archive_dest_path "$archive")" ]] || return 1
  done
  [[ -f "$dir/share/terminfo/78/xterm-ghostty" ]] || return 1
  [[ -d "$dir/share/ghostty/shell-integration" ]] || return 1
  _ghostty_optimize_stamp_matches "$dir" || return 1
  _ghostty_sha_stamp_matches "$dir" || return 1
  return 0
}

_ghostty_optimize_stamp_matches() {
  local artifact_root="$1"
  local stamp="$artifact_root/.built-optimize"
  local built_optimize=""

  # Missing stamp = pre-INT-471 artifact tree. Tempting to backfill with
  # $EXPECTED_GHOSTTY_OPTIMIZE and adopt the existing tree, but Zig's
  # default optimize mode (what pre-INT-471 builds used because the script
  # didn't pass -Doptimize) is Debug — exactly the mode this PR exists to
  # stop shipping. Backfilling as ReleaseFast would stamp a Debug tree
  # with a ReleaseFast label, ship the original beachball, and make the
  # drift detector swear everything's fine. So: rebuild. The one-time
  # cost on first pull is the honest answer.
  if [[ ! -f "$stamp" ]]; then
    echo "[ensure_ghostty_artifacts] note: $artifact_root has no .built-optimize stamp — either a pre-INT-471 tree (built Debug by default) or an interrupted publish; rebuilding to record a trustworthy mode (expected $EXPECTED_GHOSTTY_OPTIMIZE, $EXPECTED_GHOSTTY_OPTIMIZE_SOURCE)." >&2
    return 1
  fi

  # Read the first line and strip a trailing CR (CRLF on shared volumes).
  # Don't trim arbitrary whitespace: a stamp like "Release Fast" should NOT
  # silently match "ReleaseFast" — the stamp lying about its content is the
  # bug class this whole mechanism exists to prevent.
  IFS= read -r built_optimize < "$stamp" || true
  built_optimize="${built_optimize%$'\r'}"
  if [[ "$built_optimize" != "$EXPECTED_GHOSTTY_OPTIMIZE" ]]; then
    echo "[ensure_ghostty_artifacts] note: $artifact_root was built with Zig optimize='$built_optimize'; expected $EXPECTED_GHOSTTY_OPTIMIZE ($EXPECTED_GHOSTTY_OPTIMIZE_SOURCE), so rebuilding." >&2
    return 1
  fi

  return 0
}

# Validates or warns when the worktree's pinned vendor/ghostty SHA differs from
# the SHA recorded in the artifacts the worktree is consuming. Compares the
# worktree's committed gitlink (HEAD:vendor/ghostty) against the parent's
# .built-from-sha stamp, which build_ghostty_xcframework.sh writes from the
# actual submodule HEAD that zig compiled.
_ghostty_sha_stamp_matches() {
  local artifact_root="$1"
  local stamp="$artifact_root/.built-from-sha"
  local worktree_pin built_from
  worktree_pin="$(git -C "$ROOT_DIR" rev-parse HEAD:vendor/ghostty 2>/dev/null || echo unknown)"
  if [[ "$worktree_pin" == "unknown" ]]; then
    echo "[ensure_ghostty_artifacts] note: can't resolve HEAD:vendor/ghostty to verify artifact SHA drift." >&2
    [[ "$REQUIRE_GHOSTTY_PIN_MATCH" == 0 ]]
    return
  fi
  if [[ ! -f "$stamp" ]]; then
    echo "[ensure_ghostty_artifacts] note: $artifact_root has no .built-from-sha stamp — can't verify vendor SHA drift. Rebuild parent's Ghostty once to populate it." >&2
    [[ "$REQUIRE_GHOSTTY_PIN_MATCH" == 0 ]]
    return
  fi
  IFS= read -r built_from < "$stamp" || true
  built_from="${built_from%$'\r'}"
  if [[ "$worktree_pin" != "$built_from" ]]; then
    cat >&2 <<EOF
[ensure_ghostty_artifacts] WARNING: vendor/ghostty SHA mismatch.
[ensure_ghostty_artifacts]   worktree HEAD:vendor/ghostty = $worktree_pin
[ensure_ghostty_artifacts]   artifacts at $artifact_root were built from = $built_from
EOF
    if [[ "$REQUIRE_GHOSTTY_PIN_MATCH" == 1 ]]; then
      echo "[ensure_ghostty_artifacts] Exact pin match required; rebuilding from this worktree's pin." >&2
      return 1
    fi
    cat >&2 <<EOF
[ensure_ghostty_artifacts] Build will run against those artifacts, not what this worktree's commit pins.
[ensure_ghostty_artifacts] To force a local rebuild from this worktree's pin: trash "$ARTIFACT_DIR" && ./script/build_ghostty_xcframework.sh
EOF
  fi
  return 0
}

# 1. Local artifacts already present. File checks through $ARTIFACT_DIR follow
# worktree symlinks, so they validate the tree the build will actually consume.
# Switching branches can change HEAD:vendor/ghostty without re-invoking step 2,
# so the SHA-drift check has to fire on every run, even in main. Both stamp
# checks happen inside _ghostty_artifacts_present.
if _ghostty_artifacts_present "$ARTIFACT_DIR"; then
  exit 0
fi

# 2. Worktree → try to symlink parent's artifacts.
if command -v git >/dev/null 2>&1 && git -C "$ROOT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  GIT_DIR="$(git -C "$ROOT_DIR" rev-parse --path-format=absolute --git-dir)"
  GIT_COMMON_DIR="$(git -C "$ROOT_DIR" rev-parse --path-format=absolute --git-common-dir)"

  if [[ "$GIT_DIR" != "$GIT_COMMON_DIR" ]]; then
    PARENT_REPO="$(dirname "$GIT_COMMON_DIR")"
    PARENT_ARTIFACT_DIR="$PARENT_REPO/.build/ghostty"

    # If there's a stale symlink (pointing at incomplete artifacts or the
    # wrong optimize mode — we know it's stale because step 1 followed it and
    # failed), remove it before re-evaluating. Trusting it would replicate the
    # bug we're fixing.
    if [[ -L "$ARTIFACT_DIR" ]]; then
      echo "[ensure_ghostty_artifacts] removing stale symlink at $ARTIFACT_DIR (target missing required artifacts or expected optimize mode)" >&2
      rm "$ARTIFACT_DIR"
    fi

    # If a real (non-symlink) directory exists, treat it as an in-progress
    # local build — fall through to step 3 (rebuild), which resumes the Zig
    # cache rather than clobbering the partial dir with a symlink.
    if [[ -d "$ARTIFACT_DIR" && ! -L "$ARTIFACT_DIR" ]]; then
      : # intentional no-op; fallthrough to local rebuild
    elif _ghostty_artifacts_present "$PARENT_ARTIFACT_DIR"; then
      mkdir -p "$ROOT_DIR/.build"
      ln -s "$PARENT_ARTIFACT_DIR" "$ARTIFACT_DIR"
      echo "[ensure_ghostty_artifacts] symlinked $ARTIFACT_DIR -> $PARENT_ARTIFACT_DIR" >&2
      exit 0
    else
      echo "[ensure_ghostty_artifacts] parent main checkout at $PARENT_REPO does not have a complete .build/ghostty for optimize=$EXPECTED_GHOSTTY_OPTIMIZE — falling back to a local rebuild." >&2
    fi
  fi
fi

# 3. Fall through: rebuild from vendor/ghostty.
# `git worktree add` does NOT recursively init submodules, so a worktree
# may have an empty vendor/ghostty even though the main checkout's is fine.
if [[ "$REQUIRE_GHOSTTY_PIN_MATCH" == 1 ]]; then
  pinned_sha="$(git -C "$ROOT_DIR" rev-parse HEAD:vendor/ghostty 2>/dev/null || echo "")"
  if [[ -z "$pinned_sha" ]]; then
    echo "[ensure_ghostty_artifacts] can't resolve HEAD:vendor/ghostty; refusing an exact-pin build." >&2
    exit 1
  fi

  if [[ ! -e "$ROOT_DIR/vendor/ghostty/.git" ]]; then
    echo "[ensure_ghostty_artifacts] Initializing vendor/ghostty at the pinned revision..." >&2
    git -C "$ROOT_DIR" submodule update --init --recursive -- vendor/ghostty
  fi

  checked_out_sha="$(git -C "$ROOT_DIR/vendor/ghostty" rev-parse HEAD 2>/dev/null || echo "")"
  if [[ "$checked_out_sha" != "$pinned_sha" ]]; then
    echo "[ensure_ghostty_artifacts] vendor/ghostty is checked out at $checked_out_sha but HEAD pins $pinned_sha." >&2
    git -C "$ROOT_DIR/vendor/ghostty" cat-file -e "$pinned_sha" 2>/dev/null \
      || git -C "$ROOT_DIR/vendor/ghostty" fetch --quiet origin

    if ! git -C "$ROOT_DIR/vendor/ghostty" diff --quiet \
        || ! git -C "$ROOT_DIR/vendor/ghostty" diff --cached --quiet \
        || ! git -C "$ROOT_DIR/vendor/ghostty" merge-base --is-ancestor "$checked_out_sha" "$pinned_sha"; then
      cat >&2 <<EOF
[ensure_ghostty_artifacts] vendor/ghostty can't be re-synced automatically without
potentially discarding local edits or a local commit. Resolve it manually, then run:
  git -C vendor/ghostty status
  git -C vendor/ghostty log $pinned_sha..$checked_out_sha
  git submodule update -- vendor/ghostty
EOF
      exit 1
    fi

    echo "[ensure_ghostty_artifacts] Syncing vendor/ghostty to the pinned revision..." >&2
    git -C "$ROOT_DIR" submodule update -- vendor/ghostty
  fi
fi

if [[ ! -e "$ROOT_DIR/vendor/ghostty/.git" ]]; then
  cat >&2 <<EOF
[ensure_ghostty_artifacts] vendor/ghostty submodule is not initialized in this worktree.
[ensure_ghostty_artifacts] Run from this directory:
[ensure_ghostty_artifacts]   git submodule update --init --recursive
[ensure_ghostty_artifacts] Then re-run whatever you were trying to build.
EOF
  exit 1
fi

exec "$ROOT_DIR/script/build_ghostty_xcframework.sh"
