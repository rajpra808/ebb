import Foundation
import Testing
@testable import ScanCore

@Suite("Categories")
struct CategoryTests {
    @Test("Bundled catalog loads with every spec category but 1 and 15")
    func catalogLoads() throws {
        let catalog = try CategoryCatalog.builtIn()
        let numbers = catalog.enabled.map(\.category.number).sorted()
        #expect(numbers == [2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14])
        #expect(catalog.definitions.allSatisfy { !$0.category.title.isEmpty && !$0.category.summary.isEmpty })
        // Spec §3: categories that can't come back are never pre-selected.
        for definition in catalog.definitions where definition.category.comesBack == .no {
            #expect(!definition.category.preselected, "\(definition.category.id)")
        }
    }

    @Test("Catalog rejects duplicate ids and unknown collectors")
    func catalogValidation() throws {
        let duplicate = """
        { "version": 1, "categories": [
          { "id": "a", "number": 1, "title": "A", "summary": "s", "comesBack": { "kind": "no" },
            "rule": "r", "preselected": false, "collector": { "type": "knownPaths", "paths": [] } },
          { "id": "a", "number": 2, "title": "B", "summary": "s", "comesBack": { "kind": "no" },
            "rule": "r", "preselected": false, "collector": { "type": "knownPaths", "paths": [] } }
        ] }
        """
        #expect(throws: CatalogError.duplicateID("a")) { try CategoryCatalog(data: Data(duplicate.utf8)) }

        let unknown = """
        { "version": 1, "categories": [
          { "id": "a", "number": 1, "title": "A", "summary": "s", "comesBack": { "kind": "no" },
            "rule": "r", "preselected": false, "collector": { "type": "magic" } }
        ] }
        """
        #expect(throws: (any Error).self) { try CategoryCatalog(data: Data(unknown.utf8)) }
    }

    // MARK: 5. Python virtual envs

    @Test("Venvs in inactive projects are reported with their allocated size")
    func pythonVenv() async throws {
        let fixture = try Fixture()
        try fixture.project("code/ml", marker: "requirements.txt")
        try fixture.file("code/ml/train.py")
        try fixture.file("code/ml/.venv/pyvenv.cfg", size: 100)
        try fixture.file("code/ml/.venv/lib/python3.12/site-packages/numpy/core.so", size: 300_000)
        // A folder called env without pyvenv.cfg is just a folder.
        try fixture.file("code/ml/env/settings.yaml")
        try fixture.ageEverything()

        let result = try await fixture.scan()
        let venv = fixture.absolute("code/ml/.venv")
        let item = try #require(result.item(at: venv))
        #expect(item.categoryID == "python-venvs")
        let expected = try fixture.allocatedSize(of: venv)
        #expect(item.allocatedBytes == expected)
        #expect(item.fileCount == 2)
        #expect(item.preselected)
        #expect(item.projectPath == fixture.absolute("code/ml"))
        #expect(item.reason.hasPrefix("Project inactive 60 days"))
        #expect(result.item(at: fixture.absolute("code/ml/env")) == nil)
    }

    // MARK: 6. Node / JS leftovers

    @Test("node_modules and build caches in inactive JS projects are reported")
    func nodeLeftovers() async throws {
        let fixture = try Fixture()
        try fixture.project("code/site")
        try fixture.file("code/site/src/index.ts")
        try fixture.file("code/site/node_modules/react/index.js", size: 50_000)
        try fixture.file("code/site/node_modules/react/package.json", size: 300)
        try fixture.file("code/site/.next/cache/webpack.pack", size: 120_000)
        try fixture.file("code/site/.turbo/log.txt")
        try fixture.file("code/site/dist/main.js", size: 20_000)
        try fixture.ageEverything()

        let result = try await fixture.scan()
        let found = Set(result.items(in: "node-leftovers").map { Paths.relative($0.path, to: fixture.home) })
        #expect(found == ["code/site/node_modules", "code/site/.next", "code/site/.turbo", "code/site/dist"])

        let modules = try #require(result.item(at: fixture.absolute("code/site/node_modules")))
        let expected = try fixture.allocatedSize(of: modules.path)
        #expect(modules.allocatedBytes == expected)
        #expect(modules.comesBack == .yes(howTo: "npm install (or pnpm/yarn/bun install), then rebuild"))
    }

