#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="awesoMux"
MIN_SYSTEM_VERSION="15.0"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/runtime-profile.sh"

# Distinct production and development identities. macOS routes a notification click by bundle
# identifier, not file path: every bundle claiming an id competes to be the
# one LaunchServices reopens, and the most-recently-registered usually wins.
# When the dist build shared the installed app's id, every `build_and_run`
# re-registered a fresh contender and notification clicks started opening a
# random dev build. Give the dist/dev build its own `.dev` id so it can never
# hijack the installed app's notifications; `--install` produces the real,
# shippable app and keeps the production identity.
# The primary checkout keeps the stable `.dev` identity. Linked worktrees append
# a stable path-derived id so their state, defaults, notifications, and daemon
# namespaces cannot collide. `runtime-profile.sh` and AppRuntimeProfile share
# this bundle-id/path contract; tests pin their byte-identical results.
PROD_BUNDLE_ID="$AWESOMUX_PRODUCTION_BUNDLE_ID"

# os.Logger subsystem is a literal string hardcoded throughout Sources/ — it is
# NOT derived from CFBundleIdentifier, so it stays put no matter which identity
# the bundle ships with. Log-stream predicates must filter on this constant, not
# on $BUNDLE_ID, or a `.dev` build's logs (still emitted under the prod
# subsystem) would match nothing.
LOG_SUBSYSTEM="$PROD_BUNDLE_ID"
PROCESS_ENUMERATION_FAILURE=70

# BUNDLE_DISPLAY_NAME (CFBundleName) distinguishes the two identities everywhere
# macOS shows the app by name — System Settings → Notifications, the menu bar,
# the app switcher — so a `.dev` build doesn't render as a second, identical
# "awesoMux" row the user can't tell apart from the installed one.
case "$MODE" in
  --install|install|--stage-release|stage-release) RUNTIME_PROFILE="production" ;;
  *)                 RUNTIME_PROFILE="$(awesomux_checkout_profile "$ROOT_DIR")" ;;
esac
awesomux_resolve_profile "$RUNTIME_PROFILE"
BUNDLE_ID="$AWESOMUX_PROFILE_BUNDLE_ID"
BUNDLE_DISPLAY_NAME="$AWESOMUX_PROFILE_DISPLAY_NAME"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
INSTALL_DIR="${AWESOMUX_INSTALL_DIR:-$HOME/Applications}"
INSTALLED_APP_BUNDLE="$INSTALL_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
AGENT_HOOK_NAME="awesoMuxAgentHook"
AGENT_HOOK_BINARY="$APP_MACOS/$AGENT_HOOK_NAME"
# awesoMuxBridgeHelper: the remote per-invocation bridge helper (INT-698). Built
# by `swift build` alongside the app and staged the same way as
# awesoMuxAgentHook — Bundle.main.executableURL is how the app locates both.
BRIDGE_HELPER_NAME="awesoMuxBridgeHelper"
BRIDGE_HELPER_BINARY="$APP_MACOS/$BRIDGE_HELPER_NAME"
# amx: the vendored zmx persistent-session backend (ADR-0011). Built by
# script/build_amx.sh and staged beside the main executable so the bridge can
# spawn `amx attach <id>` and Swift can locate it via Bundle.main.executableURL.
AMX_NAME="amx"
AMX_BUILT_BINARY="$ROOT_DIR/.build/amx/amx"
AMX_BINARY="$APP_MACOS/$AMX_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
APP_ICON_SOURCE="$ROOT_DIR/Resources/AppIcon.icon"
APP_FONTS="$ROOT_DIR/Resources/Fonts"
LICENSE_RESOURCES="$ROOT_DIR/Resources/Licenses"
APP_AGENT_INTEGRATIONS="$ROOT_DIR/Resources/AgentIntegrations"
APP_LOCALIZATIONS="$ROOT_DIR/Resources"
APP_STRING_CATALOG="$APP_LOCALIZATIONS/Localizable.xcstrings"
GHOSTTY_ARTIFACT_DIR="$ROOT_DIR/.build/ghostty"
GHOSTTY_SHARE="$GHOSTTY_ARTIFACT_DIR/share"

cd "$ROOT_DIR"

usage() {
  cat <<'USAGE'
Usage: script/build_and_run.sh [MODE]

Modes:
  run (default)                       Build, stage, sign, and launch dist/awesoMux.app.
  --debug, debug                      Build debug and launch the app binary under lldb.
  --logs, logs                        Launch and stream logs for the awesoMux process.
  --telemetry, telemetry              Launch and stream all awesoMux subsystem logs.
  --perf, perf                        Launch and stream performance/memory samples.
  --terminal-diagnostics,             Launch with terminal color diagnostics enabled
    terminal-diagnostics              and stream only that log category.
  --shortcut-diagnostics,             Launch with focus-sidebar shortcut diagnostics
    shortcut-diagnostics              enabled and stream only that log category.
  --window-diagnostics,               Launch with INT-746 window-order diagnostics
    window-diagnostics                enabled and stream only that log category.
  --perf-install, perf-install        Stream performance logs for the installed bundle.
  --malloc-stack-logging,             Launch directly with MallocStackLogging=1.
    malloc-stack-logging
  --verify, verify                    Launch, verify the process starts, then quit it.
                                       Exits 1 if the app never starts, 3 if it starts
                                       but cannot be terminated afterwards.
  --install, install                  Install into ~/Applications and launch that bundle.
  --stage-release, stage-release      Build, stage, and ad-hoc sign dist/awesoMux.app
                                       with the production profile, then exit without
                                       launching. Consumed by script/build_release.sh.
  --help, -h, help                    Show this help and exit.

Environment:
  AWESOMUX_GHOSTTY_OPTIMIZE            Ghostty Zig optimize mode: Debug, ReleaseSafe,
                                       ReleaseFast (default), or ReleaseSmall. Debug mode
                                       defaults this to Debug when it is not set.
  AWESOMUX_ZIG                         Compatible Zig binary used when Ghostty artifacts
                                       need to be built.
  AWESOMUX_INSTALL_DIR                 Install destination (default: ~/Applications).
  AWESOMUX_PERF_SAMPLE_INTERVAL_SECONDS
                                       Perf sample interval from 1 to 3600 seconds
                                       (default: 30; --perf and --perf-install only).
  AWESOMUX_PERF_SAMPLE_PORTS           Include Mach port counts: 0 or 1
                                       (default: 0; --perf and --perf-install only).

See docs/ghostty-integration.md#build-the-xcframework for Ghostty build details.
USAGE
}

