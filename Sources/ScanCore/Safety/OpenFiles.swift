#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// Paths that running processes have open, captured once per scan with
/// `lsof`.
///
/// This is best effort: `lsof` only sees the current user's processes, and a
/// file can be opened a moment after the snapshot. It also includes each
/// process's working folder, so a terminal sitting in a folder counts.
public struct OpenFiles: Sendable {
    /// Sorted, so "anything open inside this folder?" is a binary search.
    private let paths: [String]
    /// False when `lsof` couldn't run; callers should say so in warnings.
    public let isAvailable: Bool

    public init(paths: [String], isAvailable: Bool = true) {
        self.paths = Array(Set(paths)).sorted()
        self.isAvailable = isAvailable
    }

    public static let unavailable = OpenFiles(paths: [], isAvailable: false)

    /// Takes a snapshot of the current user's open files.
    public static func snapshot(timeout: TimeInterval = 20) async -> OpenFiles {
        guard let lsof = Subprocess.locate("lsof", fallbacks: ["/usr/sbin/lsof", "/usr/bin/lsof"]) else {
            return .unavailable
        }
        // -n/-P: no DNS or port lookups. -w: no warnings. -F n: names only.
        let arguments = ["-n", "-P", "-w", "-F", "n", "-u", String(getuid())]
        guard let output = await Subprocess.run(lsof, arguments: arguments, timeout: timeout) else {
            return .unavailable
        }
        // lsof exits 1 when some processes couldn't be inspected; the output
        // for the rest is still good.
        return OpenFiles(paths: parse(output.stdout), isAvailable: true)
    }

    static func parse(_ data: Data) -> [String] {
        var result: [String] = []
        for line in data.split(separator: UInt8(ascii: "\n")) where line.first == UInt8(ascii: "n") {
            guard line.count > 1, line[line.startIndex + 1] == UInt8(ascii: "/") else { continue }
            var path = String(decoding: line.dropFirst(), as: UTF8.self)
            // Unlinked-but-open files carry this suffix. Other names may
            // legitimately contain " (", so only this one is stripped.
            if path.hasSuffix(" (deleted)") { path.removeLast(" (deleted)".count) }
            result.append(path)
        }
        return result
    }

    public func isOpen(_ path: String) -> Bool {
        firstOpen(inside: path) != nil
    }

    /// The first open path that is `path` or lives inside it.
    public func firstOpen(inside path: String) -> String? {
        var low = 0
        var high = paths.count
        while low < high {
            let middle = (low + high) / 2
            if paths[middle] < path { low = middle + 1 } else { high = middle }
        }
        // "/a/b" sorts before "/a/b/c" and "/a/b-x" sorts between them, so
        // scan forward while entries still share the prefix.
        var index = low
        while index < paths.count, paths[index].hasPrefix(path) {
            if Paths.isSameOrDescendant(paths[index], of: path) { return paths[index] }
            index += 1
        }
        return nil
    }
}
