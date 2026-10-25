#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
@testable import ScanCore

/// A throwaway home folder (`<base>/Users/me`), temp folder and "outside"
/// folder for one test.
///
/// Everything is created under the system temp directory and removed when
/// the fixture is deallocated. File contents are random so APFS can't
/// compress or deduplicate them and sizes stay predictable.
final class Fixture {
    let base: String
    let home: String
    let temp: String
    /// A folder outside the scanned home, for symlink and hard-link tests.
    let outside: String
    let now = Date()

    init() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ebb-tests-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        // Canonical, so /var vs /private/var never makes paths differ.
        base = FileSystem.canonicalPath(root) ?? root
        // Laid out like a Mac: siblings of the home folder are other users.
        home = base + "/Users/me"
        temp = base + "/tmp"
        outside = base + "/outside"
        for folder in [home, temp, outside] {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        }
    }

    deinit {
        try? FileManager.default.removeItem(atPath: base)
    }

    // MARK: Building

    /// Writes a file of `size` random bytes at `path` (relative to home
    /// unless absolute), creating folders as needed.
    @discardableResult
    func file(_ path: String, size: Int = 4096, daysOld: Double = 60) throws -> String {
        let full = absolute(path)
        try FileManager.default.createDirectory(
            atPath: Paths.parent(of: full), withIntermediateDirectories: true
        )
        var bytes = [UInt8](repeating: 0, count: size)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        guard FileManager.default.createFile(atPath: full, contents: Data(bytes)) else {
            throw FixtureError("couldn't create \(full)")
        }
        try setAge(full, days: daysOld)
        return full
    }

    @discardableResult
    func folder(_ path: String) throws -> String {
        let full = absolute(path)
        try FileManager.default.createDirectory(atPath: full, withIntermediateDirectories: true)
        return full
    }

    @discardableResult
    func symlink(_ path: String, to destination: String) throws -> String {
        let full = absolute(path)
        try FileManager.default.createDirectory(
            atPath: Paths.parent(of: full), withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(atPath: full, withDestinationPath: destination)
        return full
    }

    @discardableResult
    func hardLink(_ path: String, to existing: String) throws -> String {
        let full = absolute(path)
        try FileManager.default.createDirectory(
            atPath: Paths.parent(of: full), withIntermediateDirectories: true
        )
        try FileManager.default.linkItem(atPath: absolute(existing), toPath: full)
        return full
    }

    /// A project: a marker file plus any extra files, everything old.
    @discardableResult
    func project(_ path: String, marker: String = "package.json") throws -> String {
        try file(Paths.join(path, marker), size: 200)
        return absolute(path)
    }

    // MARK: Ages

    /// Sets the modification date of one path, without following symlinks.
    func setAge(_ path: String, days: Double) throws {
        try setAge(path, seconds: days * 86_400)
    }

    func setAge(_ path: String, hours: Double) throws {
        try setAge(path, seconds: hours * 3600)
    }

    /// Sets only the last-read date, as opening a model would.
    func setLastRead(_ path: String, days: Double) throws {
        let full = absolute(path)
        guard let status = FileSystem.status(atPath: full) else { throw FixtureError("no \(path)") }
        let read = now.addingTimeInterval(-days * 86_400)
        var times = [timeval](repeating: timeval(), count: 2)
        times[0].tv_sec = Int(read.timeIntervalSince1970)
        times[1].tv_sec = Int(status.modificationDate.timeIntervalSince1970)
        guard lutimes(full, &times) == 0 else { throw FixtureError("couldn't set the read date of \(path)") }
    }

    private func setAge(_ path: String, seconds: Double) throws {
        let date = now.addingTimeInterval(-seconds)
        var times = [timeval](repeating: timeval(), count: 2)
        times[0].tv_sec = Int(date.timeIntervalSince1970)
        times[1].tv_sec = Int(date.timeIntervalSince1970)
        guard lutimes(absolute(path), &times) == 0 else {
            throw FixtureError("couldn't set the date of \(path)")
        }
    }

    /// Makes everything under the fixture `days` old, including folders.
    /// Call after building, then make specific paths newer.
    func ageEverything(days: Double = 60) throws {
        for root in [home, temp, outside] {
            try setAge(root, days: days)
            guard let enumerator = FileManager.default.enumerator(atPath: root) else { continue }
            while let relative = enumerator.nextObject() as? String {
                try setAge(Paths.join(root, relative), days: days)
            }
        }
    }

    // MARK: Scanning

    func options(rulesTimeLimit: TimeInterval = 5) -> ScanOptions {
        ScanOptions(
            home: home,
            temporaryDirectory: temp,
            checkOpenFiles: false,
            queryTools: false,
            ruleTimeLimit: rulesTimeLimit,
            maxConcurrency: 4,
            now: now
        )
    }

    func scan(
        rules: [Rule] = [],
        configure: (inout ScanOptions) -> Void = { _ in }
    ) async throws -> ScanResult {
        var options = options()
        configure(&options)
        return try await scanner(options: options, rules: rules).scan()
    }

    /// A scanner that sees no running processes, so a test's result doesn't
    /// depend on what else runs on the machine.
    func scanner(options: ScanOptions? = nil, rules: [Rule] = [],
                 processes: [RunningProcessSignal.Process] = []) throws -> DiskScanner {
        var scanner = DiskScanner(catalog: try CategoryCatalog.builtIn(), options: options ?? self.options(),
                                  rules: rules)
        scanner.signals = scanner.signals.map {
            $0 is RunningProcessSignal ? RunningProcessSignal(processes: processes) : $0
        }
        return scanner
    }

    func absolute(_ path: String) -> String {
        path.hasPrefix("/") ? path : Paths.join(home, path)
    }

    /// Allocated size from a second implementation, to check ScanCore's own
    /// arithmetic. On macOS that's Foundation's `totalFileAllocatedSize`.
    /// On Linux, swift-corelibs-foundation multiplies `st_blocks` by the
    /// block size rather than 512, so a plain `lstat` walk is used instead.
    func allocatedSize(of path: String) throws -> Int64 {
        #if canImport(Darwin)
        return try foundationAllocatedSize(of: path)
        #else
        var total = Int64(0)
        var info = stat()
        guard lstat(path, &info) == 0 else { throw FixtureError("can't stat \(path)") }
        total += Int64(info.st_blocks) * 512
        if let children = FileManager.default.enumerator(atPath: path) {
            while let relative = children.nextObject() as? String {
                guard lstat(Paths.join(path, relative), &info) == 0 else { continue }
                total += Int64(info.st_blocks) * 512
            }
        }
        return total
        #endif
    }

    private func foundationAllocatedSize(of path: String) throws -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isDirectoryKey, .isSymbolicLinkKey]
        let url = URL(fileURLWithPath: path)
        var total = Int64(try url.resourceValues(forKeys: keys).totalFileAllocatedSize ?? 0)
        if try url.resourceValues(forKeys: keys).isDirectory == true {
            let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys))
            while let child = enumerator?.nextObject() as? URL {
                total += Int64(try child.resourceValues(forKeys: keys).totalFileAllocatedSize ?? 0)
            }
        }
        return total
    }
}

