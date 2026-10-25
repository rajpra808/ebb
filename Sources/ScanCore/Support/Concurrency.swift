import Dispatch
import Foundation

enum BlockingIO {
    /// Runs blocking file-system work on a utility-QoS GCD thread.
    ///
    /// `readdir`/`lstat` block the calling thread. Running them directly in a
    /// task would tie up Swift's small cooperative pool, so they're handed to
    /// GCD, which can add threads. Callers bound the parallelism themselves.
    static func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: work())
            }
        }
    }
}

extension Sequence where Element: Sendable {
    /// Like `map`, but runs up to `maxConcurrency` transforms at a time.
    /// Results keep the order of the input.
    func concurrentMap<T: Sendable>(
        maxConcurrency: Int,
        _ transform: @escaping @Sendable (Element) async -> T
    ) async -> [T] {
        let elements = Array(self)
        guard !elements.isEmpty else { return [] }
        let width = Swift.max(1, Swift.min(maxConcurrency, elements.count))

        return await withTaskGroup(of: (Int, T).self, returning: [T].self) { group in
            var results = [T?](repeating: nil, count: elements.count)
            var next = 0

            func addNext() {
                let index = next
                let element = elements[index]
                group.addTask(priority: .utility) { (index, await transform(element)) }
                next += 1
            }

            for _ in 0..<width { addNext() }
            while let (index, value) = await group.next() {
                results[index] = value
                if next < elements.count { addNext() }
            }
            // Every slot is filled once the group drains.
            return results.compactMap { $0 }
        }
    }
}

/// A value guarded by a lock, for the few places where concurrent walkers
/// share state. Not used on hot paths.
final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) {
        self.value = value
    }

    func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}

/// Remembers one value per key (a scan), so a signal builds its index once
/// and every project reuses it. Building happens under the lock, so it runs
/// once even when many projects ask at the same moment.
final class PerScanCache<Value: Sendable>: @unchecked Sendable {
    private let stored = Locked<(key: String, value: Value)?>(nil)

    func value(for key: String, make: () -> Value) -> Value {
        stored.withLock { stored in
            if let stored, stored.key == key { return stored.value }
            let value = make()
            stored = (key, value)
            return value
        }
    }
}
