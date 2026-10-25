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
    private let paths: SortedPaths
    /// False when `lsof` couldn't run; callers should say so in warnings.
    public let isAvailable: Bool

    public init(paths: [String], isAvailable: Bool = true) {
        self.paths = SortedPaths(paths)
        self.isAvailable = isAvailable
    }

    public static let unavailable = OpenFiles(paths: [], isAvailable: false)

    public var count: Int { paths.count }

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
        paths.first(inside: path)
    }
}
