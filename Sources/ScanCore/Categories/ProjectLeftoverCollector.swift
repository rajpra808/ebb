import Foundation

/// Categories 5, 6 and 7: folders like `node_modules` and `.venv` inside
/// projects that no activity signal considers active.
struct ProjectLeftoverCollector: Sendable {
    let definitions: [CategoryDefinition]
    let git: GitClient

    func collect(from assessments: [ProjectAssessment]) async -> Findings {
        let categories = Dictionary(uniqueKeysWithValues: definitions.map { ($0.category.id, $0.category) })
        var findings = Findings()

        for assessment in assessments where !assessment.isActive {
            guard let survey = assessment.survey else { continue }
            let leftovers = survey.leftovers.filter { $0.isReported && categories[$0.categoryID] != nil }
            if leftovers.isEmpty { continue }

            let root = assessment.project.root
            let tracked = await trackedLeftovers(leftovers, in: root)
            for leftover in leftovers {
                guard let category = categories[leftover.categoryID] else { continue }
                let relative = Paths.relative(leftover.path, to: root)

                switch tracked {
                case .some(let tracked) where tracked.contains(relative):
                    findings.skipped.append(SkippedItem(
                        path: leftover.path, categoryID: category.id,
                        reason: SkipReason(.trackedByGit, "contains files tracked by git")
                    ))
                    continue
                case .none where leftover.confirmUntracked:
                    findings.skipped.append(SkippedItem(
                        path: leftover.path, categoryID: category.id,
                        reason: SkipReason(.unverified, "couldn't confirm with git that it's build output")
                    ))
                    continue
                default:
                    break
                }

                let lastActivity = assessment.lastActivity
                findings.candidates.append(Candidate(
                    path: leftover.path,
                    categoryID: category.id,
                    comesBack: category.comesBack,
                    preselected: category.preselected,
                    projectPath: root,
                    packageManaged: true,
                    describe: { _, now in
                        guard let lastActivity else { return "Project shows no activity" }
                        return "Project inactive \(Age.describe(from: lastActivity, to: now))"
                    }
                ))
            }
        }
        return findings
    }

    /// Leftovers (relative paths) holding tracked files. `[]` for projects
    /// outside git, `nil` when git couldn't answer.
    private func trackedLeftovers(_ leftovers: [Leftover], in root: String) async -> Set<String>? {
        guard GitActivity.gitDirectory(of: root) != nil else { return [] }
        let relative = leftovers.map { Paths.relative($0.path, to: root) }
        return await git.pathsContainingTrackedFiles(in: root, candidates: relative)
    }
}
