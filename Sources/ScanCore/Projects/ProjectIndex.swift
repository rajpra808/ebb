/// Fast lookups over a set of project roots.
struct ProjectIndex: Sendable {
    private let containing: PathSet
    private let sorted: SortedPaths

    init(roots: [String]) {
        containing = PathSet(roots)
        sorted = SortedPaths(roots)
    }

    var isEmpty: Bool { sorted.count == 0 }

    func contains(root path: String) -> Bool {
        containing.contains(path)
    }

    /// The project that `path` is in or is, if any.
    func project(containing path: String) -> String? {
        containing.ancestor(of: path)
    }

    /// The first project at or below `path`, e.g. a project inside a temp
    /// folder that is being considered as a whole.
    func project(inside path: String) -> String? {
        sorted.first(inside: path)
    }

    /// Either of the above: anything that overlaps `path`.
    func project(overlapping path: String) -> String? {
        project(containing: path) ?? project(inside: path)
    }
}
