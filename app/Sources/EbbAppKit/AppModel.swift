import EbbClean
import Foundation
import Observation
import ScanCore

/// Everything the app shows, and the actions behind its buttons.
@MainActor
@Observable
public final class AppModel {
    public enum ScanState: Equatable {
        case idle
        case scanning(String)
        case failed(String)
    }

    public private(set) var result: ScanResult?
    public private(set) var scanState: ScanState = .idle
    public var selection = Selection(preselectedFrom: nil)
    public private(set) var history: [CleanRecord] = []
    public private(set) var bytesInTrash: Int64 = 0
    /// One line after a clean or put back, e.g. "Moved 5 items (6.2 GB)".
    public private(set) var notice: String?
    public private(set) var isCleaning = false

    public let home: String
    private let options: ScanOptions
    private let store: ResultStore
    private let cleanHistory: CleanHistory
    private let trash: any TrashBin

    public init(options: ScanOptions = .currentUser(), trash: any TrashBin = SystemTrash()) {
        self.options = options
        home = options.canonicalized().home
        store = ResultStore(fileURL: ResultStore.defaultLocation(home: home))
        cleanHistory = CleanHistory(fileURL: CleanHistory.defaultLocation(home: home))
        self.trash = trash
        result = store.load()
        selection = Selection(preselectedFrom: result)
        reloadHistory()
    }

    // MARK: Derived values

    public var isScanning: Bool {
        if case .scanning = scanState { return true }
        return false
    }

    public var safeToClearBytes: Int64 { result?.totals.safeToClearBytes ?? 0 }
    public var worthALookBytes: Int64 { result?.totals.worthALookBytes ?? 0 }

    /// Pre-selected bytes that need a command (pnpm store, Go modules,
    /// Docker) rather than a move to Trash. The app shows the command only.
    public var commandOnlyBytes: Int64 {
        (result?.items ?? []).filter { $0.preselected && !$0.isTrashable }.reduce(0) { $0 + $1.allocatedBytes }
    }

    public var selectionTotals: Selection.Totals {
        result.map { selection.totals(in: $0) } ?? Selection.Totals()
    }

    /// Free space for important data on the home volume, as Finder shows it.
    public var freeSpace: (free: Int64, total: Int64)? {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]
        guard let values = try? URL(fileURLWithPath: home).resourceValues(forKeys: keys),
              let free = values.volumeAvailableCapacityForImportantUsage, let total = values.volumeTotalCapacity
        else { return nil }
        return (free, Int64(total))
    }

    /// Bytes moved to Trash this calendar month, not counting put-backs.
    public var freedThisMonth: (bytes: Int64, cleans: Int) {
        let calendar = Calendar.current
        let thisMonth = history.filter { calendar.isDate($0.date, equalTo: Date(), toGranularity: .month) }
        let bytes = thisMonth.flatMap(\.entries).filter { $0.restoredAt == nil }.reduce(0) { $0 + $1.allocatedBytes }
        return (bytes, thisMonth.count)
    }

    // MARK: Actions

    public func scan() async {
        guard !isScanning else { return }
        scanState = .scanning("Starting")
        var scanner = DiskScanner(catalog: (try? CategoryCatalog.builtIn()) ?? CategoryCatalog(definitions: []),
                                  options: options, rules: loadRules())
        scanner.onProgress = { [weak self] progress in
            let text = ProgressText.describe(progress)
            Task { @MainActor in
                guard let self, self.isScanning, let text else { return }
                self.scanState = .scanning(text)
            }
        }
        let fresh = await scanner.scan()
        result = fresh
        selection = Selection(preselectedFrom: fresh)
        scanState = .idle
        try? store.save(fresh)
    }

    /// Moves the ticked items to the Trash after checking each one again.
    public func cleanSelection(source: String) async {
        guard let result, !isCleaning else { return }
        let items = selection.items(in: result)
        guard !items.isEmpty else { return }
        isCleaning = true
        defer { isCleaning = false }

        let scanner = DiskScanner(catalog: (try? CategoryCatalog.builtIn()) ?? CategoryCatalog(definitions: []),
                                  options: options, rules: loadRules())
        let cleaner = Cleaner(scanner: scanner, history: cleanHistory, trash: trash)
        do {
            let report = try await cleaner.clean(items, source: source)
            let moved = Set(report.moved.map(\.item.path))
            self.result = result.removingItems(at: moved)
            selection.remove(Array(moved))
            if let updated = self.result { try? store.save(updated) }
            notice = Self.describe(report)
        } catch {
            notice = "Couldn't clean: \(error.localizedDescription)"
        }
        reloadHistory()
    }

    public func putBack(_ record: CleanRecord, paths: [String]? = nil) {
        let scanner = DiskScanner(catalog: (try? CategoryCatalog.builtIn()) ?? CategoryCatalog(definitions: []),
                                  options: options)
        let cleaner = Cleaner(scanner: scanner, history: cleanHistory, trash: trash)
        do {
            let report = try cleaner.putBack(cleanID: record.id, paths: paths)
            notice = report.failed.isEmpty
                ? "Put back \(count(report.restored.count, "item"))."
                : "Put back \(count(report.restored.count, "item")); \(report.failed.count) couldn't be: "
                    + (report.failed.first?.why ?? "")
        } catch {
            notice = "Couldn't put back: \(error.localizedDescription)"
        }
        reloadHistory()
    }

    public func dismissNotice() {
        notice = nil
    }

    public func reloadHistory() {
        history = ((try? cleanHistory.load()) ?? []).sorted { $0.date > $1.date }
        bytesInTrash = (try? cleanHistory.bytesStillInTrash()) ?? 0
    }

    private func loadRules() -> [Rule] {
        let rules = RuleStore(fileURL: RuleStore.defaultLocation(home: home))
        return (try? rules.load().rules) ?? []
    }

    static func describe(_ report: Cleaner.Report) -> String {
        var text = "Moved \(count(report.moved.count, "item")) (\(ByteCount.format(report.movedBytes))) to the Trash."
        if !report.kept.isEmpty {
            text += " Left \(report.kept.count) alone because they changed since the scan."
        }
        return text
    }
}

func count(_ number: Int, _ noun: String) -> String {
    "\(number) \(noun)\(number == 1 ? "" : "s")"
}

/// What the scan is doing, in a few words, for the menu bar and window.
public enum ProgressText {
    public static func describe(_ progress: ScanProgress) -> String? {
        switch progress {
        case .findingProjects(let folders, let projects):
            return "Looking for projects: \(folders.formatted()) folders, \(projects.formatted()) found"
        case .checkingProjects(let checked, let total):
            return "Checking which projects are active: \(checked) of \(total)"
        case .collecting(let what):
            return "Looking at \(what)"
        case .applyingRules(let rules):
            return "Applying \(count(rules, "custom rule"))"
        case .measuring(let checked, let total, _):
            return "Measuring \(checked.formatted()) of \(total.formatted())"
        case .finished:
            return nil
        }
    }
}

/// The last scan, kept in `~/Library/Application Support/Ebb/last-scan.json`
/// so the menu bar can show a number the moment the app starts.
struct ResultStore {
    let fileURL: URL

    static func defaultLocation(home: String) -> URL {
        URL(fileURLWithPath: home + "/Library/Application Support/Ebb/last-scan.json")
    }

    func load() -> ScanResult? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let result = try? decoder.decode(ScanResult.self, from: data),
              result.formatVersion == ScanResult.formatVersion
        else { return nil }
        return result
    }

    func save(_ result: ScanResult) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(result).write(to: fileURL, options: .atomic)
    }
}
