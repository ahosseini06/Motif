#!/bin/bash
# Packages Motif.app into a disk image you can send to someone.
#
#   Scripts/package.sh
#       Ad-hoc signed. Works, but each recipient has to approve it once in System Settings (see the note put in the image).
#
#   MOTIF_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" MOTIF_NOTARY_PROFILE=motif Scripts/package.sh
#       Signed with the hardened runtime, notarised by Apple and stapled: opens with a normal double-click on any Mac.
#       Needs an Apple Developer Program membership. One-time setup:
#         1. Create a "Developer ID Application" certificate at developer.apple.com and install it in your keychain.
#         2. xcrun notarytool store-credentials motif --apple-id you@example.com --team-id TEAMID --password <app-specific password>
set -euo pipefail
cd "$(dirname "$0")/.."

Scripts/bundle.sh
APP=build/Motif.app
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="build/Motif-$VERSION.dmg"
IDENTITY="${MOTIF_SIGN_IDENTITY:-}"
PROFILE="${MOTIF_NOTARY_PROFILE:-}"

if [ -n "$IDENTITY" ]; then
  # Inside out: nested executables first, then the bundle. The hardened runtime is a condition of notarisation.
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP/Contents/MacOS/motif-cli"
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
  codesign --verify --deep --strict "$APP"
  echo "Signed with: $IDENTITY"
fi

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/Motif.app"
ln -s /Applications "$STAGE/Applications"
if [ -z "$IDENTITY" ] || [ -z "$PROFILE" ]; then
  cat > "$STAGE/Read me first.txt" <<'NOTE'
Motif — installing

1. Drag Motif into Applications.
2. Open it. macOS will say it can't verify the developer — this build isn't notarised by Apple yet. Click Done.
3. Open System Settings → Privacy & Security, scroll down to "Motif was blocked…", click Open Anyway, and confirm.
   You only do this once.

   (Or, in Terminal:  xattr -dr com.apple.quarantine /Applications/Motif.app )

Needs a Mac with Apple Silicon running macOS 26 or later.

Descriptions use Google's Gemini API: add your own key in Motif → Settings (⌘,). A paid-tier key isn't used for training.
Camera-movement tagging, search and the shot designer work without one. The first project downloads a ~50 MB depth model.
NOTE
fi

rm -f "$DMG"
hdiutil create -volname "Motif $VERSION" -srcfolder "$STAGE" -ov -format UDZO -fs HFS+ "$DMG" >/dev/null

if [ -n "$IDENTITY" ] && [ -n "$PROFILE" ]; then
  codesign --force --timestamp --sign "$IDENTITY" "$DMG"
  echo "Notarising (usually a few minutes)…"
  xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$DMG"
  echo "Notarised and stapled."
fi

echo "Packaged $DMG ($(du -h "$DMG" | cut -f1))"