    @Test("dist and build are left alone outside JS projects")
    func genericNamesNeedPackageJSON() async throws {
        let fixture = try Fixture()
        try fixture.project("code/tool", marker: "pyproject.toml")
        try fixture.file("code/tool/dist/tool-1.0.tar.gz")
        try fixture.file("code/tool/build/report.pdf")
        try fixture.ageEverything()

        let result = try await fixture.scan()
        #expect(result.items.isEmpty)
    }

    @Test("Build output that git tracks is skipped")
    func trackedDistIsSkipped() async throws {
        try #require(GitFixture.isAvailable, "needs git")
        let fixture = try Fixture()
        let project = try fixture.project("code/lib")
        try fixture.file("code/lib/dist/lib.js")
        try GitFixture.run(["init", "-q"], in: project)
        try GitFixture.run(["add", "."], in: project)
        try GitFixture.run(["commit", "-qm", "initial"], in: project)
        try fixture.ageEverything()

        let result = try await fixture.scan()
        let dist = fixture.absolute("code/lib/dist")
        #expect(result.item(at: dist) == nil)
        #expect(result.skip(at: dist)?.reason.code == .trackedByGit)
    }

    @Test("Untracked build output in a git project is reported")
    func untrackedDistIsReported() async throws {
        try #require(GitFixture.isAvailable, "needs git")
        let fixture = try Fixture()
        let project = try fixture.project("code/app")
        try fixture.file("code/app/index.js")
        try GitFixture.run(["init", "-q"], in: project)
        try GitFixture.run(["add", "package.json", "index.js"], in: project)
        try GitFixture.run(["commit", "-qm", "initial"], in: project)
        try fixture.file("code/app/dist/bundle.js")
        try fixture.ageEverything()

        let result = try await fixture.scan()
        #expect(result.item(at: fixture.absolute("code/app/dist")) != nil)
    }

    // MARK: 8. Package manager caches

    @Test("Package manager caches are reported whatever their age")
    func packageCaches() async throws {
        let fixture = try Fixture()
        try fixture.file(".npm/_cacache/content-v2/sha512/ab/cd", size: 80_000)
        try fixture.file("Library/Caches/pip/wheels/x.whl", size: 40_000)
        try fixture.file("Library/Caches/Homebrew/downloads/node.tar.gz", size: 60_000)
        try fixture.file("go/pkg/mod/github.com/x/y@v1/y.go", size: 10_000)
        try fixture.file("Library/pnpm/store/v10/files/00/abc", size: 10_000)
        try fixture.ageEverything(days: 2)

        let result = try await fixture.scan()
        let caches = result.items(in: "package-caches")
        #expect(Set(caches.compactMap(\.source)) == ["npm", "pip", "Homebrew", "Go modules", "pnpm store"])

        let npm = try #require(result.item(at: fixture.absolute(".npm/_cacache")))
        let expected = try fixture.allocatedSize(of: npm.path)
        #expect(npm.allocatedBytes == expected)
        #expect(npm.clearCommand == nil)

        let pnpm = try #require(result.item(at: fixture.absolute("Library/pnpm/store")))
        #expect(pnpm.isEstimated)
        #expect(pnpm.clearCommand == "pnpm store prune")
        #expect(result.item(at: fixture.absolute("go/pkg/mod"))?.clearCommand == "go clean -modcache")
    }

    @Test("A cache that is a symlink is not followed")
    func symlinkedCacheIsIgnored() async throws {
        let fixture = try Fixture()
        try fixture.file(Paths.join(fixture.outside, "npm-cache/blob"), size: 50_000)
        try fixture.folder(".npm")
        try fixture.symlink(".npm/_cacache", to: Paths.join(fixture.outside, "npm-cache"))
        try fixture.ageEverything()

        let result = try await fixture.scan()
        #expect(result.items(in: "package-caches").isEmpty)
    }

    // MARK: 12. Temp files

    @Test("Temp files older than 3 days are reported, newer ones aren't")
    func tempFiles() async throws {
        let fixture = try Fixture()
        let old = try fixture.file(Paths.join(fixture.temp, "old-render.mov"), size: 30_000)
        let folder = try fixture.file(Paths.join(fixture.temp, "build-1234/obj.o"), size: 10_000)
        let recent = try fixture.file(Paths.join(fixture.temp, "fresh.log"))
        let apple = try fixture.file(Paths.join(fixture.temp, "com.apple.something/state"))
        try fixture.ageEverything(days: 10)
        try fixture.setAge(recent, days: 2)

        let result = try await fixture.scan()
        let temps = Set(result.items(in: "temp-files").map(\.path))
        #expect(temps == [old, Paths.parent(of: folder)])
        #expect(!temps.contains(recent))
        #expect(!temps.contains(Paths.parent(of: apple)))
    }

