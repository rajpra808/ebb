import Foundation
import Testing
@testable import ScanCore

@Suite("Active-work protection")
struct ActiveProjectTests {
    @Test("A recent source edit protects the whole project")
    func recentEdit() async throws {
        let fixture = try Fixture()
        let project = try fixture.project("code/app")
        try fixture.file("code/app/node_modules/lib/index.js", size: 50_000)
        try fixture.file("code/app/.venv/pyvenv.cfg")
        let source = try fixture.file("code/app/src/main.ts")
        try fixture.ageEverything()
        try fixture.setAge(source, days: 3)

        let result = try await fixture.scan()
        #expect(!result.reports(anythingOverlapping: project))
        let active = try #require(result.activeProjects.first { $0.path == project })
        #expect(active.signals.map(\.signal).contains("recent-edit"))
        #expect(active.signals.first { $0.signal == "recent-edit" }?.detail == "src/main.ts edited 3 days ago")
    }

    @Test("Recent git activity protects the project even with old files")
    func recentGitHead() async throws {
        let fixture = try Fixture()
        let project = try fixture.project("code/api")
        try fixture.file("code/api/node_modules/lib/index.js", size: 50_000)
        try fixture.file("code/api/.git/HEAD", size: 30)
        try fixture.file("code/api/.git/logs/HEAD", size: 300)
        try fixture.ageEverything()
        try fixture.setAge(fixture.absolute("code/api/.git/logs/HEAD"), days: 2)

        let result = try await fixture.scan()
        #expect(!result.reports(anythingOverlapping: project))
        let active = try #require(result.activeProjects.first { $0.path == project })
        #expect(active.signals.map(\.signal) == ["git"])
        #expect(active.signals.first?.detail == "git commit or checkout 2 days ago")
    }

    @Test("Each git file counts: HEAD and index too")
    func gitIndexAndHead() async throws {
        for file in ["HEAD", "index"] {
            let fixture = try Fixture()
            let project = try fixture.project("code/p")
            try fixture.file("code/p/node_modules/x.js")
            try fixture.file("code/p/.git/\(file)", size: 30)
            try fixture.ageEverything()
            try fixture.setAge(fixture.absolute("code/p/.git/\(file)"), days: 1)

            let result = try await fixture.scan()
            #expect(!result.reports(anythingOverlapping: project), "git \(file)")
        }
    }

    @Test("Worktrees: a .git file pointing elsewhere is followed for activity")
    func worktreeGitFile() async throws {
        let fixture = try Fixture()
        let project = try fixture.project("code/feature")
        try fixture.file("code/feature/node_modules/x.js")
        let gitDir = try fixture.folder("code/main/.git/worktrees/feature")
        try fixture.file("code/main/.git/worktrees/feature/HEAD", size: 40)
        let pointer = fixture.absolute("code/feature/.git")
        try "gitdir: \(gitDir)\n".write(toFile: pointer, atomically: true, encoding: .utf8)
        try fixture.ageEverything()
        try fixture.setAge(Paths.join(gitDir, "HEAD"), days: 1)

        let result = try await fixture.scan()
        #expect(!result.reports(anythingOverlapping: project))
    }

    @Test("Edits inside leftover folders don't make a project active")
    func leftoverEditsDontCount() async throws {
        let fixture = try Fixture()
        let project = try fixture.project("code/old")
        try fixture.file("code/old/index.js")
        let installed = try fixture.file("code/old/node_modules/lib/new.js")
        try fixture.ageEverything()
        // Changed 5 days ago: within activeDays but outside the 24 h window.
        try fixture.setAge(installed, days: 5)

        let result = try await fixture.scan()
        #expect(result.activeProjects.isEmpty)
        let item = try #require(result.item(at: fixture.absolute("code/old/node_modules")))
        #expect(item.projectPath == project)
    }

    @Test("activeDays decides where active ends")
    func activeDaysWindow() async throws {
        let fixture = try Fixture()
        let project = try fixture.project("code/mid")
        try fixture.file("code/mid/node_modules/x.js")
        let source = try fixture.file("code/mid/main.go")
        try fixture.ageEverything()
        try fixture.setAge(source, days: 20)

        let strict = try await fixture.scan { $0.activeDays = 30 }
        #expect(!strict.reports(anythingOverlapping: project))

        let relaxed = try await fixture.scan { $0.activeDays = 14 }
        #expect(relaxed.item(at: fixture.absolute("code/mid/node_modules")) != nil)
    }

    @Test("A monorepo is one project: activity in one package protects all")
    func monorepoIsOneProject() async throws {
        let fixture = try Fixture()
        let root = try fixture.project("code/mono")
        try fixture.file("code/mono/packages/web/package.json")
        try fixture.file("code/mono/packages/web/node_modules/x.js")
        try fixture.file("code/mono/packages/api/package.json")
        let edit = try fixture.file("code/mono/packages/api/server.ts")
        try fixture.ageEverything()
        try fixture.setAge(edit, days: 1)

        let result = try await fixture.scan()
        #expect(!result.reports(anythingOverlapping: root))
        #expect(result.activeProjects.map(\.path) == [root])
    }

    @Test("Projects inside node_modules or hidden tool folders aren't discovered")
    func discoveryIgnoresDependencyTrees() async throws {
        let fixture = try Fixture()
        try fixture.file(".nvm/versions/node/v20/lib/node_modules/npm/package.json")
        try fixture.file("Library/Application Support/Thing/package.json")
        try fixture.project("code/real")
        try fixture.ageEverything()

        let found = await ProjectDiscovery(excluded: PathSet([fixture.absolute("Library")]),
                                           allowOtherVolumes: false, maxConcurrency: 2)
            .projects(under: [fixture.home])
        #expect(found.map(\.root) == [fixture.absolute("code/real")])
    }

    @Test("Custom signals plug in through ActivitySignal")
    func customSignal() async throws {
        struct PinnedSignal: ActivitySignal {
            let id = "pinned"
            let pinned: String
            func evaluate(_ project: Project, in context: ActivityContext) async -> ActivityEvidence? {
                project.root == pinned ? ActivityEvidence(signal: id, detail: "always keep", date: nil) : nil
            }
        }

        let fixture = try Fixture()
        let project = try fixture.project("code/keep")
        try fixture.file("code/keep/node_modules/x.js")
        try fixture.ageEverything()

        var scanner = try fixture.scanner()
        scanner.signals.append(PinnedSignal(pinned: project))
        let result = await scanner.scan()
        #expect(!result.reports(anythingOverlapping: project))
        #expect(result.activeProjects.first?.signals.map(\.signal) == ["pinned"])
    }

    @Test("ebb active lists the same projects a scan protects")
    func activeOnly() async throws {
        let fixture = try Fixture()
        let busy = try fixture.project("code/busy")
        try fixture.project("code/idle")
        try fixture.ageEverything()
        try fixture.setAge(Paths.join(busy, "package.json"), days: 1)

        let scanner = try fixture.scanner()
        let found = await scanner.activeProjects()
        #expect(found.projects.map(\.path) == [busy])
        #expect(found.inactiveCount == 1)
    }
}
