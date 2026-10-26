import EbbClean
import Foundation
import ScanCore

/// Which items the user has ticked, and what that adds up to.
///
/// Starts from the scan's pre-selection. Items cleared with a tool's own
/// command (Go modules, the pnpm store, Docker) can be ticked when Ebb is
/// allowed to run that command and the tool is installed. They start
/// unticked, because unlike the Trash they can't be put back.
public struct Selection: Equatable, Sendable {
    public private(set) var paths: Set<String>

    public init(preselectedFrom result: ScanResult?) {
        paths = Set((result?.items ?? []).filter { $0.preselected && $0.isTrashable }.map(\.path))
    }

    /// Whether the user can tick this item at all.
    public static func isSelectable(_ item: Item) -> Bool {
        item.isTrashable || ToolCommandRunner().canRun(item)
    }

    public func contains(_ item: Item) -> Bool {
        paths.contains(item.path)
    }

    public mutating func toggle(_ item: Item) {
        guard Self.isSelectable(item) else { return }
        if paths.contains(item.path) { paths.remove(item.path) } else { paths.insert(item.path) }
    }

    public mutating func set(_ items: [Item], selected: Bool) {
        for item in items where Self.isSelectable(item) {
            if selected { paths.insert(item.path) } else { paths.remove(item.path) }
        }
    }

    public mutating func remove(_ removed: [String]) {
        paths.subtract(removed)
    }

    public func items(in result: ScanResult) -> [Item] {
        result.items.filter { paths.contains($0.path) }
    }

    public struct Totals: Equatable, Sendable {
        public var count = 0
        public var bytes: Int64 = 0
        public var comesBack: Int64 = 0
        public var redownload: Int64 = 0
        public var goneForGood: Int64 = 0
    }

    public func totals(in result: ScanResult) -> Totals {
        items(in: result).reduce(into: Totals()) { totals, item in
            totals.count += 1
            totals.bytes += item.allocatedBytes
            switch item.comesBack {
            case .yes: totals.comesBack += item.allocatedBytes
            case .redownload: totals.redownload += item.allocatedBytes
            case .no, .notApplicable: totals.goneForGood += item.allocatedBytes
            }
        }
    }
}

/// The filter above the Recommendations list.
public enum RecommendationFilter: String, CaseIterable, Sendable, Identifiable {
    case all = "All"
    case comesBack = "Regenerates"
    case needsALook = "Needs a look"

    public var id: String { rawValue }

    public func includes(_ item: Item) -> Bool {
        switch self {
        case .all: return true
        case .comesBack: return item.preselected
        case .needsALook: return !item.preselected
        }
    }
}
