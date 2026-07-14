#!/usr/bin/env bash
# Release build: stage via build_and_run.sh --stage-release, stamp version
# metadata, sign with Developer ID + Hardened Runtime, package, notarize,
# staple, checksum. Policy: docs/adr/0019-macos-distribution-signing-and-sandbox-posture.md
# Checklist context: docs/releasing.md
# Retries rebuild from scratch; add a resume mode only if release cadence
# makes that painful.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="$ROOT_DIR/dist/awesoMux.app"
APP_MACOS="$APP_BUNDLE/Contents/MacOS"
INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"

VERSION=""
BUILD_NUMBER=""
IDENTITY="Developer ID Application"
NOTARY_PROFILE="awesomux-notary"
OUTPUT_DIR="$ROOT_DIR/dist/release"
UNSIGNED=0

usage() {
  cat <<'USAGE'
Usage: script/build_release.sh --version X.Y.Z [options]

Options:
  --version X.Y.Z        Release version (required; becomes CFBundleShortVersionString).
                         Exactly three integers — CFBundleShortVersionString does not
                         accept prerelease suffixes; an rc gets its own numeric version.
  --build-number N       CFBundleVersion (default: git rev-list --count HEAD).
  --identity NAME        Codesign identity (default: "Developer ID Application",
                         which matches the team's Developer ID cert by prefix).
                         Pass the full "Developer ID Application: Name (TEAMID)"
                         string if more than one Developer ID cert is installed.
  --notary-profile NAME  notarytool keychain profile (default: awesomux-notary).
  --output DIR           Artifact directory (default: dist/release).
  --unsigned             Dry run: ad-hoc sign, skip notarization/stapling.
                         Creates an -unsigned.dmg without signing
                         credentials (still requires full Xcode and the
                         amx/Zig toolchain).
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="${2:?--version needs a value}"; shift 2 ;;
    --build-number) BUILD_NUMBER="${2:?--build-number needs a value}"; shift 2 ;;
    --identity) IDENTITY="${2:?--identity needs a value}"; shift 2 ;;
    --notary-profile) NOTARY_PROFILE="${2:?--notary-profile needs a value}"; shift 2 ;;
    --output) OUTPUT_DIR="${2:?--output needs a value}"; shift 2 ;;
    --unsigned) UNSIGNED=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# --output given as a relative path resolves against the repo root, matching
