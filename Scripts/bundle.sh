#!/bin/bash
# Builds Motif.app from the SwiftPM package. No Xcode required — Command Line Tools are enough.
#   Scripts/bundle.sh            → build/Motif.app
#   Scripts/bundle.sh --install  → also copies it to /Applications
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product MotifApp
swift build -c release --product motif-cli

APP=build/Motif.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/MotifApp "$APP/Contents/MacOS/Motif"
cp .build/release/motif-cli "$APP/Contents/MacOS/motif-cli"

if [ ! -f build/Motif.icns ]; then
  swift Scripts/make-icon.swift build/Motif.iconset && iconutil -c icns build/Motif.iconset -o build/Motif.icns
fi
cp build/Motif.icns "$APP/Contents/Resources/Motif.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Motif</string>
  <key>CFBundleDisplayName</key><string>Motif</string>
  <key>CFBundleIdentifier</key><string>ai.motif.app</string>
  <key>CFBundleExecutable</key><string>Motif</string>
  <key>CFBundleIconFile</key><string>Motif</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Motif Project</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Owner</string>
      <key>LSTypeIsPackage</key><true/>
      <key>LSItemContentTypes</key><array><string>ai.motif.project</string></array>
    </dict>
  </array>
  <key>UTExportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key><string>ai.motif.project</string>
      <key>UTTypeDescription</key><string>Motif Project</string>
      <key>UTTypeConformsTo</key><array><string>com.apple.package</string><string>public.composite-content</string></array>
      <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>motif</string></array></dict>
    </dict>
  </array>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null 2>&1
echo "Built $APP"

if [ "${1:-}" = "--install" ]; then
  rm -rf /Applications/Motif.app && cp -R "$APP" /Applications/Motif.app && echo "Installed /Applications/Motif.app"
fi
