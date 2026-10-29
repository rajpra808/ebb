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
version=${EBB_VERSION:-0.2.8}
build=build
bundle="$build/Ebb.app"

# Builds one product for one architecture (empty = this Mac's) and prints
# the binary's path. Architectures are built one at a time: passing several
# --arch flags switches SwiftPM to a build system that can't embed
# categories.json.
build() { # build <package dir> <product> [arch]
    flags="-c release"
    [ -n "${3:-}" ] && flags="$flags --arch $3"
    (cd "$1" && swift build $flags --product "$2" >&2 && echo "$(swift build $flags --show-bin-path)/$2")
}

if [ "${EBB_UNIVERSAL:-0}" = "1" ]; then
    mkdir -p "$build/universal"
    app_bin="$build/universal/EbbApp"
    cli_bin="$build/universal/ebb"
    lipo -create "$(build . EbbApp arm64)" "$(build . EbbApp x86_64)" -output "$app_bin"
    lipo -create "$(build .. ebb arm64)" "$(build .. ebb x86_64)" -output "$cli_bin"
else
    app_bin="$(build . EbbApp)"
    cli_bin="$(build .. ebb)"
fi

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
