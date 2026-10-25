import Foundation

/// Category 2: old Claude Code chats.
///
/// Claude Code deletes chats itself after `cleanupPeriodDays` (30 by
/// default). Ebb doesn't fight that setting: it never suggests a chat
/// younger than it, so raising the setting to keep history also keeps Ebb
/// away from it.
enum ClaudeHistory {
    static let defaultCleanupPeriodDays = 30

    static func collector(category: Category, spec: FolderContentsSpec, options: ScanOptions)
        -> FolderContentsCollector {
        let period = cleanupPeriodDays(home: options.home)
        var collector = FolderContentsCollector(category: category, spec: spec, options: options)
        collector.olderThanDays = max(spec.olderThanDays, period ?? defaultCleanupPeriodDays)
        collector.reasonNote = period.map { "Claude Code is set to keep chats \($0) days" }
            ?? "Claude Code keeps chats 30 days by default"
        return collector
    }

    /// `cleanupPeriodDays` from `~/.claude/settings.json`, if set. The file
    /// is only read, never reported.
    static func cleanupPeriodDays(home: String) -> Int? {
        let path = Paths.join(home, ".claude/settings.json")
        guard let status = FileSystem.status(atPath: path), status.isRegularFile, status.logicalSize < 1_000_000,
              let data = FileManager.default.contents(atPath: path),
              let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return (settings["cleanupPeriodDays"] as? NSNumber)?.intValue
    }
}
