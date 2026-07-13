#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

expected_swift_version="$(tr -d '[:space:]' < "$ROOT_DIR/.swift-version")"
case "$(uname -s)" in
    Darwin) formatter_platform="darwin" ;;
    Linux) formatter_platform="linux" ;;
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
swift_version_output="$(swift --version)"
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
