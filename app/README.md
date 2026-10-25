# Ebb for Mac

The menu bar app and its window, in SwiftUI. It's a separate Swift package
so the root package (ScanCore, EbbClean and the CLI) keeps building on
Linux; it uses those libraries for everything that touches the disk.

```
Sources/EbbAppKit/   state and display logic, no views (tested)
Sources/EbbApp/      the SwiftUI app: menu bar popover and main window
Tests/               EbbAppKit tests, including scan → clean → put back
scripts/bundle.sh    builds build/Ebb.app
design/              the UI design reference (open the .html in a browser)
```

## Build and run

```
./scripts/bundle.sh
open build/Ebb.app
```

Ebb lives in the menu bar (it has no Dock icon). To open the window
straight away, for example when working on a pane:

```
open build/Ebb.app --args --show-window recommendations   # or overview, active, history
```

The bundle is signed ad hoc, which is enough on the Mac that built it.
Developer ID signing and notarization come with the release work.

Tests: `../scripts/test.sh` (or `swift test` with Xcode installed).

## What's in it

- **Menu bar:** the safe-to-clear total, the top categories, how many active
  projects were skipped, and Review / Move to Trash.
- **Overview:** free space, safe to clear, worth a look, freed this month,
  top recommendations.
- **Recommendations:** every item with a checkbox, its path, why it's safe
  and whether it comes back; a side panel with the selected total split by
  comes back / re-download / gone for good.
- **Active projects:** each protected project and the signals behind it.
- **History:** every clean, with Put back per item or for the whole clean,
  and how much from Ebb cleans still sits in the Trash.

Cleaning goes through `EbbClean`: every item is checked again right before
it moves, only moves to the Trash, and is logged. Items that need a command
(`pnpm store prune`, `go clean -modcache`, Docker prune) show the command
and can't be ticked.

The app scans when it starts if the last scan is from an earlier day, and
keeps the result in `~/Library/Application Support/Ebb/last-scan.json`.
The daily agent, notifications and Settings come next.
