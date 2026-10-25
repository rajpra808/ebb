# Custom rules

Custom rules let you add your own patterns on top of the built-in categories.
They're stored in `~/Library/Application Support/Ebb/rules.json`
(`~/.local/share/ebb/rules.json` on Linux), and the same file format is used
for import and export.

There are two kinds:

- **`suggest`** rules list matching files under "worth a look". They are
  **never pre-selected**, and every built-in check still applies: the
  never-touch list, active projects, files changed in the last 24 hours, and
  open files.
- **`neverTouch`** rules protect matches from every category and every other
  rule. A never-touch match anywhere inside a candidate folder protects the
  whole folder.

## From the command line

```
ebb rule add <regex> --in <dir> [--in <dir>...] [--older 14d] [--larger 50MB]
             [--never-touch] [--full-path] [--name "..."] [--comes-back "..."]
ebb rule list [--json]
```

Examples:

```
# Screen recordings older than 3 months and bigger than 500 MB
ebb rule add '\.mov$' --in ~/Movies --older 3m --larger 500MB --name "Old screen recordings"

# Never suggest anything in client folders, anywhere
ebb rule add '^client-' --never-touch --name "Client work"

# Match on the full path instead of the file name
ebb rule add '/exports/2024/' --full-path --in ~/Documents --name "2024 exports"
```

- Ages: `14d`, `2w`, `3m` (30-day months), `1y`, or a number of days.
- Sizes: decimal units, `50MB`, `1.5GB`, `200k`.
- `--comes-back`: `no` (default, "gone for good"), `redownload`, or any how-to
  text such as `"re-export from Final Cut"`.
- Folders are stored with `~` so the file works on another Mac.

`ebb scan` picks rules up automatically.

## Matching

- Patterns use ICU syntax (`NSRegularExpression`) and match anywhere in the
  string unless you anchor them with `^` and `$`.
- `fileName` (default) tests the file name. For never-touch rules, every folder
  name below the rule's folder is tested too, so `^client-` protects
  `~/code/client-acme/anything`.
- `fullPath` tests the absolute path.
- Suggest rules match regular files only. They don't enter protected folders,
  active projects, other disks, or iCloud placeholders.

## Limits

- **Invalid rules are skipped, never fatal.** `ebb rule add` refuses an
  invalid regex. If `rules.json` is edited by hand and contains one, the scan
  skips that rule and prints a warning. An entry that can't be read at all is
  skipped too, and `rule add` won't save over the file until it's fixed, so it
  never silently drops your rules.
- **Time-boxed.** Each rule gets 15 seconds per folder for walking and
  matching combined. A pattern that backtracks badly, like `^(a+)+$`, is
  stopped part-way; matches found so far are kept and the scan reports a
  warning. A never-touch rule that can't decide on a path within 0.25 s
  counts as a match, so the path is protected.
- **10,000 matches per rule and folder.** More than that is almost certainly
  too broad a pattern; the rest are dropped with a warning.

## File format

```json
{
  "version": 1,
  "rules": [
    {
      "id": "3f2a9c1e",
      "name": "Old screen recordings",
      "pattern": "\\.mov$",
      "matchOn": "fileName",
      "roots": ["~/Movies"],
      "olderThanDays": 90,
      "largerThanMB": 500,
      "action": "suggest",
      "comesBack": { "kind": "no" }
    }
  ]
}
```

Only `id`, `name` and `pattern` are required. Defaults: `matchOn: fileName`,
`roots: []` (allowed only for never-touch rules, meaning everywhere),
`action: suggest`, `comesBack: no`.
