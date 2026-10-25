# Contributing

Thanks for helping. Ebb looks at people's disks, so the bar for safety is
higher than for most projects. A missed cleanup costs a few megabytes; a wrong
one costs someone's work.

## Ground rules

- **ScanCore stays read-only.** No `removeItem`, `trashItem` or writes outside
  `~/Library/Application Support/Ebb/` and test temp folders. Moving to the
  Trash lives in `EbbClean`, only behind an explicit user action, and never
  calls `removeItem` on user data.
- **Never follow symlinks.** Use `FileSystem.status` (`lstat`) and
  `FileSystem.entries` (`readdir`), not `FileManager` enumerators, so this
  stays explicit.
- **When unsure, leave it out.** If a check can't get an answer (git missing,
  folder unreadable, regex timed out), skip the item and say why.
- **The never-touch list only grows.** Removing an entry needs a strong reason
  in the pull request.

## Workflow

```
swift build
./scripts/test.sh          # or `swift test` with Xcode
swift run ebb scan --details
```

Every change that affects what gets reported needs a test with a fixture
tree. `Tests/ScanCoreTests/Fixtures/Fixture.swift` builds a fake home folder
(laid out as `<tmp>/Users/me`) with helpers for files, symlinks, hard links
and ages.

`NeverTouchTests` is the release gate. If you add a category or a rule
feature, add a case there showing it can't reach protected files.

## Style

- Follow the existing code: plain structs, small files, one type per concern.
- Doc comments explain *why*, not what the next line does.
- Error and reason text is written for the person reading `ebb scan`: short,
  concrete, no jargon. "Project inactive 41 days", not "inactivity threshold
  exceeded".
- `.swift-format` and `.editorconfig` hold the formatting settings (4 spaces,
  110 columns).

## Commits and pull requests

- Small commits with a clear subject line in the imperative ("Add uv cache to
  package caches"), and a body when the reason isn't obvious.
- For new categories, paste the relevant `ebb scan --details` lines from your
  own machine into the pull request.

By contributing you agree your work is released under the MIT license.
