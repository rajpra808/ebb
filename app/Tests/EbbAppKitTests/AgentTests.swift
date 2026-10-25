#if canImport(Darwin)
import Darwin
#endif
import Foundation
import Testing
@testable import EbbAppKit
@testable import ScanCore

private struct FakeConditions: SystemConditions {
    var onAdapter = true
    var battery: Int? = 80
    var idle: TimeInterval = 600

    func power() -> (onAdapter: Bool, batteryPercent: Int?) { (onAdapter, battery) }
    func idleSeconds() -> TimeInterval { idle }
}

private final class RecordingNotifier: Notifier, @unchecked Sendable {
    private let lock = NSLock()
    private var notices: [AgentPolicy.Notice] = []
    let allowed: Bool

    init(allowed: Bool = true) {
        self.allowed = allowed
    }

    var posted: [AgentPolicy.Notice] { lock.withLock { notices } }

    func post(_ notice: AgentPolicy.Notice) async -> Bool {
        guard allowed else { return false }
        lock.withLock { notices.append(notice) }
        return true
    }
}

@Suite("Daily agent")
struct AgentTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }()

    private func at(_ hour: Int, _ minute: Int = 0, day: Int = 25) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute)) ?? Date()
    }

    private var enabled: EbbSettings {
        var settings = EbbSettings()
        settings.agent.isEnabled = true
        settings.agent.earliestMinuteOfDay = 14 * 60
        return settings
    }

    @Test("Scans once a day, after the earliest time, when idle and powered")
    func decisions() {
        func decide(_ date: Date, _ state: AgentState = AgentState(), _ settings: EbbSettings? = nil,
                    _ conditions: FakeConditions = FakeConditions()) -> AgentPolicy.Decision {
            AgentPolicy.decide(now: date, state: state, settings: settings ?? enabled, conditions: conditions,
                               calendar: calendar)
        }
        #expect(decide(at(15), AgentState(), EbbSettings()) == .wait("the daily agent is off"))
        #expect(decide(at(13, 59)) == .wait("too early; scans after 14:00"))
        #expect(decide(at(15)) == .scan)
        #expect(decide(at(15), AgentState(lastScanAt: at(14, 30))) == .wait("already scanned today"))
        // Slept through yesterday's slot: scans the first good hour today.
        #expect(decide(at(15), AgentState(lastScanAt: at(14, day: 23))) == .scan)
        #expect(decide(at(15), AgentState(), nil, FakeConditions(onAdapter: false, battery: 20))
            == .wait("on battery at 20%"))
        #expect(decide(at(15), AgentState(), nil, FakeConditions(onAdapter: false, battery: 60)) == .scan)
        #expect(decide(at(15), AgentState(), nil, FakeConditions(idle: 30)) == .wait("the Mac is in use"))
    }

    private func result(bytes: Int64) -> ScanResult {
        let items = [
            Item(path: "/a/node_modules", categoryID: "node-leftovers", allocatedBytes: bytes / 2, sharedBytes: 0,
                 isEstimated: false, fileCount: 1, lastUsed: nil, comesBack: .yes(howTo: ""), reason: "",
                 preselected: true, projectPath: "/a", source: nil, ruleID: nil, clearCommand: nil, packageManaged: true),
            Item(path: "/b/node_modules", categoryID: "node-leftovers", allocatedBytes: bytes / 4, sharedBytes: 0,
                 isEstimated: false, fileCount: 1, lastUsed: nil, comesBack: .yes(howTo: ""), reason: "",
                 preselected: true, projectPath: "/b", source: nil, ruleID: nil, clearCommand: nil, packageManaged: true),
            Item(path: "docker:build-cache", categoryID: "docker", allocatedBytes: bytes / 4, sharedBytes: 0,
                 isEstimated: true, fileCount: 1, lastUsed: nil, comesBack: .yes(howTo: ""), reason: "",
                 preselected: true, projectPath: nil, source: "build cache", ruleID: nil,
                 clearCommand: "docker builder prune", packageManaged: false),
        ]
        let categories = ["node-leftovers", "docker"].map {
            Category(id: $0, number: 0, title: $0, summary: "", comesBack: .yes(howTo: ""), ruleDescription: "",
                     preselected: true)
        }
        return ScanResult(formatVersion: 1, startedAt: Date(), durationSeconds: 1, roots: [], activeDays: 14,
                          categories: categories, items: items, skipped: [], activeProjects: [],
                          totals: DiskScanner.totals(of: items, categories: categories), warnings: [])
    }

    @Test("Notifies above the threshold, once a day, only when the total grew")
    func notices() throws {
        func notice(_ bytes: Int64, _ state: AgentState = AgentState(), cleaned: Date? = nil) -> AgentPolicy.Notice? {
            AgentPolicy.notice(for: result(bytes: bytes), state: state, settings: enabled, lastCleanAt: cleaned,
                               now: at(15), calendar: calendar)
        }
        let first = try #require(notice(6_200_000_000))
        #expect(first.title == "6.2 GB can be cleared safely")
        #expect(first.body == "2 inactive node_modules, Docker build cache")

        #expect(notice(1_500_000_000) == nil, "below 2 GB")
        let yesterday = AgentState(lastNotifiedAt: at(15, day: 24), lastNotifiedBytes: 6_200_000_000)
        #expect(notice(6_000_000_000, yesterday) == nil, "didn't grow")
        #expect(notice(7_000_000_000, yesterday) != nil, "grew")
        #expect(notice(3_000_000_000, yesterday, cleaned: at(9)) != nil, "cleaned since, so it starts over")
        let today = AgentState(lastNotifiedAt: at(9), lastNotifiedBytes: 1)
        #expect(notice(9_000_000_000, today) == nil, "already notified today")
    }

    @Test("A run scans, saves the result for the app, notifies and remembers")
    func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ebb-agent-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root + "/Users/me/Downloads", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/tmp", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        guard let resolved = realpath(root, nil) else { throw CocoaError(.fileNoSuchFile) }
        let base = String(cString: resolved)
        free(resolved)
        let home = base + "/Users/me"

        let installer = home + "/Downloads/Big.dmg"
        FileManager.default.createFile(atPath: installer, contents: Data(repeating: 1, count: 200_000))
        let old = Date().addingTimeInterval(-60 * 86_400)
        for path in [installer, home + "/Downloads"] {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: path)
        }
        var settings = EbbSettings()
        settings.agent.isEnabled = true
        settings.agent.earliestMinuteOfDay = 0
        settings.agent.notifyThresholdGB = 0.0001
        try SettingsStore(fileURL: SettingsStore.defaultLocation(home: home)).save(settings)

        let notifier = RecordingNotifier()
        let runner = AgentRunner(home: home, temporaryDirectory: base + "/tmp", conditions: FakeConditions(),
                                 notifier: notifier)
        let line = await runner.run()
        #expect(line.hasPrefix("Scanned in"))
        #expect(line.hasSuffix("Notified."))
        #expect(notifier.posted.count == 1)
        #expect(notifier.posted.first?.body == "1 old installer")
        #expect(ResultStore(fileURL: ResultStore.defaultLocation(home: home)).load()?.items.map(\.path) == [installer])

        #expect(await runner.run() == "Not scanning: already scanned today.")
        #expect(notifier.posted.count == 1)
    }

    @Test("A notification that wasn't delivered isn't remembered as sent")
    func undeliveredNotification() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ebb-agent-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root + "/Users/me/Downloads", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/tmp", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let home = root + "/Users/me"
        let installer = home + "/Downloads/Big.dmg"
        FileManager.default.createFile(atPath: installer, contents: Data(repeating: 1, count: 200_000))
        let old = Date().addingTimeInterval(-60 * 86_400)
        for path in [installer, home + "/Downloads"] {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: path)
        }
        var settings = EbbSettings()
        settings.agent.isEnabled = true
        settings.agent.notifyThresholdGB = 0.0001
        try SettingsStore(fileURL: SettingsStore.defaultLocation(home: home)).save(settings)

        let runner = AgentRunner(home: home, temporaryDirectory: root + "/tmp", conditions: FakeConditions(),
                                 notifier: RecordingNotifier(allowed: false))
        let line = await runner.run(force: true)
        #expect(line.hasSuffix("Notifications are off, so none was shown."))
        let data = try Data(contentsOf: AgentRunner.stateLocation(home: home))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let state = try decoder.decode(AgentState.self, from: data)
        #expect(state.lastScanAt != nil)
        #expect(state.lastNotifiedAt == nil)
    }

    @Test("The LaunchAgent runs the app's binary hourly at low priority")
    func launchAgentPlist() throws {
        let agent = LaunchAgent(home: "/Users/me")
        #expect(agent.plistURL.path == "/Users/me/Library/LaunchAgents/com.serveka.ebb.agent.plist")
        let plist = agent.plist(executable: "/Applications/Ebb.app/Contents/MacOS/Ebb")
        #expect(plist["ProgramArguments"] as? [String] == ["/Applications/Ebb.app/Contents/MacOS/Ebb", "--agent"])
        #expect(plist["StartInterval"] as? Int == 3600)
        #expect(plist["RunAtLoad"] as? Bool == true)
        #expect(plist["ProcessType"] as? String == "Background")
        #expect(plist["LowPriorityIO"] as? Bool == true)
        // It must serialize as a valid property list.
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        #expect(!data.isEmpty)
    }

    @Test("Always keep drops matching items from the current result at once")
    @MainActor
    func alwaysKeepUpdatesResult() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ebb-keep-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root + "/Users/me/Downloads", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/tmp", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        guard let resolved = realpath(root, nil) else { throw CocoaError(.fileNoSuchFile) }
        let base = String(cString: resolved)
        free(resolved)
        let home = base + "/Users/me"
        let installer = home + "/Downloads/Keep.dmg"
        FileManager.default.createFile(atPath: installer, contents: Data(repeating: 2, count: 50_000))
        let old = Date().addingTimeInterval(-60 * 86_400)
        for path in [installer, home + "/Downloads"] {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: path)
        }

        let model = AppModel(options: ScanOptions(home: home, temporaryDirectory: base + "/tmp", checkOpenFiles: false,
                                                  queryTools: false, maxConcurrency: 2))
        await model.scan()
        #expect(model.result?.items.count == 1)
        model.alwaysKeep(installer)
        #expect(model.result?.items.isEmpty == true)
        #expect(SettingsStore(fileURL: SettingsStore.defaultLocation(home: home)).load().alwaysKeep == [installer])
        await model.scan()
        #expect(model.result?.items.isEmpty == true)
    }
}
