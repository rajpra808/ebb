import Foundation
import Testing
@testable import ScanCore

@Suite("Support")
struct SupportTests {
    @Test("Descendant checks respect component boundaries")
    func descendants() {
        #expect(Paths.isSameOrDescendant("/a/b", of: "/a/b"))
        #expect(Paths.isSameOrDescendant("/a/b/c", of: "/a/b"))
        #expect(!Paths.isSameOrDescendant("/a/bc", of: "/a/b"))
        #expect(!Paths.isSameOrDescendant("/a", of: "/a/b"))
        #expect(Paths.isSameOrDescendant("/anything", of: "/"))
    }

    @Test("Path helpers")
    func helpers() {
        #expect(Paths.join("/a", "b") == "/a/b")
        #expect(Paths.join("/", "b") == "/b")
        #expect(Paths.parent(of: "/a/b") == "/a")
        #expect(Paths.parent(of: "/a") == "/")
        #expect(Paths.lastComponent(of: "/a/b.txt") == "b.txt")
        #expect(Paths.relative("/a/b/c", to: "/a") == "b/c")
        #expect(Paths.fileExtension(of: "Tool.DMG") == "dmg")
        #expect(Paths.fileExtension(of: ".env") == nil)
        #expect(Paths.normalized("/a/b/") == "/a/b")
    }

    @Test("Sorted path lookups find members inside a folder, not lookalikes")
    func sortedPaths() {
        let paths = SortedPaths(["/a/b-x/file", "/a/b/c/open.log", "/z"])
        #expect(paths.first(inside: "/a/b") == "/a/b/c/open.log")
        #expect(paths.first(inside: "/a/b/c/open.log") == "/a/b/c/open.log")
        #expect(paths.first(inside: "/a/bc") == nil)
        #expect(paths.first(inside: "/y") == nil)
    }

    @Test("Project index answers containment both ways")
    func projectIndex() {
        let index = ProjectIndex(roots: ["/home/me/code/app"])
        #expect(index.project(overlapping: "/home/me/code/app/node_modules") == "/home/me/code/app")
        #expect(index.project(overlapping: "/home/me/code") == "/home/me/code/app")
        #expect(index.project(overlapping: "/home/me/code/application") == nil)
    }

    @Test("lsof name records are parsed, annotations removed")
    func lsofParsing() {
        let output = """
        p123
        fcwd
        n/Users/me/code/app
        ftxt
        n/Applications/Thing.app/Contents/MacOS/Thing
        f4
        n/private/var/folders/x/T/scratch (deleted)
        f5
        n192.168.1.2:443->10.0.0.1:5000
        f6
        n/Users/me/My (Draft) Notes.txt
        """
        let paths = OpenFiles.parse(Data(output.utf8))
        #expect(paths == [
            "/Users/me/code/app",
            "/Applications/Thing.app/Contents/MacOS/Thing",
            "/private/var/folders/x/T/scratch",
            "/Users/me/My (Draft) Notes.txt",
        ])
    }

    @Test("The open-file snapshot sees a file this process holds open")
    func liveSnapshot() async throws {
        let fixture = try Fixture()
        let path = try fixture.file("held-open.txt")
        let handle = try #require(FileHandle(forReadingAtPath: path))
        defer { try? handle.close() }

        let snapshot = await OpenFiles.snapshot()
        try #require(snapshot.isAvailable, "lsof isn't available here")
        #expect(snapshot.isOpen(path))
        #expect(snapshot.isOpen(Paths.parent(of: path)))
    }

    @Test("Ages read naturally")
    func ages() {
        let now = Date()
        #expect(Age.describe(from: now.addingTimeInterval(-30), to: now) == "1 minute")
        #expect(Age.describe(from: now.addingTimeInterval(-3 * 3600), to: now) == "3 hours")
        #expect(Age.describe(from: now.addingTimeInterval(-86_400 * 1.5), to: now) == "1 day")
        #expect(Age.describe(from: now.addingTimeInterval(-86_400 * 41), to: now) == "41 days")
    }

    @Test("ComesBack encodes to stable JSON")
    func comesBackJSON() throws {
        let values: [ComesBack] = [.yes(howTo: "npm i"), .redownload, .no, .notApplicable]
        let data = try JSONEncoder().encode(values)
        #expect(try JSONDecoder().decode([ComesBack].self, from: data) == values)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains(#""kind":"yes""#) && text.contains(#""howTo":"npm i""#))
    }

    @Test("A scan result survives a JSON round trip")
    func scanResultJSON() async throws {
        let fixture = try Fixture()
        try fixture.file("Downloads/a.dmg")
        try fixture.ageEverything()
        let result = try await fixture.scan()

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ScanResult.self, from: encoder.encode(result))
        #expect(decoded.items.map(\.path) == result.items.map(\.path))
        #expect(decoded.totals == result.totals)
        #expect(decoded.formatVersion == 1)
    }
}
