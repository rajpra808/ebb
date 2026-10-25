import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Category 13: files with identical contents in Downloads, Desktop and
/// Documents.
///
/// Files are grouped by size, then by a hash of their first 64 KB, then by a
/// full SHA-256, so most files are never read in full. In each group the
/// oldest copy is kept and the others are suggested, never pre-selected.
///
/// Project folders, app bundles and other packages, hidden files, symlinks
/// and iCloud placeholders are skipped: duplicates there are either
/// source code or not really on this Mac.
struct DuplicateCollector: Sendable {
    let category: Category
    let spec: DuplicatesSpec
    let options: ScanOptions

    static let partialHashBytes = 64 * 1024

    func collect() async -> Findings {
        #if canImport(CryptoKit)
        let minimumBytes = Int64(spec.minimumMB * 1_000_000)
        let deadline = Date().addingTimeInterval(spec.timeLimitSeconds ?? 60)
        let folders = spec.folders.map { ScanOptions.canonical(options.expand($0)) }
        let files = await BlockingIO.run {
            folders.flatMap { Self.files(in: $0, minimumBytes: minimumBytes) }
        }

        var findings = Findings()
        let groups = await Self.duplicateGroups(files, deadline: deadline, maxConcurrency: options.maxConcurrency)
        if Date() > deadline {
            findings.warnings.append("The duplicate search hit its time limit; some duplicates may be missing")
        }
        for group in groups {
            let kept = group.min { ($0.created, $0.path) < ($1.created, $1.path) } ?? group[0]
            let keptName = abbreviated(kept.path)
            for copy in group where copy.path != kept.path {
                findings.candidates.append(Candidate(
                    path: copy.path, categoryID: category.id, comesBack: .no, preselected: false,
                    describe: { _, _ in "Same contents as \(keptName), which is kept" }
                ))
            }
        }
        return findings
        #else
        var findings = Findings()
        findings.warnings.append("Duplicate search isn't available on this platform yet")
        return findings
        #endif
    }

    struct File: Equatable, Sendable {
        let path: String
        let size: Int64
        let created: Date
        let inode: InodeKey
    }

    static func files(in root: String, minimumBytes: Int64) -> [File] {
        guard let rootStatus = FileSystem.status(atPath: root), rootStatus.isDirectory else { return [] }
        var result: [File] = []
        var stack = [root]
        while let folder = stack.popLast() {
            guard let entries = try? FileSystem.entries(ofDirectory: folder) else { continue }
            if folder != root && isProject(entries) { continue }

            for entry in entries where !entry.name.hasPrefix(".") {
                let path = Paths.join(folder, entry.name)
                guard let status = FileSystem.status(atPath: path), !status.isDataless,
                      status.device == rootStatus.device
                else { continue }
                if status.isDirectory {
                    if let ext = Paths.fileExtension(of: entry.name), ProjectDiscovery.packageExtensions.contains(ext) {
                        continue
                    }
                    if ProjectDiscovery.dependencyFolderNames.contains(entry.name) { continue }
                    stack.append(path)
                } else if status.isRegularFile, status.logicalSize >= minimumBytes {
                    result.append(File(path: path, size: status.logicalSize, created: status.creationDate,
                                       inode: InodeKey(device: status.device, inode: status.inode)))
                }
            }
        }
        return result
    }

    private static func isProject(_ entries: [DirectoryEntry]) -> Bool {
        entries.contains { entry in
            ProjectDiscovery.markerNames.contains(entry.name)
                || Paths.fileExtension(of: entry.name).map(ProjectDiscovery.markerExtensions.contains) == true
        }
    }

    /// Groups of two or more distinct files (not hard links of one file)
    /// with identical contents, sorted by path. Hashing runs in parallel.
    static func duplicateGroups(_ files: [File], deadline: Date, maxConcurrency: Int) async -> [[File]] {
        // Same size, and not hard links of one file.
        let sameSize = Dictionary(grouping: files, by: \.size).values.compactMap { group -> [File]? in
            var seen = Set<InodeKey>()
            let distinct = group.sorted { $0.path < $1.path }.filter { seen.insert($0.inode).inserted }
            return distinct.count > 1 ? distinct : nil
        }

        // Then the same first 64 KB, then the same full hash. Small files
        // are fully covered by the first pass.
        let partial = await regroup(sameSize, deadline: deadline, maxConcurrency: maxConcurrency) {
            hash($0.path, limit: partialHashBytes)
        }
        let small = partial.filter { $0[0].size <= Int64(partialHashBytes) }
        let large = partial.filter { $0[0].size > Int64(partialHashBytes) }
        let full = await regroup(large, deadline: deadline, maxConcurrency: maxConcurrency) {
            hash($0.path, limit: nil)
        }
        return (small + full).sorted { $0[0].path < $1[0].path }
    }

    /// Splits each group by `key`, keeping sub-groups of two or more.
    private static func regroup(
        _ groups: [[File]], deadline: Date, maxConcurrency: Int,
        by key: @escaping @Sendable (File) -> String?
    ) async -> [[File]] {
        let files = groups.enumerated().flatMap { index, group in group.map { (index, $0) } }
        let keys = await files.concurrentMap(maxConcurrency: maxConcurrency) { _, file in
            await BlockingIO.run { Date() > deadline ? nil : key(file) }
        }
        var buckets: [String: [File]] = [:]
        for ((group, file), digest) in zip(files, keys) {
            guard let digest else { continue }
            buckets["\(group):\(digest)", default: []].append(file)
        }
        return buckets.values.filter { $0.count > 1 }.map { $0.sorted { $0.path < $1.path } }
    }

    /// SHA-256 of the first `limit` bytes (or the whole file), as hex.
    static func hash(_ path: String, limit: Int?) -> String? {
        #if canImport(CryptoKit)
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        var remaining = limit ?? Int.max
        while remaining > 0 {
            let chunk = (try? handle.read(upToCount: min(remaining, 1 << 20))) ?? nil
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
            remaining -= chunk.count
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        #else
        return nil
        #endif
    }

    private func abbreviated(_ path: String) -> String {
        path.hasPrefix(options.home + "/") ? "~" + path.dropFirst(options.home.count) : path
    }
}
