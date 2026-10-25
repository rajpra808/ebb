import ArgumentParser
import Foundation
import ScanCore

public struct Ebb: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "ebb",
        abstract: "Finds disk space that is safe to clear, and leaves your active work alone.",
        discussion: "Ebb is read-only for now: no command moves or deletes anything.",
        version: "0.1.0",
        subcommands: [Scan.self, Active.self, RuleCommand.self],
        defaultSubcommand: Scan.self
    )

    public init() {}
}

/// Flags shared by commands that look at projects.
struct ScanFlags: ParsableArguments {
    @Option(name: .customLong("in"), help: ArgumentHelp(
        "Folder to search for projects (repeatable). Defaults to your home folder.",
        valueName: "dir"
    ))
    var roots: [String] = []

    @Option(help: ArgumentHelp("A project with activity in this many days is active.", valueName: "days"))
    var activeDays: Int = 14

    @Flag(help: "Also look at ~/Library/Caches in the temp files category.")
    var libraryCaches = false

    @Flag(help: "Follow folders onto external disks and network volumes.")
    var allVolumes = false

    @Flag(name: .shortAndLong, help: "Don't show what the scan is doing while it runs.")
    var quiet = false

    func validate() throws {
        guard (1...365).contains(activeDays) else {
            throw ValidationError("--active-days must be between 1 and 365.")
        }
    }

    func options() -> ScanOptions {
        var options = ScanOptions.currentUser()
        if !roots.isEmpty {
            options.projectRoots = roots.map { absolutePath($0, home: options.home) }
        }
        options.activeDays = activeDays
        options.includeLibraryCaches = libraryCaches
        options.includeOtherVolumes = allVolumes
        return options
    }
}

/// Resolves `~` and relative paths the way a shell user expects.
func absolutePath(_ path: String, home: String) -> String {
    if path == "~" { return home }
    if path.hasPrefix("~/") { return home + path.dropFirst(1) }
    if path.hasPrefix("/") { return path }
    return URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        .standardizedFileURL.path
}

func loadRules(home: String) -> (rules: [Rule], warnings: [String]) {
    let store = RuleStore(fileURL: RuleStore.defaultLocation(home: home))
    do {
        let file = try store.load()
        return (file.rules, file.problems)
    } catch {
        return ([], ["Custom rules weren't loaded: \(error)"])
    }
}

struct StandardError: TextOutputStream {
    mutating func write(_ string: String) {
        FileHandle.standardError.write(Data(string.utf8))
    }
}

// MARK: - scan

struct Scan: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List what's safe to clear. Read-only."
    )

    @OptionGroup var flags: ScanFlags

    @Flag(help: "Print the result as JSON.")
    var json = false

    @Flag(help: "List every item and everything skipped, with reasons.")
    var details = false

    mutating func run() async throws {
        let options = flags.options()
        let loaded = loadRules(home: options.home)
        var scanner = Scanner(catalog: try CategoryCatalog.builtIn(), options: options, rules: loaded.rules)
        scanner.onProgress = ProgressLine.handler(home: options.canonicalized().home, enabled: !flags.quiet)
        var result = await scanner.scan()
        result.warnings.insert(contentsOf: loaded.warnings, at: 0)

        if json {
            print(try JSONOutput.encode(result))
            return
        }
        let report = Report(result: result, home: options.canonicalized().home)
        print(report.summary(), terminator: "")
        if details {
            print(report.details(), terminator: "")
            print(report.skipped(), terminator: "")
        }
        var stderr = StandardError()
        print(report.warnings(), terminator: "", to: &stderr)
    }
}

// MARK: - active

struct Active: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List projects Ebb considers active, and why."
    )

    @OptionGroup var flags: ScanFlags

    @Flag(help: "Print the result as JSON.")
    var json = false

    mutating func run() async throws {
        let options = flags.options()
        var scanner = Scanner(catalog: try CategoryCatalog.builtIn(), options: options)
        scanner.onProgress = ProgressLine.handler(home: options.canonicalized().home, enabled: !flags.quiet)
        let started = Date()
        let found = await scanner.activeProjects()

        if json {
            print(try JSONOutput.encode(found.projects))
            return
        }
        let home = options.canonicalized().home
        if found.projects.isEmpty {
            print("  No active projects in the last \(options.activeDays) days.")
        }
        for project in found.projects {
            print("  \(abbreviate(project.path, home: home))")
            for signal in project.signals {
                print("      \(signal.signal.padding(toLength: 12, withPad: " ", startingAt: 0))\(signal.detail)")
            }
        }
        let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
        print("\n  \(plural(found.projects.count, "active project")), "
            + "\(found.inactiveCount) inactive. Active means activity in the last \(options.activeDays) days. "
            + "(\(seconds)s)")
        var stderr = StandardError()
        for warning in found.warnings { print("  note: \(warning)", to: &stderr) }
    }
}

enum JSONOutput {
    static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}