if [[ "$MODE" == "--help" || "$MODE" == "-h" || "$MODE" == "help" ]]; then
  usage
  exit 0
fi

mode_requires_amx() {
  [[ "$MODE" == "--install" || "$MODE" == "install" || "$MODE" == "--stage-release" || "$MODE" == "stage-release" ]]
}

mode_requires_exact_ghostty_pin() {
  [[ "$MODE" == "--install" || "$MODE" == "install" || "$MODE" == "--perf-install" || "$MODE" == "perf-install" || "$MODE" == "--stage-release" || "$MODE" == "stage-release" ]]
}

amx_install_error() {
  local detail="$1"

  cat >&2 <<EOF
error: $detail
       --install and --stage-release require the bundled amx command-bridge backend.
       Refusing to replace the installed app with a local-shell-only build.

To fix:
  git submodule update --init --recursive
  ./script/build_amx.sh

If initialization fails, confirm the vendor/zmx submodule is reachable:
  https://github.com/Interactive-Buffoonery/zmx.git
EOF
}

zmx_submodule_is_initialized() {
  [[ -d "$ROOT_DIR/vendor/zmx/.git" || -f "$ROOT_DIR/vendor/zmx/.git" ]]
}

trash_path() {
  local path="$1"

  if ! command -v trash >/dev/null 2>&1; then
    echo "trash command is required to replace app bundles safely." >&2
    exit 1
  fi

  trash "$path"
}

app_executable_path() {
  local bundle="$1"

  printf '%s/Contents/MacOS/%s\n' "$bundle" "$APP_NAME"
}

awesomux_candidate_pids() {
  local output status

  if output="$(pgrep -x "$APP_NAME" 2>&1)"; then
    [[ -n "$output" ]] && printf '%s\n' "$output"
    return 0
  else
    status="$?"
  fi

  # pgrep exits 1 for "no matching process". Any other status means process
  # enumeration itself failed, and treating that as "not running" can leave an
  # old installed app alive while --install opens the replacement.
  if [[ "$status" == 1 ]]; then
    return 0
  fi

  echo "error: unable to enumerate running $APP_NAME processes (pgrep exited $status)." >&2
  [[ -n "$output" ]] && printf '%s\n' "$output" >&2
  return "$PROCESS_ENUMERATION_FAILURE"
}

# PIDs whose actual executable IS this bundle's binary.
#
# `pgrep -x "$APP_NAME"` finds processes named exactly `awesoMux`, then we
# confirm each candidate's real executable path (`ps -o comm=`, which is the
# absolute exec path on macOS) with a fixed-string compare. We deliberately
# do NOT use `pgrep -f <path>`: `-f` matches an extended REGEX against the
# whole command line, so the bundle path's dots are wildcards, an install
# dir with regex metacharacters breaks the match, and — worst — an `lldb`,
# `leaks`, editor, or `tail` whose argv merely mentions the path would be
# treated as the running app (false-positive `--verify`) or get killed by a
# normal build. Matching the exact exec path of a process named `awesoMux`
# keeps the dist-vs-installed distinction without those footguns.
app_bundle_pids() {
  local bundle="$1"
  local executable
  executable="$(app_executable_path "$bundle")"

  local candidate_pids
  if candidate_pids="$(awesomux_candidate_pids)"; then
    :
  else
    return "$?"
  fi

  local pid comm stat status
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    if comm="$(ps -p "$pid" -o comm= 2>&1)"; then
      :
    else
      status="$?"
      kill -0 "$pid" >/dev/null 2>&1 || continue
      echo "error: unable to inspect $APP_NAME process $pid (ps comm exited $status)." >&2
      [[ -n "$comm" ]] && printf '%s\n' "$comm" >&2
      return "$PROCESS_ENUMERATION_FAILURE"
    fi
    # An unreaped zombie is not a running app; counting it would make the
    # post-kill exit wait spin forever on a corpse SIGKILL can't remove.
    if stat="$(ps -p "$pid" -o stat= 2>&1)"; then
      :
    else
      status="$?"
      kill -0 "$pid" >/dev/null 2>&1 || continue
      echo "error: unable to inspect $APP_NAME process $pid (ps stat exited $status)." >&2
      [[ -n "$stat" ]] && printf '%s\n' "$stat" >&2
      return "$PROCESS_ENUMERATION_FAILURE"
    fi
    [[ "$stat" == Z* ]] && continue
    if [[ "$comm" == "$executable" ]]; then
      printf '%s\n' "$pid"
    fi
  done <<< "$candidate_pids"
}

