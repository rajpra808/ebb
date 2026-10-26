#!/bin/sh
# Installs Ebb, the Mac disk cleanup agent: https://ebb.serveka.com
#
#   curl -fsSL https://ebb.serveka.com/install.sh | sh
#   curl -fsSL https://ebb.serveka.com/install.sh | sh -s -- --uninstall
#
# What it does, and nothing else:
#   1. downloads the latest release of Ebb.zip from GitHub and checks its
#      SHA-256 against the checksum published with the release;
#   2. puts Ebb.app in /Applications (or ~/Applications if that isn't
#      writable), replacing an older Ebb;
#   3. links the `ebb` and `ebbctl` commands into /usr/local/bin (or
#      ~/.local/bin). An existing `ebb` that isn't Ebb's is left alone.
#
# --uninstall removes the app, the commands and the daily agent, and keeps
# your settings and clean history. Add --purge to remove those as well.
# Nothing Ebb moved to the Trash is touched either way.
#
# EBB_APP_DIR, EBB_BIN_DIR and EBB_DOWNLOAD_URL override where it installs
# and downloads from (used to test the script).
set -eu

REPO="rajpra808/ebb"
ASSET="Ebb.zip"
AGENT_LABEL="com.serveka.ebb.agent"

say() { printf '  %s\n' "$*"; }
fail() { printf '  error: %s\n' "$*" >&2; exit 1; }

app_dir() {
    if [ -n "${EBB_APP_DIR:-}" ]; then echo "$EBB_APP_DIR"
    elif [ -w /Applications ]; then echo /Applications
    else echo "$HOME/Applications"; fi
}

bin_dir() {
    if [ -n "${EBB_BIN_DIR:-}" ]; then echo "$EBB_BIN_DIR"
    elif [ -d /usr/local/bin ] && [ -w /usr/local/bin ]; then echo /usr/local/bin
    else echo "$HOME/.local/bin"; fi
}

# True if $1 is a symlink into an Ebb.app bundle.
is_ebb_link() {
    [ -L "$1" ] && case "$(readlink "$1")" in */Ebb.app/Contents/Helpers/ebb) return 0 ;; esac
    return 1
}

quit_running_app() {
    if pgrep -x Ebb >/dev/null 2>&1; then
        osascript -e 'tell application id "com.serveka.ebb" to quit' >/dev/null 2>&1 || true
        sleep 1
    fi
}

uninstall() {
    purge=$1
    quit_running_app
    launchctl bootout "gui/$(id -u)/$AGENT_LABEL" >/dev/null 2>&1 || true
    rm -f "$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"
    for dir in ${EBB_APP_DIR:-/Applications "$HOME/Applications"}; do
        if [ -d "$dir/Ebb.app" ]; then
            rm -rf "$dir/Ebb.app"
            say "Removed $dir/Ebb.app"
        fi
    done
    for dir in ${EBB_BIN_DIR:-/usr/local/bin "$HOME/.local/bin" /opt/homebrew/bin}; do
        for name in ebb ebbctl; do
            if is_ebb_link "$dir/$name"; then rm -f "$dir/$name"; say "Removed $dir/$name"; fi
        done
    done
    if [ "$purge" = 1 ]; then
        rm -rf "$HOME/Library/Application Support/Ebb" "$HOME/Library/Logs/Ebb"
        say "Removed Ebb's settings, rules and history."
    else
        say "Kept your settings and history in ~/Library/Application Support/Ebb (use --purge to remove them)."
    fi
    say "Ebb is uninstalled. Anything it moved to the Trash is still there."
}

install() {
    [ "$(uname -s)" = Darwin ] || fail "Ebb is a Mac app. On Linux, build the CLI from source: https://github.com/$REPO"
    major=$(sw_vers -productVersion | cut -d. -f1)
    [ "$major" -ge 14 ] || fail "Ebb needs macOS 14 or later (this Mac has $(sw_vers -productVersion))."

    work=$(mktemp -d)
    trap 'rm -rf "$work"' EXIT

    url="${EBB_DOWNLOAD_URL:-https://github.com/$REPO/releases/latest/download}"
    say "Downloading Ebb…"
    curl -fsSL "$url/$ASSET" -o "$work/$ASSET" || fail "couldn't download $url/$ASSET"
    curl -fsSL "$url/$ASSET.sha256" -o "$work/$ASSET.sha256" || fail "couldn't download the checksum"
    expected=$(awk '{print $1}' "$work/$ASSET.sha256")
    actual=$(shasum -a 256 "$work/$ASSET" | awk '{print $1}')
    [ -n "$expected" ] && [ "$expected" = "$actual" ] || fail "checksum mismatch; not installing"

    ditto -x -k "$work/$ASSET" "$work/unpacked"
    [ -d "$work/unpacked/Ebb.app" ] || fail "the download doesn't contain Ebb.app"
    codesign --verify --strict "$work/unpacked/Ebb.app" 2>/dev/null || fail "the app's signature doesn't verify"

    target=$(app_dir)
    mkdir -p "$target"
    quit_running_app
    # The old copy moves aside and goes away with the temp folder.
    [ -d "$target/Ebb.app" ] && mv "$target/Ebb.app" "$work/previous.app"
    mv "$work/unpacked/Ebb.app" "$target/Ebb.app"
    say "Installed $target/Ebb.app"

    bin=$(bin_dir)
    mkdir -p "$bin"
    helper="$target/Ebb.app/Contents/Helpers/ebb"
    for name in ebb ebbctl; do
        if [ -e "$bin/$name" ] && ! is_ebb_link "$bin/$name"; then
            say "Left $bin/$name alone; it isn't Ebb's."
            continue
        fi
        ln -sf "$helper" "$bin/$name"
    done
    say "Linked the ebb and ebbctl commands in $bin"

    case ":$PATH:" in
        *":$bin:"*) ;;
        *) say "Add $bin to your PATH to use the commands, e.g. in ~/.zshrc: export PATH=\"$bin:\$PATH\"" ;;
    esac
    # MacTeX ships its own `ebb` (extractbb). If it comes first, use ebbctl.
    found=$(command -v ebb 2>/dev/null || true)
    if [ -n "$found" ] && [ "$found" != "$bin/ebb" ]; then
        say "Note: \`ebb\` on your PATH is $found, not Ebb. Use \`ebbctl\`, which is the same tool."
    fi

    say ""
    say "Done. Open Ebb from Applications, or run \`ebbctl scan\` in a terminal."
    [ -n "${EBB_APP_DIR:-}" ] || open "$target/Ebb.app" 2>/dev/null || true
}

case "${1:-}" in
    --uninstall) [ "${2:-}" = "--purge" ] && uninstall 1 || uninstall 0 ;;
    "") install ;;
    *) fail "unknown option $1 (use --uninstall, optionally with --purge)" ;;
esac