struct FixtureError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

extension ScanResult {
    func item(at path: String) -> Item? {
        items.first { $0.path == path }
    }

    func items(in category: String) -> [Item] {
        items.filter { $0.categoryID == category }
    }

    func skip(at path: String) -> SkippedItem? {
        skipped.first { $0.path == path }
    }

    /// True if any reported item is `path`, contains it, or is inside it.
    func reports(anythingOverlapping path: String) -> Bool {
        items.contains {
            Paths.isSameOrDescendant($0.path, of: path) || Paths.isSameOrDescendant(path, of: $0.path)
        }
    }
}

/// Runs `git` for fixtures that need a real repository.
enum GitFixture {
    static var isAvailable: Bool { GitClient.locate().isAvailable }

    static func run(_ arguments: [String], in folder: String) throws {
        guard let git = GitClient.locate().executable else { throw FixtureError("git not available") }
        let environment = [
            "GIT_AUTHOR_NAME": "Ebb Tests", "GIT_AUTHOR_EMAIL": "tests@example.com",
            "GIT_COMMITTER_NAME": "Ebb Tests", "GIT_COMMITTER_EMAIL": "tests@example.com",
            "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
        ]
        let output = Subprocess.runBlocking(
            git, arguments: ["-C", folder] + arguments, environment: environment, timeout: 30
        )
        guard output?.status == 0 else { throw FixtureError("git \(arguments.joined(separator: " ")) failed") }
    }
}
