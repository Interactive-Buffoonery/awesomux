#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 2 ]]; then
  echo "usage: validate_appcast.sh <appcast.xml> <expected-dmg-url>" >&2
  exit 2
fi

APPCAST_PATH="$1"
EXPECTED_DMG_URL="$2"
XMLLINT="/usr/bin/xmllint"
SPARKLE_NAMESPACE="http://www.andymatuschak.org/xml-namespaces/sparkle"

if [[ ! -s "$APPCAST_PATH" ]]; then
  echo "error: appcast is missing or empty: $APPCAST_PATH" >&2
  exit 1
fi
if [[ ! -x "$XMLLINT" ]]; then
  echo "error: xmllint is required to validate the generated appcast" >&2
  exit 1
fi

ENCLOSURE_COUNT="$("$XMLLINT" --nonet --xpath 'count(//*[local-name()="enclosure"])' "$APPCAST_PATH")" || {
  echo "error: appcast is not valid XML: $APPCAST_PATH" >&2
  exit 1
}
if [[ "$ENCLOSURE_COUNT" != "1" ]]; then
  echo "error: appcast must contain exactly one enclosure; found $ENCLOSURE_COUNT" >&2
  exit 1
fi

ACTUAL_DMG_URL="$("$XMLLINT" --nonet --xpath 'string((//*[local-name()="enclosure"])[1]/@url)' "$APPCAST_PATH")"
if [[ "$ACTUAL_DMG_URL" != "$EXPECTED_DMG_URL" ]]; then
  echo "error: appcast has unexpected enclosure URL: $ACTUAL_DMG_URL" >&2
  echo "       expected: $EXPECTED_DMG_URL" >&2
  exit 1
fi

ED_SIGNATURE="$("$XMLLINT" --nonet --xpath \
  "normalize-space((//*[local-name()=\"enclosure\"])[1]/@*[local-name()=\"edSignature\" and namespace-uri()=\"$SPARKLE_NAMESPACE\"])" \
  "$APPCAST_PATH")"
if [[ -z "$ED_SIGNATURE" ]]; then
  echo "error: appcast enclosure must have a nonempty sparkle:edSignature" >&2
  exit 1
fi
