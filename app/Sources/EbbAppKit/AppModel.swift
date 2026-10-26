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
    /// 0 to 1 while measuring, nil while the scan can't tell how far it is.
    public private(set) var scanFraction: Double?
    /// The scan's phase in a few words, e.g. "Checking projects".
    public private(set) var scanPhase = ""
    public var selection = Selection(preselectedFrom: nil)
    public private(set) var history: [CleanRecord] = []
    public private(set) var bytesInTrash: Int64 = 0
    /// One line after a clean or put back, e.g. "Moved 5 items (6.2 GB)".
    public private(set) var notice: String?
    public private(set) var isCleaning = false
    /// Saved as soon as it changes; the next scan uses it.
    public var settings: EbbSettings {
        didSet {
            guard settings != oldValue else { return }
            try? settingsStore.save(settings)
        }
    }

    public let home: String
    private let options: ScanOptions
    private let store: ResultStore
    private let cleanHistory: CleanHistory
    private let settingsStore: SettingsStore
    private let trash: any TrashBin

    public init(options: ScanOptions = .currentUser(), trash: any TrashBin = SystemTrash()) {
        self.options = options
        home = options.canonicalized().home
        store = ResultStore(fileURL: ResultStore.defaultLocation(home: home))
        cleanHistory = CleanHistory(fileURL: CleanHistory.defaultLocation(home: home))
        settingsStore = SettingsStore(fileURL: SettingsStore.defaultLocation(home: home))
        settings = settingsStore.load()
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

    /// Everything moved to Trash and not put back, since the first clean.
    public var freedSinceInstall: Int64 {
        history.flatMap(\.entries).filter { $0.restoredAt == nil }.reduce(0) { $0 + $1.allocatedBytes }
    }

    // MARK: Actions

    public func scan() async {
        guard !isScanning else { return }
        scanState = .scanning("Starting")
        scanPhase = "Starting"
        scanFraction = nil
        var scanner = makeScanner()
        scanner.onProgress = { [weak self] progress in
            let text = ProgressText.describe(progress)
            let phase = ProgressText.phase(progress)
            let fraction = ProgressText.fraction(progress)
            Task { @MainActor in
                guard let self, self.isScanning, let text else { return }
                self.scanState = .scanning(text)
                self.scanPhase = phase
                self.scanFraction = fraction
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

        let cleaner = Cleaner(scanner: makeScanner(), history: cleanHistory, trash: trash)
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
        let cleaner = Cleaner(scanner: makeScanner(), history: cleanHistory, trash: trash)
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

    // MARK: Settings

    /// Marks a project or path "Always keep": it drops out of the current
    /// result now and out of every scan from here on.
    public func alwaysKeep(_ path: String) {
        guard !settings.alwaysKeep.contains(path) else { return }
        settings.alwaysKeep.append(path)
        guard let result else { return }
        let dropped = Set(result.items.map(\.path).filter {
            $0 == path || $0.hasPrefix(path + "/") || path.hasPrefix($0 + "/")
        })
        self.result = result.removingItems(at: dropped)
        selection.remove(Array(dropped))
        if let updated = self.result { try? store.save(updated) }
    }

    public func stopKeeping(_ path: String) {
        settings.alwaysKeep.removeAll { $0 == path }
    }

    public func isKept(_ path: String) -> Bool {
        settings.alwaysKeep.contains(path)
    }

    /// Turns the daily agent on or off, installing or removing its
    /// LaunchAgent. `executable` is this app's binary.
    public func setAgentEnabled(_ enabled: Bool, executable: String) {
        let agent = LaunchAgent(home: home)
        if enabled {
            if settings.agent.earliestMinuteOfDay == nil {
                // Somewhere between 10:00 and 18:00, fixed from then on.
                settings.agent.earliestMinuteOfDay = Int.random(in: 600...1080)
            }
            do {
                try agent.install(executable: executable)
                settings.agent.isEnabled = true
            } catch {
                notice = "Couldn't turn on the daily agent: \(error)"
            }
        } else {
            agent.uninstall()
            settings.agent.isEnabled = false
        }
    }

    /// Pauses daily scans for `days`, or until resumed when nil.
    public func pauseDailyScans(days: Int?) {
        settings.agent.pausedUntil = days.map { Date().addingTimeInterval(Double($0) * 86_400) } ?? .distantFuture
    }

    public func resumeDailyScans() {
        settings.agent.pausedUntil = nil
    }

    /// "Paused until Thursday" or "Paused", for the menu bar.
    public var pauseDescription: String? {
        guard let until = settings.agent.pausedUntil, until > Date() else { return nil }
        if until == .distantFuture { return "Daily scans paused" }
        return "Daily scans paused until " + until.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
    }

    /// Re-points the LaunchAgent at this copy of the app if it moved.
    public func repairAgentIfNeeded(executable: String) {
        let agent = LaunchAgent(home: home)
        if settings.agent.isEnabled && !agent.isInstalled(executable: executable) {
            try? agent.install(executable: executable)
        }
    }

    private func makeScanner() -> DiskScanner {
        let catalog = (try? CategoryCatalog.builtIn()) ?? CategoryCatalog(definitions: [])
        return DiskScanner.configured(settings: settings, options: options, catalog: catalog, rules: loadRules())
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
    /// The phase as a short title.
    public static func phase(_ progress: ScanProgress) -> String {
        switch progress {
        case .findingProjects: return "Finding your projects"
        case .checkingProjects: return "Checking which are active"
        case .collecting: return "Looking at caches and tools"
        case .applyingRules: return "Applying your rules"
        case .measuring: return "Measuring what can go"
        case .finished: return "Done"
        }
    }

    /// How far along, where the scan knows: checking projects and measuring
    /// have totals; finding projects doesn't.
    public static func fraction(_ progress: ScanProgress) -> Double? {
        switch progress {
        case .findingProjects: return 0.08
        case .checkingProjects(let checked, let total):
            return total > 0 ? 0.1 + 0.25 * Double(checked) / Double(total) : 0.1
        case .collecting, .applyingRules: return 0.4
        case .measuring(let checked, let total, _):
            return total > 0 ? 0.45 + 0.55 * Double(checked) / Double(total) : 0.45
        case .finished: return 1
        }
    }

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
