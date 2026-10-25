#!/bin/sh
# Runs the test suite. Use this instead of `swift test` on a Mac that only
# has the Command Line Tools (no Xcode): they ship swift-testing in a folder
# the compiler doesn't search, so it needs pointing there. With Xcode or on
# Linux this is the same as `swift test`.
set -eu

developer_dir=${DEVELOPER_DIR:-$(xcode-select -p 2>/dev/null || true)}
frameworks=/Library/Developer/CommandLineTools/Library/Developer/Frameworks

case "$developer_dir" in
/Library/Developer/CommandLineTools*)
    if [ -d "$frameworks/Testing.framework" ]; then
        # The CLT's Testing/Foundation cross-import overlay ships without its
        # module files, so overlays are switched off too.
        exec swift test \
            -Xswiftc -F -Xswiftc "$frameworks" \
            -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
            -Xlinker -rpath -Xlinker "$frameworks" \
            "$@"
    fi
    ;;
esac

exec swift test "$@"
