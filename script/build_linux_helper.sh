#!/usr/bin/env bash
# Cross-compiles the static Linux bridge helper for both supported
# architectures. Needs a swift.org toolchain matching .swift-version —
# Xcode's toolchain cannot use the Static Linux SDK.
set -euo pipefail
cd "$(dirname "$0")/.."

SWIFT_VERSION="$(cat .swift-version)"
# Static Linux SDK pin — MUST move in lockstep with .swift-version
# (docs/toolchain.md). URL and checksum verified against
# https://www.swift.org/documentation/articles/static-linux-getting-started.html
# and independently re-derived with `shasum -a 256` on the downloaded
# artifactbundle; reviewed on bump like .github/swift-toolchain-checksums.txt rows.
SDK_URL="https://download.swift.org/swift-6.3.3-release/static-sdk/swift-6.3.3-RELEASE/swift-6.3.3-RELEASE_static-linux-0.1.0.artifactbundle.tar.gz"
SDK_CHECKSUM="87c3eaf908e67c0e13a84367119e12273cec1d2cd3d81f7d74bb36722d6b607b"
SDK_ID_PREFIX="swift-${SWIFT_VERSION}-RELEASE_static-linux"

# `Apple Swift version 6.3.3 (swiftlang-...)` (Xcode) contains the substring
# "Swift version 6.3.3" too, so match the OSS release tag specifically —
# it's the only banner format that carries the Static Linux SDK.
if ! swift --version 2>/dev/null | grep -q "swift-${SWIFT_VERSION}-RELEASE"; then
  echo "error: active toolchain is not the swift.org Swift ${SWIFT_VERSION} release." >&2
  echo "       Install via swiftly (https://www.swift.org/install) and retry;" >&2
  echo "       the Xcode toolchain cannot consume the Static Linux SDK." >&2
  exit 1
fi

if ! swift sdk list 2>/dev/null | grep -q "${SDK_ID_PREFIX}"; then
  swift sdk install "${SDK_URL}" --checksum "${SDK_CHECKSUM}"
fi

checksum() {
  if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi
}

mkdir -p dist/linux-helper
for arch in x86_64 aarch64; do
  swift build -c release --product awesoMuxBridgeHelper --swift-sdk "${arch}-swift-linux-musl"
  out="dist/linux-helper/awesomux-bridge-helper-linux-${arch}"
  install -m 0755 ".build/${arch}-swift-linux-musl/release/awesoMuxBridgeHelper" "${out}"
  (cd dist/linux-helper && checksum "$(basename "${out}")" > "$(basename "${out}").sha256")
done

echo "Built:"
ls -l dist/linux-helper/
