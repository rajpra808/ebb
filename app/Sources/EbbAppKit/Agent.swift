import EbbClean
import Foundation
import ScanCore

/// What the daily agent remembers between runs, in
/// `~/Library/Application Support/Ebb/agent-state.json`.
public struct AgentState: Codable, Equatable, Sendable {
    public var lastScanAt: Date?
    public var lastNotifiedAt: Date?
    public var lastNotifiedBytes: Int64 = 0

    public init(lastScanAt: Date? = nil, lastNotifiedAt: Date? = nil, lastNotifiedBytes: Int64 = 0) {
        self.lastScanAt = lastScanAt
        self.lastNotifiedAt = lastNotifiedAt
        self.lastNotifiedBytes = lastNotifiedBytes
    }
}

/// The Mac's state, as far as the agent cares. Behind a protocol so tests
/// can pretend to be on battery or busy.
public protocol SystemConditions: Sendable {
    /// Whether the Mac runs on its power adapter, and the battery charge
    /// (nil without a battery).
    func power() -> (onAdapter: Bool, batteryPercent: Int?)
    /// Seconds since the last keyboard or mouse input.
    func idleSeconds() -> TimeInterval
}

/// The decisions the daily agent makes, kept free of side effects.
public enum AgentPolicy {
    /// Wait for this much quiet before scanning, so the scan doesn't compete
    /// with someone working.
    public static let requiredIdle: TimeInterval = 120

    public enum Decision: Equatable, Sendable {
        case scan
        case wait(String)
    }

    /// Whether to scan now. launchd starts the agent every hour; this picks
    /// the first good moment of each day after the user's earliest time,
    /// which also catches up after the Mac slept through it.
    public static func decide(
        now: Date, state: AgentState, settings: EbbSettings, conditions: SystemConditions,
        calendar: Calendar = .current
    ) -> Decision {
        guard settings.agent.isEnabled else { return .wait("the daily agent is off") }
        if let last = state.lastScanAt, calendar.isDate(last, inSameDayAs: now) {
            return .wait("already scanned today")
        }
        let minute = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
        if let earliest = settings.agent.earliestMinuteOfDay, minute < earliest {
            return .wait("too early; scans after \(String(format: "%02d:%02d", earliest / 60, earliest % 60))")
        }
        let power = conditions.power()
        if !power.onAdapter, let battery = power.batteryPercent, battery < settings.agent.minimumBatteryPercent {
            return .wait("on battery at \(battery)%")
        }
        if conditions.idleSeconds() < requiredIdle {
            return .wait("the Mac is in use")
        }
        return .scan
    }

    public struct Notice: Equatable, Sendable {
        public let title: String
        public let body: String
    }

    /// The notification for a finished scan, or nil: only when
    /// enough can be cleared, it grew since the last notification, and none
    /// was sent today. A clean since the last notification resets "grew".
    public static func notice(
        for result: ScanResult, state: AgentState, settings: EbbSettings, lastCleanAt: Date?,
        now: Date, calendar: Calendar = .current
    ) -> Notice? {
        let bytes = result.totals.safeToClearBytes
        guard Double(bytes) >= settings.agent.notifyThresholdGB * 1_000_000_000 else { return nil }
        if let notified = state.lastNotifiedAt {
            if calendar.isDate(notified, inSameDayAs: now) { return nil }
            let cleanedSince = lastCleanAt.map { $0 > notified } ?? false
            if !cleanedSince && bytes <= state.lastNotifiedBytes { return nil }
        }
        return Notice(title: "\(ByteCount.format(bytes)) can be cleared safely", body: summary(of: result))
    }

    /// "3 inactive node_modules, package caches, Docker build cache"
    static func summary(of result: ScanResult) -> String {
        let byCategory = Dictionary(grouping: result.items.filter(\.preselected), by: \.categoryID)
        let ranked = byCategory.sorted {
            $0.value.reduce(0) { $0 + $1.allocatedBytes } > $1.value.reduce(0) { $0 + $1.allocatedBytes }
        }
        let phrases = ranked.prefix(3).map { id, items in phrase(for: id, items: items) }
        return phrases.joined(separator: ", ")
    }

