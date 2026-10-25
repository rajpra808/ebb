import Foundation

/// Categories 12 and 14: the direct children of a folder (`$TMPDIR`,
/// `~/Downloads`), filtered by type and age.
struct FolderContentsCollector: Sendable {
    static let quarantineAttribute = "com.apple.quarantine"

    let category: Category
    let spec: FolderContentsSpec
    let options: ScanOptions

    func collect() -> Findings {
        var findings = Findings()
        let extensions = spec.extensions.map { Set($0.map { $0.lowercased() }) }
        let needsDownload = Set((spec.requireDownloadedFor ?? []).map { $0.lowercased() })
        let minimumAge = Double(spec.olderThanDays) * 86_400

        for folder in spec.folders where isEnabled(folder) {
            let base = ScanOptions.canonical(options.expand(folder.path))
            guard let entries = try? FileSystem.entries(ofDirectory: base) else { continue }

            for entry in entries.sorted(by: { $0.name < $1.name }) {
                let name = entry.name
                // Hidden entries belong to whatever made them; skip them.
                if name.hasPrefix(".") { continue }
                if spec.skipNamePrefixes?.contains(where: { name.hasPrefix($0) }) == true { continue }

                let path = Paths.join(base, name)
                guard let status = FileSystem.status(atPath: path) else { continue }
                // Regular files and folders only: no symlinks, sockets or pipes.
                guard status.isRegularFile || (status.isDirectory && spec.filesOnly != true) else { continue }

                let fileExtension = Paths.fileExtension(of: name)
                if let extensions {
                    guard let fileExtension, extensions.contains(fileExtension) else { continue }
                }
                if let fileExtension, needsDownload.contains(fileExtension),
                   !FileSystem.hasExtendedAttribute(Self.quarantineAttribute, atPath: path) {
                    findings.skipped.append(SkippedItem(
                        path: path, categoryID: category.id,
                        reason: SkipReason(.unverified, "not downloaded from the web, may be your own archive")
                    ))
                    continue
                }

                let template = spec.reason ?? "Untouched for {age}"
                findings.candidates.append(Candidate(
                    path: path,
                    categoryID: category.id,
                    comesBack: category.comesBack,
                    preselected: category.preselected,
                    minimumAge: minimumAge,
                    describe: { lastUsed, now in
                        let age = lastUsed.map { Age.describe(from: $0, to: now) } ?? "a while"
                        return template.replacingOccurrences(of: "{age}", with: age)
                    }
                ))
            }
        }
        return findings
    }

    private func isEnabled(_ folder: FolderContentsSpec.Folder) -> Bool {
        switch folder.optIn {
        case nil: return true
        case "libraryCaches": return options.includeLibraryCaches
        default: return false
        }
    }
}
