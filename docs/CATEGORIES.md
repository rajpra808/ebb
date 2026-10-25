# Categories

Categories live in
[`Sources/ScanCore/Categories/categories.json`](../Sources/ScanCore/Categories/categories.json),
which is compiled into the binary. Numbers match the table in
[SPEC.md](SPEC.md) §3.

## Implemented

| # | id | Finds | Rule | Comes back | Pre-selected |
|---|---|---|---|---|---|
| 5 | `python-venvs` | `.venv`, `venv`, `env` folders containing `pyvenv.cfg` | Project inactive | yes, `pip install` | yes |
| 6 | `node-leftovers` | `node_modules`, `.next`, `.turbo`, `.parcel-cache`, and `dist`/`build`, each next to a `package.json` | Project inactive | yes, reinstall and rebuild | yes |
| 8 | `package-caches` | npm, Yarn, Bun, pip, Homebrew, CocoaPods and Go module caches; pnpm store | Always eligible | yes, refilled on next install | yes |
| 12 | `temp-files` | Entries in `$TMPDIR`; `~/Library/Caches` with `--library-caches` | Nothing inside changed in 3 days, not open | yes, apps recreate them | yes |
| 14 | `old-installers` | `.dmg`, `.pkg`, `.zip` in `~/Downloads` | Older than 30 days | re-download | yes |

Category 7 (`build-outputs`: Rust `target`, Swift `.build`, Gradle) is listed
but disabled until it has fixtures. Its folder names still count as leftovers,
so editing them doesn't make a project look active.

### Details that matter for safety

- **`dist` and `build`** are common names for real folders. They're only
  suggested next to a `package.json`, and only if `git ls-files` confirms
  nothing inside is tracked. If git can't answer, they're skipped.
- **Package-managed contents.** A package inside `node_modules` may ship its
  own `CLAUDE.md` or `.git`. For project leftovers and caches, built-in
  protected *names* inside don't block the item, because the package manager
  wrote them and reinstalling brings them back. Protected *paths* and your
  never-touch rules still block it.
- **pnpm store** is reported with `clearCommand: "pnpm store prune"` and an
  estimated size, since pruning removes only packages no project uses. Moving
  the whole store to Trash would break every pnpm project.
- **Go module cache** files are read-only on disk; it's reported with
  `clearCommand: "go clean -modcache"`.
- **Temp files** are judged per top-level entry: a folder counts as old only
  if nothing inside, including the folder dates, changed in 3 days. Names
  starting with `com.apple.` are skipped.
- **Zip files** only count when macOS marked them as downloaded (the
  `com.apple.quarantine` attribute), so your own archives stay out.

## Catalog format

```jsonc
{
  "id": "node-leftovers",     // stable, used in JSON and `ebb clean --select` later
  "number": 6,                // spec table number, for cross-reference
  "title": "Node / JS build leftovers",
  "summary": "One sentence shown in the app.",
  "comesBack": { "kind": "yes", "howTo": "npm install" },   // or redownload | no | notApplicable
  "rule": "Project inactive", // the default rule in words
  "preselected": true,
  "enabled": true,            // optional, default true
  "collector": { "type": "...", ... }
}
```

### `projectLeftovers`

Folders inside projects. Reported only when no activity signal considers the
project active.

```json
"collector": {
  "type": "projectLeftovers",
  "leftovers": [
    { "names": [".venv", "venv", "env"], "containsFile": "pyvenv.cfg" },
    { "names": ["dist", "build"], "siblingFile": "package.json", "confirmUntracked": true }
  ]
}
```

- `containsFile`: the folder must contain this file.
- `siblingFile`: the folder next to it must contain this file.
- `confirmUntracked`: only report when git confirms nothing inside is
  tracked (or the project isn't a git repository).

### `knownPaths`

Fixed locations. `~` and `$TMPDIR` are expanded. A path that is a symlink is
ignored.

```json
"collector": {
  "type": "knownPaths",
  "paths": [
    { "label": "npm", "path": "~/.npm/_cacache" },
    { "label": "pnpm store", "path": "~/Library/pnpm/store",
      "clearCommand": "pnpm store prune", "estimated": true,
      "comesBack": { "kind": "yes", "howTo": "pnpm install" } }
  ]
}
```

### `folderContents`

Direct children of a folder, filtered by age and type.

```json
"collector": {
  "type": "folderContents",
  "folders": [{ "path": "~/Downloads" }, { "path": "~/Library/Caches", "optIn": "libraryCaches" }],
  "olderThanDays": 30,
  "extensions": ["dmg", "pkg", "zip"],
  "filesOnly": true,
  "requireDownloadedFor": ["zip"],
  "skipNamePrefixes": ["com.apple."],
  "reason": "Downloaded {age} ago"
}
```

`optIn` folders are scanned only when the matching option is on (today only
`libraryCaches`, set by `--library-caches`).

## Adding one

1. Add the entry to `categories.json`. Keep `id`s lowercase with hyphens.
2. Add a fixture test in `Tests/ScanCoreTests/CategoryTests.swift` that builds
   a fake home folder with the files your category should find, plus at least
   one lookalike it must not find, and asserts paths and sizes.
3. Run `./scripts/test.sh`. The never-touch suite must still pass.
4. Run `swift run ebb scan --details` on your own Mac and include the relevant
   lines in the pull request.
