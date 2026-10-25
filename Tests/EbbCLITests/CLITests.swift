import ArgumentParser
import Foundation
import Testing
@testable import EbbCLI
@testable import ScanCore

@Suite("CLI parsing")
struct ParsingTests {
    @Test("scan is the default command")
    func defaultCommand() throws {
        let command = try Ebb.parseAsRoot([])
        #expect(command is Scan)
    }

    @Test("scan flags parse")
    func scanFlags() throws {
        let scan = try #require(try Ebb.parseAsRoot(["scan", "--json", "--details", "--active-days", "30",
                                                     "--in", "/tmp/code", "--library-caches"]) as? Scan)
        #expect(scan.json)
        #expect(scan.details)
        #expect(scan.flags.activeDays == 30)
        #expect(scan.flags.roots == ["/tmp/code"])
        #expect(scan.flags.libraryCaches)
        #expect(!scan.flags.allVolumes)
    }

    @Test("activeDays out of range is rejected")
    func activeDaysRange() {
        #expect(throws: (any Error).self) { try Ebb.parseAsRoot(["scan", "--active-days", "0"]) }
        #expect(throws: (any Error).self) { try Ebb.parseAsRoot(["active", "--active-days", "9999"]) }
    }

    @Test("rule add builds the rule the user described")
    func ruleAdd() throws {
        let add = try #require(try Ebb.parseAsRoot([
            "rule", "add", #"\.mov$"#, "--in", "/Users/me/Movies", "--older", "14d", "--larger", "50MB",
            "--name", "Old recordings", "--comes-back", "re-export from Final Cut",
        ]) as? RuleCommand.Add)
        let rule = try add.makeRule(home: "/Users/me")
        #expect(rule.name == "Old recordings")
        #expect(rule.pattern == #"\.mov$"#)
        #expect(rule.roots == ["~/Movies"])
        #expect(rule.olderThanDays == 14)
        #expect(rule.largerThanMB == 50)
        #expect(rule.action == .suggest)
        #expect(rule.matchOn == .fileName)
        #expect(rule.comesBack == .yes(howTo: "re-export from Final Cut"))
    }

    @Test("rule add --never-touch doesn't need a folder")
    func ruleAddNeverTouch() throws {
        let add = try #require(try Ebb.parseAsRoot(["rule", "add", "^client-", "--never-touch", "--full-path"])
            as? RuleCommand.Add)
        let rule = try add.makeRule(home: "/Users/me")
        #expect(rule.action == .neverTouch)
        #expect(rule.matchOn == .fullPath)
        #expect(rule.roots.isEmpty)
        #expect(rule.name == "^client-")
    }

    @Test("rule add needs --in for suggest rules")
    func ruleAddNeedsFolder() {
        #expect(throws: (any Error).self) { try Ebb.parseAsRoot(["rule", "add", "x"]) }
    }

    @Test("Bad ages and sizes are rejected with a clear message")
    func badValues() {
        #expect(throws: (any Error).self) { try Ebb.parseAsRoot(["rule", "add", "x", "--in", "/", "--older", "soon"]) }
        #expect(throws: (any Error).self) { try Ebb.parseAsRoot(["rule", "add", "x", "--in", "/", "--larger", "huge"]) }
    }

    @Test("Ages accept days, weeks, months and years", arguments: [
        ("14d", 14), ("2w", 14), ("3m", 90), ("1y", 365), ("7", 7),
    ])
    func durations(text: String, days: Int) throws {
        #expect(try Duration.days(text) == days)
    }

    @Test("Comes-back labels map to the model")
    func comesBackLabels() {
        #expect(RuleCommand.Add.comesBack(from: nil) == .no)
        #expect(RuleCommand.Add.comesBack(from: "no") == .no)
        #expect(RuleCommand.Add.comesBack(from: "Re-download") == .redownload)
        #expect(RuleCommand.Add.comesBack(from: "brew install x") == .yes(howTo: "brew install x"))
    }

    @Test("Paths resolve ~ and relative folders")
    func paths() {
        #expect(absolutePath("~/code", home: "/Users/me") == "/Users/me/code")
        #expect(absolutePath("~", home: "/Users/me") == "/Users/me")
        #expect(absolutePath("/opt/x", home: "/Users/me") == "/opt/x")
        #expect(absolutePath("sub", home: "/Users/me").hasSuffix("/sub"))
        #expect(abbreviate("/Users/me/Movies", home: "/Users/me") == "~/Movies")
        #expect(abbreviate("/Users/meow", home: "/Users/me") == "/Users/meow")
    }
}