terminate_app_bundle() {
  local bundle="$1"
  local signal="${2:-TERM}"
  local pids
  if pids="$(app_bundle_pids "$bundle")"; then
    :
  else
    echo "error: cannot safely determine whether $bundle is running; refusing to continue." >&2
    exit "$PROCESS_ENUMERATION_FAILURE"
  fi

  if [[ -n "$pids" ]]; then
    # Word-split intentional: one or more PIDs on separate lines.
    # shellcheck disable=SC2086
    kill -s "$signal" $pids >/dev/null 2>&1 || true
  fi
}

app_bundle_is_running() {
  local bundle="$1"
  local pids

  if pids="$(app_bundle_pids "$bundle")"; then
    :
  else
    return "$?"
  fi

  [[ -n "$pids" ]]
}

# Polls until the bundle reaches the wanted state ("running" or "exited").
app_bundle_in_state() {
  local bundle="$1"
  local state="$2"
  local status

  if app_bundle_is_running "$bundle"; then
    [[ "$state" == "running" ]]
    return
  else
    status="$?"
  fi

  if [[ "$status" != 1 ]]; then
    return "$status"
  fi

  [[ "$state" == "exited" ]]
}

wait_for_app_bundle_state() {
  local bundle="$1"
  local state="$2"
  local attempts="${3:-20}"
  local delay_seconds="${4:-0.25}"
  local attempt

  for ((attempt = 1; attempt <= attempts; attempt++)); do
    if app_bundle_in_state "$bundle" "$state"; then
      return 0
    else
      local status="$?"
    fi
    if [[ "$status" != 1 ]]; then
      return "$status"
    fi
    sleep "$delay_seconds"
  done

  # Re-sample once more: the state may have flipped during the final sleep,
  # and a stale answer here turns into a false failure.
  app_bundle_in_state "$bundle" "$state"
}

wait_for_app_bundle() {
  wait_for_app_bundle_state "$1" running "${2:-20}" "${3:-0.25}"
}

wait_for_app_bundle_exit() {
  wait_for_app_bundle_state "$1" exited "${2:-20}" "${3:-0.25}"
}

# terminate_app_bundle only sends the signal; it doesn't confirm the target
# actually died. A caller that replaces or relaunches the same bundle right
# after can't assume that — the exit is asynchronous, so without waiting the
# old process can still be tearing down while a second instance starts on top
# of it. Wait for the exit and escalate to SIGKILL before declaring success,
# same as --verify already does for its own cleanup.
terminate_app_bundle_and_wait() {
  local bundle="$1"
  local status

  terminate_app_bundle "$bundle"
  if wait_for_app_bundle_exit "$bundle"; then
    return 0
  else
    status="$?"
  fi

  # Only escalate for a genuine "still running" (status 1). Any other status
  # is app_bundle_pids failing to enumerate at all (PROCESS_ENUMERATION_FAILURE)
  # — sending SIGKILL and declaring a fresh "still running" wouldn't be true.
  if [[ "$status" != 1 ]]; then
    return "$status"
  fi

  echo "warning: $bundle did not exit after SIGTERM; escalating to SIGKILL." >&2
  terminate_app_bundle "$bundle" KILL
  if ! wait_for_app_bundle_exit "$bundle" 8; then
    echo "error: $bundle is still running; refusing to continue." >&2
    return 3
  fi
}

# --debug/debug means the dev wants to attach lldb. Swift's CONFIG flips to
# debug below; Ghostty needs the same treatment so libghostty symbols aren't
# stripped and the optimizer's local reorderings don't make stepping useless.
# (The original beachball this PR fixes was diagnosed inside libghostty —
# that's exactly where someone using --debug needs symbols.) If the caller
# already set AWESOMUX_GHOSTTY_OPTIMIZE explicitly, honor their choice.
if [[ "$MODE" == "--debug" || "$MODE" == "debug" ]] && [[ -z "${AWESOMUX_GHOSTTY_OPTIMIZE:-}" ]]; then
  export AWESOMUX_GHOSTTY_OPTIMIZE=Debug
fi

# Installed production builds must use the Ghostty revision pinned by the
# commit being installed. Development modes may reuse another worktree's
# compatible artifacts (with a warning) to keep iteration fast.
if mode_requires_exact_ghostty_pin; then
  export AWESOMUX_GHOSTTY_REQUIRE_PIN_MATCH=1
fi

"$ROOT_DIR/script/ensure_ghostty_artifacts.sh"

