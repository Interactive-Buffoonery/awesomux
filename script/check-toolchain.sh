#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

case "$(uname -s)" in
    Darwin)
        if [[ -n "${SWIFT_EXEC:-}${SWIFT_EXEC_MANIFEST:-}" ]]; then
            echo "error: native builds require the Xcode compiler; unset SWIFT_EXEC and SWIFT_EXEC_MANIFEST" >&2
            exit 1
        fi
        if [[ -n "${TOOLCHAINS:-}" && "$TOOLCHAINS" != "com.apple.dt.toolchain.XcodeDefault" ]]; then
            echo "error: native builds require the default Xcode toolchain; unset TOOLCHAINS or use com.apple.dt.toolchain.XcodeDefault" >&2
            exit 1
        fi
        formatter_platform="darwin"
        expected_swift_version="$(tr -d '[:space:]' < "$ROOT_DIR/.swift-version-macos")"
        expected_xcode_version="$(tr -d '[:space:]' < "$ROOT_DIR/.xcode-version")"
        actual_xcode_version="$(xcodebuild -version | awk '/^Xcode / { print $2 }')"
        actual_sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
        if [[ "$actual_xcode_version" != "$expected_xcode_version" || "${actual_sdk_version%%.*}" != "${expected_xcode_version%%.*}" ]]; then
            echo "error: Xcode $expected_xcode_version with macOS ${expected_xcode_version%%.*} SDK is required; found Xcode $actual_xcode_version, SDK $actual_sdk_version" >&2
            exit 1
        fi
        ;;
    Linux)
        formatter_platform="linux"
        expected_swift_version="$(tr -d '[:space:]' < "$ROOT_DIR/.swift-version")"
        ;;
    *)
        echo "error: unsupported formatter platform: $(uname -s)" >&2
        exit 1
        ;;
esac
expected_formatter_version="$(awk -F= -v platform="$formatter_platform" '$1 == platform { print $2 }' "$ROOT_DIR/.swift-format-version")"
if [[ -z "$expected_formatter_version" ]]; then
    echo "error: no swift-format version is pinned for $formatter_platform" >&2
    exit 1
fi
if swift_version_output="$(swift --version 2>&1)"; then
    :
else
    probe_status=$?
    printf 'error: PATH Swift version probe failed (exit %s)\n%s\n' "$probe_status" "$swift_version_output" >&2
    exit "$probe_status"
fi
if [[ "$formatter_platform" == darwin ]]; then
    if selected_swift_version_output="$(xcrun swift --version 2>&1)"; then
        :
    else
        probe_status=$?
        printf 'error: selected Xcode Swift version probe failed (exit %s)\n%s\n' "$probe_status" "$selected_swift_version_output" >&2
        exit "$probe_status"
    fi
    if [[ "$swift_version_output" != "$selected_swift_version_output" ]]; then
        echo "error: PATH Swift differs from the selected Xcode toolchain; check PATH, DEVELOPER_DIR, and TOOLCHAINS" >&2
        exit 1
    fi
fi
actual_swift_version="$(sed -nE 's/.*Swift version ([^ ]+).*/\1/p' <<< "$swift_version_output" | head -1)"

if [[ "$actual_swift_version" != "$expected_swift_version" ]]; then
    echo "error: Swift $expected_swift_version is required" >&2
    echo "Found: $(head -1 <<< "$swift_version_output")" >&2
    exit 1
fi

if ! swift format --version >/dev/null 2>&1; then
    echo "error: the toolchain-integrated 'swift format' command is unavailable" >&2
    exit 1
fi

actual_formatter_version="$(swift format --version | tr -d '[:space:]')"
if [[ "$actual_formatter_version" != "$expected_formatter_version" ]]; then
    echo "error: swift-format $expected_formatter_version is required; found $actual_formatter_version" >&2
    exit 1
fi

echo "Toolchain versions match: Swift $expected_swift_version, swift-format $expected_formatter_version"
