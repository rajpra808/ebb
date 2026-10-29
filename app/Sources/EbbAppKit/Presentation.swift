import Foundation
import ScanCore

/// How an item reads in the app: a short title, the place it's in, and its
/// comes-back badge.
public struct ItemPresentation: Equatable, Sendable {
    /// e.g. "node_modules", "npm cache", "Tool-1.2.dmg"
    public let title: String
    /// e.g. "old-landing" for a project leftover; nil otherwise.
    public let context: String?
    /// The path with the home folder shown as `~`. Empty for Docker items.
    public let path: String
    public let badge: Badge

    public enum Badge: String, Equatable, Sendable {
        case comesBack = "Regenerates"
        case redownload = "Re-download"
        case goneForGood = "Gone for good"
        case notApplicable = "Info"
    }

    public init(_ item: Item, home: String) {
        let name = (item.path as NSString).lastPathComponent
        switch item.categoryID {
        case "package-caches":
            title = (item.source ?? name) + (item.source?.hasSuffix("store") == true ? "" : " cache")
            context = nil
        case "docker":
            title = "Docker " + (item.source ?? "data")
            context = nil
        default:
            title = name
            context = item.projectPath.map { ($0 as NSString).lastPathComponent }
        }
        path = item.path.hasPrefix("/") ? Self.abbreviate(item.path, home: home) : ""
        badge = Badge(item.comesBack)
    }

    public static func abbreviate(_ path: String, home: String) -> String {
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

extension ItemPresentation.Badge {
    public init(_ comesBack: ComesBack) {
        switch comesBack {
        case .yes: self = .comesBack
        case .redownload: self = .redownload
        case .no: self = .goneForGood
        case .notApplicable: self = .notApplicable
        }
    }
}

/// One line of the menu bar summary: a category with its total.
public struct CategorySummary: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let detail: String
    public let bytes: Int64
    public let badge: ItemPresentation.Badge
    public let isEstimated: Bool
    /// The tool commands that clear these items, when they can't go to the
    /// Trash (e.g. `go clean -modcache`). Empty for Trash items.
    public var commands: [String] = []

    /// Pre-selected categories, biggest first, as the menu bar shows them.
    /// `which` narrows it to items the Move to Trash button handles, or to
    /// the ones that need a tool's command.
    public static func safeToClear(in result: ScanResult, which: Kind = .all) -> [CategorySummary] {
        let categories = Dictionary(result.categories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let items = result.items.filter { $0.preselected && which.includes($0) }
        let grouped = Dictionary(grouping: items, by: \.categoryID)
        return grouped.compactMap { id, items -> CategorySummary? in
            guard let category = categories[id] else { return nil }
            return CategorySummary(
                id: id,
                title: category.title,
                detail: detail(for: id, items: items),
                bytes: items.reduce(0) { $0 + $1.allocatedBytes },
                badge: ItemPresentation.Badge(category.comesBack),
                isEstimated: items.contains(where: \.isEstimated),
                commands: Array(Set(items.compactMap(\.clearCommand))).sorted()
            )
        }
        .sorted { $0.bytes > $1.bytes }
    }

    public enum Kind: Sendable {
        case all, trash, toolCommand

        func includes(_ item: Item) -> Bool {
            switch self {
            case .all: return true
            case .trash: return item.isTrashable
            case .toolCommand: return !item.isTrashable
            }
        }
    }

    static func detail(for categoryID: String, items: [Item]) -> String {
        switch categoryID {
        case "python-venvs", "node-leftovers", "build-outputs":
            let projects = Set(items.compactMap(\.projectPath)).count
            return projects == 1 ? "1 inactive project" : "\(projects) inactive projects"
        case "package-caches", "docker":
            var seen = Set<String>()
            return items.compactMap(\.source).filter { seen.insert($0).inserted }.joined(separator: ", ")
        default:
            return items.count == 1 ? "1 item" : "\(items.count) items"
        }
    }
}

/// Short relative dates for headers: "today, 8:30", "yesterday, 21:12",
/// "13 Oct, 10:40".
public enum DateText {
    public static func describe(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return "today, \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "yesterday, \(time)"
        }
        return date.formatted(.dateTime.day().month(.abbreviated)) + ", " + time
    }
}

/// The line under "Safe to clear": how many items, and how they come back.
public enum SafeToClearText {
    public static func detail(for items: [Item]) -> String {
        let total = "\(items.count) item\(items.count == 1 ? "" : "s")"
        guard !items.isEmpty else { return total }
        let comeBack = items.filter { if case .yes = $0.comesBack { return true } else { return false } }.count
        if comeBack == items.count { return total + " · all regenerate" }
        return total + " · \(comeBack) regenerate, \(items.count - comeBack) re-download"
    }
}
