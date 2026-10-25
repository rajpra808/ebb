import Foundation

/// Old entries in known folders: `$TMPDIR`, `~/Downloads`, agent chat
/// folders, model caches, Xcode device support.
///
/// Candidates sit at a fixed depth below each folder (`depth`), so
/// `~/.codex/sessions` with depth 3 yields one candidate per day folder.
struct FolderContentsCollector: Sendable {
    static let quarantineAttribute = "com.apple.quarantine"

    let category: Category
    let spec: FolderContentsSpec
    let options: ScanOptions
    /// Overrides `spec.olderThanDays` (Claude Code's own retention setting).
    var olderThanDays: Int?
    /// Appended to every reason.
    var reasonNote: String?

    init(category: Category, spec: FolderContentsSpec, options: ScanOptions) {
        self.category = category
        self.spec = spec
        self.options = options
    }

    func collect() -> Findings {
        var findings = Findings()
        let minimumAge = Double(olderThanDays ?? spec.olderThanDays) * 86_400
        for folder in spec.folders where isEnabled(folder) {
            let base = ScanOptions.canonical(options.expand(folder.path))
            var entries = self.entries(below: base, depth: max(1, spec.depth ?? 1))
                .map { Entry(path: $0.path, name: Paths.relative($0.path, to: base), status: $0.status) }
            if spec.keepNewest == true, let newest = entries.max(by: { $0.status.modificationDate < $1.status.modificationDate }) {
                entries.removeAll { $0.path == newest.path }
            }
            for entry in entries {
                if let skip = downloadCheck(entry) {
                    findings.skipped.append(skip)
                    continue
                }
                findings.candidates.append(candidate(for: entry, minimumAge: minimumAge))
            }
        }
        return findings
    }

    private struct Entry {
        let path: String
        let name: String
        let status: FileStatus
    }

    /// Entries exactly `depth` levels below `base`, never through symlinks.
    private func entries(below base: String, depth: Int) -> [Entry] {
        guard let listing = try? FileSystem.entries(ofDirectory: base) else { return [] }
        var result: [Entry] = []
        for item in listing.sorted(by: { $0.name < $1.name }) {
            let path = Paths.join(base, item.name)
            guard let status = FileSystem.status(atPath: path) else { continue }
            if depth > 1 {
                if status.isDirectory && !status.isDataless {
                    result += entries(below: path, depth: depth - 1)
                }
                continue
            }
            if accepts(item.name, status) {
                result.append(Entry(path: path, name: item.name, status: status))
            }
        }
        return result
    }

    private func accepts(_ name: String, _ status: FileStatus) -> Bool {
        // Hidden entries belong to whatever made them.
        if name.hasPrefix(".") { return false }
        if spec.skipNames?.contains(name) == true { return false }
        if spec.skipNamePrefixes?.contains(where: { name.hasPrefix($0) }) == true { return false }
        if let prefixes = spec.namePrefixes, !prefixes.contains(where: { name.hasPrefix($0) }) { return false }
        // Regular files and folders only: no symlinks, sockets or pipes.
        guard status.isRegularFile || (status.isDirectory && spec.filesOnly != true) else { return false }
        if let extensions = spec.extensions {
            guard let fileExtension = Paths.fileExtension(of: name),
                  extensions.contains(where: { $0.lowercased() == fileExtension })
            else { return false }
        }
        return true
    }

    private func downloadCheck(_ entry: Entry) -> SkippedItem? {
        let needsDownload = (spec.requireDownloadedFor ?? []).map { $0.lowercased() }
        guard let fileExtension = Paths.fileExtension(of: entry.path), needsDownload.contains(fileExtension),
              !FileSystem.hasExtendedAttribute(Self.quarantineAttribute, atPath: entry.path)
        else { return nil }
        return SkippedItem(
            path: entry.path, categoryID: category.id,
            reason: SkipReason(.unverified, "not downloaded from the web, may be your own archive")
        )
    }

    private func candidate(for entry: Entry, minimumAge: TimeInterval) -> Candidate {
        let template = spec.reason ?? "Untouched for {age}"
        let name = label(for: entry)
        let note = reasonNote
        return Candidate(
            path: entry.path,
            categoryID: category.id,
            comesBack: category.comesBack,
            preselected: category.preselected,
            minimumAge: minimumAge,
            useAccessTime: spec.useAccessTime ?? false,
            describe: { lastUsed, now in
                let age = lastUsed.map { Age.describe(from: $0, to: now) } ?? "a while"
                let reason = template
                    .replacingOccurrences(of: "{age}", with: age)
                    .replacingOccurrences(of: "{name}", with: name)
                return note.map { reason + ". " + $0 } ?? reason
            }
        )
    }

    private func label(for entry: Entry) -> String {
        switch spec.label {
        case "vscodeWorkspace":
            return Self.workspaceFolder(of: entry.path, home: options.home) ?? entry.name
        case "huggingFaceRepo":
            let folder = Paths.lastComponent(of: entry.path)
            let repo = folder.drop { $0 != "-" }.dropFirst(2)
            return repo.isEmpty ? folder : repo.replacingOccurrences(of: "--", with: "/")
        default:
            return entry.name
        }
    }

    /// The project folder a VS Code-style workspace storage entry belongs to,
    /// e.g. "~/code/app", from its `workspace.json`.
    static func workspaceFolder(of storage: String, home: String) -> String? {
        let file = Paths.join(storage, "workspace.json")
        guard let status = FileSystem.status(atPath: file), status.isRegularFile, status.logicalSize < 64_000,
              let data = FileManager.default.contents(atPath: file),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let uri = (object["folder"] ?? object["workspace"]) as? String,
              let url = URL(string: uri), url.isFileURL
        else { return nil }
        let path = url.path
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    private func isEnabled(_ folder: FolderContentsSpec.Folder) -> Bool {
        switch folder.optIn {
        case nil: return true
        case "libraryCaches": return options.includeLibraryCaches
        default: return false
        }
    }
}
