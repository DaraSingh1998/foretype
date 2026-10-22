#!/usr/bin/env bash
# Builds a release: <out>/Foretype-<version>.dmg (the app, with the Sparkle updater, next to an
# Applications link), its .sha256, the update feed appcast.xml and the Homebrew cask.
#
#   FORETYPE_SPARKLE_KEY_FILE  Sparkle EdDSA private key (tools/sparkle/edkey.swift format: the
#                              base64 32-byte seed). When set, the DMG is signed and appcast.xml
#                              written; the release workflow passes it from a secret.
#   FORETYPE_DOWNLOAD_BASE     Where the DMG will be served (default: this version's GitHub
#                              release, https://github.com/DaraSingh1998/foretype/releases/download/v<version>).
#   FORETYPE_SIGN_IDENTITY     As in build-mac.sh. With a Developer ID the DMG is signed too.
#   FORETYPE_NOTARY_PROFILE    Keychain profile from `xcrun notarytool store-credentials`: notarize
#                              and staple (needs a Developer ID; releases are self-signed today).
#   FORETYPE_OUT               Output folder (default: build/).
#   Plus everything scripts/build-mac.sh reads (FORETYPE_VERSION, FORETYPE_FEED_URL, ...).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${FORETYPE_OUT:-$ROOT/build}"
REPO="DaraSingh1998/foretype"
export FORETYPE_SPARKLE="${FORETYPE_SPARKLE:-1}"
"$ROOT/scripts/build-mac.sh"

APP="$OUT/Foretype.app"
plist() { /usr/libexec/PlistBuddy -c "Print $1" "$APP/Contents/Info.plist"; }
VERSION="$(plist CFBundleShortVersionString)"
BUILD="$(plist CFBundleVersion)"
DMG="$OUT/Foretype-$VERSION.dmg"
WORK="$(mktemp -d "$OUT/dmg.XXXXXX")"
STAGE="$WORK/Foretype"
trap '[ -d "$WORK/mnt" ] && hdiutil detach -force "$WORK/mnt" >/dev/null 2>&1; rm -rf "$WORK"' EXIT
mkdir "$STAGE"
ditto "$APP" "$STAGE/Foretype.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
if command -v SetFile >/dev/null 2>&1; then
  # The volume icon: .VolumeIcon.icns at the root and the root's custom-icon flag, which only
  # sticks when set on the mounted volume, so this goes through a read-write image. SetFile
  # comes with the Command Line Tools; without it the disk image keeps the generic icon.
  cp "$ROOT/mac/Resources/AppIcon.icns" "$STAGE/.VolumeIcon.icns"
  hdiutil create -volname "Foretype $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$WORK/rw.dmg" >/dev/null
  mkdir "$WORK/mnt"
  hdiutil attach -nobrowse -noautoopen -mountpoint "$WORK/mnt" "$WORK/rw.dmg" >/dev/null
  SetFile -a C "$WORK/mnt"
  hdiutil detach "$WORK/mnt" >/dev/null
  rmdir "$WORK/mnt"
  hdiutil convert "$WORK/rw.dmg" -format UDZO -o "$DMG" >/dev/null
else
  hdiutil create -volname "Foretype $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
fi
hdiutil verify "$DMG" >/dev/null

case "${FORETYPE_SIGN_IDENTITY:-}" in
  "Developer ID Application:"*) codesign --force --timestamp --sign "$FORETYPE_SIGN_IDENTITY" "$DMG" ;;
esac
if [ -n "${FORETYPE_NOTARY_PROFILE:-}" ]; then
  case "${FORETYPE_SIGN_IDENTITY:-}" in
    "Developer ID Application:"*) ;;
    *) echo "notarization needs a Developer ID (FORETYPE_SIGN_IDENTITY)"; exit 1 ;;
  esac
  xcrun notarytool submit "$DMG" --keychain-profile "$FORETYPE_NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose "$DMG"
fi

SHA="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
echo "$SHA  $(basename "$DMG")" >"$DMG.sha256"
SIZE="$(stat -f%z "$DMG")"

if [ -n "${FORETYPE_SPARKLE_KEY_FILE:-}" ]; then
  SIG="$(swift "$ROOT/tools/sparkle/edkey.swift" sign "$FORETYPE_SPARKLE_KEY_FILE" "$DMG")"
  BASE="${FORETYPE_DOWNLOAD_BASE:-https://github.com/$REPO/releases/download/v$VERSION}"
  NOTES=""
  [ -z "${FORETYPE_DOWNLOAD_BASE:-}" ] && NOTES="
    <sparkle:releaseNotesLink>https://github.com/$REPO/releases/tag/v$VERSION</sparkle:releaseNotesLink>"
  # One item: each release uploads its own appcast.xml, and the apps read the latest
  # release's (SUFeedURL .../releases/latest/download/appcast.xml).
  cat >"$OUT/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
<channel>
  <title>Foretype</title>
  <item>
    <title>Foretype $VERSION</title>
    <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
    <sparkle:version>$BUILD</sparkle:version>
    <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
    <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>$NOTES
    <enclosure url="$BASE/Foretype-$VERSION.dmg" $SIG type="application/octet-stream"/>
  </item>
</channel>
</rss>
XML
  xmllint --noout "$OUT/appcast.xml"
  echo "appcast: $OUT/appcast.xml (build $BUILD)"
else
  echo "appcast: not written (set FORETYPE_SPARKLE_KEY_FILE)"
fi

sed -e "s/@VERSION@/$VERSION/" -e "s/@SHA256@/$SHA/" "$ROOT/packaging/homebrew/foretype.rb.in" >"$OUT/foretype.rb"
echo "dmg: $DMG ($SIZE bytes, sha256 $SHA)"
echo "homebrew cask: $OUT/foretype.rb"
