# ebb on Linux

The CLI builds and runs on Linux, but Ebb is a Mac app first and Linux
support is limited. Treat results as a preview.

## Build

Swift 5.10 or later:

```
swift build -c release
.build/release/ebb scan
```

Or in Docker, from the repository root:

```
docker run --rm -v "$PWD":/src -w /src swift:6.0 swift build -c release
```

## Differences from macOS

- **Paths.** Package caches are looked up at their Linux locations too
  (`~/.cache/pip`, `~/.cache/yarn`, `~/.local/share/pnpm/store`), but several
  catalog entries are Mac paths (`~/Library/Caches/...`) and simply won't
  match.
- **Rules file** lives at `~/.local/share/ebb/rules.json`.
- **Sizes.** There's no APFS clone information, so sizes are plain allocated
  blocks. Hard links are still counted once.
- **Other users** are recognized from the folder that holds your home folder
  (usually `/home`).
- **Downloads.** `.zip` files need the macOS quarantine attribute to be
  suggested, so on Linux zips in Downloads are always skipped.
- `lsof` must be installed for the open-file check; without it the scan
  continues and prints a note.
