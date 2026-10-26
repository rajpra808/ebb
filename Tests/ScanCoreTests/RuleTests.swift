import Foundation
import Testing
@testable import ScanCore

@Suite("Custom rules")
struct RuleTests {
    @Test("A suggest rule finds matching files and never pre-selects them")
    func suggestMatches() async throws {
        let fixture = try Fixture()
        let big = try fixture.file("Movies/screen-2026-01.mov", size: 300_000)
        try fixture.file("Movies/small.mov", size: 1_000)
        let young = try fixture.file("Movies/recent.mov", size: 300_000)
        try fixture.file("Movies/keep.mp4", size: 300_000)
        try fixture.ageEverything(days: 120)
        try fixture.setAge(young, days: 10)

        let rule = Rule(name: "Old recordings", pattern: #"\.mov$"#, roots: ["~/Movies"],
                        olderThanDays: 30, largerThanMB: 0.1)
        let result = try await fixture.scan(rules: [rule])

        let matches = result.items(in: "custom-rules")
        #expect(matches.map(\.path) == [big])
        let item = try #require(matches.first)
        #expect(!item.preselected)
        #expect(item.ruleID == rule.id)
        #expect(item.reason == "Matches your rule 'Old recordings'")
        #expect(item.comesBack == .no)
        #expect(result.totals.worthALookBytes == item.allocatedBytes)
        #expect(result.totals.safeToClearBytes == 0)
    }

    @Test("Full-path rules match against the whole path")
    func fullPathMatching() async throws {
        let fixture = try Fixture()
        let match = try fixture.file("exports/2024/q1/report.csv")
        try fixture.file("exports/2025/q1/report.csv")
        try fixture.ageEverything()

        let rule = Rule(name: "2024 exports", pattern: "/2024/", matchOn: .fullPath, roots: ["~/exports"])
        let result = try await fixture.scan(rules: [rule])
        #expect(result.items(in: "custom-rules").map(\.path) == [match])
    }

    @Test("An invalid regex is skipped with a warning, and the scan still runs")
    func invalidRegex() async throws {
        let fixture = try Fixture()
        try fixture.file("Downloads/old.dmg")
        try fixture.ageEverything()

        let broken = Rule(name: "broken", pattern: "([unclosed", roots: ["~"])
        let result = try await fixture.scan(rules: [broken])
        #expect(result.warnings.contains { $0.contains("Skipped rule 'broken'") })
        #expect(result.items(in: "old-installers").count == 1)
        #expect(throws: RuleError.invalidPattern("([unclosed")) { try broken.validate() }
    }

