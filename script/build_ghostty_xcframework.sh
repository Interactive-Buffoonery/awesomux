#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GHOSTTY_DIR="$ROOT_DIR/vendor/ghostty"
ARTIFACT_DIR="$ROOT_DIR/.build/ghostty"

usage() {
  cat <<'USAGE'
Usage: script/build_ghostty_xcframework.sh

Build the pinned Ghostty submodule and publish the native macOS XCFramework,
link archive, runtime resources, and build stamps under .build/ghostty.

Arguments:
  --help, -h                           Show this help and exit.

Environment:
  AWESOMUX_GHOSTTY_OPTIMIZE            Zig optimize mode: Debug, ReleaseSafe,
                                       ReleaseFast (default), or ReleaseSmall.
  AWESOMUX_ZIG                         Path or command name for a compatible Zig binary.

See docs/ghostty-integration.md#build-the-xcframework for prerequisites and details.
USAGE
}

case "${1:-}" in
  --help|-h)
    usage
    exit 0
    ;;
esac

# If .build/ghostty is a symlink (left over from a worktree's parent-symlink
# bootstrap in ensure_ghostty_artifacts.sh), unlink it before rebuilding.
# Otherwise the rebuild writes through the symlink and silently mutates the
# parent worktree's state.
if [[ -L "$ARTIFACT_DIR" ]]; then
  echo "[build_ghostty_xcframework] removing parent-symlink at $ARTIFACT_DIR before local rebuild" >&2
  rm "$ARTIFACT_DIR"
fi
AWESOMUX_SHARE_DIR="$ARTIFACT_DIR/share"
AWESOMUX_GHOSTTY_OPTIMIZE="${AWESOMUX_GHOSTTY_OPTIMIZE:-ReleaseFast}"

case "$AWESOMUX_GHOSTTY_OPTIMIZE" in
  Debug|ReleaseSafe|ReleaseFast|ReleaseSmall) ;;
  *)
    echo "AWESOMUX_GHOSTTY_OPTIMIZE='$AWESOMUX_GHOSTTY_OPTIMIZE' is invalid; must be one of: Debug, ReleaseSafe, ReleaseFast, ReleaseSmall." >&2
    exit 2
    ;;
esac

AWESOMUX_ZIG_CACHE_DIR="$ARTIFACT_DIR/zig-cache-$AWESOMUX_GHOSTTY_OPTIMIZE"
AWESOMUX_ZIG_GLOBAL_CACHE_DIR="$ARTIFACT_DIR/zig-global-cache-$AWESOMUX_GHOSTTY_OPTIMIZE"
AWESOMUX_INSTALL_DIR="$ARTIFACT_DIR/install"
GHOSTTY_XCFRAMEWORK="$ARTIFACT_DIR/GhosttyKit.xcframework"
GHOSTTY_BUILT_SHARE_DIR="$AWESOMUX_INSTALL_DIR/share"
GHOSTTY_REQUIRED_ZIG_VERSION=""
ZIG_BIN=""

# shellcheck source=script/ghostty_link_archives.sh
source "$ROOT_DIR/script/ghostty_link_archives.sh"

find_archive() {
  local name="$1"
  local matches=()
  local source

  while IFS= read -r source; do
    matches+=("$source")
  done < <(find "$AWESOMUX_ZIG_CACHE_DIR" -name "$name" -type f -print 2>/dev/null | LC_ALL=C sort || true)

  case "${#matches[@]}" in
    0)
      return 0
      ;;
    *)
      if [[ "${#matches[@]}" -gt 1 ]]; then
        echo "Found multiple Ghostty build archives named $name in fresh $AWESOMUX_ZIG_CACHE_DIR; using first sorted candidate." >&2
      fi
      echo "${matches[0]}"
      ;;
  esac
}

# On Xcode 26.4, downloaded Metal can be reachable only through its toolchain
# identifier, not plain `xcrun metal`.
select_metal_toolchain() {
  local identifier

  if ! command -v xcodebuild >/dev/null 2>&1; then
    return 1
  fi

  identifier="$(
    xcodebuild -showComponent MetalToolchain -json 2>/dev/null \
      | plutil -extract toolchainIdentifier raw -o - - 2>/dev/null \
      || true
  )"

  if [[ -z "$identifier" ]]; then
    return 1
  fi

  if TOOLCHAINS="$identifier" xcrun -sdk macosx metal -v >/dev/null 2>&1; then
    echo "$identifier"
    return 0
  fi

  return 1
}

