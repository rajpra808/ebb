# Ebb for Mac

The menu bar app and its window, in SwiftUI. It's a separate Swift package
so the root package (ScanCore, EbbClean and the CLI) keeps building on
Linux; it uses those libraries for everything that touches the disk.

```
Sources/EbbAppKit/   state and display logic, no views (tested)
Sources/EbbApp/      the SwiftUI app: menu bar popover and main window
Tests/               EbbAppKit tests, including scan → clean → put back
scripts/bundle.sh    builds build/Ebb.app
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
  and whether it regenerates; a side panel with the selected total split by
  regenerates / re-download / gone for good.
- **Active projects:** each protected project and the signals behind it.
- **History:** every clean, with Put back per item or for the whole clean,
  and how much from Ebb cleans still sits in the Trash.
- **Settings:** daily agent, notify threshold, battery limit, menu bar size,
  open at login; activeDays and each activity signal; folders to scan and
  skip; Always keep and the locked built-in never-touch list; custom rules;
  categories; About.
- **First run:** welcome, Full Disk Access (it notices when you switch it
  on), and the first scan, with the daily agent offered at the end.
- **Always keep** on any project (Active projects) or item (right-click in
  Recommendations).

## The daily agent

Turning the agent on writes `~/Library/LaunchAgents/com.serveka.ebb.agent.plist`
and loads it with `launchctl`. launchd then runs the app's own binary with
`--agent` every hour and at login, at background priority. Each run:

1. does nothing unless the agent is on, today's scan hasn't happened, it's
   past the day's earliest time (picked at random between 10:00 and 18:00
   when the agent is first turned on), the Mac has been idle for 2 minutes,
   and it's on power or the battery is above the limit (30% by default);
2. scans read-only and saves the result for the app;
3. notifies only if at least the threshold (2 GB) can be cleared, it grew
   since the last notification (or you cleaned since), and none was shown
   today. Clicking the notification opens Recommendations.

The agent never cleans. Turning it off unloads the job and removes the
plist. Logs go to `~/Library/Logs/Ebb/agent.log`.

To try one run by hand: `build/Ebb.app/Contents/MacOS/Ebb --agent --now`
(skips the time, idle and power checks).

Cleaning goes through `EbbClean`: every item is checked again right before
it moves, only moves to the Trash, and is logged. Items that need a command
(`pnpm store prune`, `go clean -modcache`, Docker prune) show the command
and can't be ticked.

The app scans when it starts if the last scan is from an earlier day, and
keeps the result in `~/Library/Application Support/Ebb/last-scan.json`.
Settings live next to it in `settings.json`, shared with the `ebb` CLI.
