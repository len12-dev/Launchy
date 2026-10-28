#!/usr/bin/env bash
# Construit Launchy.app (macOS, Apple Silicon et Intel) à partir du package Swift.
# Usage : bash scripts/build_macos_app.sh   → produit dist/Launchy.app et dist/Launchy-macos.zip
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="0.3.0"
APP="dist/Launchy.app"

swift build -c release
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Launchy "$APP/Contents/MacOS/Launchy"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Launchy</string>
    <key>CFBundleDisplayName</key><string>Launchy</string>
    <key>CFBundleIdentifier</key><string>me.len_studio.launchy</string>
    <key>CFBundleExecutable</key><string>Launchy</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# Signature ad hoc : nécessaire pour que macOS accepte le lancement d'un binaire non notarié.
codesign --force --deep --sign - "$APP"

rm -f "dist/Launchy-macos.zip"
ditto -c -k --keepParent "$APP" "dist/Launchy-macos.zip"
echo "Créé : $APP et dist/Launchy-macos.zip"