require_metal_toolchain() {
  local metal_toolchain

  if ! command -v xcrun >/dev/null 2>&1; then
    echo "xcrun is required to build Ghostty's Metal shaders but is not on PATH." >&2
    exit 1
  fi

  if xcrun -sdk macosx metal -v >/dev/null 2>&1; then
    return 0
  fi

  if metal_toolchain="$(select_metal_toolchain)"; then
    export TOOLCHAINS="$metal_toolchain"
    echo "Using Xcode Metal Toolchain $metal_toolchain" >&2
    return 0
  fi

  cat >&2 <<EOF
Apple's Metal Toolchain is required to build Ghostty's Metal shaders.
Install it with:

  xcodebuild -downloadComponent MetalToolchain

Then re-run this build.
EOF
  exit 1
}

read_ghostty_required_zig_version() {
  local version

  version="$(sed -nE 's/.*\.minimum_zig_version[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$GHOSTTY_DIR/build.zig.zon" | head -n 1)"
  if [[ -z "$version" ]]; then
    echo "Could not read Ghostty's minimum_zig_version from $GHOSTTY_DIR/build.zig.zon." >&2
    exit 1
  fi

  echo "$version"
}

parse_zig_version() {
  local version="$1"
  local major minor patch

  IFS='.' read -r major minor patch <<<"$version"
  patch="${patch%%[^0-9]*}"

  if [[ ! "$major" =~ ^[0-9]+$ || ! "$minor" =~ ^[0-9]+$ || ! "$patch" =~ ^[0-9]+$ ]]; then
    return 1
  fi

  printf '%s %s %s\n' "$major" "$minor" "$patch"
}

