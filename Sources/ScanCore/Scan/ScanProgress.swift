import Dispatch

/// What a scan is doing right now, for a progress line or a progress bar.
public enum ScanProgress: Sendable, Equatable {
    case findingProjects(foldersSearched: Int, projectsFound: Int)
    case checkingProjects(checked: Int, total: Int)
    /// Looking for candidates; `what` is e.g. "Docker" or "temp files".
    case collecting(String)
    case applyingRules(ruleCount: Int)
    /// `current` is the item most recently measured.
    case measuring(checked: Int, total: Int, current: String?)
    case finished
}

/// Counts work from many threads and passes updates on at most ten times a
/// second, plus every phase change. The handler is called while a lock is
/// held, so updates arrive in order; it should return quickly.
final class ProgressReporter: @unchecked Sendable {
    private struct State {
        var folders = 0
        var projects = 0
        var checked = 0
        var lastUpdate: UInt64 = 0
    }

    private static let interval: UInt64 = 100_000_000

    private let handler: @Sendable (ScanProgress) -> Void
    private let state = Locked(State())

    init(_ handler: @escaping @Sendable (ScanProgress) -> Void) {
        self.handler = handler
    }

    /// Starts a phase: resets the "checked" counter and always reports.
    func begin(_ progress: ScanProgress) {
        state.withLock { state in
            state.checked = 0
            state.lastUpdate = DispatchTime.now().uptimeNanoseconds
            handler(progress)
        }
    }

    func searchedFolder(foundProject: Bool) {
        update { state in
            state.folders += 1
            if foundProject { state.projects += 1 }
            return .findingProjects(foldersSearched: state.folders, projectsFound: state.projects)
        }
    }

    func checkedProject(of total: Int) {
        update { state in
            state.checked += 1
            return .checkingProjects(checked: state.checked, total: total)
        }
    }

    func measured(_ path: String, of total: Int) {
        update { state in
            state.checked += 1
            return .measuring(checked: state.checked, total: total, current: path)
        }
    }

    private func update(_ change: (inout State) -> ScanProgress) {
        state.withLock { state in
            let progress = change(&state)
            let now = DispatchTime.now().uptimeNanoseconds
            guard now - state.lastUpdate >= Self.interval else { return }
            state.lastUpdate = now
            handler(progress)
        }
    }
}
