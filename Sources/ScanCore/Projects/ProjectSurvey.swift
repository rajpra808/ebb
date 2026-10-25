import Foundation

/// A leftover folder pattern, tagged with the category it belongs to.
struct LeftoverRule: Sendable {
    let categoryID: String
    /// Disabled categories still define leftovers: their folders don't count
    /// as edits, but they aren't reported.
    let isReported: Bool
    let pattern: LeftoverPattern
}

/// A leftover folder found inside a project.
public struct Leftover: Sendable, Equatable {
    public let path: String
    public let categoryID: String
    let isReported: Bool
    let confirmUntracked: Bool
}

/// One walk over a project: the newest edit outside leftover folders, and
/// the leftover folders themselves.
public struct ProjectSurvey: Sendable {
    public struct Edit: Sendable, Equatable {
        public let path: String
        public let date: Date
    }

    public let newestEdit: Edit?
    /// Only complete when the walk didn't stop early at a recent edit.
    public let leftovers: [Leftover]
    /// True if the walk stopped at the first edit newer than its cutoff.
    public let stoppedEarly: Bool

    /// Walks `root` without following symlinks or leaving its disk.
    ///
    /// - Parameter stopAtEditsAfter: stop as soon as a file changed after
    ///   this date is seen; the project is active and nothing else matters.
    static func take(
        of root: String,
        rules: [LeftoverRule],
        stopAtEditsAfter cutoff: Date
    ) -> ProjectSurvey {
        guard let rootStatus = FileSystem.status(atPath: root) else {
            return ProjectSurvey(newestEdit: nil, leftovers: [], stoppedEarly: false)
        }
        var rulesByName: [String: [LeftoverRule]] = [:]
        for rule in rules {
            for name in rule.pattern.names { rulesByName[name, default: []].append(rule) }
        }

        var newest: Edit?
        var leftovers: [Leftover] = []
        var stack = [root]

        while let folder = stack.popLast() {
            guard let entries = try? FileSystem.entries(ofDirectory: folder) else { continue }
            let names = Set(entries.map(\.name))

            for entry in entries {
                let path = Paths.join(folder, entry.name)
                // Ignored for activity: git's own data is checked by the git
                // signal, and Finder rewrites .DS_Store when you just look.
                if entry.name == ".git" || entry.name == ".DS_Store" { continue }
                guard let status = FileSystem.status(atPath: path) else { continue }

                if status.isDirectory {
                    if status.device != rootStatus.device || status.isDataless { continue }
                    if let rule = matchingRule(rulesByName[entry.name], folder: path, siblings: names) {
                        leftovers.append(Leftover(
                            path: path, categoryID: rule.categoryID, isReported: rule.isReported,
                            confirmUntracked: rule.pattern.confirmUntracked
                        ))
                        continue
                    }
                    // Never source, even when it doesn't qualify as a leftover.
                    if entry.name == "node_modules" { continue }
                    stack.append(path)
                    continue
                }

                if newest.map({ status.modificationDate > $0.date }) ?? true {
                    newest = Edit(path: path, date: status.modificationDate)
                }
                if status.modificationDate > cutoff {
                    return ProjectSurvey(newestEdit: newest, leftovers: leftovers, stoppedEarly: true)
                }
            }
        }
        return ProjectSurvey(
            newestEdit: newest,
            leftovers: leftovers.sorted { $0.path < $1.path },
            stoppedEarly: false
        )
    }

    private static func matchingRule(
        _ candidates: [LeftoverRule]?, folder: String, siblings: Set<String>
    ) -> LeftoverRule? {
        candidates?.first { rule in
            if let sibling = rule.pattern.siblingFile, !siblings.contains(sibling) { return false }
            if let required = rule.pattern.containsFile {
                guard let status = FileSystem.status(atPath: Paths.join(folder, required)),
                      status.isRegularFile
                else { return false }
            }
            return true
        }
    }
}
