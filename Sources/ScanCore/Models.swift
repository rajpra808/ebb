import Foundation

// The value types a scan produces. They're `Codable` because `ebb scan --json`
// prints them and the app will store them; field names are part of the
// public JSON format, so rename with care.

/// Whether something comes back after it's cleared, and how.
public enum ComesBack: Equatable, Sendable {
    /// Recreated by a command or by normal use, e.g. `npm install`.
    case yes(howTo: String)
    /// Only by downloading it again.
    case redownload
    /// Gone for good.
    case no
    /// The question doesn't apply (info-only categories).
    case notApplicable

    public var label: String {
        switch self {
        case .yes: return "yes"
        case .redownload: return "re-download"
        case .no: return "no"
        case .notApplicable: return "n/a"
        }
    }
}

extension ComesBack: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, howTo
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "yes": self = .yes(howTo: try container.decode(String.self, forKey: .howTo))
        case "redownload": self = .redownload
        case "no": self = .no
        case "notApplicable": self = .notApplicable
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: container, debugDescription: "Unknown comesBack kind '\(other)'"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .yes(let howTo):
            try container.encode("yes", forKey: .kind)
            try container.encode(howTo, forKey: .howTo)
        case .redownload: try container.encode("redownload", forKey: .kind)
        case .no: try container.encode("no", forKey: .kind)
        case .notApplicable: try container.encode("notApplicable", forKey: .kind)
        }
    }
}

/// A category as presented to the user. Built from `categories.json`.
public struct Category: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    /// The number in the spec's category table (§3), for cross-reference.
    public let number: Int
    public let title: String
    public let summary: String
    public let comesBack: ComesBack
    /// The default rule, in words, e.g. "Project inactive".
    public let ruleDescription: String
    public let preselected: Bool
}

/// One thing Ebb found that's safe to clear.
public struct Item: Codable, Equatable, Sendable {
    public let path: String
    public let categoryID: String
    /// Bytes that clearing this item gives back. Hard-linked data is counted
    /// once per scan, and blocks shared with files elsewhere are left out.
    public let allocatedBytes: Int64
    /// Bytes on disk that are shared with files outside this item (hard links
    /// or APFS clones). Clearing the item doesn't free them.
    public let sharedBytes: Int64
    /// True when `allocatedBytes` is a best estimate rather than exact.
    public let isEstimated: Bool
    public let fileCount: Int
    /// Newest modification time of anything inside.
    public let lastUsed: Date?
    public let comesBack: ComesBack
    /// Why it's safe, in one sentence, e.g. "Project inactive 41 days".
    public let reason: String
    public let preselected: Bool
    /// The project this item belongs to, for project leftovers.
    public let projectPath: String?
    /// The tool behind it, for caches, e.g. "npm".
    public let source: String?
    /// The custom rule that suggested this item, if any.
    public let ruleID: String?
    /// When set, the item is cleared by running this command (e.g.
    /// `pnpm store prune`) rather than by moving the path to Trash.
    public let clearCommand: String?
    /// The contents were written by a package manager and come back on
    /// reinstall, so protected names inside (a package's own `.git`) don't
    /// block it. Needed to check the item again before clearing.
    public let packageManaged: Bool

    /// Moving the path to Trash is how this item is cleared.
    public var isTrashable: Bool { clearCommand == nil && path.hasPrefix("/") }
}

/// Something that looked like a candidate but was deliberately left out.
public struct SkippedItem: Codable, Equatable, Sendable {
    public let path: String
    public let categoryID: String?
    public let reason: SkipReason
}

public struct SkipReason: Codable, Equatable, Sendable {
    public enum Code: String, Codable, Sendable {
        case activeProject
        case protected
        case modifiedRecently
        case openByProcess
        case trackedByGit
        case unverified
        case notOwned
        case unreadable
        case ruleTimedOut
    }

    public let code: Code
    /// A short human explanation, e.g. "modified 3 hours ago".
    public let detail: String

    public init(_ code: Code, _ detail: String) {
        self.code = code
        self.detail = detail
    }
}

/// Whether an item from an earlier scan is still safe to clear.
public enum RecheckResult: Equatable, Sendable {
    case safe(allocatedBytes: Int64)
    case unsafe(SkipReason)
}

/// A project Ebb considers active, and what made it so.
public struct ActiveProject: Codable, Equatable, Sendable {
    public let path: String
    public let markers: [String]
    public let signals: [ActivityEvidence]
}

/// One reason a project counts as active.
public struct ActivityEvidence: Codable, Equatable, Sendable {
    /// The `ActivitySignal.id` that produced this, e.g. "git".
    public let signal: String
    /// What was seen, e.g. "last commit 2 days ago".
    public let detail: String
    public let date: Date?

    public init(signal: String, detail: String, date: Date?) {
        self.signal = signal
        self.detail = detail
        self.date = date
    }
}

public struct CategoryTotal: Codable, Equatable, Sendable {
    public let categoryID: String
    public let title: String
    public let allocatedBytes: Int64
    public let itemCount: Int
    public let isEstimated: Bool
}

public struct ScanTotals: Codable, Equatable, Sendable {
    /// Sum of pre-selected items: the "safe to clear" number.
    public let safeToClearBytes: Int64
    /// Sum of items that are suggested but never pre-selected.
    public let worthALookBytes: Int64
    public let itemCount: Int
    public let byCategory: [CategoryTotal]
}

public struct ScanResult: Codable, Equatable, Sendable {
    /// Bumped when the JSON format changes in a breaking way.
    public static let formatVersion = 1

    public let formatVersion: Int
    public let startedAt: Date
    public let durationSeconds: Double
    public let roots: [String]
    public let activeDays: Int
    public let categories: [Category]
    public let items: [Item]
    public let skipped: [SkippedItem]
    public let activeProjects: [ActiveProject]
    public let totals: ScanTotals
    /// Problems that didn't stop the scan, e.g. an invalid custom rule.
    public var warnings: [String]
}
