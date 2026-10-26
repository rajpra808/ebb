#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import ArgumentParser
import EbbClean
import Foundation
import ScanCore

struct Clean: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Move what's safe to clear to the Trash, after asking.",
        discussion: """
        Scans first, then moves the selected items to the Trash. Nothing is deleted, and \
        every move is logged: `ebb history` lists them and `ebb undo` puts them back.

        Without --select, the pre-selected items are moved (what `ebb scan` calls "safe to \
        clear"). --select picks categories by id, including items that aren't pre-selected.

        Items cleared by a command, such as the pnpm store, are listed with the command to \
        run; Ebb doesn't run it for you.
        """
    )

    @OptionGroup var flags: ScanFlags

    @Option(help: ArgumentHelp(
        "Category ids to clear, comma-separated, e.g. node-leftovers,package-caches.", valueName: "ids"
    ))
    var select: String?

    @Flag(name: .shortAndLong, help: "Don't ask for confirmation.")
    var yes = false

    @Flag(help: "Show what would be moved, and move nothing.")
    var dryRun = false

    var selectedCategories: Set<String>? {
        select.map { Set($0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }) }
    }

    func validate() throws {
        if let selected = selectedCategories {
            let known = Set((try CategoryCatalog.builtIn()).definitions.map(\.category.id) + ["custom-rules"])
            let unknown = selected.subtracting(known)
            guard unknown.isEmpty else {
                throw ValidationError("Unknown category: \(unknown.sorted().joined(separator: ", ")). "
                    + "Run `ebb scan` to see the ids.")
            }
        }
    }

    /// The items to clear from a scan result.
    static func selection(from result: ScanResult, categories: Set<String>?) -> [Item] {
        guard let categories else { return result.items.filter(\.preselected) }
        return result.items.filter { categories.contains($0.categoryID) }
    }

    mutating func run() async throws {
        let options = flags.options()
        let home = options.canonicalized().home
        let loaded = loadRules(home: options.home)
        var scanner = try flags.scanner(rules: loaded.rules)
        scanner.onProgress = ProgressLine.handler(home: home, enabled: !flags.quiet)
        let result = await scanner.scan()

        let selected = Self.selection(from: result, categories: selectedCategories)
        let trashable = selected.filter(\.isTrashable)
        let commands = selected.filter { !$0.isTrashable }
        let total = trashable.reduce(0) { $0 + $1.allocatedBytes }

        if trashable.isEmpty && commands.isEmpty {
            print("  Nothing selected to clear.")
            return
        }
        if !trashable.isEmpty {
            print(Table(rows: Self.summaryRows(trashable), rightAligned: [1]).render(), terminator: "")
            print("\n  \(plural(trashable.count, "item")), \(ByteCount.format(total)), will go to the Trash.")
        }
        print(Self.commandHint(commands), terminator: "")
        if dryRun || trashable.isEmpty {
            if dryRun { print("  Dry run: nothing was moved.") }
            return
        }
        guard yes || Self.confirm("  Move them to the Trash? [y/N] ") else {
            print("  Nothing was moved.")
            return
        }

        let cleaner = Cleaner(scanner: scanner, history: CleanHistory(fileURL: CleanHistory.defaultLocation(home: home)))
        let report = try await cleaner.clean(trashable, source: "cli")
        print("\n  Moved \(plural(report.moved.count, "item")) (\(ByteCount.format(report.movedBytes))) to the Trash.")
        if !report.kept.isEmpty {
            print("  Left alone, because things changed since the scan:")
            for kept in report.kept {
                print("    \(abbreviate(kept.item.path, home: home))  \(kept.why)")
            }
        }
        if let id = report.cleanID {
            print("  Undo with `ebb undo \(id)`. The space is freed when you empty the Trash.")
        }
    }

    static func summaryRows(_ items: [Item]) -> [[String]] {
        let byCategory = Dictionary(grouping: items, by: \.categoryID)
        return byCategory.keys.sorted().map { id in
            let members = byCategory[id] ?? []
            return [id, ByteCount.format(members.reduce(0) { $0 + $1.allocatedBytes }), plural(members.count, "item")]
        }
    }

    static func commandHint(_ items: [Item]) -> String {
        guard !items.isEmpty else { return "" }
        var out = "\n  Not moved to the Trash; clear these with their own command if you want to:\n"
        for item in items {
            out += "    \(item.clearCommand ?? "")   (\(ByteCount.format(item.allocatedBytes)))\n"
        }
        return out
    }

    /// Asks on the terminal. Without one there's nobody to ask, so the
    /// answer is no.
    static func confirm(_ question: String) -> Bool {
        guard isatty(STDIN_FILENO) == 1 else {
            print("  Not a terminal, so nothing was moved. Pass --yes to confirm.")
            return false
        }
        print(question, terminator: "")
        fflush(stdout)
        let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased()
        return answer == "y" || answer == "yes"
    }
}

