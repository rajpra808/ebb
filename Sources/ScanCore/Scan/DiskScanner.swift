import Foundation

/// Runs a read-only scan: find projects, decide which are active, collect
/// candidates from every category and rule, check each one, measure, and
/// add it all up.
///
/// Nothing here writes to disk. The only processes started are `lsof` and
/// `git ls-files`.
public struct DiskScanner: Sendable {
    public let catalog: CategoryCatalog
    public let options: ScanOptions
    public let rules: [Rule]
    /// Signals that can mark a project active (spec §4, checks 1 to 5).
    /// Pinned projects will be one more.
    public var signals: [any ActivitySignal] = [
        GitActivitySignal(),
        RecentEditSignal(),
        ClaudeCodeSessionSignal(),
        CodexSessionSignal(),
        RunningProcessSignal(),
        EditorRecentsSignal(),
    ]
    public var git: GitClient?
    /// Called as the scan moves along, from any thread, at most about ten
    /// times a second. Keep it quick.
    public var onProgress: (@Sendable (ScanProgress) -> Void)?

    public init(catalog: CategoryCatalog, options: ScanOptions, rules: [Rule] = []) {
        self.catalog = catalog
        self.options = options
        self.rules = rules
    }

    // MARK: - Scan

    public func scan() async -> ScanResult {
        let started = Date()
        let options = options.canonicalized()
        let progress = onProgress.map(ProgressReporter.init)
        var warnings: [String] = []

        async let openFilesSnapshot = options.checkOpenFiles ? OpenFiles.snapshot() : OpenFiles.unavailable
        let preset = self.git
        let git = await BlockingIO.run { preset ?? GitClient.locate() }
        if !git.isAvailable {
            warnings.append("git isn't available; generic folders like dist/ and build/ are left alone")
        }
        let compiled = CompiledRule.compile(rules, options: options)
        warnings += compiled.warnings

        let projects = await assessProjects(options: options, progress: progress, warnings: &warnings)
        let active = ProjectIndex(roots: projects.filter(\.isActive).map(\.project.root))

        var findings = await collect(projects: projects, active: active, rules: compiled.rules,
                                     git: git, options: options, progress: progress)
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
        progress?.begin(.measuring(checked: 0, total: candidates.count, current: nil))
        let verdicts = await candidates.concurrentMap(maxConcurrency: options.maxConcurrency) { candidate in
            let verdict = await BlockingIO.run { gate.check(candidate) }
            progress?.measured(candidate.path, of: candidates.count)
            return verdict
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
        progress?.begin(.finished)
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

    /// Checks items from an earlier scan again, right before they're cleared.
    ///
    /// Time passes between a scan and a click: a project may have become
    /// active, a file may be open, something may have changed. Each item
    /// goes through the same safety gate as in a scan, with fresh open files
    /// and a fresh look at the project it sits in. The item's category age
    /// rule isn't re-applied; the 24-hour rule is.
    public func recheck(_ items: [Item]) async -> [RecheckResult] {
        let options = options.canonicalized()
        async let openFilesSnapshot = options.checkOpenFiles ? OpenFiles.snapshot() : OpenFiles.unavailable
        let compiled = CompiledRule.compile(rules, options: options).rules

        let home = options.home
        let projects = await BlockingIO.run {
            Dictionary(items.compactMap { item in
                ProjectDiscovery.enclosingProject(of: item.path, below: home).map { (item.path, $0) }
            }, uniquingKeysWith: { first, _ in first })
        }
        let assessor = ProjectAssessor(
            signals: signals, leftoverRules: leftoverRules, home: options.home, now: options.now,
            activeSince: options.activeSince, maxConcurrency: options.maxConcurrency
        )
        let unique = Dictionary(projects.values.map { ($0.root, $0) }, uniquingKeysWith: { first, _ in first })
        let assessed = await assessor.assess(unique.values.sorted { $0.root < $1.root })
        let active = ProjectIndex(roots: assessed.filter(\.isActive).map(\.project.root))

        let gate = SafetyGate(
            neverTouch: NeverTouchList(home: options.home),
            neverTouchRules: compiled.filter { $0.rule.action == .neverTouch },
            activeProjects: active,
            openFiles: await openFilesSnapshot,
            userID: getuid(),
            now: options.now,
            recentlyChangedSince: options.recentlyChangedSince
        )
        return await items.concurrentMap(maxConcurrency: options.maxConcurrency) { item in
            guard item.isTrashable else {
                return .unsafe(SkipReason(.unverified, "cleared with a command, not by moving to Trash"))
            }
            let candidate = Candidate(
                path: item.path, categoryID: item.categoryID, comesBack: item.comesBack,
                preselected: item.preselected, packageManaged: item.packageManaged, describe: { _, _ in item.reason }
            )
            switch await BlockingIO.run({ gate.check(candidate) }) {
            case .accepted(let measurement):
                return .safe(allocatedBytes: measurement.privateBytes)
            case .skipped(let reason):
                return .unsafe(reason)
            case .tooRecent:
                return .safe(allocatedBytes: item.allocatedBytes)
            }
        }
    }

    /// Only the project half of a scan, for `ebb active`.
    public func activeProjects() async -> (projects: [ActiveProject], inactiveCount: Int, warnings: [String]) {
        let options = options.canonicalized()
        let progress = onProgress.map(ProgressReporter.init)
        var warnings: [String] = []
        let assessed = await assessProjects(options: options, progress: progress, warnings: &warnings)
        progress?.begin(.finished)
        return (Self.activeProjects(from: assessed), assessed.filter { !$0.isActive }.count, warnings)
    }

    // MARK: - Steps

    private func assessProjects(
        options: ScanOptions,
        progress: ProgressReporter?,
        warnings: inout [String]
    ) async -> [ProjectAssessment] {
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

        progress?.begin(.findingProjects(foldersSearched: 0, projectsFound: 0))
        let discovery = ProjectDiscovery(
            excluded: PathSet(discoveryExclusions(options: options)),
            allowOtherVolumes: options.includeOtherVolumes,
            maxConcurrency: options.maxConcurrency,
            progress: progress
        )
        let projects = await discovery.projects(under: roots)

        let assessor = ProjectAssessor(
            signals: signals,
            leftoverRules: leftoverRules,
            home: options.home,
            now: options.now,
            activeSince: options.activeSince,
            maxConcurrency: options.maxConcurrency,
            progress: progress
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
        for case .knownPaths(let paths) in catalog.definitions.flatMap(\.collectors) {
            excluded += paths.map { options.expand($0.path) }
        }
        return excluded
    }

    private var leftoverRules: [LeftoverRule] {
        catalog.definitions.flatMap { definition -> [LeftoverRule] in
            definition.collectors.flatMap { collector -> [LeftoverRule] in
                guard case .projectLeftovers(let patterns) = collector else { return [] }
                return patterns.map {
                    LeftoverRule(categoryID: definition.category.id, isReported: definition.isEnabled, pattern: $0)
                }
            }
        }
    }

    private func collect(
        projects: [ProjectAssessment],
        active: ProjectIndex,
        rules: [CompiledRule],
        git: GitClient,
        options: ScanOptions,
        progress: ProgressReporter?
    ) async -> Findings {
        let leftoverCategories = catalog.enabled.filter { definition in
            definition.collectors.contains {
                if case .projectLeftovers = $0 { return true }
                return false
            }
        }
        progress?.begin(.collecting("project leftovers"))
        // Leftovers first: they're judged per project, with one git call each.
        var findings = await ProjectLeftoverCollector(definitions: leftoverCategories, git: git)
            .collect(from: projects)

        // After that, catalog order decides which category claims a path
        // when two overlap.
        for definition in catalog.enabled {
            for collector in definition.collectors {
                findings.merge(await collect(collector, for: definition.category, projects: projects,
                                             options: options, progress: progress))
            }
        }

        let suggestRules = rules.filter { $0.rule.action == .suggest }.count
        if suggestRules > 0 { progress?.begin(.applyingRules(ruleCount: suggestRules)) }
        findings.merge(await RuleCollector(
            rules: rules,
            neverTouch: NeverTouchList(home: options.home),
            activeProjects: active,
            options: options
        ).collect())
        return findings
    }

    private func collect(
        _ collector: CollectorSpec,
        for category: Category,
        projects: [ProjectAssessment],
        options: ScanOptions,
        progress: ProgressReporter?
    ) async -> Findings {
        switch collector {
        case .projectLeftovers:
            return Findings()
        case .knownPaths(let paths):
            progress?.begin(.collecting(category.title.lowercased()))
            return KnownPathCollector(category: category, paths: paths, options: options).collect()
        case .folderContents(let spec):
            progress?.begin(.collecting(category.title.lowercased()))
            return await BlockingIO.run {
                FolderContentsCollector(category: category, spec: spec, options: options).collect()
            }
        case .claudeHistory(let spec):
            progress?.begin(.collecting(category.title.lowercased()))
            return await BlockingIO.run {
                ClaudeHistory.collector(category: category, spec: spec, options: options).collect()
            }
        case .ollamaModels(let path, let days):
            progress?.begin(.collecting("Ollama models"))
            let age = Double(days) * 86_400
            return await BlockingIO.run {
                OllamaCollector(category: category, modelsFolder: path, options: options, minimumAge: age).collect()
            }
        case .xcodeDerivedData(let path):
            progress?.begin(.collecting("Xcode DerivedData"))
            return await BlockingIO.run {
                DerivedDataCollector(category: category, folder: path, options: options, projects: projects)
                    .collect()
            }
        case .unavailableSimulators:
            guard options.queryTools else { return Findings() }
            progress?.begin(.collecting("simulators"))
            return await UnavailableSimulatorCollector(category: category).collect()
        case .docker:
            guard options.queryTools else { return Findings() }
            progress?.begin(.collecting("Docker"))
            return await DockerCollector(category: category, now: options.now,
                                         recentlyChangedSince: options.recentlyChangedSince).collect()
        case .duplicates(let spec):
            progress?.begin(.collecting("duplicate files"))
            return await DuplicateCollector(category: category, spec: spec, options: options).collect()
        }
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
            let lastUsed = measurement.lastUsed(countingReads: candidate.useAccessTime)
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
                clearCommand: candidate.clearCommand,
                packageManaged: candidate.packageManaged
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
