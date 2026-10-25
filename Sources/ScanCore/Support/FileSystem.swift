#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// The subset of `lstat(2)` that the scanner cares about.
///
/// Every call is an `lstat`, never a `stat`: symbolic links describe
/// themselves and are never followed.
struct FileStatus: Sendable {
    let device: UInt64
    let inode: UInt64
    let mode: UInt32
    let linkCount: UInt64
    let logicalSize: Int64
    /// Bytes of storage allocated on disk (`st_blocks * 512`).
    let allocatedSize: Int64
    let modificationDate: Date
    /// Last read. macOS updates it on read (at most once a day per file), so
    /// it's a fair "last used" for files like models that are only read.
    let accessDate: Date
    /// When the file was created. Falls back to the modification date where
    /// the file system doesn't record it.
    let creationDate: Date
    let ownerID: UInt32
    /// BSD file flags. Always 0 on Linux.
    let flags: UInt32

    var isDirectory: Bool { mode & UInt32(S_IFMT) == UInt32(S_IFDIR) }
    var isRegularFile: Bool { mode & UInt32(S_IFMT) == UInt32(S_IFREG) }
    var isSymbolicLink: Bool { mode & UInt32(S_IFMT) == UInt32(S_IFLNK) }

    /// True for iCloud and File Provider placeholders whose contents live in
    /// the cloud. Listing or reading them would trigger a download.
    var isDataless: Bool {
        #if canImport(Darwin)
        return flags & UInt32(SF_DATALESS) != 0
        #else
        return false
        #endif
    }
}

struct DirectoryEntry: Sendable {
    enum Kind: Sendable {
        case directory, regularFile, symbolicLink, other, unknown
    }

    let name: String
    let kind: Kind
}

struct FileSystemError: Error, CustomStringConvertible {
    let path: String
    let code: Int32

    var description: String { "\(path): \(String(cString: strerror(code)))" }
}

/// Thin, synchronous wrappers over POSIX calls.
///
/// Foundation's `FileManager` enumerators are convenient but slow for
/// millions of entries and hide whether symlinks were followed. The scanner
/// walks with `readdir` + `lstat` instead and stays in control of both.
enum FileSystem {
    static func status(atPath path: String) -> FileStatus? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        #if canImport(Darwin)
        let modified = info.st_mtimespec
        let accessed = info.st_atimespec
        let created = info.st_birthtimespec
        let flags = UInt32(info.st_flags)
        #else
        let modified = info.st_mtim
        let accessed = info.st_atim
        let created = info.st_mtim
        let flags: UInt32 = 0
        #endif
        return FileStatus(
            device: UInt64(truncatingIfNeeded: info.st_dev),
            inode: UInt64(truncatingIfNeeded: info.st_ino),
            mode: UInt32(truncatingIfNeeded: info.st_mode),
            linkCount: UInt64(truncatingIfNeeded: info.st_nlink),
            logicalSize: Int64(info.st_size),
            allocatedSize: Int64(info.st_blocks) * 512,
            modificationDate: date(modified),
            accessDate: date(accessed),
            creationDate: date(created),
            ownerID: UInt32(truncatingIfNeeded: info.st_uid),
            flags: flags
        )
    }

    private static func date(_ time: timespec) -> Date {
        Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1e9)
    }

    static func exists(_ path: String) -> Bool {
        status(atPath: path) != nil
    }

    /// Lists a directory without following symlinks and without `.`/`..`.
    static func entries(ofDirectory path: String) throws -> [DirectoryEntry] {
        guard let directory = opendir(path) else {
            throw FileSystemError(path: path, code: errno)
        }
        defer { closedir(directory) }

        var result: [DirectoryEntry] = []
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
            }
            if name == "." || name == ".." { continue }
            result.append(DirectoryEntry(name: name, kind: kind(ofDirectoryEntryType: entry.pointee.d_type)))
        }
        return result
    }

    /// The canonical absolute path, with symlinks such as `/var` → `/private/var`
    /// resolved. Used only on scan roots, never while walking.
    static func canonicalPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func hasExtendedAttribute(_ name: String, atPath path: String) -> Bool {
        #if canImport(Darwin)
        return getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW) >= 0
        #else
        // Only used for the macOS quarantine flag, which Linux doesn't set.
        return false
        #endif
    }

    /// Bytes that belong to this file alone and would be freed by deleting it.
    ///
    /// APFS clones (`cp -c`, and pnpm on macOS) share blocks with other
    /// files, so `st_blocks` overstates what deleting one copy gives back.
    /// Returns `nil` where the file system can't tell us (non-APFS, Linux).
    static func privateAllocatedSize(atPath path: String) -> Int64? {
        #if canImport(Darwin)
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE)

        // The kernel packs the reply: a u_int32_t length, then an off_t at
        // byte 4. A Swift tuple would pad the off_t to byte 8, so use bytes.
        var buffer = [UInt8](repeating: 0, count: 16)
        let options = UInt32(FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW)
        let status = buffer.withUnsafeMutableBytes { raw in
            getattrlist(path, &request, raw.baseAddress, raw.count, options)
        }
        guard status == 0 else { return nil }
        return buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: Int64.self) }
        #else
        return nil
        #endif
    }

    private static func kind(ofDirectoryEntryType type: UInt8) -> DirectoryEntry.Kind {
        switch Int32(type) {
        case Int32(DT_DIR): return .directory
        case Int32(DT_REG): return .regularFile
        case Int32(DT_LNK): return .symbolicLink
        case Int32(DT_UNKNOWN): return .unknown
        default: return .other
        }
    }
}
