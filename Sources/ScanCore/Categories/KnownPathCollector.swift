import Foundation

/// Category 8: package manager caches at fixed locations.
struct KnownPathCollector: Sendable {
    let category: Category
    let paths: [KnownPath]
    let options: ScanOptions

    func collect() -> Findings {
        var findings = Findings()
        for known in paths {
            let path = options.expand(known.path)
            // A cache that is a symlink points somewhere we didn't choose to
            // scan; leave it.
            guard let status = FileSystem.status(atPath: path), status.isDirectory else { continue }

            let label = known.label
            let command = known.clearCommand
            findings.candidates.append(Candidate(
                path: path,
                categoryID: category.id,
                comesBack: known.comesBack ?? category.comesBack,
                preselected: category.preselected,
                clearCommand: command,
                isEstimated: known.estimated ?? false,
                packageManaged: true,
                describe: { lastUsed, now in
                    if let command, known.estimated == true {
                        return "\(label): files no project uses; `\(command)` removes them"
                    }
                    guard let lastUsed else { return "\(label) cache" }
                    return "\(label) cache, last written \(Age.describe(from: lastUsed, to: now)) ago"
                }
            ))
        }
        return findings
    }
}
