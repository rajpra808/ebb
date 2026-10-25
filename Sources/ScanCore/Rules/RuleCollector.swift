import Foundation

/// Walks the folders of `suggest` rules and collects matching files.
///
/// Each (rule, folder) pair gets a time budget. The walk and the regex both
/// count against it, so neither a huge folder nor a catastrophic pattern can
/// hold up the scan; whatever was found before the deadline is still used.
struct RuleCollector: Sendable {
    /// More matches than this from one rule is almost certainly a pattern
    /// that's too broad. The rest are dropped with a warning.
    static let matchLimit = 10_000

    static let category = Category(
        id: "custom-rules",
        number: 0,
        title: "Custom rules",
        summary: "Matches from your own rules. Never pre-selected.",
        comesBack: .no,
        ruleDescription: "Your rules",
        preselected: false
    )

    let rules: [CompiledRule]
    let neverTouch: NeverTouchList
    let activeProjects: ProjectIndex
    let options: ScanOptions

    func collect() async -> Findings {
        let jobs = rules.filter { $0.rule.action == .suggest }
            .flatMap { rule in rule.roots.map { (rule, $0) } }
        let results = await jobs.concurrentMap(maxConcurrency: options.maxConcurrency) { rule, root in
            await BlockingIO.run { collect(rule, in: root) }
        }
        return results.reduce(into: Findings()) { $0.merge($1) }
    }

    private func collect(_ compiled: CompiledRule, in root: String) -> Findings {
        var findings = Findings()
        let rule = compiled.rule
        guard let rootStatus = FileSystem.status(atPath: root), rootStatus.isDirectory else {
            findings.warnings.append("Rule '\(rule.name)': folder \(root) doesn't exist")
            return findings
        }
        if neverTouch.protection(for: root) != nil { return findings }
        if let project = activeProjects.project(containing: root) {
            findings.skipped.append(SkippedItem(
                path: root, categoryID: RuleCollector.category.id,
                reason: SkipReason(.activeProject, "in active project \(Paths.lastComponent(of: project))")
            ))
            return findings
        }
        if !options.includeOtherVolumes,
           let home = FileSystem.status(atPath: options.home), home.device != rootStatus.device {
            findings.warnings.append("Rule '\(rule.name)': \(root) is on another disk; skipped")
            return findings
        }

        let deadline = Date().addingTimeInterval(options.ruleTimeLimit)
        let minimumBytes = rule.largerThanMB.map { Int64($0 * 1_000_000) }
        let modifiedBefore = rule.olderThanDays.map { options.now.addingTimeInterval(-Double($0) * 86_400) }
        var stack = [root]

        walk: while let folder = stack.popLast() {
            if Date() > deadline {
                findings.timedOut(rule, in: root, limit: options.ruleTimeLimit)
                break
            }
            guard let entries = try? FileSystem.entries(ofDirectory: folder) else { continue }

            for entry in entries {
                // Protected names (.git, .env, CLAUDE.md...) are never
                // candidates and protected folders aren't entered. The gate
                // re-checks every match against the full list.
                if neverTouch.protection(forName: entry.name) != nil { continue }
                let path = Paths.join(folder, entry.name)
                guard let status = FileSystem.status(atPath: path) else { continue }

                if status.isDirectory {
                    guard status.device == rootStatus.device, !status.isDataless,
                          !activeProjects.contains(root: path)
                    else { continue }
                    stack.append(path)
                    continue
                }
                guard status.isRegularFile else { continue }
                if let minimumBytes, status.allocatedSize < minimumBytes { continue }
                if let modifiedBefore, status.modificationDate > modifiedBefore { continue }

                switch compiled.matches(name: entry.name, path: path, deadline: deadline) {
                case .noMatch:
                    continue
                case .timedOut:
                    findings.timedOut(rule, in: root, limit: options.ruleTimeLimit)
                    break walk
                case .match:
                    if findings.candidates.count >= Self.matchLimit {
                        findings.warnings.append(
                            "Rule '\(rule.name)' matched more than \(Self.matchLimit) files in \(root); "
                                + "only the first \(Self.matchLimit) are listed"
                        )
                        break walk
                    }
                    findings.candidates.append(candidate(for: path, rule: rule))
                }
            }
        }
        return findings
    }

    private func candidate(for path: String, rule: Rule) -> Candidate {
        let name = rule.name
        return Candidate(
            path: path,
            categoryID: Self.category.id,
            comesBack: rule.comesBack,
            preselected: false,
            ruleID: rule.id,
            minimumAge: rule.olderThanDays.map { Double($0) * 86_400 },
            describe: { _, _ in "Matches your rule '\(name)'" }
        )
    }
}

private extension Findings {
    mutating func timedOut(_ rule: Rule, in root: String, limit: TimeInterval) {
        skipped.append(SkippedItem(
            path: root, categoryID: RuleCollector.category.id,
            reason: SkipReason(.ruleTimedOut, "rule '\(rule.name)' hit its \(Int(limit))s limit here")
        ))
        warnings.append("Rule '\(rule.name)' stopped after \(Int(limit))s in \(root); results are partial")
    }
}
