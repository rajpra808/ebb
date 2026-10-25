# ebb on macOS

macOS 14 or later. macOS is the primary platform.

## Build and install

```
swift build -c release
install -m 755 .build/release/ebb /usr/local/bin/ebb    # or anywhere on your PATH
```

The binary is self-contained: the category catalog is compiled in.

A Homebrew cask and a signed, notarized build are planned for the app
release.

## Full Disk Access

Without Full Disk Access, macOS hides parts of your home folder (Mail,
Messages, some app containers) from command line tools. Ebb still works; it
just can't see or vouch for those folders, and reports them as skipped.

To grant it, open **System Settings → Privacy & Security → Full Disk
Access** and add the terminal app you run `ebb` from (Terminal, iTerm,
Ghostty...). Restart the terminal afterwards.

## What it runs

- `lsof` once per scan, to list files open in your own processes.
- `git ls-files` in inactive git projects that have a `dist` or `build`
  folder, to check nothing in it is tracked. Optional locks are disabled, so
  it doesn't touch the index.

If git isn't installed (`/usr/bin/git` without the Command Line Tools is only
an installer stub), Ebb skips `dist` and `build` folders instead of guessing.

## Tests with only the Command Line Tools

The Command Line Tools ship swift-testing in a folder the compiler doesn't
search, so plain `swift test` finds no tests. Use `./scripts/test.sh`.
