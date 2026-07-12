#!/usr/bin/env bash
#
# Canonical Ghostty archive list for the artifact scripts. Package.swift cannot
# source shell files, so script/check_ghostty_archive_drift.sh fails preflight
# when its linker flags drift from this list.

GHOSTTY_LINK_ARCHIVES=(
  libghostty-fat.a
)

ghostty_link_archive_source_name() {
  local archive="$1"

  case "$archive" in
    libghostty-fat.a)
      echo "libghostty-internal-fat.a"
      ;;
    *)
      echo "$archive"
      ;;
  esac
}

ghostty_link_archive_dest_path() {
  local archive="$1"

  echo "GhosttyKit.xcframework/macos-arm64/$archive"
}
