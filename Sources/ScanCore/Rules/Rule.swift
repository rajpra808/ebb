import Foundation

/// A user-defined rule (see docs/RULES.md).
///
/// `suggest` rules add matches to "Worth a look"; they're never pre-selected
/// and still pass every built-in check. `neverTouch` rules protect matches
/// from every category and every other rule.
public struct Rule: Codable, Equatable, Sendable, Identifiable {
    public enum MatchTarget: String, Codable, Sendable, CaseIterable {
        /// The regex is tested against the file name only.
        case fileName
        /// The regex is tested against the absolute path.
        case fullPath
    }

    public enum Action: String, Codable, Sendable, CaseIterable {
        case suggest
        case neverTouch
    }

    public var id: String
    public var name: String
    /// An `NSRegularExpression` pattern.
    public var pattern: String
    public var matchOn: MatchTarget
    /// Folders the rule applies to. `~` is allowed and kept as typed so an
    /// exported rules file works on another Mac. A `neverTouch` rule with no
    /// folders applies everywhere.
    public var roots: [String]
    public var olderThanDays: Int?
    public var largerThanMB: Double?
    public var action: Action
    public var comesBack: ComesBack

    public init(
        id: String = Rule.makeID(),
        name: String,
        pattern: String,
        matchOn: MatchTarget = .fileName,
        roots: [String],
        olderThanDays: Int? = nil,
        largerThanMB: Double? = nil,
        action: Action = .suggest,
        comesBack: ComesBack = .no
    ) {
        self.id = id
        self.name = name
        self.pattern = pattern
        self.matchOn = matchOn
        self.roots = roots
        self.olderThanDays = olderThanDays
        self.largerThanMB = largerThanMB
        self.action = action
        self.comesBack = comesBack
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, pattern, matchOn, roots, olderThanDays, largerThanMB, action, comesBack
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        pattern = try container.decode(String.self, forKey: .pattern)
        matchOn = try container.decodeIfPresent(MatchTarget.self, forKey: .matchOn) ?? .fileName
        roots = try container.decodeIfPresent([String].self, forKey: .roots) ?? []
        olderThanDays = try container.decodeIfPresent(Int.self, forKey: .olderThanDays)
        largerThanMB = try container.decodeIfPresent(Double.self, forKey: .largerThanMB)
        action = try container.decodeIfPresent(Action.self, forKey: .action) ?? .suggest
        comesBack = try container.decodeIfPresent(ComesBack.self, forKey: .comesBack) ?? .no
    }

    /// A short random id, easy to type in `ebb rule` commands.
    public static func makeID() -> String {
        String(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(8))
    }

    /// Checks the rule can be used, without scanning anything.
    public func validate() throws {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { throw RuleError.emptyName }
        do {
            _ = try NSRegularExpression(pattern: pattern)
        } catch {
            throw RuleError.invalidPattern(pattern)
        }
        if action == .suggest && roots.isEmpty { throw RuleError.noFolders }
        if let days = olderThanDays, days < 0 { throw RuleError.negativeThreshold }
        if let megabytes = largerThanMB, megabytes < 0 { throw RuleError.negativeThreshold }
    }
}

public enum RuleError: Error, Equatable, CustomStringConvertible {
    case emptyName
    case invalidPattern(String)
    case noFolders
    case negativeThreshold

    public var description: String {
        switch self {
        case .emptyName: return "the rule needs a name"
        case .invalidPattern(let pattern): return "'\(pattern)' is not a valid regular expression"
        case .noFolders: return "a suggest rule needs at least one folder to look in"
        case .negativeThreshold: return "age and size limits can't be negative"
        }
    }
}
