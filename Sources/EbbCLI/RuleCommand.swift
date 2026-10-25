import ArgumentParser
import Foundation
import ScanCore

struct RuleCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rule",
        abstract: "Manage custom rules in rules.json.",
        subcommands: [Add.self, List.self]
    )

    struct Add: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Add a custom rule.",
            discussion: """
            Suggest rules list matches under "worth a look"; they're never pre-selected, \
            and built-in protections still apply. --never-touch rules protect matches \
            from every category and rule.

            Examples:
              ebb rule add '\\.mov$' --in ~/Movies --older 90d --larger 500MB --name "Old screen recordings"
              ebb rule add '^client-' --in ~/code --never-touch
            """
        )

        @Argument(help: ArgumentHelp("Regular expression (ICU syntax, as in NSRegularExpression).",
                                     valueName: "regex"))
        var pattern: String

        @Option(name: .customLong("in"), help: ArgumentHelp(
            "Folder to look in (repeatable). Required unless --never-touch.", valueName: "dir"
        ))
        var roots: [String] = []

        @Option(help: ArgumentHelp("Only files not changed in this long, e.g. 14d or 2w.", valueName: "age"))
        var older: String?

        @Option(help: ArgumentHelp("Only files at least this big, e.g. 50MB or 1.5GB.", valueName: "size"))
        var larger: String?

        @Flag(help: "Protect matches instead of suggesting them.")
        var neverTouch = false

        @Flag(help: "Match the full path instead of just the file name.")
        var fullPath = false

        @Option(help: "A name for the rule. Defaults to the pattern.")
        var name: String?

        @Option(help: ArgumentHelp(
            "What happens after clearing: no, redownload, or a how-to such as \"re-export from Final Cut\".",
            valueName: "label"
        ))
        var comesBack: String?

        var olderThanDays: Int? {
            get throws { try older.map(Duration.days) }
        }

        var largerThanMB: Double? {
            get throws {
                try larger.map { text in
                    guard let bytes = ByteCount.parse(text) else {
                        throw ValidationError("Can't read size '\(text)'. Try 50MB or 1.5GB.")
                    }
                    return Double(bytes) / 1_000_000
                }
            }
        }

        func validate() throws {
            _ = try olderThanDays
            _ = try largerThanMB
            if !neverTouch && roots.isEmpty {
                throw ValidationError("Say where to look with --in <dir>.")
            }
        }

        func makeRule(home: String) throws -> Rule {
            Rule(
                name: name ?? pattern,
                pattern: pattern,
                matchOn: fullPath ? .fullPath : .fileName,
                roots: roots.map { tildeAbbreviated(absolutePath($0, home: home), home: home) },
                olderThanDays: try olderThanDays,
                largerThanMB: try largerThanMB,
                action: neverTouch ? .neverTouch : .suggest,
                comesBack: Self.comesBack(from: comesBack)
            )
        }

        static func comesBack(from label: String?) -> ComesBack {
            switch label?.trimmingCharacters(in: .whitespaces).lowercased() {
            case nil, "", "no": return .no
            case "redownload", "re-download": return .redownload
            default: return .yes(howTo: label ?? "")
            }
        }

        mutating func run() throws {
            let home = ScanOptions.currentUser().home
            let store = RuleStore(fileURL: RuleStore.defaultLocation(home: home))
            let rule: Rule
            do {
                rule = try store.add(try makeRule(home: home))
            } catch let error as RuleError {
                throw ValidationError(error.description)
            }
            let verb = rule.action == .neverTouch ? "Protecting" : "Suggesting"
            print("  Added rule \(rule.id): \(verb) matches of /\(rule.pattern)/ in "
                + (rule.roots.isEmpty ? "every folder" : rule.roots.joined(separator: ", ")))
            print("  Saved to \(abbreviate(store.fileURL.path, home: home)). `ebb scan` will use it.")
        }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show custom rules.")

        @Flag(help: "Print rules.json as stored.")
        var json = false

        mutating func run() throws {
            let home = ScanOptions.currentUser().home
            let store = RuleStore(fileURL: RuleStore.defaultLocation(home: home))
            let file = try store.load()
            if json {
                print(String(decoding: try RuleStore.encode(file.rules), as: UTF8.self))
                return
            }
            if file.rules.isEmpty {
                print("  No custom rules. Add one with `ebb rule add <regex> --in <dir>`.")
            } else {
                let rows = file.rules.map { rule -> [String] in
                    var limits: [String] = []
                    if let days = rule.olderThanDays { limits.append("older than \(days)d") }
                    if let megabytes = rule.largerThanMB {
                        limits.append("larger than \(ByteCount.format(Int64(megabytes * 1_000_000)))")
                    }
                    return [
                        rule.id,
                        rule.action == .neverTouch ? "never touch" : "suggest",
                        rule.name,
                        "/\(rule.pattern)/" + (rule.matchOn == .fullPath ? " (path)" : ""),
                        rule.roots.isEmpty ? "everywhere" : rule.roots.joined(separator: ", "),
                        limits.joined(separator: ", "),
                    ]
                }
                print(Table(rows: rows, rightAligned: []).render(), terminator: "")
            }
            var stderr = StandardError()
            for problem in file.problems { print("  note: \(problem)", to: &stderr) }
        }
    }
}

/// Keeps rules portable between Macs: `/Users/me/Movies` is stored as
/// `~/Movies`.
func tildeAbbreviated(_ path: String, home: String) -> String {
    abbreviate(path, home: home)
}

/// Parses ages typed on the command line: `14d`, `2w`, `3m` (30-day
/// months), `1y`, or a bare number of days.
enum Duration {
    static func days(_ text: String) throws -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        let digits = trimmed.prefix { $0.isNumber }
        let multipliers = ["": 1, "d": 1, "w": 7, "m": 30, "y": 365]
        guard let value = Int(digits), let multiplier = multipliers[String(trimmed.dropFirst(digits.count))]
        else {
            throw ValidationError("Can't read age '\(text)'. Try 14d, 2w or 6m.")
        }
        return value * multiplier
    }
}
