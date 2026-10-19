#!/usr/bin/env bash
# Builds build/Foretype-<version>.dmg for distribution.
#
#   FORETYPE_SIGN_IDENTITY   Developer ID Application identity (required for notarization).
#   FORETYPE_NOTARY_PROFILE  Keychain profile from `xcrun notarytool store-credentials`. When set,
#                            the DMG is notarized and the ticket stapled; otherwise it is left
#                            unnotarized (fine for local testing; Gatekeeper will warn others).
#   SPARKLE_BIN              Directory with Sparkle's sign_update (from the Sparkle release
#                            tarball). When set, writes the EdDSA signature for the appcast.
#   Plus everything scripts/build-mac.sh reads (FORETYPE_SPARKLE, FORETYPE_FEED_URL, ...).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/build-mac.sh"

APP="$ROOT/build/Foretype.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="$ROOT/build/Foretype-$VERSION.dmg"
STAGE="$(mktemp -d "$ROOT/build/dmg.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/Foretype.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Foretype $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
hdiutil verify "$DMG" >/dev/null

if [ -n "${FORETYPE_SIGN_IDENTITY:-}" ]; then
  codesign --force --timestamp --sign "$FORETYPE_SIGN_IDENTITY" "$DMG"
fi
if [ -n "${FORETYPE_NOTARY_PROFILE:-}" ]; then
  [ -n "${FORETYPE_SIGN_IDENTITY:-}" ] || { echo "notarization needs FORETYPE_SIGN_IDENTITY (Developer ID)"; exit 1; }
  xcrun notarytool submit "$DMG" --keychain-profile "$FORETYPE_NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose "$DMG"
  NOTARIZED=yes
else
  NOTARIZED="no (set FORETYPE_NOTARY_PROFILE)"
fi

SHA="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
echo "$SHA  $(basename "$DMG")" >"$DMG.sha256"
SIZE="$(stat -f%z "$DMG")"

if [ -n "${SPARKLE_BIN:-}" ]; then
  SIG="$("$SPARKLE_BIN/sign_update" "$DMG")"
  cat >"$ROOT/build/appcast-item.xml" <<XML
<item>
  <title>Foretype $VERSION</title>
  <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
  <sparkle:version>$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Contents/Info.plist")</sparkle:version>
  <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
  <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
  <enclosure url="https://github.com/OWNER/foretype/releases/download/v$VERSION/Foretype-$VERSION.dmg" $SIG type="application/octet-stream"/>
</item>
XML
  echo "appcast item: build/appcast-item.xml (replace OWNER)"
fi

sed -e "s/@VERSION@/$VERSION/" -e "s/@SHA256@/$SHA/" "$ROOT/packaging/homebrew/foretype.rb.in" >"$ROOT/build/foretype.rb"
echo "dmg: $DMG ($SIZE bytes, sha256 $SHA)"
echo "notarized: $NOTARIZED"
echo "homebrew cask: build/foretype.rb"
