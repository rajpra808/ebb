import Foundation

/// Size and age worked out by the collector instead of by walking the path:
/// Docker reports its own numbers, and an Ollama model is a set of blobs
/// shared with other models.
struct PrecomputedSize: Sendable {
    let allocatedBytes: Int64
    let fileCount: Int
    let lastUsed: Date?
    /// Files the item consists of, checked for being open.
    let paths: [String]
    /// The path isn't a file (e.g. "docker:build-cache"), so file checks
    /// don't apply.
    let isVirtual: Bool
}

/// Something a collector thinks might be clearable. It becomes an `Item`
/// only after the safety gate checks it and the measurer sizes it.
struct Candidate: Sendable {
    let path: String
    let categoryID: String
    let comesBack: ComesBack
    let preselected: Bool
    let projectPath: String?
    let source: String?
    let ruleID: String?
    let clearCommand: String?
    let isEstimated: Bool
    /// The contents were written by a package manager and return on
    /// reinstall. Built-in never-touch *names* inside (a package's own
    /// `CLAUDE.md` or `.git`) don't block the item. Never-touch rules and
    /// protected paths still do.
    let packageManaged: Bool
    /// Only reported if nothing inside changed for this long. Candidates
    /// that are simply too new are dropped quietly rather than "skipped".
    let minimumAge: TimeInterval?
    /// Count reads as use when judging age (models are only ever read).
    let useAccessTime: Bool
    let precomputed: PrecomputedSize?
    /// Builds the reason sentence once the last-used date is known.
    let describe: @Sendable (_ lastUsed: Date?, _ now: Date) -> String

    init(
        path: String,
        categoryID: String,
        comesBack: ComesBack,
        preselected: Bool,
        projectPath: String? = nil,
        source: String? = nil,
        ruleID: String? = nil,
        clearCommand: String? = nil,
        isEstimated: Bool = false,
        packageManaged: Bool = false,
        minimumAge: TimeInterval? = nil,
        useAccessTime: Bool = false,
        precomputed: PrecomputedSize? = nil,
        describe: @escaping @Sendable (_ lastUsed: Date?, _ now: Date) -> String
    ) {
        self.path = path
        self.categoryID = categoryID
        self.comesBack = comesBack
        self.preselected = preselected
        self.projectPath = projectPath
        self.source = source
        self.ruleID = ruleID
        self.clearCommand = clearCommand
        self.isEstimated = isEstimated
        self.packageManaged = packageManaged
        self.minimumAge = minimumAge
        self.useAccessTime = useAccessTime
        self.precomputed = precomputed
        self.describe = describe
    }
}

/// What a collector hands back to the scanner.
struct Findings: Sendable {
    var candidates: [Candidate] = []
    var skipped: [SkippedItem] = []
    var warnings: [String] = []

    mutating func merge(_ other: Findings) {
        candidates += other.candidates
        skipped += other.skipped
        warnings += other.warnings
    }
}