    private static func phrase(for categoryID: String, items: [Item]) -> String {
        let projects = Set(items.compactMap(\.projectPath)).count
        switch categoryID {
        case "node-leftovers":
            let modules = items.filter { $0.path.hasSuffix("/node_modules") }.count
            return modules > 0 ? "\(modules) inactive node_modules" : "JS build output in \(projects) projects"
        case "python-venvs": return items.count == 1 ? "1 old virtual env" : "\(items.count) old virtual envs"
        case "build-outputs": return "build output in \(projects == 1 ? "1 project" : "\(projects) projects")"
        case "package-caches": return "package caches"
        case "xcode": return "Xcode build data"
        case "docker": return "Docker build cache"
        case "temp-files": return "old temp files"
        case "old-installers": return items.count == 1 ? "1 old installer" : "\(items.count) old installers"
        default: return categoryID.replacingOccurrences(of: "-", with: " ")
        }
    }
}

/// Posts the daily notification.
public protocol Notifier: Sendable {
    /// Returns whether it was delivered; false if notifications are off.
    func post(_ notice: AgentPolicy.Notice) async -> Bool
}

/// One run of the daily agent: decide, scan, save, maybe notify.
public struct AgentRunner: Sendable {
    let home: String
    let temporaryDirectory: String
    let conditions: SystemConditions
    let notifier: Notifier

    public init(home: String, temporaryDirectory: String, conditions: SystemConditions, notifier: Notifier) {
        self.home = home
        self.temporaryDirectory = temporaryDirectory
        self.conditions = conditions
        self.notifier = notifier
    }

    public static func stateLocation(home: String) -> URL {
        URL(fileURLWithPath: home + "/Library/Application Support/Ebb/agent-state.json")
    }

    /// Runs once and returns a line for the agent's log. `force` skips the
    /// time, power and idle checks (for `--agent --now`).
    public func run(now: Date = Date(), force: Bool = false) async -> String {
        let settings = SettingsStore(fileURL: SettingsStore.defaultLocation(home: home)).load()
        var state = loadState()
        if !force {
            if case .wait(let why) = AgentPolicy.decide(now: now, state: state, settings: settings, conditions: conditions) {
                return "Not scanning: \(why)."
            }
        }

        let options = ScanOptions(home: home, temporaryDirectory: temporaryDirectory, now: now)
        let rules = (try? RuleStore(fileURL: RuleStore.defaultLocation(home: home)).load().rules) ?? []
        let catalog = (try? CategoryCatalog.builtIn()) ?? CategoryCatalog(definitions: [])
        let result = await DiskScanner.configured(settings: settings, options: options, catalog: catalog, rules: rules).scan()
        try? ResultStore(fileURL: ResultStore.defaultLocation(home: home)).save(result)
        state.lastScanAt = now

        var line = "Scanned in \(Int(result.durationSeconds))s: \(ByteCount.format(result.totals.safeToClearBytes)) safe to clear."
        let history = CleanHistory(fileURL: CleanHistory.defaultLocation(home: home))
        let lastClean = (try? history.load())?.map(\.date).max()
        if let notice = AgentPolicy.notice(for: result, state: state, settings: settings, lastCleanAt: lastClean, now: now) {
            // Only a delivered notification counts; otherwise the next run
            // may try again once notifications are allowed.
            if await notifier.post(notice) {
                state.lastNotifiedAt = now
                state.lastNotifiedBytes = result.totals.safeToClearBytes
                line += " Notified."
            } else {
                line += " Notifications are off, so none was shown."
            }
        }
        saveState(state)
        return line
    }

    private func loadState() -> AgentState {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: Self.stateLocation(home: home)),
              let state = try? decoder.decode(AgentState.self, from: data)
        else { return AgentState() }
        return state
    }

    private func saveState(_ state: AgentState) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let url = Self.stateLocation(home: home)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoder.encode(state).write(to: url, options: .atomic)
    }
}
