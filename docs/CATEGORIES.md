# Categories

Categories live in
[`Sources/ScanCore/Categories/categories.json`](../Sources/ScanCore/Categories/categories.json),
which is compiled into the binary. Each category has a stable `id` and a
`number`, the row in the table below.

## Implemented

| # | id | Finds | Rule | Regenerates | Pre-selected |
|---|---|---|---|---|---|
| 2 | `claude-code-history` | Chats in `~/.claude/projects`, `~/.claude/shell-snapshots`, `~/.claude/todos` | Older than 30 days, or your `cleanupPeriodDays` if longer | no | no |
| 3 | `agent-history` | Codex day folders in `~/.codex/sessions`, Gemini CLI `tmp` and `history`, Cursor `workspaceStorage` | Older than 30 days | no | no |
| 4 | `local-models` | Ollama models (per tag), LM Studio models, Hugging Face downloads | Not read or written in 30 days | re-download | no |
| 5 | `python-venvs` | `.venv`, `venv`, `env` folders containing `pyvenv.cfg` | Project inactive | yes, `pip install` | yes |
| 6 | `node-leftovers` | `node_modules`, `.next`, `.turbo`, `.parcel-cache`, and `dist`/`build`, each next to a `package.json` | Project inactive | yes, reinstall and rebuild | yes |
| 7 | `build-outputs` | Rust `target`, Swift `.build`, Gradle `.gradle` and `build` | Project inactive | yes, rebuild | yes |
| 8 | `package-caches` | npm, Yarn, Bun, pip, Homebrew, CocoaPods and Go module caches; pnpm store | Always eligible | yes, refilled on next install | yes |
| 9 | `xcode` | DerivedData, old device support, unavailable simulators | DerivedData of inactive or deleted projects; device support unused 30 days, newest kept | yes | yes |
| 10 | `xcode-archives` | `.xcarchive` bundles in `~/Library/Developer/Xcode/Archives` | Older than 90 days | no | no |
| 11 | `docker` | Untagged images no container uses, unused build cache | Not used by any container, older than a day | yes, rebuild or pull | yes |
| 12 | `temp-files` | Entries in `$TMPDIR`; `~/Library/Caches` with `--library-caches` | Nothing inside changed in 3 days, not open | yes, apps recreate them | yes |
| 13 | `duplicates` | Identical files of 1 MB or more in Downloads, Desktop, Documents | Same size, then same SHA-256; oldest copy kept | no | no |
| 14 | `old-installers` | `.dmg`, `.pkg`, `.zip` in `~/Downloads` | Older than 30 days | re-download | yes |

Not yet: 1 (biggest space users, info only) and 15 (Trash reminder) come
with the app.

### Details that matter for safety

- **AI tool history is never pre-selected** and its settings, credentials,
  memory folders and `CLAUDE.md` files are on the never-touch list. A memory
  folder inside a chat folder blocks that whole folder.
- **Claude Code's `cleanupPeriodDays`** is read from `~/.claude/settings.json`.
  If you set it above 30, Ebb waits that long too.
- **Models count as used when read.** A model downloaded a year ago and loaded
  last week is kept. Ollama models are sized by the blobs only they use, which
  is what `ollama rm` frees.
- **DerivedData is judged by its project** (from its `info.plist`): kept while
  the project is active, and kept if the project is outside the scanned
  folders, since Ebb can't tell.
- **Docker** numbers come from `docker system df`. The suggested commands use
  `--filter until=24h`, so they remove exactly what was counted. On macOS,
  Docker Desktop returns the space gradually.
- **Duplicates** skip project folders, app bundles, hidden files, hard links of
  the same file and iCloud placeholders. Reading files for the hash updates
  their last-read date, nothing else.

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
  "number": 6,                // its row in the table above
  "title": "Node / JS build leftovers",
  "summary": "One sentence shown in the app.",
  "comesBack": { "kind": "yes", "howTo": "npm install" },   // or redownload | no | notApplicable
  "rule": "Project inactive", // the default rule in words
  "preselected": true,
  "enabled": true,            // optional, default true
  "collector": { "type": "...", ... }       // or "collectors": [ ... ] for several
}
```

Collector types: `projectLeftovers`, `knownPaths` and `folderContents` are
general and described below. `claudeHistory`, `ollamaModels`,
`xcodeDerivedData`, `unavailableSimulators`, `docker` and `duplicates` have
logic of their own in `Sources/ScanCore/Categories`.

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

More options: `depth` (candidates sit this many levels down, e.g. 3 for
`sessions/2026/04/20`), `namePrefixes`, `skipNames`, `useAccessTime` (reads
count as use), `keepNewest` (never the latest entry), and `label`
(`vscodeWorkspace` or `huggingFaceRepo`) to show a readable `{name}` in the
reason.

## Adding one

1. Add the entry to `categories.json`. Keep `id`s lowercase with hyphens.
2. Add a fixture test in `Tests/ScanCoreTests/CategoryTests.swift` that builds
   a fake home folder with the files your category should find, plus at least
   one lookalike it must not find, and asserts paths and sizes.
3. Run `./scripts/test.sh`. The never-touch suite must still pass.
4. Run `swift run ebb scan --details` on your own Mac and include the relevant
   lines in the pull request.
