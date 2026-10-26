#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Testing
@testable import EbbClean
@testable import ScanCore

/// A Trash inside the fixture folder, so tests never touch the real one.
struct FolderTrash: TrashBin {
    let folder: String

    func moveToTrash(_ path: String) throws -> String {
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        var target = folder + "/" + (path as NSString).lastPathComponent
        while FileManager.default.fileExists(atPath: target) { target += " copy" }
        try FileManager.default.moveItem(atPath: path, toPath: target)
        return target
    }
}

/// A fake home folder with one inactive project and an old installer.
final class CleanFixture {
    let base: String
    let home: String
    let now = Date()

    init() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ebb-clean-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root + "/Users/me", withIntermediateDirectories: true)
        // realpath, like ScanCore: /var/folders → /private/var/folders.
        guard let resolved = realpath(root, nil) else { throw CocoaError(.fileNoSuchFile) }
        base = String(cString: resolved)
        free(resolved)
        home = base + "/Users/me"
        try FileManager.default.createDirectory(atPath: base + "/tmp", withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(atPath: base)
    }

    var trash: FolderTrash { FolderTrash(folder: base + "/.Trash") }
    var history: CleanHistory { CleanHistory(fileURL: URL(fileURLWithPath: base + "/support/history.json")) }

    @discardableResult
    func file(_ relative: String, size: Int = 4096, daysOld: Double = 60) throws -> String {
        let path = home + "/" + relative
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: path, contents: Data((0..<size).map { _ in UInt8.random(in: 0...255) })) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try age(path, days: daysOld)
        return path
    }

    func age(_ path: String, days: Double) throws {
        let date = now.addingTimeInterval(-days * 86_400)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
    }

    /// Ages every folder too: adding files makes a folder's date "now".
    func ageFolders(days: Double = 60) throws {
        let enumerator = FileManager.default.enumerator(atPath: home)
        while let relative = enumerator?.nextObject() as? String {
            let path = home + "/" + relative
            var isFolder: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isFolder), isFolder.boolValue {
                try age(path, days: days)
            }
        }
    }

    func scanner() throws -> DiskScanner {
        let options = ScanOptions(home: home, temporaryDirectory: base + "/tmp", checkOpenFiles: false,
                                  queryTools: false, maxConcurrency: 2, now: now)
        var scanner = DiskScanner(catalog: try CategoryCatalog.builtIn(), options: options)
        scanner.signals = scanner.signals.map { $0 is RunningProcessSignal ? RunningProcessSignal(processes: []) : $0 }
        return scanner
    }

    func cleaner() throws -> Cleaner {
        Cleaner(scanner: try scanner(), history: history, trash: trash)
    }

    /// A project with an old `node_modules` and an old installer, scanned.
    func scannedItems() async throws -> [Item] {
        try file("code/site/package.json", size: 100)
        try file("code/site/node_modules/react/index.js", size: 20_000)
        try file("Downloads/Tool.dmg", size: 30_000)
        try ageFolders()
        return try await scanner().scan().items
    }
}

