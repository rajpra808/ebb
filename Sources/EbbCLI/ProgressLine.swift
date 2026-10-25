#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import ScanCore

/// A one-line status on stderr that rewrites itself as the scan moves on,
/// and disappears when it's done. Only shown when stderr is a terminal, so
/// piped output and `--json` stay clean.
final class ProgressLine: @unchecked Sendable {
    // Callers (ScanCore's reporter) already serialize updates.

    private let home: String
    private var isShowing = false

    private init(home: String) {
        self.home = home
    }

    /// A handler for `Scanner.onProgress`, or nil when there's nowhere to
    /// show it.
    static func handler(home: String, enabled: Bool) -> (@Sendable (ScanProgress) -> Void)? {
        guard enabled, isatty(STDERR_FILENO) == 1 else { return nil }
        let line = ProgressLine(home: home)
        return { line.show($0) }
    }

    func show(_ progress: ScanProgress) {
        guard let text = Self.describe(progress, home: home) else {
            clear()
            return
        }
        write("\r\u{1B}[2K" + Self.fitted(text, width: Self.terminalWidth()))
        isShowing = true
    }

    private func clear() {
        guard isShowing else { return }
        write("\r\u{1B}[2K")
        isShowing = false
    }

    private func write(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }

    static func describe(_ progress: ScanProgress, home: String) -> String? {
        switch progress {
        case .findingProjects(let folders, let projects):
            return "  Looking for projects: \(grouped(folders)) folders searched, \(grouped(projects)) projects found"
        case .checkingProjects(let checked, let total):
            return "  Checking which projects are active: \(grouped(checked)) of \(grouped(total))"
        case .collectingCandidates:
            return "  Looking at caches, temp files and downloads"
        case .applyingRules(let count):
            return "  Applying \(plural(count, "custom rule"))"
        case .measuring(let checked, let total, let current):
            let path = current.map { "  " + abbreviate($0, home: home) } ?? ""
            return "  Measuring \(grouped(checked)) of \(grouped(total))\(path)"
        case .finished:
            return nil
        }
    }

    /// Cuts the middle out of long lines so the end of a path stays visible.
    static func fitted(_ text: String, width: Int) -> String {
        let limit = max(20, width - 1)
        guard text.count > limit else { return text }
        let keep = limit - 1
        return String(text.prefix(keep / 2)) + "…" + String(text.suffix(keep - keep / 2))
    }

    private static func terminalWidth() -> Int {
        var size = winsize()
        guard ioctl(STDERR_FILENO, UInt(TIOCGWINSZ), &size) == 0, size.ws_col > 0 else { return 80 }
        return Int(size.ws_col)
    }

    static func grouped(_ number: Int) -> String {
        let digits = String(number)
        var result = ""
        for (index, digit) in digits.enumerated() {
            if index > 0 && (digits.count - index) % 3 == 0 { result += "," }
            result.append(digit)
        }
        return result
    }
}
