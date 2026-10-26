import Foundation

/// The user's choices, shared by the app, the daily agent and the CLI.
/// Stored in `~/Library/Application Support/Ebb/settings.json`.
///
/// Every field has a default and a missing field takes it, so older files
/// keep working as settings are added.
public struct EbbSettings: Codable, Equatable, Sendable {
    /// Activity this recent makes a project active. The app offers 7, 14, 30.
    public var activeDays = 14
    /// Projects and folders the user marked "Always keep". A project here is
    /// always active; any other path here is never suggested.
    public var alwaysKeep: [String] = []
    /// Where to look for projects. `~` is the home folder.
    public var scanFolders: [String] = ["~"]
    public var excludedFolders: [String] = []
    public var includeOtherVolumes = false
    public var includeLibraryCaches = false
    /// Category ids switched off.
    public var disabledCategories: [String] = []
    /// `ActivitySignal.id`s switched off (e.g. "editor").
    public var disabledSignals: [String] = []
    public var agent = AgentSettings()
    public var showSizeInMenuBar = true
    public var completedFirstRun = false

    public struct AgentSettings: Codable, Equatable, Sendable {
        public var isEnabled = false
        /// Notify only when at least this much can be cleared.
        public var notifyThresholdGB = 2.0
        /// On battery, only scan above this charge.
        public var minimumBatteryPercent = 30
        /// Minutes after midnight before which the daily scan doesn't start.
        /// Picked at random when the agent is first turned on, so Macs don't
        /// all scan at the same minute.
        public var earliestMinuteOfDay: Int?
        /// Daily scans are paused until this date. `distantFuture` pauses
        /// them until the user resumes.
        public var pausedUntil: Date?

        public init() {}

        public func isPaused(at date: Date) -> Bool {
            pausedUntil.map { $0 > date } ?? false
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let defaults = AgentSettings()
            isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? defaults.isEnabled
            notifyThresholdGB = try container.decodeIfPresent(Double.self, forKey: .notifyThresholdGB)
                ?? defaults.notifyThresholdGB
            minimumBatteryPercent = try container.decodeIfPresent(Int.self, forKey: .minimumBatteryPercent)
                ?? defaults.minimumBatteryPercent
            earliestMinuteOfDay = try container.decodeIfPresent(Int.self, forKey: .earliestMinuteOfDay)
            pausedUntil = try container.decodeIfPresent(Date.self, forKey: .pausedUntil)
        }
    }

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = EbbSettings()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T {
            try container.decodeIfPresent(T.self, forKey: key) ?? fallback
        }
        activeDays = try value(.activeDays, defaults.activeDays)
        alwaysKeep = try value(.alwaysKeep, defaults.alwaysKeep)
        scanFolders = try value(.scanFolders, defaults.scanFolders)
        excludedFolders = try value(.excludedFolders, defaults.excludedFolders)
        includeOtherVolumes = try value(.includeOtherVolumes, defaults.includeOtherVolumes)
        includeLibraryCaches = try value(.includeLibraryCaches, defaults.includeLibraryCaches)
        disabledCategories = try value(.disabledCategories, defaults.disabledCategories)
        disabledSignals = try value(.disabledSignals, defaults.disabledSignals)
        agent = try value(.agent, defaults.agent)
        showSizeInMenuBar = try value(.showSizeInMenuBar, defaults.showSizeInMenuBar)
        completedFirstRun = try value(.completedFirstRun, defaults.completedFirstRun)
    }

    /// Scan options for `home` with these settings applied.
    public func scanOptions(home: String, temporaryDirectory: String) -> ScanOptions {
        var options = ScanOptions(home: home, temporaryDirectory: temporaryDirectory)
        apply(to: &options)
        return options
    }

    public func apply(to options: inout ScanOptions) {
        options.activeDays = activeDays
        options.projectRoots = scanFolders.isEmpty ? [options.home] : scanFolders
        options.excludedFolders = excludedFolders
        options.includeOtherVolumes = includeOtherVolumes
        options.includeLibraryCaches = includeLibraryCaches
        options.alwaysKeep = alwaysKeep
    }

    /// The catalog without the categories switched off.
    public func filter(_ catalog: CategoryCatalog) -> CategoryCatalog {
        let disabled = Set(disabledCategories)
        return CategoryCatalog(definitions: catalog.definitions.filter { !disabled.contains($0.category.id) })
    }
}

/// Reads and writes `settings.json`.
public struct SettingsStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public static func defaultLocation(home: String) -> URL {
        #if os(macOS)
        URL(fileURLWithPath: Paths.join(home, "Library/Application Support/Ebb/settings.json"))
        #else
        URL(fileURLWithPath: Paths.join(home, ".local/share/ebb/settings.json"))
        #endif
    }

    /// The saved settings, or the defaults if there's no file or it can't be
    /// read. Never fails: a broken settings file mustn't stop a scan.
    public func load() -> EbbSettings {
        guard let data = try? Data(contentsOf: fileURL),
              let settings = try? JSONDecoder().decode(EbbSettings.self, from: data)
        else { return EbbSettings() }
        return settings
    }

    public func save(_ settings: EbbSettings) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(settings).write(to: fileURL, options: .atomic)
    }
}

/// Check 6: the user marked the project, or a folder in it,
/// "Always keep".
public struct PinnedSignal: ActivitySignal {
    public let id = "pinned"
    public let pinned: [String]

    public init(pinned: [String]) {
        self.pinned = pinned.map(Paths.normalized)
    }

    public func evaluate(_ project: Project, in context: ActivityContext) async -> ActivityEvidence? {
        let hit = pinned.first {
            Paths.isSameOrDescendant($0, of: project.root) || Paths.isSameOrDescendant(project.root, of: $0)
        }
        guard hit != nil else { return nil }
        return ActivityEvidence(signal: id, detail: "you chose Always keep", date: nil)
    }
}

extension DiskScanner {
    /// A scanner set up from the user's settings: their options, categories,
    /// signals, rules and Always keep list.
    public static func configured(
        settings: EbbSettings, options: ScanOptions, catalog: CategoryCatalog, rules: [Rule]
    ) -> DiskScanner {
        var options = options
        settings.apply(to: &options)
        var scanner = DiskScanner(catalog: settings.filter(catalog), options: options, rules: rules)
        let disabled = Set(settings.disabledSignals)
        scanner.signals = scanner.signals.filter { !disabled.contains($0.id) }
        let pinned = settings.alwaysKeep.map { ScanOptions.canonical(options.expand($0)) }
        if !pinned.isEmpty { scanner.signals.append(PinnedSignal(pinned: pinned)) }
        return scanner
    }
}
