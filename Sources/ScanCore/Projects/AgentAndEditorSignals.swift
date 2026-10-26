#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

// Activity checks 3 to 5. Each signal reads its source once per scan into an
// index, then answers for every project with a lookup.

/// Something seen for a folder at a time: a session, an editor window.
struct FolderActivity: Sendable, Equatable {
    let folder: String
    let date: Date
}

extension [FolderActivity] {
    /// The latest activity in `root` or below it, on or after `since`.
    func latest(inside root: String, since: Date) -> FolderActivity? {
        filter { $0.date >= since && Paths.isSameOrDescendant($0.folder, of: root) }
            .max { $0.date < $1.date }
    }
}

// MARK: - 3. AI agent sessions

/// A Claude Code session for the project within `activeDays`.
///
/// Claude Code keeps each folder's chats in `~/.claude/projects/<name>`,
/// where the name is the folder path with every character other than a
/// letter or digit replaced by "-". Because the encoding loses
/// information, a folder whose name starts with the project's encoded path
/// also counts. That can mark an extra project active, never fewer.
public struct ClaudeCodeSessionSignal: ActivitySignal {
    public let id = "claude-code"
    private let cache = PerScanCache<[String: Date]>()

    public init() {}

    public func evaluate(_ project: Project, in context: ActivityContext) async -> ActivityEvidence? {
        let sessions = await BlockingIO.run {
            cache.value(for: context.cacheKey) { Self.latestSessions(home: context.home, since: context.activeSince) }
        }
        let encoded = Self.encode(project.root)
        let latest = sessions
            .filter { $0.key == encoded || $0.key.hasPrefix(encoded + "-") }
            .map(\.value)
            .max()
        guard let latest else { return nil }
        return ActivityEvidence(
            signal: id, detail: "Claude Code session \(Age.describe(from: latest, to: context.now)) ago", date: latest
        )
    }

    static func encode(_ path: String) -> String {
        String(path.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    }

    /// Folder name → newest chat file, for folders with a chat since `since`.
    static func latestSessions(home: String, since: Date) -> [String: Date] {
        let root = Paths.join(home, ".claude/projects")
        guard let folders = try? FileSystem.entries(ofDirectory: root) else { return [:] }
        var result: [String: Date] = [:]
        for folder in folders {
            let path = Paths.join(root, folder.name)
            guard let files = try? FileSystem.entries(ofDirectory: path) else { continue }
            let newest = files
                .filter { $0.name.hasSuffix(".jsonl") }
                .compactMap { FileSystem.status(atPath: Paths.join(path, $0.name))?.modificationDate }
                .max()
            if let newest, newest >= since { result[folder.name] = newest }
        }
        return result
    }
}

/// A Codex session whose working folder is inside the project.
///
/// Codex writes `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`; the first
/// line holds the session's `cwd`. Only files changed within `activeDays`
/// are opened, and only their first line is read.
public struct CodexSessionSignal: ActivitySignal {
    public let id = "codex"
    private let cache = PerScanCache<[FolderActivity]>()

    public init() {}

    public func evaluate(_ project: Project, in context: ActivityContext) async -> ActivityEvidence? {
        let sessions = await BlockingIO.run {
            cache.value(for: context.cacheKey) { Self.recentSessions(home: context.home, since: context.activeSince) }
        }
        guard let latest = sessions.latest(inside: project.root, since: context.activeSince) else { return nil }
        let folder = latest.folder == project.root ? "" : " in \(Paths.relative(latest.folder, to: project.root))"
        return ActivityEvidence(
            signal: id, detail: "Codex session\(folder) \(Age.describe(from: latest.date, to: context.now)) ago",
            date: latest.date
        )
    }

    static func recentSessions(home: String, since: Date) -> [FolderActivity] {
        let root = Paths.join(home, ".codex/sessions")
        var result: [FolderActivity] = []
        var stack = [(root, 0)]
        while let (folder, depth) = stack.popLast() {
            guard depth <= 4, let entries = try? FileSystem.entries(ofDirectory: folder) else { continue }
            for entry in entries where !entry.name.hasPrefix(".") {
                let path = Paths.join(folder, entry.name)
                guard let status = FileSystem.status(atPath: path) else { continue }
                if status.isDirectory {
                    stack.append((path, depth + 1))
                } else if status.isRegularFile, entry.name.hasSuffix(".jsonl"), status.modificationDate >= since,
                          let cwd = workingFolder(ofSession: path) {
                    result.append(FolderActivity(folder: cwd, date: status.modificationDate))
                }
            }
        }
        return result
    }

    /// `payload.cwd` from the session's first line (`session_meta`).
    static func workingFolder(ofSession path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 256 * 1024),
              let line = head.split(separator: UInt8(ascii: "\n"), maxSplits: 1).first,
              let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              let payload = object["payload"] as? [String: Any],
              let cwd = payload["cwd"] as? String, cwd.hasPrefix("/")
        else { return nil }
        return Paths.normalized(cwd)
    }
}

// MARK: - 4. Running processes

/// A process (shell, dev server, `claude`, `node`...) whose working folder
/// is inside the project, right now.
public struct RunningProcessSignal: ActivitySignal {
    public struct Process: Sendable, Equatable {
        public let pid: Int32
        public let command: String
        public let workingFolder: String

        public init(pid: Int32, command: String, workingFolder: String) {
            self.pid = pid
            self.command = command
            self.workingFolder = workingFolder
        }
    }

    public let id = "process"
    private let fixed: [Process]?
    private let cache = PerScanCache<[Process]>()

    /// - Parameter processes: a fixed list, for tests. By default the
    ///   current user's processes are listed with `lsof` once per scan.
    public init(processes: [Process]? = nil) {
        fixed = processes
    }

