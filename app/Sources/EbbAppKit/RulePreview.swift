import Foundation
import ScanCore

/// What a rule would match right now, for the rule editor's live preview.
/// Runs the rule through a real read-only scan, so it shows exactly what a
/// scan would suggest, with every built-in protection applied.
public enum RulePreview {
    public struct Match: Equatable, Sendable {
        public let path: String
        public let bytes: Int64
    }

    public struct Result: Equatable, Sendable {
        public var matches: [Match] = []
        public var bytes: Int64 = 0
        /// Matched, but left out by a built-in check.
        public var skipped = 0
        public var isTruncated = false
        public var isRunning = false

        public init() {}
    }

    public static func run(_ rule: Rule, home: String, limit: Int = 200) async -> Result {
        var options = ScanOptions.currentUser()
        options.home = home
        options.ruleTimeLimit = 5
        // Only the rule's folders matter, and never-touch rules have none.
        options.projectRoots = rule.roots.isEmpty ? [home] : rule.roots.map { options.expand($0) }
        let suggest = Rule(id: rule.id, name: rule.name, pattern: rule.pattern, matchOn: rule.matchOn,
                           roots: rule.roots.isEmpty ? ["~"] : rule.roots, olderThanDays: rule.olderThanDays,
                           largerThanMB: rule.largerThanMB, action: .suggest, comesBack: rule.comesBack)
        // An empty catalog: only the rule collects anything.
        let scanner = DiskScanner(catalog: CategoryCatalog(definitions: []), options: options, rules: [suggest])
        let scan = await scanner.scan()

        var result = Result()
        let found = scan.items.filter { $0.ruleID == rule.id }.sorted { $0.allocatedBytes > $1.allocatedBytes }
        result.matches = found.prefix(limit).map { Match(path: $0.path, bytes: $0.allocatedBytes) }
        result.isTruncated = found.count > limit
        result.bytes = found.reduce(0) { $0 + $1.allocatedBytes }
        result.skipped = scan.skipped.filter { $0.categoryID == "custom-rules" }.count
        return result
    }
}
