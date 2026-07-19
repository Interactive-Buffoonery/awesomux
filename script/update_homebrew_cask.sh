#!/usr/bin/env bash
set -euo pipefail

VERSION=""
SHA256=""
CASK_PATH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="${2:?--version needs a value}"; shift 2 ;;
    --sha256) SHA256="${2:?--sha256 needs a value}"; shift 2 ;;
    --cask) CASK_PATH="${2:?--cask needs a value}"; shift 2 ;;
    *) echo "error: unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$VERSION" || -z "$SHA256" || -z "$CASK_PATH" ]]; then
  echo "error: --version, --sha256, and --cask are required" >&2
  exit 2
fi
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: --version must be X.Y.Z, got: $VERSION" >&2
  exit 2
fi
if [[ ! "$SHA256" =~ ^[0-9a-f]{64}$ ]]; then
  echo "error: --sha256 must be 64 lowercase hexadecimal characters" >&2
  exit 2
fi
if [[ ! -f "$CASK_PATH" ]]; then
  echo "error: cask not found: $CASK_PATH" >&2
  exit 1
fi

VERSION_LINES="$(grep -Ec '^  version "[^"]+"$' "$CASK_PATH" || true)"
SHA256_LINES="$(grep -Ec '^  sha256 "[0-9a-f]{64}"$' "$CASK_PATH" || true)"
if [[ "$VERSION_LINES" -ne 1 || "$SHA256_LINES" -ne 1 ]]; then
  echo "error: expected exactly one version and one SHA-256 field in $CASK_PATH" >&2
  exit 1
fi

VERSION="$VERSION" SHA256="$SHA256" perl -pi -e '
  s/^  version "[^"]+"$/  version "$ENV{VERSION}"/;
  s/^  sha256 "[0-9a-f]+"$/  sha256 "$ENV{SHA256}"/;
' "$CASK_PATH"
