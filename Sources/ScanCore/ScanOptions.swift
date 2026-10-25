import Foundation

/// Everything a scan needs to know about the machine and the user's
/// settings. Tests point `home` and `temporaryDirectory` at fixture trees.
public struct ScanOptions: Sendable {
    /// The user's home folder.
    public var home: String
    /// The per-user temp folder (`$TMPDIR`).
    public var temporaryDirectory: String
    /// Folders searched for projects. Defaults to the home folder.
    public var projectRoots: [String]
    /// Folders never searched for projects (on top of `~/Library`, Trash and
    /// known cache locations, which are always skipped).
    public var excludedFolders: [String]
    /// Paths the user marked "Always keep": never suggested, nor anything
    /// inside them or containing them.
    public var alwaysKeep: [String] = []
    /// A project with activity in this many days is active (spec §4).
    public var activeDays: Int
    /// Anything changed this recently is skipped, whatever the category.
    public var recentChangeWindow: TimeInterval
    /// Opt-in for `~/Library/Caches` in the temp files category.
    public var includeLibraryCaches: Bool
    /// Follow scan roots onto other disks and network volumes.
    public var includeOtherVolumes: Bool
    public var checkOpenFiles: Bool
    /// Ask Docker and `xcrun simctl` for their own numbers. Off in tests,
    /// which mustn't depend on what's installed.
    public var queryTools: Bool
    /// Upper bound on how long one custom rule may spend in one folder.
    public var ruleTimeLimit: TimeInterval
    public var maxConcurrency: Int
    /// "Now", fixed for the whole scan so every age is measured the same way.
    public var now: Date

    public init(
        home: String,
        temporaryDirectory: String,
        projectRoots: [String]? = nil,
        excludedFolders: [String] = [],
        activeDays: Int = 14,
        recentChangeWindow: TimeInterval = 24 * 3600,
        includeLibraryCaches: Bool = false,
        includeOtherVolumes: Bool = false,
        checkOpenFiles: Bool = true,
        queryTools: Bool = true,
        ruleTimeLimit: TimeInterval = 15,
        maxConcurrency: Int = min(8, max(2, ProcessInfo.processInfo.activeProcessorCount)),
        now: Date = Date()
    ) {
        self.home = home
        self.temporaryDirectory = temporaryDirectory
        self.projectRoots = projectRoots ?? [home]
        self.excludedFolders = excludedFolders
        self.activeDays = activeDays
        self.recentChangeWindow = recentChangeWindow
        self.includeLibraryCaches = includeLibraryCaches
        self.includeOtherVolumes = includeOtherVolumes
        self.checkOpenFiles = checkOpenFiles
        self.queryTools = queryTools
        self.ruleTimeLimit = ruleTimeLimit
        self.maxConcurrency = maxConcurrency
        self.now = now
    }

    /// Options for the person running this process.
    public static func currentUser() -> ScanOptions {
        let environment = ProcessInfo.processInfo.environment
        let home = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        let temporary = environment["TMPDIR"].flatMap { $0.isEmpty ? nil : $0 } ?? NSTemporaryDirectory()
        return ScanOptions(home: home, temporaryDirectory: temporary)
    }

    var activeSince: Date { now.addingTimeInterval(-Double(activeDays) * 86_400) }
    var recentlyChangedSince: Date { now.addingTimeInterval(-recentChangeWindow) }

    /// Expands `~` and `$TMPDIR` at the start of a catalog or rule path.
    func expand(_ path: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return Paths.join(home, String(path.dropFirst(2))) }
        if path == "$TMPDIR" { return temporaryDirectory }
        if path.hasPrefix("$TMPDIR/") { return Paths.join(temporaryDirectory, String(path.dropFirst(8))) }
        return path
    }

    /// The same options with every folder resolved to its canonical path,
    /// so paths from `lsof` and from the walkers compare equal.
    public func canonicalized() -> ScanOptions {
        var copy = self
        copy.home = Self.canonical(home)
        copy.temporaryDirectory = Self.canonical(temporaryDirectory)
        copy.projectRoots = projectRoots.map { Self.canonical(copy.expand($0)) }
        copy.excludedFolders = excludedFolders.map { Self.canonical(copy.expand($0)) }
        copy.alwaysKeep = alwaysKeep.map { Self.canonical(copy.expand($0)) }
        return copy
    }

    static func canonical(_ path: String) -> String {
        FileSystem.canonicalPath(path) ?? Paths.normalized(path)
    }
}
