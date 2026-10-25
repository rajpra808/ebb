import Foundation
import Testing
@testable import ScanCore

/// The release gate from spec §8: none of this may ever be reported, even
/// with a custom rule that matches everything.
@Suite("Never-touch")
struct NeverTouchTests {
    /// Suggests every file under home and temp.
    static func matchEverything(_ fixture: Fixture) -> [Rule] {
        [
            Rule(name: "everything", pattern: ".*", roots: [fixture.home, fixture.temp]),
            Rule(name: "every path", pattern: ".*", matchOn: .fullPath, roots: [fixture.home]),
        ]
    }

    @Test("Protected names are never reported, even by a .* rule", arguments: [
        ".git/config", ".env", ".env.local", ".env.production", "CLAUDE.md", "CLAUDE.local.md",
        "AGENTS.md", ".credentials.json", ".netrc", ".npmrc", "id.pem", "login.keychain-db",
    ])
    func protectedNames(relative: String) async throws {
        let fixture = try Fixture()
        let path = try fixture.file("notes/\(relative)")
        try fixture.ageEverything()

        let result = try await fixture.scan(rules: Self.matchEverything(fixture))
        #expect(!result.reports(anythingOverlapping: path), "\(relative) was reported")
    }

    @Test("Protected locations are never reported, even by a .* rule", arguments: [
        ".claude/settings.json", ".claude/settings.local.json", ".claude/.credentials.json",
        ".claude/projects/-Users-me-code/memory/notes.md", ".claude.json",
        ".codex/config.toml", ".codex/auth.json", ".ssh/id_ed25519", ".aws/credentials",
        "Library/Keychains/login.keychain-db", "Library/Application Support/Ebb/rules.json",
        ".Trash/old.dmg",
    ])
    func protectedPaths(relative: String) async throws {
        let fixture = try Fixture()
        let path = try fixture.file(relative)
        try fixture.ageEverything()

        let result = try await fixture.scan(rules: Self.matchEverything(fixture))
        #expect(!result.reports(anythingOverlapping: path), "\(relative) was reported")
    }

    @Test("A temp folder holding a .git or .env is skipped as a whole")
    func protectedInsideCandidate() async throws {
        let fixture = try Fixture()
        try fixture.file(Paths.join(fixture.temp, "checkout/.git/HEAD"))
        try fixture.file(Paths.join(fixture.temp, "checkout/readme.md"))
        try fixture.file(Paths.join(fixture.temp, "deploy/.env"))
        try fixture.ageEverything(days: 10)

        let result = try await fixture.scan()
        for name in ["checkout", "deploy"] {
            let folder = Paths.join(fixture.temp, name)
            #expect(result.item(at: folder) == nil)
            #expect(result.skip(at: folder)?.reason.code == .protected)
        }
    }

    @Test("A file changed an hour ago is never reported")
    func recentlyModified() async throws {
        let fixture = try Fixture()
        let installer = try fixture.file("Downloads/old.dmg")
        let temp = try fixture.file(Paths.join(fixture.temp, "render.tmp"))
        let ruleMatch = try fixture.file("Movies/clip.mov")
        try fixture.ageEverything(days: 60)
        for path in [installer, temp, ruleMatch] { try fixture.setAge(path, hours: 1) }

        let result = try await fixture.scan(rules: Self.matchEverything(fixture))
        for path in [installer, temp, ruleMatch] {
            #expect(!result.reports(anythingOverlapping: path), "\(path) was reported")
        }
    }

    @Test("A recent change deep inside an inactive project's node_modules blocks it")
    func recentInsideLeftover() async throws {
        let fixture = try Fixture()
        try fixture.project("code/app")
        let fresh = try fixture.file("code/app/node_modules/.cache/fresh.json")
        try fixture.ageEverything()
        try fixture.setAge(fresh, hours: 1)

        let result = try await fixture.scan()
        let modules = fixture.absolute("code/app/node_modules")
        #expect(result.item(at: modules) == nil)
        #expect(result.skip(at: modules)?.reason.code == .modifiedRecently)
    }

    @Test("Symlinks escaping the root are not followed or reported")
    func escapingSymlinks() async throws {
        let fixture = try Fixture()
        let secret = try fixture.file(Paths.join(fixture.outside, "big/data.bin"), size: 200_000)
        try fixture.project("code/app")
        try fixture.file("code/app/node_modules/real.js", size: 1000)
        try fixture.symlink("code/app/node_modules/escape", to: Paths.parent(of: secret))
        try fixture.symlink("Downloads/link.dmg", to: secret)
        try fixture.symlink(Paths.join(fixture.temp, "link-dir"), to: Paths.parent(of: secret))
        try fixture.symlink("code/linked-project", to: fixture.outside)
        try fixture.ageEverything()

        let result = try await fixture.scan(rules: Self.matchEverything(fixture))
        #expect(!result.reports(anythingOverlapping: secret))
        #expect(!result.reports(anythingOverlapping: fixture.outside))
        #expect(result.item(at: fixture.absolute("Downloads/link.dmg")) == nil)
        #expect(result.item(at: Paths.join(fixture.temp, "link-dir")) == nil)

        // The symlink counts as its own few bytes, not as its target.
        let modules = try #require(result.item(at: fixture.absolute("code/app/node_modules")))
        #expect(modules.allocatedBytes < 100_000)
    }