    @Test("A temp folder with one recent file inside is skipped as a whole")
    func tempFolderWithRecentFile() async throws {
        let fixture = try Fixture()
        try fixture.file(Paths.join(fixture.temp, "job/old.dat"))
        let fresh = try fixture.file(Paths.join(fixture.temp, "job/new.dat"))
        try fixture.ageEverything(days: 10)
        try fixture.setAge(fresh, hours: 2)

        let result = try await fixture.scan()
        let job = Paths.join(fixture.temp, "job")
        #expect(result.item(at: job) == nil)
        #expect(result.skip(at: job)?.reason.code == .modifiedRecently)
    }

    @Test("~/Library/Caches is only scanned when asked")
    func libraryCachesOptIn() async throws {
        let fixture = try Fixture()
        let cache = try fixture.file("Library/Caches/com.example.app/blob", size: 20_000)
        try fixture.ageEverything(days: 10)

        let off = try await fixture.scan()
        #expect(off.items(in: "temp-files").isEmpty)

        let on = try await fixture.scan { $0.includeLibraryCaches = true }
        #expect(on.item(at: Paths.parent(of: cache)) != nil)
    }

    // MARK: 14. Old installers

    @Test("Old disk images and packages in Downloads are reported")
    func oldInstallers() async throws {
        let fixture = try Fixture()
        let dmg = try fixture.file("Downloads/Tool-1.2.dmg", size: 90_000)
        let pkg = try fixture.file("Downloads/Driver.PKG", size: 20_000)
        let recent = try fixture.file("Downloads/New.dmg")
        let pdf = try fixture.file("Downloads/invoice.pdf")
        try fixture.ageEverything(days: 45)
        try fixture.setAge(recent, days: 10)

        let result = try await fixture.scan()
        let installers = result.items(in: "old-installers")
        #expect(Set(installers.map(\.path)) == [dmg, pkg])
        #expect(result.item(at: dmg)?.comesBack == .redownload)
        #expect(result.item(at: dmg)?.reason == "Downloaded 45 days ago")
        #expect(result.item(at: recent) == nil)
        #expect(result.item(at: pdf) == nil)
    }

    #if os(macOS)
    @Test("Zip files only count when they were downloaded")
    func zipNeedsQuarantine() async throws {
        let fixture = try Fixture()
        let downloaded = try fixture.file("Downloads/sdk.zip")
        let ownArchive = try fixture.file("Downloads/backup.zip")
        let value = "0081;6500a000;Safari;"
        let status = setxattr(downloaded, FolderContentsCollector.quarantineAttribute, value, value.utf8.count, 0, 0)
        try #require(status == 0, "couldn't set the quarantine attribute")
        try fixture.ageEverything(days: 45)

        let result = try await fixture.scan()
        #expect(result.item(at: downloaded) != nil)
        #expect(result.item(at: ownArchive) == nil)
        #expect(result.skip(at: ownArchive)?.reason.code == .unverified)
    }
    #endif

    // MARK: Totals

    @Test("Totals add up per category and overall")
    func totals() async throws {
        let fixture = try Fixture()
        try fixture.project("code/a")
        try fixture.file("code/a/node_modules/x.js", size: 10_000)
        try fixture.project("code/b")
        try fixture.file("code/b/node_modules/y.js", size: 20_000)
        try fixture.file("Downloads/a.dmg", size: 30_000)
        try fixture.ageEverything()

        let result = try await fixture.scan()
        let node = try #require(result.totals.byCategory.first { $0.categoryID == "node-leftovers" })
        #expect(node.itemCount == 2)
        #expect(node.allocatedBytes == result.items(in: "node-leftovers").reduce(0) { $0 + $1.allocatedBytes })
        #expect(result.totals.safeToClearBytes == result.items.reduce(0) { $0 + $1.allocatedBytes })
        #expect(result.totals.worthALookBytes == 0)
    }
}
