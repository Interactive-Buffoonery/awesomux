#!/usr/bin/env bash
# Release build: stage via build_and_run.sh --stage-release, stamp version
# metadata, sign with Developer ID + Hardened Runtime, package, notarize,
# staple, checksum. Policy: docs/adr/0019-macos-distribution-signing-and-sandbox-posture.md
# Checklist context: docs/releasing.md
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
                         Lets contributors exercise the packaging path
                         without release credentials.
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

BUILD_NUMBER="${BUILD_NUMBER:-$(git -C "$ROOT_DIR" rev-list --count HEAD)}"

# Pin the Ghostty optimize mode: ensure_ghostty_artifacts.sh verifies the
# cached archive against AWESOMUX_GHOSTTY_OPTIMIZE itself, so a Debug value
# leaked from a debugging shell would pass its own check and ship a Debug
# Ghostty. Releases are always ReleaseFast.
export AWESOMUX_GHOSTTY_OPTIMIZE=ReleaseFast

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
    exit 1
  fi
done

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
  if codesign -d --entitlements - --xml "$target" 2>/dev/null | grep -q '<key>'; then
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
ZIP_PATH="$OUTPUT_DIR/awesoMux-$VERSION.zip"
rm -f "$ZIP_PATH" "$ZIP_PATH.sha256"
# ditto -c -k --keepParent is the only supported archiver here: it preserves
# the signed bundle byte-for-byte (resource forks, symlinks, permissions).
/usr/bin/ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP_PATH"

if [[ "$UNSIGNED" -eq 0 ]]; then
  echo "Submitting $ZIP_PATH for notarization (profile: $NOTARY_PROFILE)..."
  # Structured output + preserved exit code: Apple warns against scraping
  # notarytool's human-readable messages, and set -e would otherwise kill the
  # script before the diagnosis guidance below prints.
  NOTARY_STDERR="$OUTPUT_DIR/notarytool-submit.stderr.log"
  set +e
  SUBMIT_JSON="$(xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARY_PROFILE" \
    --wait --timeout 45m --output-format json 2>"$NOTARY_STDERR")"
  SUBMIT_EXIT=$?
  set -e
  # notarytool pretty-prints its JSON ("status": "Accepted", space after the
  # colon) — the patterns must allow optional whitespace.
  SUBMISSION_ID="$(sed -n 's/.*"id": *"\([0-9a-f-]*\)".*/\1/p' <<<"$SUBMIT_JSON" | head -1)"
  SUBMIT_STATUS="$(sed -n 's/.*"status": *"\([^"]*\)".*/\1/p' <<<"$SUBMIT_JSON" | head -1)"
  if [[ "$SUBMIT_EXIT" -ne 0 || "$SUBMIT_STATUS" != "Accepted" ]]; then
    echo "error: notarization not accepted (exit=$SUBMIT_EXIT, status=${SUBMIT_STATUS:-unknown})." >&2
    echo "$SUBMIT_JSON" >&2
    cat "$NOTARY_STDERR" >&2 || true
    echo "       Inspect with: xcrun notarytool log ${SUBMISSION_ID:-<submission-id>} --keychain-profile $NOTARY_PROFILE" >&2
    echo "       Resume a timed-out wait with: xcrun notarytool wait ${SUBMISSION_ID:-<submission-id>} --keychain-profile $NOTARY_PROFILE" >&2
    echo "       Do NOT add entitlements speculatively; capture the failure first (ADR-0019)." >&2
    exit 1
  fi
  # Fetch the log even on success — Apple surfaces nested-code warnings only
  # there. Kept as a release artifact; fetch failure is non-fatal.
  xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$NOTARY_PROFILE" \
    "$OUTPUT_DIR/notarization-log-$VERSION.json" \
    || echo "warning: could not fetch notarization log for $SUBMISSION_ID" >&2
  rm -f "$NOTARY_STDERR"

  # A zip cannot be stapled. Staple the .app, then rebuild the archive so the
  # distributed zip contains the ticket. Skipping the re-zip ships an
  # unstapled archive that still passes ONLINE Gatekeeper checks but fails
  # offline — easy to miss.
  xcrun stapler staple "$APP_BUNDLE"
  rm -f "$ZIP_PATH"
  /usr/bin/ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP_PATH"

  # Validate the exact artifact users will download, not the staging copy:
  # extract the final zip fresh and assess that.
  VALIDATE_DIR="$(mktemp -d -t awesomux-release-validate)"
  /usr/bin/ditto -x -k "$ZIP_PATH" "$VALIDATE_DIR"
  codesign --verify --deep --strict "$VALIDATE_DIR/awesoMux.app"
  spctl --assess --type execute --verbose "$VALIDATE_DIR/awesoMux.app"
  xcrun stapler validate "$VALIDATE_DIR/awesoMux.app"
  rm -rf "$VALIDATE_DIR"
fi

(cd "$OUTPUT_DIR" && shasum -a 256 "$(basename "$ZIP_PATH")" > "$(basename "$ZIP_PATH").sha256")

# Source-to-artifact binding: the build must not have dirtied tracked files,
# and HEAD must still be the commit captured above — the tag in the release
# flow points at exactly this commit.
if [[ -n "$(git -C "$ROOT_DIR" status --porcelain)" || "$(git -C "$ROOT_DIR" rev-parse HEAD)" != "$RELEASE_COMMIT" ]]; then
  echo "error: worktree or HEAD changed during the build; artifact is not attributable to $RELEASE_COMMIT" >&2
  exit 1
fi

echo
echo "Release artifact: $ZIP_PATH"
echo "Checksum:         $ZIP_PATH.sha256"
echo "Version:          $VERSION ($BUILD_NUMBER)"
echo "Commit:           $RELEASE_COMMIT  <- tag exactly this"
if [[ "$UNSIGNED" -eq 1 ]]; then
  echo "Mode:             UNSIGNED dry run — not distributable"
fi
