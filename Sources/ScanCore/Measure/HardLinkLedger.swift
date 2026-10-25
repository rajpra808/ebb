/// Turns per-item measurements into numbers that add up.
///
/// A hard-linked file's data is only freed when *every* link is gone. So
/// across one scan:
/// - a file whose links are all inside reported items is counted once, for
///   the first item (in report order) that holds a link to it;
/// - a file with links outside every reported item isn't freed by clearing,
///   so it's left out of the totals and reported as shared instead.
///
/// pnpm on Linux, and some Homebrew and Xcode setups, rely on hard links.
struct HardLinkLedger {
    struct Share: Equatable {
        /// Bytes clearing this item frees.
        let allocatedBytes: Int64
        /// Bytes on disk that stay because something else still uses them.
        let sharedBytes: Int64
    }

    /// - Parameter measurements: in report order. The result has the same
    ///   order.
    static func reconcile(_ measurements: [Measurement]) -> [Share] {
        var linksSeenInScan: [InodeKey: Int] = [:]
        for measurement in measurements {
            for (key, file) in measurement.hardLinks {
                linksSeenInScan[key, default: 0] += file.linksSeen
            }
        }

        var claimed = Set<InodeKey>()
        return measurements.map { measurement in
            var allocated = measurement.privateBytes
            var shared = measurement.cloneSharedBytes
            // Sorted so the result doesn't depend on dictionary order.
            let files = measurement.hardLinks.sorted {
                ($0.key.device, $0.key.inode) < ($1.key.device, $1.key.inode)
            }
            for (key, file) in files {
                let allLinksInScan = UInt64(linksSeenInScan[key] ?? 0) >= file.linkCount
                if !allLinksInScan {
                    shared += file.allocatedBytes
                } else if claimed.insert(key).inserted {
                    allocated += file.allocatedBytes
                }
            }
            return Share(allocatedBytes: allocated, sharedBytes: shared)
        }
    }
}