# the default, not against whatever directory invoked the script.
if [[ "$OUTPUT_DIR" != /* ]]; then
  OUTPUT_DIR="$ROOT_DIR/$OUTPUT_DIR"
fi

if [[ -z "$VERSION" ]]; then
  echo "error: --version X.Y.Z is required" >&2
  exit 2
fi
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: --version must be X.Y.Z (three integers; CFBundleShortVersionString rejects suffixes), got: $VERSION" >&2
  exit 2
fi
if [[ -n "$BUILD_NUMBER" && ! "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "error: --build-number must be a positive integer, got: $BUILD_NUMBER" >&2
  exit 2
fi

# Release artifacts must be attributable to one commit — captured here and
# re-asserted after packaging so nothing moves mid-build.
if [[ -n "$(git -C "$ROOT_DIR" status --porcelain)" ]]; then
  echo "error: worktree is not clean; commit or stash before building a release" >&2
  exit 1
fi
RELEASE_COMMIT="$(git -C "$ROOT_DIR" rev-parse HEAD)"

# The commit-count default only works with full history: a shallow checkout
# (e.g. actions/checkout's fetch-depth 1) would yield a CFBundleVersion LOWER
# than earlier releases. Explicit --build-number bypasses the guard.
if [[ -z "$BUILD_NUMBER" ]]; then
  if [[ "$(git -C "$ROOT_DIR" rev-parse --is-shallow-repository)" == "true" ]]; then
    echo "error: shallow checkout — the default build number (commit count) would regress." >&2
    echo "       Fetch full history (git fetch --unshallow) or pass --build-number explicitly." >&2
    exit 1
  fi
  BUILD_NUMBER="$(git -C "$ROOT_DIR" rev-list --count HEAD)"
fi

# Fail before the expensive build, not after it: a fresh machine without the
# signing identity or notary profile should learn that in seconds.
if [[ "$UNSIGNED" -eq 0 ]]; then
  if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
    echo "error: no 'Developer ID Application' identity in the keychain." >&2
    echo "       See docs/releasing.md 'Create required certificates and credentials'." >&2
    exit 1
  fi
  if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "error: notary keychain profile '$NOTARY_PROFILE' is missing or not working." >&2
    echo "       Create it with: xcrun notarytool store-credentials $NOTARY_PROFILE --key <AuthKey.p8> --key-id <ID> --issuer <ISSUER>" >&2
    exit 1
  fi
fi

# Pin the Ghostty optimize mode: ensure_ghostty_artifacts.sh verifies the
# cached archive against AWESOMUX_GHOSTTY_OPTIMIZE itself, so a Debug value
# leaked from a debugging shell would pass its own check and ship a Debug
# Ghostty. Releases are always ReleaseFast.
export AWESOMUX_GHOSTTY_OPTIMIZE=ReleaseFast

# SwiftPM does not reliably relink when the Ghostty archive under
# .build/ghostty changes content (known gap in this repo) — remove the cached
# release product so an exact-pin Ghostty rebuild cannot ship a stale-linked
# binary that passes every downstream check.
rm -f "$ROOT_DIR/.build/release/awesoMux"

"$ROOT_DIR/script/build_and_run.sh" --stage-release

# The staging script only warns when actool (full Xcode) is missing; a
# release bundle without the composed icon is not shippable.
if [[ ! -f "$APP_BUNDLE/Contents/Resources/AppIcon.icns" ]]; then
  echo "error: AppIcon.icns missing from staged bundle — release builds need full Xcode (actool)" >&2
  exit 1
fi
for exe in awesoMux awesoMuxAgentHook awesoMuxBridgeHelper amx; do
  if [[ ! -x "$APP_MACOS/$exe" ]]; then
    echo "error: $exe missing from staged bundle" >&2
    if [[ "$exe" == "amx" ]]; then
      echo "       Build it with: ./script/build_amx.sh (requires the vendor/zmx submodule and a Zig toolchain)" >&2
    else
      echo "       Rebuild with: swift build -c release (then re-run this script)" >&2
    fi
    exit 1
  fi
done

# dist/awesoMux.app is shared with every build_and_run.sh mode; a dev build
# started during the (long) notarization wait would mutate it mid-release.
# Work on a private copy so nothing can race the release.
RELEASE_WORK_DIR="$(mktemp -d -t awesomux-release-work)"
DMG_SOURCE_DIR="$RELEASE_WORK_DIR/dmg-root"
DMG_MOUNT=""
cleanup() {
  if [[ -n "${DMG_MOUNT:-}" ]]; then
    hdiutil detach "$DMG_MOUNT" -quiet >/dev/null 2>&1 || true
  fi
  rm -rf "${RELEASE_WORK_DIR:-}" "${VALIDATE_DIR:-}" 2>/dev/null || true
}
trap cleanup EXIT
mkdir -p "$DMG_SOURCE_DIR"
/usr/bin/ditto "$APP_BUNDLE" "$DMG_SOURCE_DIR/awesoMux.app"
ln -s /Applications "$DMG_SOURCE_DIR/Applications"
APP_BUNDLE="$DMG_SOURCE_DIR/awesoMux.app"
APP_MACOS="$APP_BUNDLE/Contents/MacOS"
INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"

# Strip stray extended attributes (quarantine, Finder metadata) before
# signing so none ride into the notarized archive.
xattr -cr "$APP_BUNDLE"

# Delete-then-Add keeps this idempotent if staging ever starts supplying
# version keys of its own.
for key in CFBundleShortVersionString CFBundleVersion; do
  /usr/libexec/PlistBuddy -c "Delete :$key" "$INFO_PLIST" 2>/dev/null || true
done
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $VERSION" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $BUILD_NUMBER" "$INFO_PLIST"

# Sign inside-out: helpers first, then the bundle (which covers the main
# executable). Hardened Runtime, no entitlements (ADR-0019). Ad-hoc
# signatures cannot carry secure timestamps, so --timestamp is signed-only.
SIGN_ARGS=(--force --options runtime)
if [[ "$UNSIGNED" -eq 1 ]]; then
  SIGN_ARGS+=(--sign -)
else
  SIGN_ARGS+=(--timestamp --sign "$IDENTITY")
fi
for exe in amx awesoMuxAgentHook awesoMuxBridgeHelper; do
  codesign "${SIGN_ARGS[@]}" "$APP_MACOS/$exe"
done
codesign "${SIGN_ARGS[@]}" "$APP_BUNDLE"

codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

# ADR-0019: entitlements start empty — on every signed executable, not just
# the outer bundle. Fail loudly if any sneak in.
for target in "$APP_BUNDLE" "$APP_MACOS/awesoMux" "$APP_MACOS/awesoMuxAgentHook" "$APP_MACOS/awesoMuxBridgeHelper" "$APP_MACOS/amx"; do
  entitlements_xml="$(codesign -d --entitlements - --xml "$target" 2>/dev/null)" || {
    echo "error: could not read entitlements for $target" >&2
    exit 1
  }
  if grep -q '<key>' <<<"$entitlements_xml"; then
    echo "error: $target carries entitlements; ADR-0019 requires none without documented evidence" >&2
    exit 1
  fi
done

if [[ "$UNSIGNED" -eq 0 ]]; then
  # Assert the signature is the one we meant: Developer ID authority, secure
  # timestamp, Hardened Runtime — before spending a notarization round-trip.
  SIGN_INFO="$(codesign -dvvv "$APP_BUNDLE" 2>&1)"
  for want in "Authority=Developer ID Application" "Timestamp=" "runtime"; do
    if ! grep -q "$want" <<<"$SIGN_INFO"; then
      echo "error: bundle signature missing expected marker: $want" >&2
      echo "$SIGN_INFO" >&2
      exit 1
    fi
  done
fi

mkdir -p "$OUTPUT_DIR"
DMG_SUFFIX=""
if [[ "$UNSIGNED" -eq 1 ]]; then
  DMG_SUFFIX="-unsigned"
fi
DMG_PATH="$OUTPUT_DIR/awesoMux-$VERSION$DMG_SUFFIX.dmg"
rm -f "$DMG_PATH" "$DMG_PATH.sha256"
hdiutil create \
  -volname awesoMux \
  -srcfolder "$DMG_SOURCE_DIR" \
  -format UDZO \
  -ov \
  "$DMG_PATH"
hdiutil verify "$DMG_PATH"

if [[ "$UNSIGNED" -eq 0 ]]; then
  codesign --force --timestamp --sign "$IDENTITY" "$DMG_PATH"
  codesign --verify --verbose=2 "$DMG_PATH"

  NOTARY_STDERR="$OUTPUT_DIR/notarytool-submit-$VERSION.stderr.log"
  rm -f "$NOTARY_STDERR"
  echo "Submitting $DMG_PATH for notarization (profile: $NOTARY_PROFILE)..."
  # Submit WITHOUT --wait so the submission id lands on disk immediately — a
  # Ctrl-C or dropped connection during the (potentially 45-minute) wait must
  # not lose the id of a submission Apple already has. plutil parses the JSON
  # structurally; notarytool's whitespace style varies across versions.
  set +e
  SUBMIT_JSON="$(xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" \
    --output-format json 2>"$NOTARY_STDERR")"
  SUBMIT_EXIT=$?
  set -e
  SUBMISSION_ID="$(plutil -extract id raw -o - - <<<"$SUBMIT_JSON" 2>/dev/null || true)"
  if [[ "$SUBMIT_EXIT" -ne 0 || -z "$SUBMISSION_ID" ]]; then
    echo "error: notarization submission failed (exit=$SUBMIT_EXIT)." >&2
    echo "$SUBMIT_JSON" >&2
    cat "$NOTARY_STDERR" >&2 || true
    exit 1
  fi
  echo "$SUBMISSION_ID" > "$OUTPUT_DIR/notarytool-submission-id-$VERSION.txt"
  echo "Submission id: $SUBMISSION_ID (waiting up to 45m; safe to Ctrl-C and resume with: xcrun notarytool wait $SUBMISSION_ID --keychain-profile $NOTARY_PROFILE)"

  set +e
  WAIT_JSON="$(xcrun notarytool wait "$SUBMISSION_ID" --keychain-profile "$NOTARY_PROFILE" \
    --timeout 45m --output-format json 2>>"$NOTARY_STDERR")"
  WAIT_EXIT=$?
  set -e
  SUBMIT_STATUS="$(plutil -extract status raw -o - - <<<"$WAIT_JSON" 2>/dev/null || true)"
  if [[ "$WAIT_EXIT" -ne 0 || "$SUBMIT_STATUS" != "Accepted" ]]; then
    echo "error: notarization not accepted (exit=$WAIT_EXIT, status=${SUBMIT_STATUS:-unknown})." >&2
    echo "$WAIT_JSON" >&2
    cat "$NOTARY_STDERR" >&2 || true
    echo "       Inspect with: xcrun notarytool log $SUBMISSION_ID --keychain-profile $NOTARY_PROFILE" >&2
    echo "       Do NOT add entitlements speculatively; capture the failure first (ADR-0019)." >&2
    exit 1
  fi
  # Fetch the log even on success — Apple surfaces nested-code warnings only
  # there. Kept as a release artifact; fetch failure is non-fatal.
  xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$NOTARY_PROFILE" \
    "$OUTPUT_DIR/notarization-log-$VERSION.json" \
    || echo "warning: could not fetch notarization log for $SUBMISSION_ID" >&2
  rm -f "$NOTARY_STDERR"

  # The DMG is the outermost distributed container, so notarize and staple it
  # directly. Gatekeeper can then verify the download without network access.
  xcrun stapler staple "$DMG_PATH"
fi

# Checksum the final artifact first — its validity does not depend on the
# assessment below, and a transient validation failure must not leave the
# artifact unchecksummed.
hdiutil verify "$DMG_PATH"
(cd "$OUTPUT_DIR" && shasum -a 256 "$(basename "$DMG_PATH")" > "$(basename "$DMG_PATH").sha256")

# Validate the exact artifact users will download, not the staging copy:
# mount the final DMG read-only and assess its app. Runs in both modes; only
# the Gatekeeper/staple checks need real signing.
VALIDATE_DIR="$(mktemp -d -t awesomux-release-validate)"
DMG_MOUNT="$VALIDATE_DIR/mount"
mkdir -p "$DMG_MOUNT"
hdiutil attach "$DMG_PATH" -readonly -nobrowse -noautoopen -mountpoint "$DMG_MOUNT"
codesign --verify --deep --strict "$DMG_MOUNT/awesoMux.app"
if [[ "$UNSIGNED" -eq 0 ]]; then
  echo "Assessing Gatekeeper acceptance (a failure right after stapling can be transient ticket propagation — re-running this step in a minute is safe; the DMG is already built)..."
  spctl --assess --type execute --verbose "$DMG_MOUNT/awesoMux.app"
  xcrun stapler validate "$DMG_PATH"
fi
hdiutil detach "$DMG_MOUNT" -quiet
DMG_MOUNT=""

# Source-to-artifact binding: the build must not have dirtied tracked files,
# and HEAD must still be the commit captured above — the tag in the release
# flow points at exactly this commit.
if [[ -n "$(git -C "$ROOT_DIR" status --porcelain | grep -v '^??' || true)" || "$(git -C "$ROOT_DIR" rev-parse HEAD)" != "$RELEASE_COMMIT" ]]; then
  echo "error: worktree or HEAD changed during the build; artifact is not attributable to $RELEASE_COMMIT" >&2
  exit 1
fi

echo
echo "Release artifact: $DMG_PATH"
echo "Checksum:         $DMG_PATH.sha256"
echo "Version:          $VERSION ($BUILD_NUMBER)"
echo "Commit:           $RELEASE_COMMIT  <- tag exactly this"
if [[ "$UNSIGNED" -eq 1 ]]; then
  echo "Mode:             UNSIGNED dry run — not distributable"
fi
