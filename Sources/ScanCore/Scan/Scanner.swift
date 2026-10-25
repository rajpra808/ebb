import Foundation

/// Runs a read-only scan: find projects, decide which are active, collect
/// candidates from every category and rule, check each one, measure, and
/// add it all up.
///
/// Nothing here writes to disk. The only processes started are `lsof` and
/// `git ls-files`.
public struct Scanner: Sendable {
    public let catalog: CategoryCatalog
    public let options: ScanOptions
    public let rules: [Rule]
    /// Signals that can mark a project active. Add new ones here.
    public var signals: [any ActivitySignal] = [GitActivitySignal(), RecentEditSignal()]
    public var git: GitClient?

    public init(catalog: CategoryCatalog, options: ScanOptions, rules: [Rule] = []) {
        self.catalog = catalog
        self.options = options
        self.rules = rules
    }

    // MARK: - Scan

    public func scan() async -> ScanResult {
        let started = Date()
        let options = options.canonicalized()
        var warnings: [String] = []

        async let openFilesSnapshot = options.checkOpenFiles ? OpenFiles.snapshot() : OpenFiles.unavailable
        let preset = self.git
        let git = await BlockingIO.run { preset ?? GitClient.locate() }
        if !git.isAvailable {
            warnings.append("git isn't available; generic folders like dist/ and build/ are left alone")
        }
        let compiled = CompiledRule.compile(rules, options: options)
        warnings += compiled.warnings

        let projects = await assessProjects(options: options, warnings: &warnings)
        let active = ProjectIndex(roots: projects.filter(\.isActive).map(\.project.root))

        var findings = await collect(projects: projects, active: active, rules: compiled.rules,
                                     git: git, options: options)
        warnings += findings.warnings

        let openFiles = await openFilesSnapshot
        if options.checkOpenFiles && !openFiles.isAvailable {
            warnings.append("lsof couldn't run, so open files weren't checked")
        }
        let gate = SafetyGate(
            neverTouch: NeverTouchList(home: options.home),
            neverTouchRules: compiled.rules.filter { $0.rule.action == .neverTouch },
            activeProjects: active,
            openFiles: openFiles,
            userID: getuid(),
            now: options.now,
            recentlyChangedSince: options.recentlyChangedSince
        )
        let candidates = Self.removingOverlaps(findings.candidates)
        let verdicts = await candidates.concurrentMap(maxConcurrency: options.maxConcurrency) { candidate in
            await BlockingIO.run { gate.check(candidate) }
        }

        var accepted: [(Candidate, ItemMeasurement)] = []
        for (candidate, verdict) in zip(candidates, verdicts) {
            switch verdict {
            case .accepted(let measurement):
                accepted.append((candidate, measurement))
            case .skipped(let reason):
                findings.skipped.append(SkippedItem(
                    path: candidate.path, categoryID: candidate.categoryID, reason: reason
                ))
            case .tooRecent:
                break
            }
        }

        let items = Self.items(from: accepted, now: options.now)
        let categories = catalog.enabled.map(\.category)
            + (compiled.rules.contains { $0.rule.action == .suggest } ? [RuleCollector.category] : [])
        return ScanResult(
            formatVersion: ScanResult.formatVersion,
            startedAt: started,
            durationSeconds: Date().timeIntervalSince(started),
            roots: options.projectRoots,
            activeDays: options.activeDays,
            categories: categories,
            items: items,
            skipped: findings.skipped.sorted { $0.path < $1.path },
            activeProjects: Self.activeProjects(from: projects),
            totals: Self.totals(of: items, categories: categories),
            warnings: warnings
        )
    }

    /// Only the project half of a scan, for `ebb active`.
    public func activeProjects() async -> (projects: [ActiveProject], inactiveCount: Int, warnings: [String]) {
        let options = options.canonicalized()
        var warnings: [String] = []
        let assessed = await assessProjects(options: options, warnings: &warnings)
        return (Self.activeProjects(from: assessed), assessed.filter { !$0.isActive }.count, warnings)
    }

    // MARK: - Steps

    private func assessProjects(options: ScanOptions, warnings: inout [String]) async -> [ProjectAssessment] {
        let homeDevice = FileSystem.status(atPath: options.home)?.device
        let neverTouch = NeverTouchList(home: options.home)
        var roots: [String] = []
        for root in options.projectRoots {
            guard let status = FileSystem.status(atPath: root), status.isDirectory else {
                warnings.append("\(root) doesn't exist; skipped")
                continue
            }
            if let entry = neverTouch.protection(for: root) {
                warnings.append("\(root) is protected (\(entry.why)); skipped")
                continue
            }
            if !options.includeOtherVolumes, status.device != homeDevice {
                warnings.append("\(root) is on another disk; skipped (pass --all-volumes to include it)")
                continue
            }
            roots.append(root)
        }

        let discovery = ProjectDiscovery(
            excluded: PathSet(discoveryExclusions(options: options)),
            allowOtherVolumes: options.includeOtherVolumes,
            maxConcurrency: options.maxConcurrency
        )
        let projects = await discovery.projects(under: roots)

        let assessor = ProjectAssessor(
            signals: signals,
            leftoverRules: leftoverRules,
            now: options.now,
            activeSince: options.activeSince,
            maxConcurrency: options.maxConcurrency
        )
        return await assessor.assess(projects)
    }

