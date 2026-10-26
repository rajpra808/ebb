import Foundation
import ScanCore

/// Clears items that a tool has to clear itself, by running the tool's own
/// command: `go clean -modcache`, `pnpm store prune`, Docker's prune.
///
/// Only commands on a fixed list run, with arguments Ebb builds itself, and
/// never through a shell. Anything else stays "run it yourself". These
/// can't go to the Trash (Go's module files are read-only, pnpm's store is
/// shared, Docker's data lives in its VM), so they can't be put back
/// either; the app says so before running them.
public struct ToolCommandRunner: Sendable {
    public struct Plan: Equatable, Sendable {
        public let executable: String
        public let arguments: [String]
        /// Shown to the user, e.g. "go clean -modcache".
        public let display: String
    }

    public init() {}

    /// The command for `item`, if it's one Ebb is allowed to run and the
    /// tool is installed.
    public func plan(for item: Item) -> Plan? {
        guard let command = item.clearCommand else { return nil }
        let words = command.split(separator: " ").map(String.init)
        guard let tool = words.first, Self.allowed.contains(words), let executable = Self.locate(tool) else {
            return nil
        }
        return Plan(executable: executable, arguments: Array(words.dropFirst()), display: command)
    }

    public func canRun(_ item: Item) -> Bool {
        plan(for: item) != nil
    }

    public struct Outcome: Equatable, Sendable {
        public let item: Item
        public let succeeded: Bool
        public let detail: String
    }

    /// Runs each item's command, one at a time.
    public func run(_ items: [Item]) async -> [Outcome] {
        var outcomes: [Outcome] = []
        for item in items {
            guard let plan = plan(for: item) else {
                outcomes.append(Outcome(item: item, succeeded: false, detail: "Ebb doesn't run this command"))
                continue
            }
            let status = await Self.execute(plan)
            outcomes.append(Outcome(
                item: item, succeeded: status == 0,
                detail: status == 0 ? "ran \(plan.display)" : "\(plan.display) failed (exit \(status))"
            ))
        }
        return outcomes
    }

    /// Exactly these command lines, nothing else.
    static let allowed: Set<[String]> = [
        ["go", "clean", "-modcache"],
        ["pnpm", "store", "prune"],
        ["docker", "image", "prune", "--force", "--filter", "until=24h"],
        ["docker", "builder", "prune", "--all", "--force", "--filter", "until=24h"],
    ]

    static func locate(_ tool: String) -> String? {
        let fallbacks = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/local/go/bin",
                         NSHomeDirectory() + "/go/bin", NSHomeDirectory() + "/Library/pnpm",
                         "/Applications/Docker.app/Contents/Resources/bin"]
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return (path + fallbacks).map { $0 + "/" + tool }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func execute(_ plan: Plan) async -> Int32 {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: plan.executable)
                process.arguments = plan.arguments
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                    process.waitUntilExit()
                    continuation.resume(returning: process.terminationStatus)
                } catch {
                    continuation.resume(returning: -1)
                }
            }
        }
    }
}
