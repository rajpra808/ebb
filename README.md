# Ebb

Your Mac's daily cleanup agent. It knows what you're working on and only
suggests what's safe.

Developer tools leave a lot behind: `node_modules` in projects you finished
months ago, virtual environments, package manager caches, old installers.
Ebb finds that space, tells you what each item is and whether it comes back,
and leaves anything you're actively working on alone.

Ebb is free and open source (MIT). No account, no telemetry, nothing leaves
your Mac.

> **Status:** early. Today there is a read-only `ebb scan` command line tool.
> The menu bar app, the daily agent and cleaning (move to Trash, with undo)
> come next. See [docs/SPEC.md](docs/SPEC.md) for the plan.

## What it looks like

This is a real run on the author's Mac (home folder, 34 active projects):

```
$ ebb scan
  claude-code-history     2.1 MB   1 item
  agent-history         129.8 MB   100 items
  local-models          147.8 MB   2 items
  python-venvs            1.0 GB   1 inactive project
  node-leftovers         ~8.9 GB   18 inactive projects
  build-outputs          ~1.6 GB   1 inactive project
  package-caches         ~4.5 GB   Bun, pip, Homebrew, CocoaPods, Go modules
  temp-files               41 KB   1 item
  old-installers          3.6 MB   1 item
  duplicates             11.1 GB   282 items

  skipped                          34 active projects, 461 other items
  safe to clear          16.0 GB
  worth a look           11.4 GB   not pre-selected

  Scanned in 27.0s. Nothing was changed. ~ means estimated.
```

"Safe to clear" counts only pre-selected items. "Worth a look" is things
that can't come back (old chats, duplicates) or that you may still want
(models); Ebb lists them but never pre-selects them.

`~` marks sizes that are estimates, usually because files are hard-linked
with something outside the item (pnpm does this).

Other commands:

```
ebb scan --details      # every item with its path, size, comes-back label and reason,
                        # then everything skipped and why
ebb scan --json         # the full result as JSON (format documented in docs/ARCHITECTURE.md)
ebb active              # projects Ebb considers active, and the signals behind each
ebb rule add '\.mov$' --in ~/Movies --older 90d --larger 500MB --name "Old recordings"
ebb rule add '^client-' --in ~/code --never-touch
ebb rule list
```

## Safety promises

These hold for every line of code, and the never-touch test suite checks them
before each release.

1. **Read-only today.** No command moves or deletes anything. When cleaning
   arrives it will move items to the Trash (never delete), only after you
   click, and keep a log so you can put things back.
2. **Your active work is off limits.** A project counts as active if, in the
   last 14 days, a source file changed, git recorded a commit, checkout or
   stage, Claude Code or Codex had a session there, or it was open in VS Code,
   Cursor or Xcode. A process running inside it right now counts too. Nothing
   inside an active project is ever suggested. `ebb active` shows exactly why
   each project counts.
3. **A built-in never-touch list always wins**, even over your own rules:
   `.git`, `.env*`, `CLAUDE.md` and other agent memory files,
   `~/.claude/settings*.json`, `.credentials*`, `~/.codex/config*`, SSH and
   cloud credentials, keychains, `/System`, and other users' home folders.
4. **Recent and open files are skipped.** Anything changed in the last 24
   hours, or open in a running app (checked with `lsof`), is left out.
5. **Symlinks are never followed** out of a scanned folder, and external disks
   and network volumes are skipped unless you ask.
6. **When unsure, Ebb leaves it out.** A folder named `build` is only
   suggested if git confirms nothing in it is tracked. A `.zip` in Downloads
   is only suggested if macOS marked it as downloaded. Folders Ebb can't fully
   read are skipped.

## How it's different

Tools like [npkill](https://github.com/voidcosmos/npkill) and
[kondo](https://github.com/tbillington/kondo) are good at finding build
folders when you ask. Ebb aims to be the thing you don't have to remember:

- **A daily agent** (coming) that scans in the background and notifies you
  once, only when it's worth it.
- **Active-work protection** from file activity, git, AI agent sessions,
  running processes and editor recents.
- **AI tool cleanup:** old Claude Code, Codex, Gemini and Cursor histories and
  unused local models, never pre-selected.

## Install and build

Ebb needs macOS 14 or later and Swift 5.10 or later (Xcode or the Command
Line Tools).

```
git clone <repo-url> ebb && cd ebb
swift build -c release
.build/release/ebb scan
```

For Full Disk Access (so Ebb can see everything in your home folder), see
[cli/mac](cli/mac/README.md). Linux notes are in [cli/linux](cli/linux/README.md).

### Running the tests

```
./scripts/test.sh
```

With Xcode installed this is the same as `swift test`. With only the Command
Line Tools, plain `swift test` finds no tests because the tools keep
swift-testing outside the default search path; the script points the
compiler at it.

## Adding a category

Categories are data. Most new categories are one entry in
[`Sources/ScanCore/Categories/categories.json`](Sources/ScanCore/Categories/categories.json):

```json
{
  "id": "uv-cache",
  "number": 8,
  "title": "uv cache",
  "summary": "Packages downloaded by uv. They refill on the next install.",
  "comesBack": { "kind": "yes", "howTo": "refilled on the next uv sync" },
  "rule": "Always eligible",
  "preselected": true,
  "collector": {
    "type": "knownPaths",
    "paths": [{ "label": "uv", "path": "~/.cache/uv" }]
  }
}
```

Three collector types exist: `projectLeftovers` (folders inside inactive
projects), `knownPaths` (fixed cache locations) and `folderContents` (old
entries in a folder such as Downloads). Every candidate still passes the same
safety checks, whatever the category says. [docs/CATEGORIES.md](docs/CATEGORIES.md)
has the full format, and [CONTRIBUTING.md](CONTRIBUTING.md) describes what a
pull request needs, including a fixture test.

## Repository layout

```
Sources/ScanCore/    the scanning library (no UI): categories, measuring,
                     projects, rules, safety
Sources/EbbCLI/      the ebb commands, as a library so they can be tested
Sources/ebb/         the executable entry point
Tests/               ScanCore and CLI tests, with fixture home folders
cli/mac, cli/linux   per-platform install notes
app/                 the menu bar app (not started), with the UI design
landing/             the landing page (not started)
docs/                spec, architecture, categories, rules
```

## Docs

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): how a scan works, and the JSON format
- [docs/CATEGORIES.md](docs/CATEGORIES.md): every category and the catalog format
- [docs/RULES.md](docs/RULES.md): custom regex rules
- [docs/SPEC.md](docs/SPEC.md): the product spec

## License

MIT. See [LICENSE](LICENSE).