# Build the amx (vendored zmx) persistent-session backend. Independent of the
# ghostty xcframework — it links none of vendor/ghostty and is a runtime helper,
# not a link-time input. Best-effort by design: the command bridge is disabled
# by default and AmxBackend falls back to a local shell when amx is absent, so a
# contributor without a Zig toolchain can still build and run the app.
#
# Rebuild when the staged amx is missing OR the vendored zmx source is newer than
# it — a plain "skip if staged" check ships a stale amx after a submodule bump
# (e.g. a fork-patch update), which silently runs the bridge against an old
# binary. mtime-based staleness is cheap and zig's own build cache makes a
# no-op rebuild fast.
#
# Also watches build_amx.sh itself: a build-flag-only change there (e.g. the
# -Doptimize fix, INT-523) touches no zmx source file, so without this a
# contributor who already has a staged binary from before the flag change
# would silently keep running it.
#
# None of that catches a submodule checked out behind the superproject's
# pin, though: `git pull` moves the gitlink but the submodule worktree keeps
# whatever commit it already had, so its files just sit there with old
# mtimes — never "newer" than a staged binary, so a stale checkout looks
# perpetually fresh and this check would otherwise skip calling
# build_amx.sh forever. Trigger a rebuild on pin mismatch too so
# build_amx.sh's own guard (which does the actual re-sync) gets a chance to
# run.
amx_needs_build=0
if [[ ! -x "$AMX_BUILT_BINARY" ]]; then
  amx_needs_build=1
elif [[ -n "$(find "$ROOT_DIR/vendor/zmx/src" "$ROOT_DIR/vendor/zmx/build.zig" "$ROOT_DIR/vendor/zmx/build.zig.zon" "$ROOT_DIR/script/build_amx.sh" -newer "$AMX_BUILT_BINARY" 2>/dev/null | head -n 1)" ]]; then
  amx_needs_build=1
elif zmx_submodule_is_initialized; then
  amx_pinned_sha="$(git -C "$ROOT_DIR" rev-parse HEAD:vendor/zmx 2>/dev/null || echo "")"
  amx_checked_out_sha="$(git -C "$ROOT_DIR/vendor/zmx" rev-parse HEAD 2>/dev/null || echo "")"
  if [[ -n "$amx_pinned_sha" && -n "$amx_checked_out_sha" && "$amx_pinned_sha" != "$amx_checked_out_sha" ]]; then
    amx_needs_build=1
  fi
fi
if [[ "$amx_needs_build" == 1 ]]; then
  if ! "$ROOT_DIR/script/build_amx.sh"; then
    if mode_requires_amx; then
      amx_install_error "amx build failed."
      exit 1
    fi
    echo "warning: amx build failed — the command bridge will be unavailable (the app runs with local shells)." >&2
  fi
fi
if mode_requires_amx && [[ ! -x "$AMX_BUILT_BINARY" ]]; then
  amx_install_error "amx is absent ($AMX_BUILT_BINARY)."
  exit 1
fi

if [[ ! -f "$GHOSTTY_SHARE/terminfo/78/xterm-ghostty" ]]; then
  echo "Ghostty terminfo resources are missing at $GHOSTTY_SHARE/terminfo." >&2
  exit 1
fi

if [[ ! -d "$GHOSTTY_SHARE/ghostty/shell-integration" ]]; then
  echo "Ghostty shell integration resources are missing at $GHOSTTY_SHARE/ghostty/shell-integration." >&2
  exit 1
fi

# Default to release for daily-driving — unqualified `swift build` produces a
# debug binary, which makes the terminal feel sluggish even on idle UI. The
# --debug/debug mode below needs unoptimized symbols for lldb, so flip back
# to the debug configuration in that case only.
CONFIG="release"
if [[ "$MODE" == "--debug" || "$MODE" == "debug" ]]; then
  CONFIG="debug"
fi

swift build -c "$CONFIG"
BUILD_BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)"
BUILD_BINARY="$BUILD_BIN_PATH/$APP_NAME"
BUILD_AGENT_HOOK_BINARY="$BUILD_BIN_PATH/$AGENT_HOOK_NAME"
DESIGN_SYSTEM_RESOURCE_BUNDLE="$BUILD_BIN_PATH/awesoMux_DesignSystem.bundle"
BUILD_BRIDGE_HELPER_BINARY="$BUILD_BIN_PATH/$BRIDGE_HELPER_NAME"

# Terminate only the staged dist bundle before replacing it. Dev and installed
# builds now use profile-scoped support/config/runtime paths plus distinct amx
# socket dirs, so a dev run can coexist with the installed app. Modes that
# explicitly manage the installed bundle (`--install`, `--perf-install`) stop it
# at their own launch/replace point below.
terminate_app_bundle "$APP_BUNDLE"

# One-time heads-up on the first launch after the dev-profile split: an empty
# dev app otherwise reads as data loss (settings reset, zero restored sessions).
if [[ "$RUNTIME_PROFILE" == development* && ! -d "$HOME/Library/Application Support/$AWESOMUX_PROFILE_SUPPORT_NAME" ]]; then
  echo "First dev-profile launch: dev state starts fresh under ~/Library/Application Support/$AWESOMUX_PROFILE_SUPPORT_NAME,"
  echo "~/.config/$AWESOMUX_PROFILE_CONFIG_NAME, and \$TMPDIR/$AWESOMUX_PROFILE_SOCKET_NAME. Installed-app state is untouched. To carry your"
  echo "settings over: cp ~/.config/awesomux/config.toml ~/.config/$AWESOMUX_PROFILE_CONFIG_NAME/ (after this first run)."
fi

if [[ -e "$APP_BUNDLE" ]]; then
  trash_path "$APP_BUNDLE"
fi
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
cp "$BUILD_AGENT_HOOK_BINARY" "$AGENT_HOOK_BINARY"
if [[ ! -d "$DESIGN_SYSTEM_RESOURCE_BUNDLE" ]]; then
  echo "error: DesignSystem resource bundle is missing: $DESIGN_SYSTEM_RESOURCE_BUNDLE" >&2
  exit 1
