import Foundation

/// One clean: what was moved to the Trash, from where, and whether it has
/// been put back.
public struct CleanRecord: Codable, Equatable, Sendable, Identifiable {
    public struct Entry: Codable, Equatable, Sendable {
        public let originalPath: String
        public let trashPath: String
        public let categoryID: String
        public let allocatedBytes: Int64
        public var restoredAt: Date?
    }

    public let id: String
    public let date: Date
    /// Where the clean was started, e.g. "cli", "review", "menu bar".
    public let source: String
    public var entries: [Entry]

    public var totalBytes: Int64 { entries.reduce(0) { $0 + $1.allocatedBytes } }
}

/// The clean log at `~/Library/Application Support/Ebb/history.json`.
///
/// Every move to Trash is written here before the next one starts, so the
/// log is complete even if a clean is interrupted.
public struct CleanHistory: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public static func defaultLocation(home: String) -> URL {
        #if os(macOS)
        let folder = home + "/Library/Application Support/Ebb"
        #else
        let folder = home + "/.local/share/ebb"
        #endif
        return URL(fileURLWithPath: folder + "/history.json")
    }

    public func load() throws -> [CleanRecord] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        return try Self.decoder.decode(Envelope.self, from: data).cleans
    }

    public func save(_ records: [CleanRecord]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Self.encoder.encode(Envelope(version: 1, cleans: records)).write(to: fileURL, options: .atomic)
    }

    /// Applies `change` to the stored records and saves them.
    @discardableResult
    func update<T>(_ change: (inout [CleanRecord]) throws -> T) throws -> T {
        var records = try load()
        let result = try change(&records)
        try save(records)
        return result
    }

    /// Bytes from Ebb cleans that are still in the Trash (not put back, not
    /// emptied).
    public func bytesStillInTrash() throws -> Int64 {
        try load().flatMap(\.entries)
            .filter { $0.restoredAt == nil && FileManager.default.fileExists(atPath: $0.trashPath) }
            .reduce(0) { $0 + $1.allocatedBytes }
    }

    private struct Envelope: Codable {
        let version: Int
        let cleans: [CleanRecord]
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
