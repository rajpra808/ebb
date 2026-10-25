import Foundation

/// Runs a helper tool (`lsof`, `git`) and collects its output.
///
/// The child gets a deadline. If it doesn't finish in time it is terminated
/// and the caller gets `nil`, so a stuck tool can't stall a scan.
enum Subprocess {
    struct Output {
        let status: Int32
        let stdout: Data
    }

    static func run(
        _ executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval
    ) async -> Output? {
        await BlockingIO.run {
            runBlocking(executable, arguments: arguments, environment: environment, timeout: timeout)
        }
    }

    static func runBlocking(
        _ executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval
    ) -> Output? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        }
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return nil
        }
        // Our copy of the write end must go, or the reader never sees EOF.
        try? stdout.fileHandleForWriting.close()

        // Drain the pipe while the child runs; a full pipe would block it.
        let collected = Locked(Data())
        let reader = DispatchGroup()
        reader.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            collected.withLock { $0 = data }
            reader.leave()
        }

        let deadline = DispatchTime.now() + timeout
        if finished.wait(timeout: deadline) == .timedOut {
            process.terminate()
            _ = finished.wait(timeout: .now() + 1)
            return nil
        }
        // A grandchild that outlives the tool can keep the pipe open; don't
        // wait for it past the deadline.
        guard reader.wait(timeout: max(deadline, .now() + 1)) == .success else { return nil }
        return Output(status: process.terminationStatus, stdout: collected.withLock { $0 })
    }

    /// The first executable called `name` on `PATH`, then in `fallbacks`.
    static func locate(_ name: String, fallbacks: [String] = []) -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let candidates = path.split(separator: ":").map { Paths.join(String($0), name) } + fallbacks
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