    @Test("neverTouch beats suggest")
    func neverTouchBeatsSuggest() async throws {
        let fixture = try Fixture()
        let keep = try fixture.file("archive/client-acme/footage.mov")
        let drop = try fixture.file("archive/other/footage.mov")
        try fixture.ageEverything()

        let rules = [
            Rule(name: "movies", pattern: #"\.mov$"#, roots: ["~/archive"]),
            Rule(name: "clients", pattern: "^client-", roots: ["~/archive"], action: .neverTouch),
        ]
        let result = try await fixture.scan(rules: rules)
        #expect(result.item(at: keep) == nil)
        #expect(result.item(at: drop) != nil)
        #expect(result.skip(at: keep)?.reason.detail == "matches your never-touch rule 'clients'")
    }

    @Test("neverTouch rules also protect built-in categories")
    func neverTouchBeatsCategories() async throws {
        let fixture = try Fixture()
        try fixture.project("code/legacy")
        try fixture.file("code/legacy/node_modules/x.js")
        let dmg = try fixture.file("Downloads/License-Key-Installer.dmg")
        try fixture.ageEverything()

        let rules = [
            Rule(name: "legacy", pattern: "/code/legacy", matchOn: .fullPath, roots: [], action: .neverTouch),
            Rule(name: "license", pattern: "(?i)license", roots: ["~/Downloads"], action: .neverTouch),
        ]
        let result = try await fixture.scan(rules: rules)
        #expect(result.item(at: fixture.absolute("code/legacy/node_modules")) == nil)
        #expect(result.item(at: dmg) == nil)
    }

    @Test("A neverTouch match deep inside a candidate protects the candidate")
    func neverTouchInsideCandidate() async throws {
        let fixture = try Fixture()
        try fixture.file(Paths.join(fixture.temp, "job/output/signed.p8"))
        try fixture.ageEverything(days: 10)

        let rule = Rule(name: "keys", pattern: #"\.p8$"#, roots: [fixture.temp], action: .neverTouch)
        let result = try await fixture.scan(rules: [rule])
        #expect(result.item(at: Paths.join(fixture.temp, "job")) == nil)
    }

    @Test("Suggest rules still respect active projects")
    func suggestRespectsActiveProjects() async throws {
        let fixture = try Fixture()
        try fixture.project("code/live")
        let log = try fixture.file("code/live/debug.log")
        let edit = try fixture.file("code/live/main.ts")
        try fixture.ageEverything()
        try fixture.setAge(edit, days: 1)

        let rule = Rule(name: "logs", pattern: #"\.log$"#, roots: ["~/code"])
        let result = try await fixture.scan(rules: [rule])
        #expect(result.item(at: log) == nil)
    }

    @Test("A catastrophic pattern is time-boxed and doesn't hang the scan")
    func catastrophicPattern() async throws {
        let fixture = try Fixture()
        // Classic exponential backtracking: (a+)+$ against aaaa...b.
        try fixture.file("evil/" + String(repeating: "a", count: 40) + "b")
        try fixture.ageEverything()

        let rule = Rule(name: "evil", pattern: "^(a+)+$", roots: ["~/evil"])
        let started = Date()
        var options = fixture.options(rulesTimeLimit: 1)
        options.checkOpenFiles = false
        let result = try await fixture.scanner(options: options, rules: [rule]).scan()
        // The rule gets 1 s. The bound only catches a hang: on a busy CI
        // runner, with every suite in parallel, the rest of the scan can take
        // a while.
        #expect(Date().timeIntervalSince(started) < 60)
        #expect(result.items(in: "custom-rules").isEmpty)
        #expect(result.warnings.contains { $0.contains("stopped after") })
    }

    @Test("A suggest rule needs folders; a neverTouch rule doesn't")
    func validation() throws {
        #expect(throws: RuleError.noFolders) { try Rule(name: "x", pattern: "x", roots: []).validate() }
        try Rule(name: "x", pattern: "x", roots: [], action: .neverTouch).validate()
        #expect(throws: RuleError.emptyName) { try Rule(name: " ", pattern: "x", roots: ["~"]).validate() }
        #expect(throws: RuleError.negativeThreshold) {
            try Rule(name: "x", pattern: "x", roots: ["~"], olderThanDays: -1).validate()
        }
    }
}

@Suite("Rule store")
struct RuleStoreTests {
    @Test("Rules round-trip through rules.json")
    func roundTrip() throws {
        let fixture = try Fixture()
        let store = RuleStore(fileURL: URL(fileURLWithPath: fixture.absolute("support/rules.json")))
        #expect(try store.load().rules.isEmpty)

        let first = try store.add(Rule(name: "a", pattern: #"\.mov$"#, roots: ["~/Movies"], olderThanDays: 90,
                                       largerThanMB: 500, comesBack: .yes(howTo: "re-export")))
        let second = try store.add(Rule(name: "b", pattern: "^secret", roots: [], action: .neverTouch))
        let loaded = try store.load()
        #expect(loaded.rules == [first, second])
        #expect(loaded.problems.isEmpty)
    }

    @Test("Adding an invalid rule fails and leaves the file alone")
    func invalidAdd() throws {
        let fixture = try Fixture()
        let store = RuleStore(fileURL: URL(fileURLWithPath: fixture.absolute("rules.json")))
        #expect(throws: RuleError.self) { try store.add(Rule(name: "bad", pattern: "(", roots: ["~"])) }
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    @Test("One unreadable entry doesn't hide the others, and blocks saving over it")
    func lenientLoading() throws {
        let fixture = try Fixture()
        let json = """
        { "version": 1, "rules": [
          { "id": "good", "name": "Good", "pattern": "x", "roots": ["~"], "action": "suggest" },
          { "id": "bad", "name": "Bad", "action": "explode" }
        ] }
        """
        let path = try fixture.file("rules.json")
        try json.write(toFile: path, atomically: true, encoding: .utf8)
        let store = RuleStore(fileURL: URL(fileURLWithPath: path))

        let file = try store.load()
        #expect(file.rules.map(\.id) == ["good"])
        #expect(file.unreadableEntries == 1)
        #expect(throws: RuleStoreError.self) { try store.add(Rule(name: "n", pattern: "n", roots: ["~"])) }
        #expect(try String(contentsOfFile: path, encoding: .utf8) == json)
    }

    @Test("Minimal entries get defaults")
    func defaults() throws {
        let json = #"{ "version": 1, "rules": [ { "id": "r", "name": "R", "pattern": "\\.log$" } ] }"#
        let rule = try #require(try RuleStore.decode(Data(json.utf8)).rules.first)
        #expect(rule.matchOn == .fileName)
        #expect(rule.action == .suggest)
        #expect(rule.comesBack == .no)
        #expect(rule.roots.isEmpty)
    }
}