    public func evaluate(_ project: Project, in context: ActivityContext) async -> ActivityEvidence? {
        let fixed = self.fixed
        let processes = await BlockingIO.run {
            cache.value(for: context.cacheKey) { fixed ?? Self.snapshot() }
        }
        guard let process = processes.first(where: { Paths.isSameOrDescendant($0.workingFolder, of: project.root) })
        else { return nil }
        let place = process.workingFolder == project.root
            ? "here" : "in \(Paths.relative(process.workingFolder, to: project.root))"
        return ActivityEvidence(signal: id, detail: "\(process.command) is running \(place)", date: context.now)
    }

    static func snapshot() -> [Process] {
        guard let lsof = Subprocess.locate("lsof", fallbacks: ["/usr/sbin/lsof", "/usr/bin/lsof"]) else { return [] }
        // -a -d cwd: only working folders. -F pcn: pid, command, name.
        let arguments = ["-n", "-P", "-w", "-a", "-d", "cwd", "-F", "pcn", "-u", String(getuid())]
        guard let output = Subprocess.runBlocking(lsof, arguments: arguments, timeout: 20) else { return [] }
        return parse(output.stdout).filter { $0.pid != getpid() }
    }

    static func parse(_ data: Data) -> [Process] {
        var result: [Process] = []
        var pid: Int32?
        var command = ""
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let tag = line.first else { continue }
            let value = String(decoding: line.dropFirst(), as: UTF8.self)
            switch tag {
            case UInt8(ascii: "p"): pid = Int32(value)
            case UInt8(ascii: "c"): command = value
            case UInt8(ascii: "n"):
                // "/" is where daemons and GUI apps sit; it says nothing.
                if let pid, value.hasPrefix("/"), value != "/" {
                    result.append(Process(pid: pid, command: command, workingFolder: Paths.normalized(value)))
                }
            default: continue
            }
        }
        return result
    }
}

// MARK: - 5. Editor recents

/// The project was open in VS Code, Cursor, another VS Code fork, or Xcode
/// within `activeDays`.
///
/// VS Code-style editors keep a `workspaceStorage/<hash>` folder per opened
/// folder, with `workspace.json` naming it and `state.vscdb` written while
/// it's open. Xcode records each workspace and when it was last opened in
/// its DerivedData `info.plist`.
public struct EditorRecentsSignal: ActivitySignal {
    public let id = "editor"
    private let cache = PerScanCache<[EditorActivity]>()

    struct EditorActivity: Sendable, Equatable {
        let editor: String
        let activity: FolderActivity
    }

    static let vscodeFamily = ["Code", "Code - Insiders", "Cursor", "Windsurf", "VSCodium", "Kiro", "Antigravity"]

    public init() {}

    public func evaluate(_ project: Project, in context: ActivityContext) async -> ActivityEvidence? {
        let recents = await BlockingIO.run {
            cache.value(for: context.cacheKey) { Self.recents(home: context.home) }
        }
        let latest = recents
            .filter { $0.activity.date >= context.activeSince
                && Paths.isSameOrDescendant($0.activity.folder, of: project.root) }
            .max { $0.activity.date < $1.activity.date }
        guard let latest else { return nil }
        let date = latest.activity.date
        return ActivityEvidence(
            signal: id, detail: "open in \(latest.editor) \(Age.describe(from: date, to: context.now)) ago", date: date
        )
    }

    static func recents(home: String) -> [EditorActivity] {
        #if os(macOS)
        let support = Paths.join(home, "Library/Application Support")
        #else
        let support = Paths.join(home, ".config")
        #endif
        var result: [EditorActivity] = []
        for editor in vscodeFamily {
            let storage = Paths.join(support, "\(editor)/User/workspaceStorage")
            guard let entries = try? FileSystem.entries(ofDirectory: storage) else { continue }
            for entry in entries {
                let path = Paths.join(storage, entry.name)
                guard let folder = workspaceFolder(path) else { continue }
                let dates = ["state.vscdb", "workspace.json"]
                    .compactMap { FileSystem.status(atPath: Paths.join(path, $0))?.modificationDate }
                guard let date = dates.max() else { continue }
                result.append(EditorActivity(editor: editor == "Code" ? "VS Code" : editor,
                                             activity: FolderActivity(folder: folder, date: date)))
            }
        }
        #if os(macOS)
        result += xcodeRecents(home: home)
        #endif
        return result
    }

    static func workspaceFolder(_ storage: String) -> String? {
        let file = Paths.join(storage, "workspace.json")
        guard let status = FileSystem.status(atPath: file), status.isRegularFile, status.logicalSize < 64_000,
              let data = FileManager.default.contents(atPath: file),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let uri = object["folder"] as? String, let url = URL(string: uri), url.isFileURL
        else { return nil }
        return Paths.normalized(url.path)
    }

    static func xcodeRecents(home: String) -> [EditorActivity] {
        let derivedData = Paths.join(home, "Library/Developer/Xcode/DerivedData")
        guard let entries = try? FileSystem.entries(ofDirectory: derivedData) else { return [] }
        return entries.compactMap { entry in
            let plist = Paths.join(Paths.join(derivedData, entry.name), "info.plist")
            guard let data = FileManager.default.contents(atPath: plist),
                  let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let workspace = info["WorkspacePath"] as? String, workspace.hasPrefix("/"),
                  let date = (info["LastAccessedDate"] as? Date)
                    ?? FileSystem.status(atPath: plist)?.modificationDate
            else { return nil }
            // The workspace file sits inside the project folder.
            return EditorActivity(editor: "Xcode",
                                  activity: FolderActivity(folder: Paths.normalized(workspace), date: date))
        }
    }
}
