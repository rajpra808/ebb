import Foundation

/// One way of telling that someone is working on a project.
///
/// Day 1 ships two signals: recent edits and recent git activity. The rest
/// from spec §4 (AI agent sessions, running processes, editor recents,
/// pinned projects) plug in here as further conformances; the scanner asks
/// every signal and a project is active if any of them answers.
public protocol ActivitySignal: Sendable {
    /// Short, stable identifier shown in `ebb active` and stored in JSON.
    var id: String { get }

    /// Evidence that `project` is active, or `nil` if this signal sees none.
    func evaluate(_ project: Project, in context: ActivityContext) async -> ActivityEvidence?
}

/// What a signal may look at.
public struct ActivityContext: Sendable {
    public let home: String
    public let now: Date
    /// Activity on or after this date makes a project active.
    public let activeSince: Date
    private let survey: @Sendable () async -> ProjectSurvey

    init(home: String, now: Date, activeSince: Date, survey: @escaping @Sendable () async -> ProjectSurvey) {
        self.home = home
        self.now = now
        self.activeSince = activeSince
        self.survey = survey
    }

    /// Identifies one scan, for signals that build an index once and reuse
    /// it for every project.
    var cacheKey: String { "\(home)|\(activeSince.timeIntervalSince1970)" }

    /// A walk over the project's files. Computed at most once per project,
    /// and only if a signal asks for it.
    public func projectSurvey() async -> ProjectSurvey {
        await survey()
    }
}

/// Spec §4 check 1: a file outside the leftover folders changed recently.
public struct RecentEditSignal: ActivitySignal {
    public let id = "recent-edit"

    public init() {}

    public func evaluate(_ project: Project, in context: ActivityContext) async -> ActivityEvidence? {
        guard let edit = await context.projectSurvey().newestEdit, edit.date >= context.activeSince else {
            return nil
        }
        let file = Paths.relative(edit.path, to: project.root)
        return ActivityEvidence(
            signal: id,
            detail: "\(file) edited \(Age.describe(from: edit.date, to: context.now)) ago",
            date: edit.date
        )
    }
}

/// Spec §4 check 2: `.git/HEAD`, `.git/index` or `.git/logs/HEAD` changed
/// recently, meaning a commit, checkout, stage or pull.
public struct GitActivitySignal: ActivitySignal {
    public let id = "git"

    public init() {}

    public func evaluate(_ project: Project, in context: ActivityContext) async -> ActivityEvidence? {
        guard let latest = GitActivity.latest(in: project.root), latest.date >= context.activeSince else {
            return nil
        }
        return ActivityEvidence(
            signal: id,
            detail: "\(latest.what) \(Age.describe(from: latest.date, to: context.now)) ago",
            date: latest.date
        )
    }
}

enum GitActivity {
    struct Event {
        let what: String
        let date: Date
    }

    /// The most recent change among the files git touches on every commit,
    /// checkout and stage.
    static func latest(in projectRoot: String) -> Event? {
        guard let gitDirectory = gitDirectory(of: projectRoot) else { return nil }
        let files = [
            ("logs/HEAD", "git commit or checkout"),
            ("index", "git index changed"),
            ("HEAD", "git HEAD moved"),
        ]
        return files
            .compactMap { file, what -> Event? in
                guard let status = FileSystem.status(atPath: Paths.join(gitDirectory, file)) else { return nil }
                return Event(what: what, date: status.modificationDate)
            }
            .max { $0.date < $1.date }
    }

    /// `.git` is a folder, or for worktrees and submodules a file holding
    /// `gitdir: <path>`.
    static func gitDirectory(of projectRoot: String) -> String? {
        let dotGit = Paths.join(projectRoot, ".git")
        guard let status = FileSystem.status(atPath: dotGit) else { return nil }
        if status.isDirectory { return dotGit }
        guard status.isRegularFile, status.logicalSize < 4096,
              let contents = try? String(contentsOfFile: dotGit, encoding: .utf8),
              let line = contents.split(separator: "\n").first, line.hasPrefix("gitdir:")
        else { return nil }
        let target = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        return target.hasPrefix("/") ? target : Paths.join(projectRoot, target)
    }
}
