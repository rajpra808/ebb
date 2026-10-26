import Foundation

/// Where cleared items go. Ebb only ever moves things to the Trash; it never
/// deletes and never empties the Trash.
public protocol TrashBin: Sendable {
    /// Moves `path` to the Trash and returns where it ended up.
    func moveToTrash(_ path: String) throws -> String

    /// Whether `path` is inside a Trash folder. Emptying only ever removes
    /// paths that pass this, so a damaged history file can't point it at
    /// anything else.
    func isInTrash(_ path: String) -> Bool
}

extension TrashBin {
    public func isInTrash(_ path: String) -> Bool {
        // ~/.Trash, and /Volumes/<disk>/.Trashes/<uid> on other disks.
        let components = path.split(separator: "/").map(String.init)
        guard let index = components.firstIndex(where: { $0 == ".Trash" || $0 == ".Trashes" }) else { return false }
        return index < components.count - 1 && !components.contains("..")
    }
}

/// The user's Trash, through Finder's own mechanism (`FileManager.trashItem`),
/// so "Put Back" in Finder works too.
public struct SystemTrash: TrashBin {
    public init() {}

    public func moveToTrash(_ path: String) throws -> String {
        #if os(macOS)
        var resulting: NSURL?
        try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &resulting)
        guard let trashed = resulting?.path else { throw CleanError.trashLocationUnknown(path) }
        return trashed
        #else
        throw CleanError.trashUnsupported
        #endif
    }
}

public enum CleanError: Error, Equatable, CustomStringConvertible {
    case trashLocationUnknown(String)
    case trashUnsupported
    case notInTrash(String)
    case originalExists(String)
    case unknownClean(String)
    case notATrashPath(String)

    public var description: String {
        switch self {
        case .trashLocationUnknown(let path): return "moved \(path) to Trash, but couldn't tell where"
        case .trashUnsupported: return "moving to Trash isn't supported on this platform yet"
        case .notInTrash(let path): return "\(path) is no longer in the Trash"
        case .originalExists(let path): return "something already exists at \(path)"
        case .unknownClean(let id): return "no clean with id \(id) in the history"
        case .notATrashPath(let path): return "\(path) isn't in the Trash, so it was left alone"
        }
    }
}
