import Foundation
import Testing
@testable import ScanCore

@Suite("Size measurement")
struct MeasureTests {
    private func measure(_ path: String) throws -> ItemMeasurement {
        guard case .measured(let result) = SizeMeasurer(protection: { _, _ in nil }).measure(path) else {
            throw FixtureError("couldn't measure \(path)")
        }
        return result
    }

    @Test("Allocated size matches Foundation's totalFileAllocatedSize")
    func allocatedSize() throws {
        let fixture = try Fixture()
        try fixture.file("tree/a.bin", size: 10_000)
        try fixture.file("tree/b/c.bin", size: 123_457)
        try fixture.file("tree/b/d/e.txt", size: 1)

        let result = try measure(fixture.absolute("tree"))
        let expected = try fixture.allocatedSize(of: fixture.absolute("tree"))
        #expect(result.privateBytes == expected)
        #expect(result.fileCount == 3)
        // Allocated, not logical: a 1-byte file still takes a block.
        #expect(result.privateBytes > 10_000 + 123_457 + 1)
    }

    @Test("Hard-linked files inside one item are counted once")
    func hardLinksWithinItem() throws {
        let fixture = try Fixture()
        let original = try fixture.file("store/blob", size: 100_000)
        try fixture.hardLink("store/copy-1", to: original)
        try fixture.hardLink("store/sub/copy-2", to: original)
        let fileSize = try #require(FileSystem.status(atPath: original)).allocatedSize

        let measurement = try measure(fixture.absolute("store"))
        let share = try #require(HardLinkLedger.reconcile([measurement]).first)
        let folders = try fixture.allocatedSize(of: fixture.absolute("store")) - 3 * fileSize
        #expect(share.allocatedBytes == folders + fileSize)
        #expect(share.sharedBytes == 0)
        #expect(measurement.fileCount == 3)
    }

    @Test("Hard links across two reported items are counted once overall")
    func hardLinksAcrossItems() async throws {
        let fixture = try Fixture()
        try fixture.project("code/a")
        let blob = try fixture.file("code/a/node_modules/big.js", size: 200_000)
        try fixture.project("code/b")
        try fixture.hardLink("code/b/node_modules/big.js", to: blob)
        try fixture.ageEverything()

        let result = try await fixture.scan()
        let items = result.items(in: "node-leftovers")
        #expect(items.count == 2)
        let fileSize = try #require(FileSystem.status(atPath: blob)).allocatedSize
        let total = items.reduce(0) { $0 + $1.allocatedBytes }
        let naive = try fixture.allocatedSize(of: fixture.absolute("code/a/node_modules"))
            + fixture.allocatedSize(of: fixture.absolute("code/b/node_modules"))
        #expect(total == naive - fileSize)
    }

    @Test("A folder whose only files are hard links to outside isn't listed")
    func fullySharedItemIsDropped() async throws {
        let fixture = try Fixture()
        let store = try fixture.file(Paths.join(fixture.outside, "store/pkg.js"), size: 150_000)
        try fixture.project("code/app")
        try fixture.hardLink("code/app/node_modules/pkg.js", to: store)
        try fixture.ageEverything()

        let result = try await fixture.scan()
        #expect(result.item(at: fixture.absolute("code/app/node_modules")) == nil)
    }

    @Test("A hard link to a file outside every item isn't promised as freed")
    func hardLinkToOutside() async throws {
        let fixture = try Fixture()
        let store = try fixture.file(Paths.join(fixture.outside, "store/pkg.js"), size: 150_000)
        try fixture.project("code/app")
        try fixture.hardLink("code/app/node_modules/pkg.js", to: store)
        try fixture.file("code/app/node_modules/own.js", size: 10_000)
        try fixture.ageEverything()

        let result = try await fixture.scan()
        let modules = try #require(result.item(at: fixture.absolute("code/app/node_modules")))
        let fileSize = try #require(FileSystem.status(atPath: store)).allocatedSize
        #expect(modules.sharedBytes == fileSize)
        #expect(modules.allocatedBytes < fileSize)
        #expect(modules.isEstimated)
    }

    #if os(macOS)
    @Test("APFS clones only count their private blocks")
    func clonesAreNotDoubleCounted() throws {
        let fixture = try Fixture()
        let original = try fixture.file(Paths.join(fixture.outside, "original.bin"), size: 400_000)
        let clone = fixture.absolute("clones/copy.bin")
        try fixture.folder("clones")
        // copyItem clones on APFS; on other file systems it copies, and the
        // private size equals the allocated size.
        try FileManager.default.copyItem(atPath: original, toPath: clone)
        guard let privateSize = FileSystem.privateAllocatedSize(atPath: clone),
              let status = FileSystem.status(atPath: clone),
              privateSize < status.allocatedSize
        else { return }

        let result = try measure(fixture.absolute("clones"))
        #expect(result.cloneSharedBytes == status.allocatedSize - privateSize)
        #expect(result.privateBytes < status.allocatedSize)
    }
    #endif

    @Test("Measuring stops at protected names inside")
    func protectedDescendant() throws {
        let fixture = try Fixture()
        try fixture.file("job/out.log")
        try fixture.file("job/nested/.env")
        let list = NeverTouchList(home: fixture.home)
        let measurer = SizeMeasurer { name, _ in list.protection(forName: name)?.why }
        guard case .containsProtected(let path, _) = measurer.measure(fixture.absolute("job")) else {
            Issue.record("expected the .env to stop the measurement")
            return
        }
        #expect(path == fixture.absolute("job/nested/.env"))
    }

    @Test("Byte counts format like Finder", arguments: [
        (Int64(0), "0 bytes"), (1, "1 byte"), (999, "999 bytes"), (1_000, "1 KB"),
        (412_300, "412 KB"), (3_100_000_000, "3.1 GB"), (999_960_000, "1.0 GB"), (1_260_000_000_000, "1.3 TB"),
    ])
    func formatting(bytes: Int64, expected: String) {
        #expect(ByteCount.format(bytes) == expected)
    }

    @Test("Sizes parse from the command line", arguments: [
        ("50MB", Int64(50_000_000)), ("1.5 GB", 1_500_000_000), ("200k", 200_000), ("1024", 1024),
    ])
    func parsing(text: String, expected: Int64) {
        #expect(ByteCount.parse(text) == expected)
    }

    @Test("Bad sizes don't parse")
    func badSizes() {
        #expect(ByteCount.parse("lots") == nil)
        #expect(ByteCount.parse("5 parsecs") == nil)
        #expect(ByteCount.parse("") == nil)
    }
}
