#!/bin/bash
# Builds Wingman as a downloadable .dmg for leinerud.se (outside the Mac App Store).
#
#   ./Scripts/direct.sh local    universal build in a .dmg, signed ad hoc: to check the .dmg looks right.
#                                Other people's Macs will refuse to open it. Don't publish this one.
#   ./Scripts/direct.sh release  signed with your Developer ID, notarized by Apple and stapled: publish this.
#
# `release` needs:
#   a "Developer ID Application" certificate in your keychain (found automatically; or set DEV_ID_CERT)
#   a notarytool keychain profile (wingman-notary, or the one NotchPet or Markd use; or set NOTARY_PROFILE)
#   what's new in this version, in Resources/ReleaseNotes/<version>.html (a few lines of HTML)
#
# `release` copies the .dmg into the website repo (SITE, default ../../Web sites/leinerud.se) and adds the
# version to public/wingman/appcast.xml there, which the app page reads for "What's new". Then point
# downloadUrl in src/content/apps/wingman.md at the new file, and commit and push the website.
#
# The version is MARKETING_VERSION and CURRENT_PROJECT_VERSION in the Xcode project. Raise both first.
# The app stays sandboxed, like in Xcode, and uses the hardened runtime, which notarization requires.
# The finished .dmg goes into build/direct (ignored by git).
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-}"
case "$MODE" in local|release) ;; *) sed -n '2,18p' "$0"; exit 64 ;; esac

# Built and signed outside iCloud Drive: it adds file attributes that codesign refuses.
WORK="$(mktemp -d /tmp/wingman-direct.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
OUT="build/direct"
SITE="${SITE:-../../Web sites/leinerud.se}"
setting() { sed -n "s/.*$1 = \(.*\);/\1/p" Wingman.xcodeproj/project.pbxproj | head -1; }
VERSION="$(setting MARKETING_VERSION)"
BUILD="$(setting CURRENT_PROJECT_VERSION)"
DMG="$OUT/Wingman-$VERSION.dmg"
NOTES="Resources/ReleaseNotes/$VERSION.html"

if [ "$MODE" = release ]; then
  IDENTITY="${DEV_ID_CERT:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)}"
  [ -n "$IDENTITY" ] || { echo "No \"Developer ID Application\" certificate in your keychain." >&2; exit 1; }
  PROFILE="${NOTARY_PROFILE:-}"
  if [ -z "$PROFILE" ]; then
    for p in wingman-notary notchpet-notary markd-notary; do
      xcrun notarytool history --keychain-profile "$p" >/dev/null 2>&1 && { PROFILE="$p"; break; }
    done
  fi
  [ -n "$PROFILE" ] || { echo "No notarytool profile. Make one: xcrun notarytool store-credentials wingman-notary" >&2; exit 1; }
  [ -f "$NOTES" ] || { echo "Write what's new in $NOTES first (a few lines of HTML)." >&2; exit 1; }
  [ -d "$SITE/public" ] || { echo "Can't find the website repo at $SITE (set SITE)." >&2; exit 1; }
  SIGNING=(CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=$IDENTITY" OTHER_CODE_SIGN_FLAGS=--timestamp)
  echo "Wingman $VERSION ($BUILD), signing as: $IDENTITY"
else
  SIGNING=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- ENABLE_HARDENED_RUNTIME=NO)
fi

# 1. Universal, signed app (the widget is signed inside it)
xcodebuild -project Wingman.xcodeproj -scheme Wingman -configuration Release \
  -archivePath "$WORK/Wingman.xcarchive" -derivedDataPath "$WORK/dd" \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO DEVELOPMENT_TEAM=RD223D229Z "${SIGNING[@]}" \
  archive | grep -E "error:|ARCHIVE (SUCCEEDED|FAILED)" || true
APP="$WORK/Wingman.xcarchive/Products/Applications/Wingman.app"
[ -d "$APP" ] || { echo "The build failed. Run it in Xcode to see why." >&2; exit 1; }
codesign --verify --deep --strict --verbose=2 "$APP"

# 2. The disk image: the app and a shortcut to /Applications, on a background with the icons laid out
STAGE="$WORK/dmg"
RW="$WORK/rw.dmg"
mkdir -p "$STAGE/.background" "$OUT"
ditto "$APP" "$STAGE/Wingman.app"
ln -s /Applications "$STAGE/Applications"
tiffutil -cathidpicheck Resources/dmg/background.png Resources/dmg/background@2x.png -out "$STAGE/.background/background.tiff"
# A Wingman disk that's still mounted from an earlier test would take the name; eject it first.
for v in /Volumes/Wingman*; do [ -d "$v" ] && hdiutil detach "$v" -quiet 2>/dev/null || true; done
hdiutil create -volname "Wingman" -srcfolder "$STAGE" -ov -format UDRW -fs HFS+ "$RW" >/dev/null
DEV="$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | awk '/Apple_HFS/ {print $1; exit}')"
# Finder lays the window out (it writes the .DS_Store). If it isn't allowed to, the .dmg still works, just plainer.
osascript >/dev/null 2>&1 <<'OSA' || echo "warning: couldn't style the .dmg window (allow your terminal to control Finder in System Settings > Privacy & Security > Automation)" >&2
tell application "Finder"
  tell disk "Wingman"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 860, 542}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 112
    set text size of opts to 13
    set background picture of opts to file ".background:background.tiff"
    set position of item "Wingman.app" of container window to {165, 275}
    set position of item "Applications" of container window to {495, 275}
    close
    open
    update without registering applications
    delay 2
    close
  end tell
end tell
OSA
sync
hdiutil detach "$DEV" -quiet || { sleep 2; hdiutil detach "$DEV" -force -quiet; }
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -ov -o "$DMG" >/dev/null

if [ "$MODE" = local ]; then
  echo "Built $DMG (ad hoc: for testing only, not for publishing)."
  exit 0
fi

codesign --force --sign "$IDENTITY" --timestamp "$DMG"

# 3. Notarize and staple, so it opens without warnings, even offline
echo "Sending to Apple for notarization (usually a few minutes)..."
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature -v "$DMG"

# 4. Publish: the .dmg into the website and a new entry at the top of its appcast (the version history)
cp "$DMG" "$SITE/public/downloads/"
mkdir -p "$SITE/public/wingman"
python3 - "$SITE/public/wingman/appcast.xml" "$VERSION" "$BUILD" "$(stat -f%z "$DMG")" "$NOTES" <<'PY'
import sys, re, os, email.utils
path, version, build, length, notes = sys.argv[1:]
items = []
if os.path.exists(path):
    items = re.findall(r'(?s)\s*<item>.*?</item>', open(path).read())
    items = [i for i in items if f'<sparkle:version>{build}</sparkle:version>' not in i]
item = f'''
    <item>
      <title>Wingman {version}</title>
      <pubDate>{email.utils.formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <description><![CDATA[{open(notes).read().strip()}]]></description>
      <enclosure url="https://leinerud.se/downloads/Wingman-{version}.dmg" type="application/octet-stream" length="{length}"/>
    </item>'''
open(path, 'w').write(f'''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Wingman</title>
    <link>https://leinerud.se/wingman/</link>
    <language>en</language>{item}{"".join(items)}
  </channel>
</rss>
''')
PY
echo "Published into the website: public/downloads/Wingman-$VERSION.dmg and public/wingman/appcast.xml."
echo "Point downloadUrl in src/content/apps/wingman.md at it, then commit and push the website."
