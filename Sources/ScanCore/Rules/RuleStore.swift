import Foundation

/// Reads and writes `rules.json`. The same format is used for import and
/// export.
///
/// ```json
/// { "version": 1, "rules": [ { "id": "3f2a9c1e", "name": "Old recordings", ... } ] }
/// ```
public struct RuleStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// `~/Library/Application Support/Ebb/rules.json` on macOS,
    /// `~/.local/share/ebb/rules.json` elsewhere.
    public static func defaultLocation(home: String) -> URL {
        #if os(macOS)
        let folder = Paths.join(home, "Library/Application Support/Ebb")
        #else
        let folder = Paths.join(home, ".local/share/ebb")
        #endif
        return URL(fileURLWithPath: Paths.join(folder, "rules.json"))
    }

    /// The rules in the file. A missing file means no rules.
    public func load() throws -> RuleFile {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return RuleFile(rules: []) }
        return try Self.decode(Data(contentsOf: fileURL))
    }

    /// Adds a rule and saves. Refuses if the file has entries Ebb can't
    /// read, since saving would drop them. Returns the rule as stored (its id
    /// changes in the unlikely case it collides).
    @discardableResult
    public func add(_ rule: Rule) throws -> Rule {
        try rule.validate()
        var file = try load()
        guard file.unreadableEntries == 0 else { throw RuleStoreError.wouldDropEntries(file.problems) }
        var rule = rule
        while file.rules.contains(where: { $0.id == rule.id }) { rule.id = Rule.makeID() }
        file.rules.append(rule)
        try save(file.rules)
        return rule
    }

    /// Removes the rule with `id` and saves. Same caution as `add`.
    public func remove(id: String) throws {
        var file = try load()
        guard file.unreadableEntries == 0 else { throw RuleStoreError.wouldDropEntries(file.problems) }
        file.rules.removeAll { $0.id == id }
        try save(file.rules)
    }

    public func save(_ rules: [Rule]) throws {
        let folder = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Self.encode(rules).write(to: fileURL, options: .atomic)
    }

    /// Decodes rules one by one, so one broken entry doesn't hide the rest.
    public static func decode(_ data: Data) throws -> RuleFile {
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw RuleStoreError.unreadable(String(describing: error))
        }
        guard envelope.version == 1 else { throw RuleStoreError.unsupportedVersion(envelope.version) }

        var file = RuleFile(rules: [])
        for (index, entry) in envelope.rules.enumerated() {
            if let rule = entry.rule {
                file.rules.append(rule)
            } else {
                file.unreadableEntries += 1
                file.problems.append("rule #\(index + 1) in rules.json can't be read and was skipped")
            }
        }
        return file
    }

    public static func encode(_ rules: [Rule]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(EncodedEnvelope(version: 1, rules: rules))
    }

    private struct Envelope: Decodable {
        let version: Int
        let rules: [LenientRule]
    }

    private struct EncodedEnvelope: Encodable {
        let version: Int
        let rules: [Rule]
    }

    private struct LenientRule: Decodable {
        let rule: Rule?

        init(from decoder: Decoder) throws {
            rule = try? Rule(from: decoder)
        }
    }
}

public struct RuleFile: Sendable, Equatable {
    public var rules: [Rule]
    public var unreadableEntries = 0
    public var problems: [String] = []
}

public enum RuleStoreError: Error, Equatable, CustomStringConvertible {
    case unreadable(String)
    case unsupportedVersion(Int)
    case wouldDropEntries([String])

    public var description: String {
        switch self {
        case .unreadable(let detail): return "rules.json isn't valid: \(detail)"
        case .unsupportedVersion(let version): return "rules.json version \(version) is not supported"
        case .wouldDropEntries(let problems):
            return "rules.json has entries Ebb can't read; fix them first (\(problems.joined(separator: "; ")))"
        }
    }
}
