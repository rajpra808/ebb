#!/bin/sh
# Builds Ebb.app from the SwiftPM packages: release build, Info.plist,
# icon, the `ebb` command line tool inside the bundle, ad-hoc signature.
# Output: app/build/Ebb.app
#
#   EBB_VERSION=0.2.0   version written to Info.plist (default 0.2.0)
#   EBB_UNIVERSAL=1     build for both Apple silicon and Intel (needs Xcode)
#
# The app is signed ad hoc, not with a Developer ID, so it isn't notarized.
# Installed with install.sh (curl, no quarantine flag) it opens normally;
# downloaded in a browser, macOS asks once (right-click › Open).
set -eu

cd "$(dirname "$0")/.."
version=${EBB_VERSION:-0.2.0}
build=build
bundle="$build/Ebb.app"

if [ "${EBB_UNIVERSAL:-0}" = "1" ]; then
    set -- -c release --arch arm64 --arch x86_64
else
    set -- -c release
fi

swift build "$@" --product EbbApp
app_bin="$(swift build "$@" --show-bin-path)/EbbApp"
(cd .. && swift build "$@" --product ebb)
cli_bin="$(cd .. && swift build "$@" --show-bin-path)/ebb"

rm -rf "$bundle"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Helpers" "$bundle/Contents/Resources"
cp "$app_bin" "$bundle/Contents/MacOS/Ebb"
cp "$cli_bin" "$bundle/Contents/Helpers/ebb"

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

# Inner code first, then the bundle.
codesign --force --sign - "$bundle/Contents/Helpers/ebb"
codesign --force --sign - "$bundle"
codesign --verify --strict "$bundle"
echo "Built $bundle ($version)"
