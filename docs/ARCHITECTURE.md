# Architecture

Ebb is one Swift package with three targets:

| Target | Kind | What it holds |
|---|---|---|
| `ScanCore` | library | Everything that looks at the disk. No UI, no printing. The app and the daily agent will use it too. |
| `EbbClean` | library | Moving to Trash, the clean log (`history.json`) and putting back. Re-checks every item through ScanCore first. |
| `EbbCLI` | library | The `ebb` commands (swift-argument-parser) and text formatting. A library so tests can parse and render without a process. |
| `ebb` | executable | A five-line async entry point. |

The macOS app is a second package in [`app/`](../app/README.md) that depends
on ScanCore and EbbClean.

## Cleaning

`Cleaner.clean` takes items from a scan (possibly hours old) and:

1. calls `DiskScanner.recheck`, which runs each item through the same
   safety gate again with a fresh open-file list and a fresh look at the
   project around it;
2. moves the items that are still safe to the Trash one at a time with
   `FileManager.trashItem`, writing each move to `history.json` before the
   next;
3. reports items that changed since the scan, and items that need a command,
   without touching them.

`Cleaner.putBack` moves items from the Trash back to where they were, and
never overwrites something that has appeared at the old path since.

## A scan, step by step

`DiskScanner.scan()` runs these steps. Nothing writes to disk. The processes it
starts are `lsof` (twice: open files, working folders), `git ls-files` (once
per inactive git project with generic leftovers like `dist`), `docker system
df` if Docker is installed, and `xcrun simctl list` if Xcode is.

1. **Canonicalize options.** Home, `$TMPDIR` and roots are resolved with
   `realpath` once, so `/var/...` and `/private/var/...` compare equal. Paths
   are never resolved again while walking.
2. **Snapshot open files.** `lsof -F n -u <uid>` starts in the background and
   is awaited before the safety checks. If it fails, the scan carries on and
   says so in `warnings`.
3. **Find projects** (`Projects/ProjectDiscovery.swift`). Walks the roots with
   `readdir` + `lstat`, never following symlinks or crossing to another disk.
   A project is the *outermost* folder with a marker (`.git`, `package.json`,
   `Cargo.toml`, ...). The walk doesn't descend into hidden folders, dependency
   trees, macOS packages, `~/Library`, Trash, or known cache locations.
4. **Decide which projects are active** (`ProjectAssessor`). Every
   `ActivitySignal` is asked about every project; any evidence makes it
   active. Signals share one lazy walk of the project (`ProjectSurvey`) that
   records the newest edit outside leftover folders and the leftover folders
   themselves, and stops early at the first recent edit.
5. **Collect candidates** from each enabled category, then from `suggest`
   rules. Catalog order decides which category claims a path when two
   overlap, and overlapping candidates are dropped (`removingOverlaps`).
6. **Check every candidate** (`Scan/SafetyGate.swift`), cheapest first:
   built-in never-touch list, never-touch rules, active projects (inside or
   containing), owner is the current user, nothing open inside, then measure.
   Measuring walks the whole item and stops at any protected name or
   never-touch match inside it, at another mounted volume, or at an unreadable
   folder. Last come the 24-hour check and the category's minimum age.
7. **Reconcile sizes and total up** (`HardLinkLedger`, `DiskScanner.items`).

Candidate walks run in a bounded task group (`concurrentMap`, at most 8 at a
time). Blocking file-system work runs on GCD at `.utility` QoS so it doesn't
starve Swift's cooperative thread pool.

## Measuring size

Sizes are allocated bytes (`st_blocks * 512`), what Finder calls "size on
disk", not logical size.

- **Hard links.** A file with more than one link is recorded by
  (device, inode). Across the whole scan, its blocks count once, for the first
  item that holds a link, and only if every link is inside reported items. If
  a link lives elsewhere (for example a pnpm store on Linux), clearing the item
  frees nothing, so the bytes go to `sharedBytes` and the item is marked
  estimated.
- **APFS clones.** On macOS, pnpm and `cp -c` clone files instead of linking
  them. Clones have one link each but share blocks. For single-link files Ebb
  reads `ATTR_CMNEXT_PRIVATESIZE` and counts only private blocks; the rest is
  shared.

## Extension points

- **Categories:** add an entry to `categories.json`. A new kind of search
  needs a new `CollectorSpec` case and collector type. See
  [CATEGORIES.md](CATEGORIES.md).
- **Activity signals:** conform to `ActivitySignal` and append it to
  `DiskScanner.signals`. Built in: `git`, `recent-edit`, `claude-code`
  (sessions in `~/.claude/projects`), `codex` (session `cwd`s), `process`
  (working folders from `lsof -d cwd`) and `editor` (VS Code-family
  `workspaceStorage` and Xcode DerivedData). Pinned projects will be the next.
  Signals that read an index build it once per scan with `PerScanCache`.

```swift
public protocol ActivitySignal: Sendable {
    var id: String { get }
    func evaluate(_ project: Project, in context: ActivityContext) async -> ActivityEvidence?
}
```

## JSON format

`ebb scan --json` prints a `ScanResult` with sorted keys and ISO 8601 dates.
`formatVersion` is bumped on breaking changes.

```jsonc
{
  "formatVersion": 1,
  "startedAt": "2026-10-25T11:40:02Z",
  "durationSeconds": 10.6,
  "roots": ["/Users/me"],
  "activeDays": 14,
  "categories": [ { "id": "node-leftovers", "number": 6, "title": "...", "summary": "...",
                    "comesBack": { "kind": "yes", "howTo": "npm install ..." },
                    "ruleDescription": "Project inactive", "preselected": true } ],
  "items": [ {
    "path": "/Users/me/code/old-site/node_modules",
    "categoryID": "node-leftovers",
    "allocatedBytes": 412000000,   // what clearing frees
    "sharedBytes": 0,              // on disk but shared with something else
    "isEstimated": false,
    "fileCount": 18233,
    "lastUsed": "2026-08-22T09:12:44Z",
    "comesBack": { "kind": "yes", "howTo": "npm install ..." },
    "reason": "Project inactive 64 days",
    "preselected": true,
    "projectPath": "/Users/me/code/old-site",
    "source": null,                // tool name for caches, e.g. "npm"
    "ruleID": null,                // set for custom-rule matches
    "clearCommand": null           // e.g. "pnpm store prune" when Trash isn't the right way
  } ],
  "skipped": [ { "path": "...", "categoryID": "temp-files",
                 "reason": { "code": "modifiedRecently", "detail": "changed 3 hours ago" } } ],
  "activeProjects": [ { "path": "...", "markers": [".git", "package.json"],
                        "signals": [ { "signal": "git", "detail": "git commit or checkout 2 days ago",
                                       "date": "..." } ] } ],
  "totals": { "safeToClearBytes": 0, "worthALookBytes": 0, "itemCount": 0,
              "byCategory": [ { "categoryID": "...", "title": "...", "allocatedBytes": 0,
                                "itemCount": 0, "isEstimated": false } ] },
  "warnings": []
}
```

`comesBack.kind` is one of `yes` (with `howTo`), `redownload`, `no`,
`notApplicable`. Skip codes: `activeProject`, `protected`,
`modifiedRecently`, `openByProcess`, `trackedByGit`, `unverified`,
`notOwned`, `unreadable`, `ruleTimedOut`.

Only skips that are worth explaining are listed. Candidates that are simply
younger than their category's age limit (a 10-day-old installer) are left out
quietly.