resolve_zig_candidate() {
  local candidate="$1"

  if [[ "$candidate" == */* ]]; then
    echo "$candidate"
  else
    command -v "$candidate" 2>/dev/null || echo "$candidate"
  fi
}

zig_is_compatible() {
  local candidate="$1"
  local required="$2"
  local version
  local required_parts candidate_parts
  local required_major required_minor required_patch
  local candidate_major candidate_minor candidate_patch

  [[ -x "$candidate" ]] || return 1
  version="$("$candidate" version 2>/dev/null | head -n 1)" || return 1

  required_parts="$(parse_zig_version "$required")" || return 1
  candidate_parts="$(parse_zig_version "$version")" || return 1

  read -r required_major required_minor required_patch <<<"$required_parts"
  read -r candidate_major candidate_minor candidate_patch <<<"$candidate_parts"

  [[ "$candidate_major" -eq "$required_major" ]] || return 1
  [[ "$candidate_minor" -eq "$required_minor" ]] || return 1
  [[ "$candidate_patch" -ge "$required_patch" ]] || return 1
  return 0
}

zig_version_or_unknown() {
  local candidate="$1"

  if [[ -x "$candidate" ]]; then
    "$candidate" version 2>/dev/null | head -n 1 || echo "unknown"
  else
    echo "missing"
  fi
}

select_zig() {
  local required="$1"
  local required_major required_minor required_patch
  local required_parts formula brew_prefix candidate resolved
  local candidates=()
  local seen=""

  required_parts="$(parse_zig_version "$required")" || {
    echo "Ghostty has an unsupported minimum_zig_version value: $required" >&2
    exit 1
  }
  read -r required_major required_minor required_patch <<<"$required_parts"
  formula="zig@$required_major.$required_minor"

  if [[ -n "${AWESOMUX_ZIG:-}" ]]; then
    resolved="$(resolve_zig_candidate "$AWESOMUX_ZIG")"
    if zig_is_compatible "$resolved" "$required"; then
      echo "$resolved"
      return 0
    fi

    cat >&2 <<EOF
AWESOMUX_ZIG points to '$AWESOMUX_ZIG', but that Zig is not compatible with Ghostty.
Ghostty requires Zig $required_major.$required_minor.x with patch >= $required_patch; found $(zig_version_or_unknown "$resolved").
Unset AWESOMUX_ZIG or point it at a compatible Zig binary.
EOF
    exit 1
  fi

  if command -v zig >/dev/null 2>&1; then
    candidates+=("$(command -v zig)")
  fi

  if command -v brew >/dev/null 2>&1; then
    brew_prefix="$(brew --prefix "$formula" 2>/dev/null || true)"
    if [[ -n "$brew_prefix" ]]; then
      candidates+=("$brew_prefix/bin/zig")
    fi
  fi

  candidates+=(
    "/opt/homebrew/opt/$formula/bin/zig"
    "/usr/local/opt/$formula/bin/zig"
  )

  for candidate in "${candidates[@]}"; do
    [[ -n "$candidate" ]] || continue
    case "$seen" in
      *"|$candidate|"*) continue ;;
    esac
    seen="$seen|$candidate|"

    if zig_is_compatible "$candidate" "$required"; then
      echo "$candidate"
      return 0
    fi
  done

  cat >&2 <<EOF
Ghostty requires Zig $required_major.$required_minor.x with patch >= $required_patch, but no compatible Zig binary was found.

Install it with:

  brew install $formula

Or set AWESOMUX_ZIG=/path/to/zig before running the build.
EOF
  exit 1
}

if [[ ! -d "$GHOSTTY_DIR/.git" && ! -f "$GHOSTTY_DIR/.git" ]]; then
  echo "Ghostty submodule is missing. Run: git submodule update --init --recursive" >&2
  exit 1
fi

GHOSTTY_REQUIRED_ZIG_VERSION="$(read_ghostty_required_zig_version)"
ZIG_BIN="$(select_zig "$GHOSTTY_REQUIRED_ZIG_VERSION")"

require_metal_toolchain

cd "$GHOSTTY_DIR"

rm -rf "$AWESOMUX_INSTALL_DIR" "$AWESOMUX_ZIG_CACHE_DIR" "$AWESOMUX_ZIG_GLOBAL_CACHE_DIR"

echo "Building Ghostty from vendor/ghostty (Zig optimize=$AWESOMUX_GHOSTTY_OPTIMIZE)."
echo "This build can take about 60-120 seconds; later app builds reuse the finished .build/ghostty artifacts."
echo "Using Zig $("$ZIG_BIN" version) at $ZIG_BIN (Ghostty requires $GHOSTTY_REQUIRED_ZIG_VERSION)"

# Fail-closed on purpose: this runs under `set -e` with no `set +e` tolerance
# block. A non-zero `zig build` aborts here even if some artifacts happen to be
# on disk — we will not link a half-built Ghostty into the app. This is STRICTER
# than the prior script, which tolerated a non-zero exit when the fat archive +
# share tree already existed. If a future Zig is found to exit non-zero after
# legitimately producing all artifacts, restore a tolerance path that logs
# loudly rather than silencing the failure.
ZIG_GLOBAL_CACHE_DIR="$AWESOMUX_ZIG_GLOBAL_CACHE_DIR" "$ZIG_BIN" build \
  --prefix "$AWESOMUX_INSTALL_DIR" \
  --cache-dir "$AWESOMUX_ZIG_CACHE_DIR" \
  -Doptimize="$AWESOMUX_GHOSTTY_OPTIMIZE" \
  -Dapp-runtime=none \
  -Demit-xcframework=true \
  -Demit-macos-app=false \
  -Dxcframework-target=native

if [[ ! -d "$GHOSTTY_BUILT_SHARE_DIR" ]]; then
  echo "Ghostty build completed without required artifacts." >&2
  exit 1
fi

declare -a GHOSTTY_ARCHIVE_SOURCES=()
for archive in "${GHOSTTY_LINK_ARCHIVES[@]}"; do
  source_name="$(ghostty_link_archive_source_name "$archive")"
  source_path="$(find_archive "$source_name")"
  if [[ -z "$source_path" ]]; then
    echo "Ghostty build completed without required archive: $source_name." >&2
    exit 1
  fi
  GHOSTTY_ARCHIVE_SOURCES+=("$source_path")
done

# Publish via a staging swap (INT-302): assemble the consumed subset
# (xcframework + share) fully in a per-process staging dir, then swap each
# artifact into place with two renames (old aside, new in). A validating
# reader through a worktree symlink previously raced the whole seconds-long
# in-place ditto of share/; the residual per-artifact absence window is now
# two rename syscalls. Stamps are removed before the swap and rewritten after
# it, so a reader never sees fresh stamps over a partially swapped tree.
# Ceiling: concurrent publishes in the same checkout remain unsupported (they
# already corrupt the shared zig cache mid-build); upgrade path if that ever
# changes is a publish lock or versioned dirs + symlink flip.
STAGING_DIR="$ARTIFACT_DIR/.staging.$$"
cleanup_staging() {
  local status=$?
  rm -rf "$STAGING_DIR"
  if [[ $status -ne 0 ]]; then
    echo "[build_ghostty_xcframework] publish did not complete; $ARTIFACT_DIR may be partial (stamps removed, so consumers will rebuild). Re-run this script or script/ensure_ghostty_artifacts.sh to recover." >&2
  fi
}
trap cleanup_staging EXIT
rm -rf "$ARTIFACT_DIR"/.staging "$ARTIFACT_DIR"/.staging.* \
  "$GHOSTTY_XCFRAMEWORK.old" "$AWESOMUX_SHARE_DIR.old"
mkdir -p "$STAGING_DIR/GhosttyKit.xcframework/macos-arm64/Headers"
cp "$GHOSTTY_DIR/include/ghostty.h" "$STAGING_DIR/GhosttyKit.xcframework/macos-arm64/Headers/ghostty.h"
for i in "${!GHOSTTY_LINK_ARCHIVES[@]}"; do
  archive="${GHOSTTY_LINK_ARCHIVES[$i]}"
  cp "${GHOSTTY_ARCHIVE_SOURCES[$i]}" "$STAGING_DIR/$(ghostty_link_archive_dest_path "$archive")"
done
mkdir -p "$STAGING_DIR/share"
ditto "$GHOSTTY_BUILT_SHARE_DIR" "$STAGING_DIR/share"

rm -f "$ARTIFACT_DIR/.built-from-sha" "$ARTIFACT_DIR/.built-optimize"
if [[ -e "$GHOSTTY_XCFRAMEWORK" ]]; then
  mv "$GHOSTTY_XCFRAMEWORK" "$GHOSTTY_XCFRAMEWORK.old"
fi
mv "$STAGING_DIR/GhosttyKit.xcframework" "$GHOSTTY_XCFRAMEWORK"
if [[ -e "$AWESOMUX_SHARE_DIR" ]]; then
  mv "$AWESOMUX_SHARE_DIR" "$AWESOMUX_SHARE_DIR.old"
fi
mv "$STAGING_DIR/share" "$AWESOMUX_SHARE_DIR"
rm -rf "$GHOSTTY_XCFRAMEWORK.old" "$AWESOMUX_SHARE_DIR.old"

# Stamp the actual submodule HEAD that zig just compiled — not the parent's
# committed gitlink. Worktrees that symlink this directory compare their own
# HEAD:vendor/ghostty against this stamp to detect drift. See
# script/ensure_ghostty_artifacts.sh. Best-effort: if there's no git context
# (tarball, detached build), skip silently — drift detection just won't fire
# downstream, which the helper handles by logging a "no stamp" note.
# Write stamps atomically (tempfile + rename), and only after the staging
# swap above has landed, so a reader through a symlink never sees fresh
# stamps pointing at a half-published tree. Two windows remain: a validating
# reader can catch the two-rename gap where an artifact dir is absent (and
# will fail closed into a rebuild), and a reader already past validation
# (mid swift-build) can still lose a dir mid-link — that now fails loud
# instead of linking a mixed tree. Upgrade path: versioned dirs + symlink
# flip.
if VENDOR_SHA="$(git -C "$GHOSTTY_DIR" rev-parse HEAD 2>/dev/null)"; then
  printf '%s\n' "$VENDOR_SHA" > "$ARTIFACT_DIR/.built-from-sha.tmp"
  mv "$ARTIFACT_DIR/.built-from-sha.tmp" "$ARTIFACT_DIR/.built-from-sha"
fi
printf '%s\n' "$AWESOMUX_GHOSTTY_OPTIMIZE" > "$ARTIFACT_DIR/.built-optimize.tmp"
mv "$ARTIFACT_DIR/.built-optimize.tmp" "$ARTIFACT_DIR/.built-optimize"

echo "Built $GHOSTTY_XCFRAMEWORK"
echo "Staged Ghostty link archives in $GHOSTTY_XCFRAMEWORK:"
printf '  %s\n' "${GHOSTTY_LINK_ARCHIVES[@]}"
