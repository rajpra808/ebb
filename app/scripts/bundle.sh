#!/bin/sh
# Builds Ebb.app from the SwiftPM package: release build, Info.plist, icon,
# ad-hoc signature. Output: app/build/Ebb.app
#
# A Developer ID signature and notarization come later (spec §9); an
# ad-hoc signed app runs on the Mac that built it.
set -eu

cd "$(dirname "$0")/.."
version=${EBB_VERSION:-0.2.0}
build=build
bundle="$build/Ebb.app"

swift build -c release --product EbbApp
binary="$(swift build -c release --show-bin-path)/EbbApp"

rm -rf "$bundle"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "$binary" "$bundle/Contents/MacOS/Ebb"

swift scripts/make-icon.swift "$build/AppIcon.iconset"
iconutil -c icns "$build/AppIcon.iconset" -o "$bundle/Contents/Resources/AppIcon.icns"

cat > "$bundle/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.serveka.ebb</string>
    <key>CFBundleName</key><string>Ebb</string>
    <key>CFBundleDisplayName</key><string>Ebb</string>
    <key>CFBundleExecutable</key><string>Ebb</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$version</string>
    <key>CFBundleVersion</key><string>$version</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHumanReadableCopyright</key><string>MIT License. Free and open source.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$bundle"
echo "Built $bundle"
