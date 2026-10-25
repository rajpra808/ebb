import Foundation
import ScanCore

/// Moves selected items to the Trash after checking each one again, logs
/// every move, and puts things back on request.
///
/// It never deletes and never runs an item's `clearCommand`; those items
/// are reported back so the user can run the command knowingly.
public struct Cleaner: Sendable {
    public let scanner: DiskScanner
    public let history: CleanHistory
    public let trash: any TrashBin

    public init(scanner: DiskScanner, history: CleanHistory, trash: any TrashBin = SystemTrash()) {
        self.scanner = scanner
        self.history = history
        self.trash = trash
    }

    public struct Report: Equatable, Sendable {
        public struct Moved: Equatable, Sendable {
            public let item: Item
            public let trashPath: String
            public let allocatedBytes: Int64
        }

        public struct NotMoved: Equatable, Sendable {
            public let item: Item
            public let why: String
        }

        public var cleanID: String?
        public var moved: [Moved] = []
        /// Failed the re-check, or the move failed. Left where it was.
        public var kept: [NotMoved] = []
        /// Cleared by a command (`pnpm store prune`); not run by Ebb.
        public var needsCommand: [Item] = []

        public var movedBytes: Int64 { moved.reduce(0) { $0 + $1.allocatedBytes } }
    }

    /// Re-checks `items`, then moves the ones that are still safe to the
    /// Trash, one at a time, logging each move as it happens.
    public func clean(_ items: [Item], source: String, date: Date = Date()) async throws -> Report {
        var report = Report()
        let trashable = items.filter(\.isTrashable)
        report.needsCommand = items.filter { !$0.isTrashable }
        guard !trashable.isEmpty else { return report }

        let verdicts = await scanner.recheck(trashable)
        let id = Self.makeID(date: date)
        try history.update { $0.append(CleanRecord(id: id, date: date, source: source, entries: [])) }
        report.cleanID = id

        for (item, verdict) in zip(trashable, verdicts) {
            guard case .safe(let bytes) = verdict else {
                if case .unsafe(let reason) = verdict { report.kept.append(.init(item: item, why: reason.detail)) }
                continue
            }
            do {
                let trashPath = try trash.moveToTrash(item.path)
                let entry = CleanRecord.Entry(
                    originalPath: item.path, trashPath: trashPath, categoryID: item.categoryID,
                    allocatedBytes: bytes, restoredAt: nil
                )
                try history.update { records in
                    if let index = records.firstIndex(where: { $0.id == id }) { records[index].entries.append(entry) }
                }
                report.moved.append(.init(item: item, trashPath: trashPath, allocatedBytes: bytes))
            } catch {
                report.kept.append(.init(item: item, why: "couldn't move it: \(error.localizedDescription)"))
            }
        }
        if report.moved.isEmpty {
            try history.update { $0.removeAll { $0.id == id } }
            report.cleanID = nil
        }
        return report
    }

    public struct RestoreReport: Equatable, Sendable {
        public var restored: [String] = []
        public var failed: [(path: String, why: String)] = []

        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.restored == rhs.restored && lhs.failed.map(\.path) == rhs.failed.map(\.path)
        }
    }

    /// Puts items from a clean back where they were. With `paths`, only
    /// those; otherwise everything from that clean still in the Trash.
    /// Never overwrites: if something now sits at the original path, that
    /// item stays in the Trash.
    public func putBack(cleanID: String, paths: [String]? = nil, date: Date = Date()) throws -> RestoreReport {
        try history.update { records in
            guard let index = records.firstIndex(where: { $0.id == cleanID }) else {
                throw CleanError.unknownClean(cleanID)
            }
            var report = RestoreReport()
            for (position, entry) in records[index].entries.enumerated() where entry.restoredAt == nil {
                if let paths, !paths.contains(entry.originalPath) { continue }
                do {
                    try Self.move(from: entry.trashPath, to: entry.originalPath)
                    records[index].entries[position].restoredAt = date
                    report.restored.append(entry.originalPath)
                } catch {
                    report.failed.append((entry.originalPath, String(describing: error)))
                }
            }
            return report
        }
    }

    private static func move(from trashPath: String, to original: String) throws {
        let files = FileManager.default
        guard files.fileExists(atPath: trashPath) else { throw CleanError.notInTrash(trashPath) }
        // fileExists follows symlinks; a dangling link still occupies the name.
        if files.fileExists(atPath: original) || (try? files.destinationOfSymbolicLink(atPath: original)) != nil {
            throw CleanError.originalExists(original)
        }
        let parent = URL(fileURLWithPath: original).deletingLastPathComponent()
        try files.createDirectory(at: parent, withIntermediateDirectories: true)
        try files.moveItem(atPath: trashPath, toPath: original)
    }

    /// Sortable and readable: `20261025-213012-4f2a`.
    static func makeID(date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let suffix = UUID().uuidString.prefix(4).lowercased()
        return "\(formatter.string(from: date))-\(suffix)"
    }
}