@Suite("Cleaning")
struct CleanerTests {
    @Test("Clean moves items to the Trash and logs each move")
    func cleanMovesAndLogs() async throws {
        let fixture = try CleanFixture()
        let items = try await fixture.scannedItems()
        #expect(items.count == 2)

        let report = try await fixture.cleaner().clean(items, source: "test")
        #expect(report.moved.count == 2)
        #expect(report.kept.isEmpty)
        for item in items { #expect(!FileManager.default.fileExists(atPath: item.path)) }

        let records = try fixture.history.load()
        #expect(records.count == 1)
        let record = try #require(records.first)
        #expect(record.id == report.cleanID)
        #expect(record.source == "test")
        #expect(Set(record.entries.map(\.originalPath)) == Set(items.map(\.path)))
        #expect(record.entries.allSatisfy { FileManager.default.fileExists(atPath: $0.trashPath) })
        #expect(record.totalBytes == report.movedBytes)
        #expect(try fixture.history.bytesStillInTrash() == report.movedBytes)
    }

    @Test("An item that changed since the scan is left alone")
    func recheckCatchesChanges() async throws {
        let fixture = try CleanFixture()
        let items = try await fixture.scannedItems()
        // Someone reinstalls a package after the scan.
        try fixture.file("code/site/node_modules/react/new.js", daysOld: 0)

        let report = try await fixture.cleaner().clean(items, source: "test")
        let modules = fixture.home + "/code/site/node_modules"
        #expect(report.moved.map(\.item.path) == [fixture.home + "/Downloads/Tool.dmg"])
        #expect(report.kept.map(\.item.path) == [modules])
        #expect(FileManager.default.fileExists(atPath: modules))
    }

    @Test("An item whose project became active since the scan is left alone")
    func recheckCatchesActiveProject() async throws {
        let fixture = try CleanFixture()
        let items = try await fixture.scannedItems()
        try fixture.file("code/site/src/app.ts", daysOld: 2)

        let report = try await fixture.cleaner().clean(items, source: "test")
        #expect(report.kept.map(\.item.path) == [fixture.home + "/code/site/node_modules"])
        #expect(report.kept.first?.why == "in active project site")
    }

    @Test("Items cleared by a command aren't moved or run")
    func commandItemsAreReported() async throws {
        let fixture = try CleanFixture()
        let store = Item(
            path: fixture.home + "/Library/pnpm/store", categoryID: "package-caches", allocatedBytes: 1000,
            sharedBytes: 0, isEstimated: true, fileCount: 1, lastUsed: nil, comesBack: .redownload, reason: "",
            preselected: true, projectPath: nil, source: "pnpm store", ruleID: nil,
            clearCommand: "pnpm store prune", packageManaged: true
        )
        let report = try await fixture.cleaner().clean([store], source: "test")
        #expect(report.moved.isEmpty)
        #expect(report.needsCommand == [store])
        #expect(try fixture.history.load().isEmpty)
    }

    @Test("Put back restores everything from a clean")
    func putBackAll() async throws {
        let fixture = try CleanFixture()
        let items = try await fixture.scannedItems()
        let cleaner = try fixture.cleaner()
        let report = try await cleaner.clean(items, source: "test")
        let id = try #require(report.cleanID)

        let restored = try cleaner.putBack(cleanID: id)
        #expect(Set(restored.restored) == Set(items.map(\.path)))
        for item in items { #expect(FileManager.default.fileExists(atPath: item.path)) }
        #expect(try fixture.history.load().first?.entries.allSatisfy { $0.restoredAt != nil } == true)
        #expect(try fixture.history.bytesStillInTrash() == 0)

        // A second put back has nothing left to do.
        #expect(try cleaner.putBack(cleanID: id).restored.isEmpty)
    }

    @Test("Put back never overwrites what's there now")
    func putBackDoesntOverwrite() async throws {
        let fixture = try CleanFixture()
        let items = try await fixture.scannedItems()
        let cleaner = try fixture.cleaner()
        let id = try #require(try await cleaner.clean(items, source: "test").cleanID)
        let installer = fixture.home + "/Downloads/Tool.dmg"
        try fixture.file("Downloads/Tool.dmg", size: 10, daysOld: 0)

        let report = try cleaner.putBack(cleanID: id, paths: [installer])
        #expect(report.restored.isEmpty)
        #expect(report.failed.map(\.path) == [installer])
        #expect(try Data(contentsOf: URL(fileURLWithPath: installer)).count == 10)
    }

    @Test("Put back of an item that was emptied from the Trash fails cleanly")
    func putBackAfterEmptying() async throws {
        let fixture = try CleanFixture()
        let items = try await fixture.scannedItems()
        let cleaner = try fixture.cleaner()
        let id = try #require(try await cleaner.clean(items, source: "test").cleanID)
        try FileManager.default.removeItem(atPath: fixture.trash.folder)

        let report = try cleaner.putBack(cleanID: id)
        #expect(report.restored.isEmpty)
        #expect(report.failed.count == 2)
        #expect(try fixture.history.bytesStillInTrash() == 0)
    }

    @Test("Emptying removes only Ebb's own items from the Trash, for good")
    func emptyTrash() async throws {
        let fixture = try CleanFixture()
        let items = try await fixture.scannedItems()
        let cleaner = try fixture.cleaner()
        let report = try await cleaner.clean(items, source: "test")
        // Something the user put in the Trash themselves.
        try FileManager.default.createDirectory(atPath: fixture.trash.folder, withIntermediateDirectories: true)
        let theirs = fixture.trash.folder + "/their-own-file.txt"
        FileManager.default.createFile(atPath: theirs, contents: Data("keep".utf8))

        let emptied = try cleaner.emptyTrash()
        #expect(emptied.removedCount == 2)
        #expect(emptied.freedBytes == report.movedBytes)
        #expect(emptied.failed.isEmpty)
        for moved in report.moved { #expect(!FileManager.default.fileExists(atPath: moved.trashPath)) }
        #expect(FileManager.default.fileExists(atPath: theirs))
        #expect(try fixture.history.bytesStillInTrash() == 0)
        #expect(try fixture.history.load().first?.entries.allSatisfy { $0.emptiedAt != nil } == true)

        // Emptied items can't be put back, and a second empty does nothing.
        let id = try #require(report.cleanID)
        #expect(try cleaner.putBack(cleanID: id).restored.isEmpty)
        #expect(try cleaner.emptyTrash().removedCount == 0)
    }

    @Test("Emptying refuses paths that aren't in a Trash folder")
    func emptyTrashChecksPaths() throws {
        let fixture = try CleanFixture()
        let outside = try fixture.file("Documents/important.txt", daysOld: 1)
        let record = CleanRecord(id: "x", date: Date(), source: "test", entries: [
            .init(originalPath: outside, trashPath: outside, categoryID: "x", allocatedBytes: 4096,
                  restoredAt: nil, emptiedAt: nil),
        ])
        try fixture.history.save([record])

        let report = try fixture.cleaner().emptyTrash()
        #expect(report.removedCount == 0)
        #expect(report.failed.count == 1)
        #expect(FileManager.default.fileExists(atPath: outside))
    }

    @Test("Trash paths are recognized, lookalikes aren't")
    func trashPaths() {
        let trash = SystemTrash()
        #expect(trash.isInTrash("/Users/me/.Trash/node_modules"))
        #expect(trash.isInTrash("/Volumes/Disk/.Trashes/501/build"))
        #expect(!trash.isInTrash("/Users/me/.Trash"))
        #expect(!trash.isInTrash("/Users/me/code/.Trash-ish/x"))
        #expect(!trash.isInTrash("/Users/me/.Trash/../Documents"))
    }

    @Test("Unknown clean ids are an error")
    func unknownID() throws {
        let fixture = try CleanFixture()
        #expect(throws: CleanError.unknownClean("nope")) { try fixture.cleaner().putBack(cleanID: "nope") }
    }

    @Test("A history file round-trips")
    func historyRoundTrip() throws {
        let fixture = try CleanFixture()
        let record = CleanRecord(id: "20261025-120000-abcd", date: Date(timeIntervalSince1970: 1_790_000_000),
                                 source: "review", entries: [
            .init(originalPath: "/a", trashPath: "/t/a", categoryID: "x", allocatedBytes: 5, restoredAt: nil,
                  emptiedAt: nil),
        ])
        try fixture.history.save([record])
        #expect(try fixture.history.load() == [record])
    }
}