    /// Places that are never searched for projects: they hold caches and
    /// app data, and every package inside would look like a project.
    private func discoveryExclusions(options: ScanOptions) -> [String] {
        var excluded = options.excludedFolders + [
            Paths.join(options.home, "Library"),
            Paths.join(options.home, ".Trash"),
            options.temporaryDirectory,
        ]
        for definition in catalog.definitions {
            if case .knownPaths(let paths) = definition.collector {
                excluded += paths.map { options.expand($0.path) }
            }
        }
        return excluded
    }

    private var leftoverRules: [LeftoverRule] {
        catalog.definitions.flatMap { definition -> [LeftoverRule] in
            guard case .projectLeftovers(let patterns) = definition.collector else { return [] }
            return patterns.map {
                LeftoverRule(categoryID: definition.category.id, isReported: definition.isEnabled, pattern: $0)
            }
        }
    }

    private func collect(
        projects: [ProjectAssessment],
        active: ProjectIndex,
        rules: [CompiledRule],
        git: GitClient,
        options: ScanOptions
    ) async -> Findings {
        var findings = Findings()

        let leftoverCategories = catalog.enabled.filter {
            if case .projectLeftovers = $0.collector { return true }
            return false
        }
        // Catalog order decides which category claims an overlapping path.
        for definition in catalog.enabled {
            switch definition.collector {
            case .projectLeftovers:
                // Collected together below, in one git call per project.
                continue
            case .knownPaths(let paths):
                findings.merge(KnownPathCollector(category: definition.category, paths: paths,
                                                  options: options).collect())
            case .folderContents(let spec):
                findings.merge(FolderContentsCollector(category: definition.category, spec: spec,
                                                       options: options).collect())
            }
        }
        var ordered = await ProjectLeftoverCollector(definitions: leftoverCategories, git: git)
            .collect(from: projects)
        ordered.merge(findings)

        ordered.merge(await RuleCollector(
            rules: rules,
            neverTouch: NeverTouchList(home: options.home),
            activeProjects: active,
            options: options
        ).collect())
        return ordered
    }

    // MARK: - Assembly

    /// Keeps the first candidate for any path; later ones that are the same
    /// path, inside it, or contain it are dropped, so nothing is counted
    /// twice.
    static func removingOverlaps(_ candidates: [Candidate]) -> [Candidate] {
        var claimed = PathSet([])
        var claimedAncestors = Set<String>()
        var result: [Candidate] = []
        for candidate in candidates {
            let path = candidate.path
            if claimed.ancestor(of: path) != nil || claimedAncestors.contains(path) { continue }
            claimed.insert(path)
            var parent = Paths.parent(of: path)
            while parent != "/" && claimedAncestors.insert(parent).inserted {
                parent = Paths.parent(of: parent)
            }
            result.append(candidate)
        }
        return result
    }

    static func items(from accepted: [(Candidate, ItemMeasurement)], now: Date) -> [Item] {
        let shares = HardLinkLedger.reconcile(accepted.map(\.1))
        return zip(accepted, shares).compactMap { pair, share in
            let (candidate, measurement) = pair
            // Frees nothing beyond its empty folders, and nothing else depends
            // on it (e.g. every file is shared with something we aren't
            // clearing): not worth listing.
            let freesFileData = share.allocatedBytes > measurement.folderBytes
            guard freesFileData || share.holdsLinksCountedElsewhere else { return nil }
            let lastUsed = measurement.newestModification
            return Item(
                path: candidate.path,
                categoryID: candidate.categoryID,
                allocatedBytes: share.allocatedBytes,
                sharedBytes: share.sharedBytes,
                isEstimated: candidate.isEstimated || share.sharedBytes > 0,
                fileCount: measurement.fileCount,
                lastUsed: lastUsed,
                comesBack: candidate.comesBack,
                reason: candidate.describe(lastUsed, now),
                preselected: candidate.preselected,
                projectPath: candidate.projectPath,
                source: candidate.source,
                ruleID: candidate.ruleID,
                clearCommand: candidate.clearCommand
            )
        }
    }

    static func activeProjects(from assessments: [ProjectAssessment]) -> [ActiveProject] {
        assessments.filter(\.isActive).map {
            ActiveProject(path: $0.project.root, markers: $0.project.markers, signals: $0.evidence)
        }
    }

    static func totals(of items: [Item], categories: [Category]) -> ScanTotals {
        let byCategory = categories.compactMap { category -> CategoryTotal? in
            let members = items.filter { $0.categoryID == category.id }
            guard !members.isEmpty else { return nil }
            return CategoryTotal(
                categoryID: category.id,
                title: category.title,
                allocatedBytes: members.reduce(0) { $0 + $1.allocatedBytes },
                itemCount: members.count,
                isEstimated: members.contains(where: \.isEstimated)
            )
        }
        return ScanTotals(
            safeToClearBytes: items.filter(\.preselected).reduce(0) { $0 + $1.allocatedBytes },
            worthALookBytes: items.filter { !$0.preselected }.reduce(0) { $0 + $1.allocatedBytes },
            itemCount: items.count,
            byCategory: byCategory
        )
    }
}
