import Foundation

/// Identifies a file's data on disk, shared by all of its hard links.
struct InodeKey: Hashable, Sendable {
    let device: UInt64
    let inode: UInt64
}

/// A file with more than one hard link, as seen inside one item.
struct HardLinkedFile: Sendable, Equatable {
    let allocatedBytes: Int64
    /// Total links the file system reports.
    let linkCount: UInt64
    /// How many of those links are inside the item.
    var linksSeen: Int
}

/// The raw numbers for one item, before hard links are reconciled across
/// the whole scan.
struct ItemMeasurement: Sendable {
    /// Bytes owned by this item alone: files with a single link, minus any
    /// blocks shared with APFS clones elsewhere.
    var privateBytes: Int64 = 0
    /// Blocks of single-link files that are shared with clones elsewhere.
    var cloneSharedBytes: Int64 = 0
    var hardLinks: [InodeKey: HardLinkedFile] = [:]
    /// The part of `privateBytes` taken by folders themselves (4 KB each on
    /// ext4, 0 on APFS).
    var folderBytes: Int64 = 0
    var fileCount = 0
    /// Newest modification date of the item or anything inside it.
    var newestModification: Date?

    /// Newest read of any file inside.
    var newestAccess: Date?

    mutating func noteModification(_ date: Date) {
        if newestModification.map({ date > $0 }) ?? true { newestModification = date }
    }

    mutating func noteAccess(_ date: Date) {
        if newestAccess.map({ date > $0 }) ?? true { newestAccess = date }
    }

    /// Last write, or last read too when reads count as use.
    func lastUsed(countingReads: Bool) -> Date? {
        guard countingReads, let access = newestAccess else { return newestModification }
        return max(access, newestModification ?? access)
    }
}

extension ItemMeasurement {
    init(_ precomputed: PrecomputedSize) {
        self.init()
        privateBytes = precomputed.allocatedBytes
        fileCount = precomputed.fileCount
        newestModification = precomputed.lastUsed
        newestAccess = precomputed.lastUsed
    }
}

enum MeasureOutcome: Sendable {
    case measured(ItemMeasurement)
    /// Something inside is protected; the whole item is left alone.
    case containsProtected(path: String, why: String)
    /// Part of it couldn't be read, so it can't be vouched for.
    case incomplete(path: String, why: String)
}

/// Measures allocated (on-disk) size, the way Finder's "size on disk" does,
/// rather than logical size.
///
/// Walks with `lstat` only: symlinks are counted as links, never followed,
/// and the walk doesn't cross onto another disk.
struct SizeMeasurer: Sendable {
    /// Returns why a file or folder inside an item is protected, if it is.
    typealias ProtectionCheck = @Sendable (_ name: String, _ path: String) -> String?

    let protection: ProtectionCheck

    func measure(_ path: String) -> MeasureOutcome {
        guard let root = FileSystem.status(atPath: path) else {
            return .incomplete(path: path, why: "disappeared during the scan")
        }
        var result = ItemMeasurement()
        guard root.isDirectory else {
            add(root, at: path, to: &result)
            return .measured(result)
        }

        result.privateBytes += root.allocatedSize
        result.folderBytes += root.allocatedSize
        result.newestModification = root.modificationDate
        var stack = [path]
        while let folder = stack.popLast() {
            let entries: [DirectoryEntry]
            do {
                entries = try FileSystem.entries(ofDirectory: folder)
            } catch {
                return .incomplete(path: folder, why: "can't read \(Paths.relative(folder, to: path))")
            }

            for entry in entries {
                let child = Paths.join(folder, entry.name)
                if let why = protection(entry.name, child) {
                    return .containsProtected(path: child, why: why)
                }
                guard let status = FileSystem.status(atPath: child) else { continue }
                if status.device != root.device {
                    return .incomplete(path: child, why: "contains another mounted volume")
                }
                if status.isDirectory {
                    // A folder's own date changes when files are added,
                    // removed or renamed, which counts as use.
                    result.privateBytes += status.allocatedSize
                    result.folderBytes += status.allocatedSize
                    result.noteModification(status.modificationDate)
                    stack.append(child)
                } else {
                    add(status, at: child, to: &result)
                }
            }
        }
        return .measured(result)
    }

    private func add(_ status: FileStatus, at path: String, to result: inout ItemMeasurement) {
        result.fileCount += 1
        result.noteModification(status.modificationDate)
        result.noteAccess(status.accessDate)

        if status.linkCount > 1 {
            let key = InodeKey(device: status.device, inode: status.inode)
            result.hardLinks[key, default: HardLinkedFile(
                allocatedBytes: status.allocatedSize, linkCount: status.linkCount, linksSeen: 0
            )].linksSeen += 1
            return
        }

        guard status.isRegularFile, status.allocatedSize > 0,
              let privateSize = FileSystem.privateAllocatedSize(atPath: path),
              privateSize < status.allocatedSize
        else {
            result.privateBytes += status.allocatedSize
            return
        }
        result.privateBytes += privateSize
        result.cloneSharedBytes += status.allocatedSize - privateSize
    }
}
