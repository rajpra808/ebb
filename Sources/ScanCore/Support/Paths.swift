/// Path helpers on plain strings.
///
/// The scanner handles hundreds of thousands of paths. Plain strings are
/// cheaper than `URL` and make the comparison rules (no trailing slash,
/// always absolute) explicit.
enum Paths {
    static func join(_ base: String, _ component: String) -> String {
        base.hasSuffix("/") ? base + component : base + "/" + component
    }

    static func lastComponent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }

    static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "." }
        return slash == path.startIndex ? "/" : String(path[..<slash])
    }

    /// True if `path` is `ancestor` or lives somewhere below it.
    static func isSameOrDescendant(_ path: String, of ancestor: String) -> Bool {
        if path == ancestor { return true }
        if ancestor == "/" { return path.hasPrefix("/") }
        return path.hasPrefix(ancestor) && path.dropFirst(ancestor.count).first == "/"
    }

    static func relative(_ path: String, to base: String) -> String {
        guard isSameOrDescendant(path, of: base), path != base else { return path }
        return String(path.dropFirst(base.count + (base == "/" ? 0 : 1)))
    }

    /// Path components without the leading root, e.g. `/a/b` → `["a", "b"]`.
    static func components(of path: String) -> [Substring] {
        path.split(separator: "/", omittingEmptySubsequences: true)
    }

    /// Removes a trailing slash so equal folders compare equal.
    static func normalized(_ path: String) -> String {
        guard path.count > 1, path.hasSuffix("/") else { return path }
        return String(path.dropLast())
    }

    static func fileExtension(of name: String) -> String? {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return nil }
        return String(name[name.index(after: dot)...]).lowercased()
    }
}

/// A set of folders that answers "is this path inside any of them?" in
/// O(depth) by checking each ancestor.
struct PathSet: Sendable {
    private var members: Set<String>

    init<S: Sequence>(_ paths: S) where S.Element == String {
        members = Set(paths.map(Paths.normalized))
    }

    var isEmpty: Bool { members.isEmpty }

    mutating func insert(_ path: String) {
        members.insert(Paths.normalized(path))
    }

    func contains(_ path: String) -> Bool {
        members.contains(path)
    }

    /// The member that equals or contains `path`, if any.
    func ancestor(of path: String) -> String? {
        var current = path
        while true {
            if members.contains(current) { return current }
            if current == "/" || current.isEmpty { return nil }
            current = Paths.parent(of: current)
        }
    }
}
