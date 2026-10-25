#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The built-in never-touch list.
///
/// Nothing on this list is ever reported, whatever a category or a custom
/// rule says. It can't be turned off: the app shows these entries locked.
/// When in doubt, add to it; a missed cleanup costs a few megabytes, a wrong
/// one costs someone's credentials or work.
public struct NeverTouchList: Sendable {
    public struct Entry: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            /// Matches any path component with this name (fnmatch glob).
            case name
            /// Matches a path, or anything inside it (fnmatch glob over the
            /// whole path, `~` expanded to the home folder).
            case path
        }

        public let kind: Kind
        public let pattern: String
        /// Shown to the user: why this is protected.
        public let why: String
    }

    public let entries: [Entry]
    private let home: String
    private let usersFolder: String
    private let names: [Entry]
    private let paths: [Entry]

    /// - Parameters:
    ///   - home: the home folder of the user being scanned.
    ///   - usersFolder: the folder holding home folders (`/Users`, `/home`).
    public init(home: String, usersFolder: String? = nil) {
        let users = usersFolder ?? Paths.parent(of: home)
        let expanded = Self.builtIn.map { entry -> Entry in
            guard entry.kind == .path else { return entry }
            let pattern = entry.pattern.replacingOccurrences(of: "~", with: home)
            return Entry(kind: .path, pattern: pattern, why: entry.why)
        }
        self.home = home
        self.usersFolder = users
        entries = expanded
        names = expanded.filter { $0.kind == .name }
        paths = expanded.filter { $0.kind == .path }
    }

    /// The entry protecting `path`, checking the path itself and every folder
    /// above it.
    public func protection(for path: String) -> Entry? {
        if let entry = otherUsersHome(containing: path) { return entry }
        for component in Paths.components(of: path) {
            if let entry = protection(forName: String(component)) { return entry }
        }
        var current = path
        while current != "/" && !current.isEmpty {
            for entry in paths where Self.matches(entry.pattern, current, pathname: true) {
                return entry
            }
            current = Paths.parent(of: current)
        }
        return nil
    }

    /// The name entry matching a single file or folder name, used while
    /// walking an item's contents.
    public func protection(forName name: String) -> Entry? {
        names.first { Self.matches($0.pattern, name, pathname: false) }
    }

    private func otherUsersHome(containing path: String) -> Entry? {
        guard Paths.isSameOrDescendant(path, of: usersFolder), path != usersFolder,
              !Paths.isSameOrDescendant(path, of: home)
        else { return nil }
        let owner = Paths.components(of: Paths.relative(path, to: usersFolder)).first.map(String.init)
        // /Users/Shared is shared by design, but it isn't ours to clean either.
        return Entry(kind: .path, pattern: Paths.join(usersFolder, owner ?? "*"), why: "another user's files")
    }

    private static func matches(_ pattern: String, _ string: String, pathname: Bool) -> Bool {
        fnmatch(pattern, string, pathname ? FNM_PATHNAME : 0) == 0
    }
}

extension NeverTouchList {
    private static func name(_ pattern: String, _ why: String) -> Entry {
        Entry(kind: .name, pattern: pattern, why: why)
    }

    private static func path(_ pattern: String, _ why: String) -> Entry {
        Entry(kind: .path, pattern: pattern, why: why)
    }

    /// Patterns before `~` expansion. Name patterns apply at any depth.
    static let builtIn: [Entry] = [
        // Version control and secrets, wherever they are.
        name(".git", "git repository data"),
        name(".env*", "environment file, may hold secrets"),
        name(".credentials*", "credentials"),
        name(".netrc", "credentials"),
        name(".npmrc", "may hold registry tokens"),
        name(".pypirc", "may hold registry tokens"),
        name("*.pem", "key or certificate"),
        name("*.p12", "key or certificate"),
        name("*.keychain", "keychain"),
        name("*.keychain-db", "keychain"),

        // AI tool memory and instructions.
        name("CLAUDE.md", "Claude Code memory"),
        name("CLAUDE.local.md", "Claude Code memory"),
        name("AGENTS.md", "agent instructions"),
        name("GEMINI.md", "Gemini CLI memory"),

        // AI tool settings and auth.
        path("~/.claude/settings*.json", "Claude Code settings"),
        path("~/.claude/.credentials*", "Claude Code credentials"),
        path("~/.claude/projects/*/memory", "Claude Code memory"),
        path("~/.claude.json", "Claude Code config and auth"),
        path("~/.codex/config*", "Codex config"),
        path("~/.codex/auth.json", "Codex credentials"),
        path("~/.gemini/settings.json", "Gemini CLI settings"),
        path("~/.gemini/oauth_creds.json", "Gemini CLI credentials"),

        // Keys, keychains and cloud credentials.
        path("~/.ssh", "SSH keys"),
        path("~/.gnupg", "GPG keys"),
        path("~/.aws", "AWS credentials"),
        path("~/.kube", "Kubernetes credentials"),
        path("~/.docker/config.json", "Docker credentials"),
        path("~/.config/gcloud", "Google Cloud credentials"),
        path("~/.config/gh", "GitHub CLI credentials"),
        path("~/Library/Keychains", "keychains"),

        // Ebb's own data, and Trash (Ebb never empties it).
        path("~/Library/Application Support/Ebb", "Ebb's own settings"),
        path("~/.Trash", "Trash"),

        // The system.
        path("/System", "macOS system files"),
        path("/Library/Keychains", "system keychains"),
        path("/private/var/db", "system databases"),
        path("/usr", "system files"),
        path("/bin", "system files"),
        path("/sbin", "system files"),
    ]
}