    @Test("Open files are never reported")
    func openFiles() async throws {
        let fixture = try Fixture()
        let open = try fixture.file(Paths.join(fixture.temp, "session/log.txt"))
        let installer = try fixture.file("Downloads/inuse.dmg")
        try fixture.ageEverything(days: 60)

        let gate = SafetyGate(
            neverTouch: NeverTouchList(home: fixture.home),
            neverTouchRules: [],
            activeProjects: ProjectIndex(roots: []),
            openFiles: OpenFiles(paths: [open, installer]),
            userID: getuid(),
            now: fixture.now,
            recentlyChangedSince: fixture.now.addingTimeInterval(-86_400)
        )
        for path in [Paths.parent(of: open), installer] {
            let candidate = Candidate(path: path, categoryID: "temp-files", comesBack: .no, preselected: true,
                                      describe: { _, _ in "" })
            guard case .skipped(let reason) = gate.check(candidate) else {
                Issue.record("\(path) passed the gate while open")
                continue
            }
            #expect(reason.code == .openByProcess)
        }
    }

    @Test("Other users' home folders are protected")
    func otherUsers() {
        let list = NeverTouchList(home: "/Users/me")
        #expect(list.protection(for: "/Users/someone/node_modules") != nil)
        #expect(list.protection(for: "/Users/Shared/cache") != nil)
        #expect(list.protection(for: "/Users/me/code/node_modules") == nil)
        #expect(list.protection(for: "/Users/meow/x") != nil)
    }

    @Test("System locations are protected")
    func system() {
        let list = NeverTouchList(home: "/Users/me")
        for path in ["/System/Library/Caches", "/usr/local/lib", "/private/var/db/x"] {
            #expect(list.protection(for: path) != nil, "\(path)")
        }
    }

    @Test("Lookalike names are not over-protected")
    func lookalikes() {
        let list = NeverTouchList(home: "/Users/me")
        #expect(list.protection(for: "/Users/me/code/app/environment.ts") == nil)
        #expect(list.protection(for: "/Users/me/code/app/.github/workflows") == nil)
        #expect(list.protection(for: "/Users/me/.claude/projects/-x/session.jsonl") == nil)
        #expect(list.protection(for: "/Users/me/.claudette/settings.json") == nil)
    }

    @Test("Files owned by someone else are skipped")
    func notOwned() throws {
        let fixture = try Fixture()
        let gate = SafetyGate(
            neverTouch: NeverTouchList(home: fixture.home),
            neverTouchRules: [],
            activeProjects: ProjectIndex(roots: []),
            openFiles: OpenFiles(paths: []),
            userID: getuid() &+ 1,
            now: fixture.now,
            recentlyChangedSince: fixture.now
        )
        let file = try fixture.file("Downloads/a.dmg")
        let candidate = Candidate(path: file, categoryID: "old-installers", comesBack: .no, preselected: true,
                                  describe: { _, _ in "" })
        guard case .skipped(let reason) = gate.check(candidate) else {
            Issue.record("a file owned by another user passed the gate")
            return
        }
        #expect(reason.code == .notOwned)
    }
}

@Suite("Never-touch: protected paths inside items")
struct ProtectedPathsInsideTests {
    @Test("A protected path inside a candidate folder blocks the whole folder")
    func memoryInsideHistory() throws {
        let fixture = try Fixture()
        try fixture.file(".claude/projects/-Users-me-app/old.jsonl")
        try fixture.file(".claude/projects/-Users-me-app/memory/notes.md")
        try fixture.ageEverything()

        let gate = SafetyGate(
            neverTouch: NeverTouchList(home: fixture.home), neverTouchRules: [],
            activeProjects: ProjectIndex(roots: []), openFiles: OpenFiles(paths: []),
            userID: getuid(), now: fixture.now, recentlyChangedSince: fixture.now.addingTimeInterval(-86_400)
        )
        for folder in [".claude/projects/-Users-me-app", ".claude/projects", ".claude"] {
            let candidate = Candidate(path: fixture.absolute(folder), categoryID: "x", comesBack: .no,
                                      preselected: false, packageManaged: true, describe: { _, _ in "" })
            guard case .skipped(let reason) = gate.check(candidate) else {
                Issue.record("\(folder) passed the gate with memory inside")
                continue
            }
            #expect(reason.code == .protected, "\(folder)")
        }
    }

    @Test("Path entries are narrowed to the folder being walked")
    func narrowing() {
        let list = NeverTouchList(home: "/Users/me")
        let claude = list.pathEntries(within: "/Users/me/.claude/projects").map(\.pattern)
        #expect(claude.contains("/Users/me/.claude/projects/*/memory"))
        #expect(!claude.contains("/Users/me/.ssh"))
        #expect(list.pathEntries(within: "/Users/me/code/app/node_modules").isEmpty)
    }

    @Test("Key files in tool folders are protected", arguments: [".elevenlabs_key", ".elevenlabs_key.old", "server.key"])
    func keyFiles(name: String) {
        #expect(NeverTouchList(home: "/Users/me").protection(forName: name) != nil)
    }
}
