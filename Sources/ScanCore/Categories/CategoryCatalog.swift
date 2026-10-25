import Foundation

/// How a category finds its candidates. Each case maps to one collector type
/// in this folder; a new category usually only needs a JSON entry using one
/// of these. A new *kind* of search needs a new case and collector.
public enum CollectorSpec: Equatable, Sendable {
    /// Folders inside projects, such as `node_modules`, reported only when
    /// the whole project is inactive.
    case projectLeftovers([LeftoverPattern])
    /// Fixed locations such as package manager caches.
    case knownPaths([KnownPath])
    /// The direct children of some folders, filtered by age and type.
    case folderContents(FolderContentsSpec)
}

/// A folder name to look for inside projects, plus conditions that make
/// sure it's the tool's output and not something with the same name.
public struct LeftoverPattern: Codable, Equatable, Sendable {
    public let names: [String]
    /// The folder must contain this file, e.g. `pyvenv.cfg` for a venv.
    public let containsFile: String?
    /// The folder next to it must contain this file, e.g. `dist` next to a
    /// `package.json`.
    public let siblingFile: String?
    /// For generic names like `build`: only report when git confirms nothing
    /// inside is tracked (or the project isn't a git repo).
    public let confirmUntracked: Bool

    public init(names: [String], containsFile: String? = nil, siblingFile: String? = nil,
                confirmUntracked: Bool = false) {
        self.names = names
        self.containsFile = containsFile
        self.siblingFile = siblingFile
        self.confirmUntracked = confirmUntracked
    }

    private enum CodingKeys: String, CodingKey {
        case names, containsFile, siblingFile, confirmUntracked
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        names = try container.decode([String].self, forKey: .names)
        containsFile = try container.decodeIfPresent(String.self, forKey: .containsFile)
        siblingFile = try container.decodeIfPresent(String.self, forKey: .siblingFile)
        confirmUntracked = try container.decodeIfPresent(Bool.self, forKey: .confirmUntracked) ?? false
    }
}

public struct KnownPath: Codable, Equatable, Sendable {
    /// The tool's name as users know it, e.g. "npm".
    public let label: String
    /// May start with `~` or `$TMPDIR`.
    public let path: String
    /// Overrides the category's comes-back label for this path.
    public let comesBack: ComesBack?
    /// Clear by running this instead of moving the folder to Trash.
    public let clearCommand: String?
    /// The measured size is a best guess (e.g. how much `pnpm store prune`
    /// would free).
    public let estimated: Bool?
}

public struct FolderContentsSpec: Codable, Equatable, Sendable {
    public struct Folder: Codable, Equatable, Sendable {
        public let path: String
        /// Only scanned when this option is turned on (see `ScanOptions`).
        public let optIn: String?
    }

    public let folders: [Folder]
    public let olderThanDays: Int
    /// Only entries with one of these extensions (lowercase, no dot).
    public let extensions: [String]?
    /// Only regular files, not folders.
    public let filesOnly: Bool?
    public let skipNamePrefixes: [String]?
    /// Extensions that only count when the file was downloaded from the web
    /// (macOS quarantine attribute), so your own zip archives are left alone.
    public let requireDownloadedFor: [String]?
}

/// A category from `categories.json`: what the user sees plus how to find it.
public struct CategoryDefinition: Equatable, Sendable {
    public let category: Category
    public let isEnabled: Bool
    public let collector: CollectorSpec
}

/// The list of categories Ebb knows about, loaded from `categories.json`.
public struct CategoryCatalog: Sendable {
    public let definitions: [CategoryDefinition]

    public var enabled: [CategoryDefinition] { definitions.filter(\.isEnabled) }

    public init(definitions: [CategoryDefinition]) {
        self.definitions = definitions
    }

    /// The catalog compiled into ScanCore from `categories.json`.
    public static func builtIn() throws -> CategoryCatalog {
        try CategoryCatalog(data: Data(PackageResources.categories_json))
    }

    public init(data: Data) throws {
        let file = try JSONDecoder().decode(CatalogFile.self, from: data)
        guard file.version == 1 else { throw CatalogError.unsupportedVersion(file.version) }

        var seen = Set<String>()
        for entry in file.categories {
            guard seen.insert(entry.id).inserted else { throw CatalogError.duplicateID(entry.id) }
        }
        definitions = file.categories.map(\.definition)
    }

    public func definition(for id: String) -> CategoryDefinition? {
        definitions.first { $0.category.id == id }
    }
}

public enum CatalogError: Error, Equatable, CustomStringConvertible {
    case unsupportedVersion(Int)
    case duplicateID(String)
    case unknownCollector(String)

    public var description: String {
        switch self {
        case .unsupportedVersion(let version): return "categories.json version \(version) is not supported"
        case .duplicateID(let id): return "categories.json lists '\(id)' more than once"
        case .unknownCollector(let type): return "categories.json uses unknown collector type '\(type)'"
        }
    }
}

// MARK: - File format

private struct CatalogFile: Decodable {
    let version: Int
    let categories: [CategoryEntry]
}

private struct CategoryEntry: Decodable {
    let id: String
    let number: Int
    let title: String
    let summary: String
    let comesBack: ComesBack
    let rule: String
    let preselected: Bool
    let enabled: Bool?
    let collector: CollectorEntry

    var definition: CategoryDefinition {
        CategoryDefinition(
            category: Category(
                id: id, number: number, title: title, summary: summary,
                comesBack: comesBack, ruleDescription: rule, preselected: preselected
            ),
            isEnabled: enabled ?? true,
            collector: collector.spec
        )
    }
}

private struct CollectorEntry: Decodable {
    let spec: CollectorSpec

    private enum CodingKeys: String, CodingKey {
        case type, leftovers, paths
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "projectLeftovers":
            spec = .projectLeftovers(try container.decode([LeftoverPattern].self, forKey: .leftovers))
        case "knownPaths":
            spec = .knownPaths(try container.decode([KnownPath].self, forKey: .paths))
        case "folderContents":
            spec = .folderContents(try FolderContentsSpec(from: decoder))
        default:
            throw CatalogError.unknownCollector(type)
        }
    }
}