struct History: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List past cleans.")

    @Flag(help: "Print the history as JSON.")
    var json = false

    func run() throws {
        let home = ScanOptions.currentUser().canonicalized().home
        let history = CleanHistory(fileURL: CleanHistory.defaultLocation(home: home))
        let records = try history.load()
        if json {
            print(try JSONOutput.encode(records))
            return
        }
        guard !records.isEmpty else {
            print("  No cleans yet.")
            return
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM, HH:mm"
        let rows = records.reversed().map { record -> [String] in
            let restored = record.entries.filter { $0.restoredAt != nil }.count
            let inTrash = record.entries.filter { $0.restoredAt == nil && FileManager.default.fileExists(atPath: $0.trashPath) }.count
            var state = "\(inTrash) in Trash"
            if restored > 0 { state += ", \(restored) put back" }
            if inTrash + restored < record.entries.count { state += ", rest emptied" }
            return [record.id, formatter.string(from: record.date), ByteCount.format(record.totalBytes),
                    plural(record.entries.count, "item"), state]
        }
        print(Table(rows: rows, rightAligned: [2]).render(), terminator: "")
        print("\n  \(ByteCount.format(try history.bytesStillInTrash())) from Ebb cleans is still in the Trash. "
            + "Run `ebbctl empty-trash` to remove it for good; your own files in the Trash stay.")
    }
}

struct EmptyTrash: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "empty-trash",
        abstract: "Remove for good what Ebb moved to the Trash.",
        discussion: "Only Ebb's own items are removed; anything else in your Trash stays. This can't be undone."
    )

    @Flag(name: .shortAndLong, help: "Don't ask for confirmation.")
    var yes = false

    func run() throws {
        let options = ScanOptions.currentUser()
        let home = options.canonicalized().home
        let history = CleanHistory(fileURL: CleanHistory.defaultLocation(home: home))
        let waiting = try history.bytesStillInTrash()
        guard waiting > 0 else {
            print("  Nothing from Ebb is waiting in the Trash.")
            return
        }
        print("  \(ByteCount.format(waiting)) from Ebb cleans is in the Trash. Your own files there stay.")
        guard yes || Clean.confirm("  Remove it for good? This can't be undone. [y/N] ") else {
            print("  Nothing was removed.")
            return
        }
        let cleaner = Cleaner(scanner: DiskScanner(catalog: try CategoryCatalog.builtIn(), options: options),
                              history: history)
        let report = try cleaner.emptyTrash()
        print("  Removed \(plural(report.removedCount, "item")), freeing \(ByteCount.format(report.freedBytes)).")
        for failure in report.failed { print("    \(failure)") }
    }
}

struct Undo: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Put items from a clean back where they were.",
        discussion: "Without an id, undoes the latest clean. Nothing is overwritten."
    )

    @Argument(help: "The clean's id from `ebb history`.")
    var id: String?

    @Option(help: ArgumentHelp("Only put back this path (repeatable).", valueName: "path"))
    var path: [String] = []

    func run() throws {
        let options = ScanOptions.currentUser()
        let home = options.canonicalized().home
        let history = CleanHistory(fileURL: CleanHistory.defaultLocation(home: home))
        let latest = try history.load().last?.id
        guard let target = id ?? latest else {
            print("  No cleans to undo.")
            return
        }
        let settings = SettingsStore(fileURL: SettingsStore.defaultLocation(home: options.home)).load()
        let scanner = DiskScanner.configured(settings: settings, options: options,
                                             catalog: try CategoryCatalog.builtIn(), rules: [])
        let cleaner = Cleaner(scanner: scanner,
                              history: history)
        let paths = path.isEmpty ? nil : path.map { absolutePath($0, home: home) }
        let report = try cleaner.putBack(cleanID: target, paths: paths)
        print("  Put back \(plural(report.restored.count, "item")).")
        for failure in report.failed {
            print("    \(abbreviate(failure.path, home: home))  \(failure.why)")
        }
    }
}
