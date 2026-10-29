import Foundation

/// Read-only questions for `git`.
///
/// Ebb never runs a git command that writes: `GIT_OPTIONAL_LOCKS=0` stops
/// even the index refresh some read commands do.
public struct GitClient: Sendable {
    public let executable: String?

    public init(executable: String?) {
        self.executable = executable
    }

    /// Finds a usable `git`, once per process.
    public static func locate() -> GitClient {
        located
    }

    private static let located = findGit()

    /// On a Mac without developer tools `/usr/bin/git` is a stub that pops up
    /// an install dialog, so it only counts when a developer directory is set
    /// up.
    private static func findGit() -> GitClient {
        guard let git = Subprocess.locate("git", fallbacks: ["/usr/bin/git"]) else {
            return GitClient(executable: nil)
        }
        #if os(macOS)
        if git == "/usr/bin/git" {
            // /usr/bin/git only forwards to the developer tools' git. Check
            // that one exists, by reading the active developer folder, rather
            // than running xcode-select, which can be slow under load.
            guard let developer = activeDeveloperDirectory(),
                  FileManager.default.isExecutableFile(atPath: developer + "/usr/bin/git")
            else { return GitClient(executable: nil) }
        }
        #endif
        return GitClient(executable: git)
    }

    public var isAvailable: Bool { executable != nil }

    /// `DEVELOPER_DIR`, or the folder `xcode-select` points at.
    static func activeDeveloperDirectory() -> String? {
        if let fromEnvironment = ProcessInfo.processInfo.environment["DEVELOPER_DIR"], !fromEnvironment.isEmpty {
            return fromEnvironment
        }
        for link in ["/var/db/xcode_select_link", "/usr/share/xcode-select/xcode_dir_link"] {
            if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: link) { return target }
        }
        // Without a selection, macOS falls back to the Command Line Tools.
        let tools = "/Library/Developer/CommandLineTools"
        return FileManager.default.fileExists(atPath: tools) ? tools : nil
    }

    /// Which of `candidates` (paths relative to `root`) contain at least one
    /// file tracked by git. Returns `nil` when git can't answer, which callers
    /// treat as "unknown", not "untracked".
    public func pathsContainingTrackedFiles(in root: String, candidates: [String]) async -> Set<String>? {
        if candidates.isEmpty { return [] }
        guard let executable else { return nil }
        let arguments = ["-C", root, "ls-files", "-z", "--cached", "--"] + candidates
        let environment = ["GIT_OPTIONAL_LOCKS": "0", "GIT_TERMINAL_PROMPT": "0"]
        guard let output = await Subprocess.run(
            executable, arguments: arguments, environment: environment, timeout: 20
        ), output.status == 0 else {
            return nil
        }

        let tracked = output.stdout
            .split(separator: 0)
            .map { String(decoding: $0, as: UTF8.self) }
        var result = Set<String>()
        for candidate in candidates
        where tracked.contains(where: { $0 == candidate || $0.hasPrefix(candidate + "/") }) {
            result.insert(candidate)
        }
        return result
    }
}