fi
cp -R "$DESIGN_SYSTEM_RESOURCE_BUNDLE" "$APP_RESOURCES/"
for font_file in \
    Fonts/Geist-Regular.ttf \
    Fonts/Geist-Medium.ttf \
    Fonts/Geist-SemiBold.ttf \
    Fonts/Geist-Bold.ttf; do
  if [[ ! -f "$APP_RESOURCES/awesoMux_DesignSystem.bundle/$font_file" ]]; then
    echo "error: required bundled font is missing: $font_file" >&2
    exit 1
  fi
done
cp "$BUILD_BRIDGE_HELPER_BINARY" "$BRIDGE_HELPER_BINARY"
chmod +x "$APP_BINARY"
chmod +x "$AGENT_HOOK_BINARY"
chmod +x "$BRIDGE_HELPER_BINARY"
# Stage amx only if it was built. A bundle without it still runs (local-shell
# only); the command bridge stays unavailable until amx is present.
if [[ -x "$AMX_BUILT_BINARY" ]]; then
  cp "$AMX_BUILT_BINARY" "$AMX_BINARY"
  chmod +x "$AMX_BINARY"
else
  if mode_requires_amx; then
    amx_install_error "amx is absent ($AMX_BUILT_BINARY)."
    exit 1
  fi
  echo "warning: amx absent ($AMX_BUILT_BINARY) — bundling without the command-bridge backend." >&2
fi
cp -R "$GHOSTTY_SHARE/." "$APP_RESOURCES/"
mkdir -p "$APP_RESOURCES/Licenses"
required_license_files=(
  "Ghostty/LICENSE"
  "zmx/LICENSE"
  "HackNerdFontMono/LICENSE.md"
  "Geist/OFL.txt"
  "swift-toml/LICENSE.md"
  "swift-markdown/LICENSE.txt"
  "swift-markdown/NOTICE.txt"
  "swift-cmark/COPYING"
)
for license_file in "${required_license_files[@]}"; do
  source_license="$LICENSE_RESOURCES/$license_file"
  bundled_license="$APP_RESOURCES/Licenses/$license_file"
  if [[ ! -f "$source_license" ]]; then
    echo "error: required license resource is missing: $source_license" >&2
    exit 1
  fi
  mkdir -p "$(dirname "$bundled_license")"
  cp "$source_license" "$bundled_license"
done

for license_file in "${required_license_files[@]}"; do
  if [[ ! -f "$APP_RESOURCES/Licenses/$license_file" ]]; then
    echo "error: required bundled license is missing: Licenses/$license_file" >&2
    exit 1
  fi
done
if [[ -d "$APP_AGENT_INTEGRATIONS" ]]; then
  mkdir -p "$APP_RESOURCES/AgentIntegrations"
  cp -R "$APP_AGENT_INTEGRATIONS/." "$APP_RESOURCES/AgentIntegrations/"
fi
find "$APP_LOCALIZATIONS" -maxdepth 1 -type d -name '*.lproj' -exec cp -R {} "$APP_RESOURCES/" \;
if ! xcrun --find xcstringstool >/dev/null 2>&1; then
  echo "error: xcstringstool is required to compile $APP_STRING_CATALOG" >&2
  exit 1
fi
CATALOG_OUTPUT="$APP_RESOURCES/.compiled-string-catalog"
mkdir -p "$CATALOG_OUTPUT"
xcrun xcstringstool compile "$APP_STRING_CATALOG" --output-directory "$CATALOG_OUTPUT"
while IFS= read -r compiled_file; do
  relative_path="${compiled_file#"$CATALOG_OUTPUT/"}"
  if [[ -e "$APP_RESOURCES/$relative_path" ]]; then
    echo "error: compiled string catalog would overwrite $relative_path" >&2
    exit 1
  fi
done < <(find "$CATALOG_OUTPUT" -type f)
while IFS= read -r compiled_file; do
  relative_path="${compiled_file#"$CATALOG_OUTPUT/"}"
  mkdir -p "$(dirname "$APP_RESOURCES/$relative_path")"
  mv "$compiled_file" "$APP_RESOURCES/$relative_path"
done < <(find "$CATALOG_OUTPUT" -type f)
find "$CATALOG_OUTPUT" -depth -type d -exec rmdir {} \;
if [[ ! -f "$APP_RESOURCES/en.lproj/Localizable.strings" ]]; then
  echo "error: no compiled string catalog staged at $APP_RESOURCES/en.lproj" >&2
  exit 1
fi
if [[ ! -f "$APP_RESOURCES/en.lproj/Localizable.stringsdict" ]]; then
  echo "error: no localized .stringsdict staged at $APP_RESOURCES/en.lproj" >&2
  echo "       (source: $APP_LOCALIZATIONS — did the localization resources move?)" >&2
  exit 1
fi

# `ATSApplicationFontsPath` registers *files* in the named directory. Stage
# the bundled TTFs into Contents/Resources/Fonts/HackNerdFontMono and point
# the plist key at that directory. LICENSE files stay out of the ATS scan
# path so CoreText doesn't log "unknown file type" warnings on every launch
# — they ship under Contents/Resources/Licenses for attribution.
mkdir -p "$APP_RESOURCES/Fonts/HackNerdFontMono"
find "$APP_FONTS/HackNerdFontMono" -maxdepth 1 -type f -name '*.ttf' \
    -exec cp {} "$APP_RESOURCES/Fonts/HackNerdFontMono/" \;
