import Foundation

/// The checks every candidate passes before it can be reported, whichever
/// category or rule produced it. Order matters only for cost: cheap path
/// checks first, measuring last.
struct SafetyGate: Sendable {
    enum Verdict: Sendable {
        case accepted(ItemMeasurement)
        case skipped(SkipReason)
        /// Not old enough for its category. Not interesting enough to list.
        case tooRecent
    }

    let neverTouch: NeverTouchList
    let neverTouchRules: [CompiledRule]
    let activeProjects: ProjectIndex
    let openFiles: OpenFiles
    let userID: UInt32
    let now: Date
    let recentlyChangedSince: Date
    var alwaysKeep = ProjectIndex(roots: [])

    /// How long a never-touch rule may spend on one path. If it runs out the
    /// path counts as protected.
    static let neverTouchMatchLimit: TimeInterval = 0.25

    func check(_ candidate: Candidate) -> Verdict {
        let path = candidate.path
        // Docker's items aren't files; there's no path to protect or walk.
        if let precomputed = candidate.precomputed, precomputed.isVirtual {
            return judgeAge(ItemMeasurement(precomputed), of: candidate)
        }

        if let entry = neverTouch.protection(for: path) {
            return .skipped(SkipReason(.protected, "protected: \(entry.why)"))
        }
        let rules = neverTouchRules.filter { $0.overlaps(path) }
        if let rule = rules.first(where: { protects($0, path) }) {
            return .skipped(SkipReason(.protected, "matches your never-touch rule '\(rule.rule.name)'"))
        }
        if let kept = alwaysKeep.project(overlapping: path) {
            let what = kept == path ? "it" : Paths.lastComponent(of: kept)
            return .skipped(SkipReason(.protected, "you chose Always keep for \(what)"))
        }
        // Either inside an active project, or containing one.
        if let project = activeProjects.project(overlapping: path) {
            return .skipped(SkipReason(.activeProject, "in active project \(Paths.lastComponent(of: project))"))
        }
        guard let status = FileSystem.status(atPath: path) else {
            return .skipped(SkipReason(.unreadable, "disappeared during the scan"))
        }
        if status.ownerID != userID {
            return .skipped(SkipReason(.notOwned, "owned by another user"))
        }
        if let open = openFiles.firstOpen(inside: path) {
            let what = open == path ? "it" : Paths.relative(open, to: path)
            return .skipped(SkipReason(.openByProcess, "\(what) is open in a running app"))
        }
        if let precomputed = candidate.precomputed {
            if let open = precomputed.paths.first(where: openFiles.isOpen) {
                return .skipped(SkipReason(.openByProcess, "\(Paths.lastComponent(of: open)) is open in a running app"))
            }
            return judgeAge(ItemMeasurement(precomputed), of: candidate)
        }

        let protectedPaths = neverTouch.pathEntries(within: path)
        let measurer = SizeMeasurer { name, child in
            if !candidate.packageManaged, let entry = neverTouch.protection(forName: name) {
                return entry.why
            }
            if !protectedPaths.isEmpty, let entry = neverTouch.protection(forPath: child, among: protectedPaths) {
                return entry.why
            }
            if let rule = rules.first(where: { protects($0, child) }) {
                return "your never-touch rule '\(rule.rule.name)'"
            }
            return nil
        }
        let measurement: ItemMeasurement
        switch measurer.measure(path) {
        case .measured(let result):
            measurement = result
        case .containsProtected(let inner, let why):
            return .skipped(SkipReason(.protected, "contains \(Paths.relative(inner, to: path)) (\(why))"))
        case .incomplete(_, let why):
            return .skipped(SkipReason(.unreadable, why))
        }

        return judgeAge(measurement, of: candidate)
    }

    private func judgeAge(_ measurement: ItemMeasurement, of candidate: Candidate) -> Verdict {
        if let changed = measurement.newestModification, changed > recentlyChangedSince {
            return .skipped(SkipReason(.modifiedRecently, "changed \(Age.describe(from: changed, to: now)) ago"))
        }
        if let minimumAge = candidate.minimumAge,
           let used = measurement.lastUsed(countingReads: candidate.useAccessTime),
           used > now.addingTimeInterval(-minimumAge) {
            return .tooRecent
        }
        return .accepted(measurement)
    }

    private func protects(_ rule: CompiledRule, _ path: String) -> Bool {
        let deadline = Date().addingTimeInterval(Self.neverTouchMatchLimit)
        // A timeout means "can't tell", and can't tell means protected.
        return rule.protects(path, deadline: deadline) != .noMatch
    }
}