@Suite("CLI output")
struct ReportTests {
    static func sampleResult() -> ScanResult {
        func item(_ path: String, _ category: String, _ bytes: Int64, project: String? = nil,
                  source: String? = nil, preselected: Bool = true, estimated: Bool = false) -> Item {
            Item(path: path, categoryID: category, allocatedBytes: bytes, sharedBytes: 0, isEstimated: estimated,
                 fileCount: 10, lastUsed: nil, comesBack: .yes(howTo: "npm i"), reason: "Project inactive 41 days",
                 preselected: preselected, projectPath: project, source: source, ruleID: nil, clearCommand: nil)
        }
        let items = [
            item("/Users/me/a/node_modules", "node-leftovers", 2_000_000_000, project: "/Users/me/a"),
            item("/Users/me/a/.next", "node-leftovers", 100_000_000, project: "/Users/me/a"),
            item("/Users/me/b/node_modules", "node-leftovers", 1_000_000_000, project: "/Users/me/b"),
            item("/Users/me/.npm/_cacache", "package-caches", 900_000_000, source: "npm"),
            item("/Users/me/Library/pnpm/store", "package-caches", 500_000_000, source: "pnpm store", estimated: true),
            item("/Users/me/Movies/x.mov", "custom-rules", 300_000_000, preselected: false),
        ]
        let categories = [
            Category(id: "node-leftovers", number: 6, title: "Node / JS build leftovers", summary: "",
                     comesBack: .yes(howTo: "npm i"), ruleDescription: "", preselected: true),
            Category(id: "package-caches", number: 8, title: "Package manager caches", summary: "",
                     comesBack: .yes(howTo: ""), ruleDescription: "", preselected: true),
            Category(id: "custom-rules", number: 0, title: "Custom rules", summary: "",
                     comesBack: .no, ruleDescription: "", preselected: false),
        ]
        return ScanResult(
            formatVersion: 1, startedAt: Date(), durationSeconds: 4.2, roots: ["/Users/me"], activeDays: 14,
            categories: categories, items: items,
            skipped: [SkippedItem(path: "/Users/me/c/node_modules", categoryID: "node-leftovers",
                                  reason: SkipReason(.activeProject, "in active project c"))],
            activeProjects: [
                ActiveProject(path: "/Users/me/c", markers: ["package.json"], signals: []),
                ActiveProject(path: "/Users/me/d", markers: [".git"], signals: []),
            ],
            totals: Scanner.totals(of: items, categories: categories),
            warnings: []
        )
    }

    @Test("Summary is aligned and ends with the totals")
    func summary() {
        let text = Report(result: Self.sampleResult(), home: "/Users/me").summary()
        let expected = """
          node-leftovers     3.1 GB   2 inactive projects
          package-caches    ~1.4 GB   npm, pnpm store
          custom-rules     300.0 MB   1 item

          skipped                     2 active projects
          safe to clear      4.5 GB
          worth a look     300.0 MB   not pre-selected

          Scanned in 4.2s. Nothing was changed. ~ means estimated.

        """
        #expect(text == expected)
    }

    @Test("Details list items biggest first with home abbreviated")
    func details() throws {
        let text = Report(result: Self.sampleResult(), home: "/Users/me").details()
        let lines = text.split(separator: "\n").map(String.init)
        let bigger = try #require(lines.firstIndex { $0.contains("~/a/node_modules") })
        let smaller = try #require(lines.firstIndex { $0.contains("~/b/node_modules") })
        #expect(bigger < smaller)
        #expect(!text.contains("/Users/me/"))
    }

    @Test("Empty results say so")
    func empty() {
        let result = ScanResult(
            formatVersion: 1, startedAt: Date(), durationSeconds: 1, roots: [], activeDays: 14, categories: [],
            items: [], skipped: [], activeProjects: [],
            totals: ScanTotals(safeToClearBytes: 0, worthALookBytes: 0, itemCount: 0, byCategory: []),
            warnings: []
        )
        let text = Report(result: result, home: "/Users/me").summary()
        #expect(text.contains("Nothing to clear right now."))
        #expect(text.contains("safe to clear   0 bytes"))
    }

    @Test("JSON output is stable: sorted keys and ISO dates")
    func json() throws {
        let text = try JSONOutput.encode(Self.sampleResult())
        #expect(text.contains(#""formatVersion" : 1"#))
        #expect(text.contains(#""safeToClearBytes" : 4500000000"#))
        let keys = ["activeDays", "activeProjects", "categories", "durationSeconds"]
        let positions = keys.compactMap { text.range(of: "\"\($0)\"")?.lowerBound }
        #expect(positions == positions.sorted())
    }
}