if ! ls "$APP_RESOURCES/Fonts/HackNerdFontMono"/*.ttf >/dev/null 2>&1; then
  echo "error: no .ttf files staged at $APP_RESOURCES/Fonts/HackNerdFontMono" >&2
  echo "       (source: $APP_FONTS/HackNerdFontMono — did the fonts get pulled?)" >&2
  exit 1
fi

# Compile the Icon Composer source into the bundle. actool renders the composed
# icon (gradient, glass, shadow) two ways: Assets.car carries the adaptive Liquid
# Glass icon used on macOS 26+, and AppIcon.icns is the flat fallback macOS 15–25
# reads via CFBundleIconFile. Both keys land in Info.plist below; CFBundleIconName
# points the modern path at Assets.car.
#
# actool ships with full Xcode, not the Command Line Tools, so — like the amx
# step above — skip rather than hard-fail when it's missing; the app still
# launches, just with a generic icon. And actool exits 0 even when it produces
# nothing (e.g. a wrong --app-icon name, verified), writing diagnostics to the
# discarded stdout plist, so neither the exit code nor `set -e` catches a broken
# icon — assert the outputs landed.
if command -v actool >/dev/null 2>&1; then
  ICON_PARTIAL_PLIST="$(mktemp -t awesomux-appicon-plist)"
  actool "$APP_ICON_SOURCE" \
    --compile "$APP_RESOURCES" \
    --platform macosx \
    --minimum-deployment-target "$MIN_SYSTEM_VERSION" \
    --app-icon AppIcon \
    --output-partial-info-plist "$ICON_PARTIAL_PLIST" \
    --errors --warnings >/dev/null
  rm -f "$ICON_PARTIAL_PLIST"
  if [[ ! -f "$APP_RESOURCES/AppIcon.icns" || ! -f "$APP_RESOURCES/Assets.car" ]]; then
    echo "error: actool did not produce AppIcon.icns + Assets.car from $APP_ICON_SOURCE" >&2
    echo "       (actool returns 0 on failure — check the .icon catalog and the --app-icon name)" >&2
    exit 1
  fi
else
  echo "warning: actool not found (needs full Xcode); skipping app icon — bundle will use a generic icon" >&2
fi

# Marketing version for the dev bundle, from the latest tag. Without it,
# Bundle.main has no CFBundleShortVersionString, TerminalAppearancePreferences
# can't advertise TERM_PROGRAM_VERSION, and process-tree tools (fastfetch)
# that read the bundle version off the amx daemon's exe path show nothing
# useful. Only the tag's numeric base survives: between tags `git describe`
# yields "0.3.0-16-gabc1234", but both CFBundle version keys must be plain
# period-separated integers or macOS can reject/misread the bundle. The regex
# gate doubles as the injection guard — git tag names may contain XML
# metacharacters, and a hostile tag on a fetched fork would otherwise inject
# arbitrary Info.plist keys into the heredoc below.
# `|| true`: on a tagless clone (shallow/fork) `git describe` exits 128 and
# `pipefail` would otherwise kill the script before the fallback runs.
APP_VERSION="$(git -C "$ROOT_DIR" describe --tags 2>/dev/null | sed 's/^v//; s/[-+].*$//' || true)"
[[ "$APP_VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || APP_VERSION=""
APP_VERSION="${APP_VERSION:-0.0.0}"
# CFBundleVersion wants a monotonic numeric build; commit count fits and keeps
# successive dev builds distinguishable now that the describe suffix is gone.
BUILD_NUMBER="$(git -C "$ROOT_DIR" rev-list --count HEAD 2>/dev/null || true)"
BUILD_NUMBER="${BUILD_NUMBER:-0}"

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUMBER</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIconName</key>
  <string>AppIcon</string>
  <key>ATSApplicationFontsPath</key>
  <string>Fonts/HackNerdFontMono</string>
  <key>CFBundleName</key>
  <string>$BUNDLE_DISPLAY_NAME</string>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSPrincipalClass</key>
  <string>AwesoMuxApplication</string>
  <key>NSQuitAlwaysKeepsWindows</key>
  <false/>
</dict>
</plist>
PLIST

# Ad-hoc codesign the bundle. macOS UNUserNotifications (and other
# framework subsystems with a system-side identity tied to the
# signature) refuse to register an unsigned bundle: requestAuthorization
# silently fails with UNErrorDomain error 1 and the app never appears
# in System Settings → Notifications. Ad-hoc signing gives the bundle
# a stable identity without requiring a developer cert.
codesign --force --deep --sign - --options runtime "$APP_BUNDLE"

is_codex_launch_environment() {
  [[ -n "${CODEX_SANDBOX-}" || -n "${CODEX_THREAD_ID-}" || -n "${CODEX_CI-}" ]]
}

open_bundle() {
  # Per the NO_COLOR spec (https://no-color.org), any non-empty value disables
  # color, so test for non-empty rather than the literal "1". Codex sets
  # NO_COLOR for its own tool output; do not let that wrapper preference leak
  # into awesoMux panes during local app launch checks.
  if is_codex_launch_environment && [[ -n "${NO_COLOR-}" ]]; then
    env -u NO_COLOR /usr/bin/open "$@"
    return
  fi

  /usr/bin/open "$@"
}

open_app() {
  local bundle="${1:-$APP_BUNDLE}"
  open_bundle -n "$bundle"
}

single_app_bundle_pid() {
  local bundle="$1"
  local pids pid selected="" count=0
  if pids="$(app_bundle_pids "$bundle")"; then
    :
  else
    return "$?"
  fi
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    selected="$pid"
    count=$((count + 1))
  done <<< "$pids"
  if [[ "$count" != 1 ]]; then
    echo "error: expected exactly one running process for $bundle; found $count." >&2
    return 1
  fi
  printf '%s\n' "$selected"
}

launch_app_and_resolve_pid() {
  local bundle="${1:-$APP_BUNDLE}"
  open_app "$bundle"
  if ! wait_for_app_bundle "$bundle" 40 0.25; then
    echo "error: $bundle did not start." >&2
    return 1
  fi
  single_app_bundle_pid "$bundle"
}

validate_perf_sample_interval() {
  local interval="$1"
  if ! awk -v value="$interval" 'BEGIN {
    exit (value ~ /^[0-9]+([.][0-9]+)?$/ && value + 0 >= 1 && value + 0 <= 3600) ? 0 : 1
  }'; then
    echo "error: AWESOMUX_PERF_SAMPLE_INTERVAL_SECONDS must be between 1 and 3600 seconds." >&2
    exit 2
  fi
}

validate_perf_sample_ports() {
  local sample_ports="$1"
  if [[ "$sample_ports" != "0" && "$sample_ports" != "1" ]]; then
    echo "error: AWESOMUX_PERF_SAMPLE_PORTS must be 0 or 1." >&2
    exit 2
  fi
}

# perfSampleIntervalSeconds lives in the *running* app's UserDefaults domain,
# which is keyed by its CFBundleIdentifier — so the domain follows the bundle
# we actually launch: the `.dev` dist build for --perf, the production installed
# build for --perf-install. Callers set PERF_DEFAULTS_DOMAIN accordingly; it
# defaults to this run's BUNDLE_ID (the dist identity).
PERF_DEFAULTS_DOMAIN="$BUNDLE_ID"

enable_perf_sampling() {
  PERF_SAMPLE_INTERVAL_SECONDS="${AWESOMUX_PERF_SAMPLE_INTERVAL_SECONDS:-30}"
  PERF_SAMPLE_PORTS="${AWESOMUX_PERF_SAMPLE_PORTS:-0}"
  validate_perf_sample_interval "$PERF_SAMPLE_INTERVAL_SECONDS"
  validate_perf_sample_ports "$PERF_SAMPLE_PORTS"
  defaults write "$PERF_DEFAULTS_DOMAIN" perfSampleIntervalSeconds -float "$PERF_SAMPLE_INTERVAL_SECONDS"
  if [[ "$PERF_SAMPLE_PORTS" == "1" ]]; then
    defaults write "$PERF_DEFAULTS_DOMAIN" perfSamplePorts -bool true
  else
    defaults write "$PERF_DEFAULTS_DOMAIN" perfSamplePorts -bool false
  fi
}

cleanup_perf_defaults() {
  defaults delete "$PERF_DEFAULTS_DOMAIN" perfSampleIntervalSeconds >/dev/null 2>&1 || true
  defaults delete "$PERF_DEFAULTS_DOMAIN" perfSamplePorts >/dev/null 2>&1 || true
}

stream_perf_logs() {
  local pid="$1"
  local port_status="mach_ports disabled"
  if [[ "${PERF_SAMPLE_PORTS:-0}" == "1" ]]; then
    port_status="mach_ports enabled"
  fi
  echo "Streaming awesoMux performance samples every ${PERF_SAMPLE_INTERVAL_SECONDS}s (${port_status}). Quit awesoMux to stop sampling; press Ctrl-C to stop watching logs."
  /usr/bin/log stream --info --style compact \
    --predicate "subsystem == \"$LOG_SUBSYSTEM\" AND processIdentifier == $pid AND (category == \"Performance\" OR category == \"GhosttyRuntimeMemory\")"
}

stream_terminal_diagnostics_logs() {
  local pid="$1"
  echo "Streaming awesoMux terminal diagnostics. Quit awesoMux to stop; press Ctrl-C to stop watching logs."
  /usr/bin/log stream --info --style compact \
    --predicate "subsystem == \"$LOG_SUBSYSTEM\" AND category == \"TerminalDiagnostics\" AND processIdentifier == $pid"
}

stream_shortcut_diagnostics_logs() {
  local pid="$1"
  echo "Streaming awesoMux shortcut diagnostics. Quit awesoMux to stop; press Ctrl-C to stop watching logs."
  /usr/bin/log stream --info --style compact \
    --predicate "subsystem == \"$LOG_SUBSYSTEM\" AND category == \"ShortcutDiagnostics\" AND processIdentifier == $pid"
}

stream_window_diagnostics_logs() {
  local pid="$1"
  echo "Streaming awesoMux window-order diagnostics. Reproduce the flash, then quit awesoMux or press Ctrl-C."
  /usr/bin/log stream --info --style compact \
    --predicate "subsystem == \"$LOG_SUBSYSTEM\" AND category == \"WindowOrderDiagnostics\" AND processIdentifier == $pid"
}

open_supports_env() {
  { /usr/bin/open --help 2>&1 || true; } | grep -q -- --env
}

run_diagnostics() {
  local environment_key="$1"
  local stream_function="$2"
  local description="$3"
  local log_pid="" open_pid="" target_pid="" status=0
  if ! open_supports_env; then
    echo "error: /usr/bin/open on this macOS does not support --env; $description diagnostics cannot inject $environment_key." >&2
    return 2
  fi

  cleanup_diagnostics() {
    if [[ -n "$log_pid" ]]; then
      kill "$log_pid" >/dev/null 2>&1 || true
    fi
    if [[ -n "$open_pid" ]]; then
      kill "$open_pid" >/dev/null 2>&1 || true
    fi
  }

  trap cleanup_diagnostics EXIT INT TERM
  open_bundle -n -W --env "$environment_key=1" "$APP_BUNDLE" &
  open_pid="$!"
  if ! wait_for_app_bundle "$APP_BUNDLE" 40 0.25; then
    echo "error: $APP_BUNDLE did not start for $description diagnostics." >&2
    cleanup_diagnostics
    trap - EXIT INT TERM
    return 1
  fi
  if ! target_pid="$(single_app_bundle_pid "$APP_BUNDLE")"; then
    cleanup_diagnostics
    trap - EXIT INT TERM
    return 1
  fi
  "$stream_function" "$target_pid" &
  log_pid="$!"
  wait "$open_pid" || status="$?"
  open_pid=""
  cleanup_diagnostics
  trap - EXIT INT TERM
  return "$status"
}

run_terminal_diagnostics() {
  run_diagnostics AWESOMUX_TERMINAL_DIAGNOSTICS stream_terminal_diagnostics_logs terminal
}

run_shortcut_diagnostics() {
  run_diagnostics AWESOMUX_SHORTCUT_DIAGNOSTICS stream_shortcut_diagnostics_logs shortcut
}

run_window_diagnostics() {
  run_diagnostics AWESOMUX_WINDOW_ORDER_DIAGNOSTICS stream_window_diagnostics_logs window-order
}

install_app() {
  mkdir -p "$INSTALL_DIR"
  terminate_app_bundle_and_wait "$INSTALLED_APP_BUNDLE"

  if [[ -e "$INSTALLED_APP_BUNDLE" ]]; then
    trash_path "$INSTALLED_APP_BUNDLE"
  fi

  /usr/bin/ditto "$APP_BUNDLE" "$INSTALLED_APP_BUNDLE"
  echo "Installed $INSTALLED_APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    pid="$(launch_app_and_resolve_pid)"
    /usr/bin/log stream --info --style compact --predicate "processIdentifier == $pid"
    ;;
  --telemetry|telemetry)
    pid="$(launch_app_and_resolve_pid)"
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$LOG_SUBSYSTEM\" AND processIdentifier == $pid"
    ;;
  --perf|perf)
    enable_perf_sampling
    trap cleanup_perf_defaults EXIT INT TERM
    pid="$(launch_app_and_resolve_pid)"
    stream_perf_logs "$pid"
    ;;
  --terminal-diagnostics|terminal-diagnostics)
    run_terminal_diagnostics
    ;;
  --shortcut-diagnostics|shortcut-diagnostics)
    run_shortcut_diagnostics
    ;;
  --window-diagnostics|window-diagnostics)
    run_window_diagnostics
    ;;
  --perf-install|perf-install)
    # This mode runs the *installed* production bundle, so the perf default must
    # land in the production UserDefaults domain, not this run's `.dev` BUNDLE_ID.
    PERF_DEFAULTS_DOMAIN="$PROD_BUNDLE_ID"
    enable_perf_sampling
    trap cleanup_perf_defaults EXIT INT TERM
    terminate_app_bundle_and_wait "$INSTALLED_APP_BUNDLE"
    pid="$(launch_app_and_resolve_pid "$INSTALLED_APP_BUNDLE")"
    stream_perf_logs "$pid"
    ;;
  --verify|verify)
    # Pass the bundle explicitly to both calls so the launch target and the
    # poll target can't drift apart. 10s (40 × 0.25s) leaves headroom for a
    # cold libghostty launch under Gatekeeper + Metal warmup on a loaded CI
    # runner; it returns the instant the app appears, so the happy path is free.
    open_app "$APP_BUNDLE"
    if ! wait_for_app_bundle "$APP_BUNDLE" 40; then
      echo "error: $APP_BUNDLE did not start." >&2
      exit 1
    fi
    # Verification succeeded; don't leave the launched app running. Graceful
    # TERM first, then SIGKILL — both path-scoped via app_bundle_pids so the
    # installed copy is never touched. Exit 3 (not 1) so callers can tell
    # "never started" from "started but wouldn't die".
    terminate_app_bundle "$APP_BUNDLE"
    if ! wait_for_app_bundle_exit "$APP_BUNDLE"; then
      echo "warning: $APP_BUNDLE ignored SIGTERM; escalating to SIGKILL." >&2
      terminate_app_bundle "$APP_BUNDLE" KILL
      if ! wait_for_app_bundle_exit "$APP_BUNDLE" 8; then
        echo "error: $APP_BUNDLE is still running after verify cleanup." >&2
        exit 3
      fi
    fi
    ;;
  --malloc-stack-logging|malloc-stack-logging)
    echo "Launching $APP_BINARY directly with MallocStackLogging=1. Run leaks against the awesoMux PID from another terminal."
    MallocStackLogging=1 "$APP_BINARY"
    ;;
  --install|install)
    install_app
    open_app "$INSTALLED_APP_BUNDLE"
    ;;
  --stage-release|stage-release)
    echo "Staged $APP_BUNDLE (production profile; not launched)."
    ;;
  *)
    usage
    exit 2
    ;;
esac
