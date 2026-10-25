/// A folder that looks like a software project.
public struct Project: Sendable, Equatable {
    public let root: String
    /// The marker files or folders that identified it, e.g. `package.json`.
    public let markers: [String]
}

/// Finds projects under the scan roots.
///
/// A project is the *outermost* folder with a marker (spec §4). Folders
/// inside it, including nested packages in a monorepo, belong to it: if any
/// part is active, all of it is. That errs toward keeping things.
struct ProjectDiscovery: Sendable {
    static let markerNames: Set<String> = [
        ".git", "package.json", "pyproject.toml", "requirements.txt", "Cargo.toml",
        "Package.swift", "go.mod", "build.gradle", "build.gradle.kts",
    ]
    static let markerExtensions: Set<String> = ["xcodeproj"]

    /// Folders that are dependency trees, not places people keep projects.
    /// Each package inside them has its own `package.json` and would look
    /// like a project.
    static let dependencyFolderNames: Set<String> = [
        "node_modules", "bower_components", "site-packages", "Pods",
    ]

    /// macOS packages: folders that Finder shows as one file. Nobody keeps
    /// projects inside an app bundle or a photo library.
    static let packageExtensions: Set<String> = [
        "app", "appex", "bundle", "framework", "kext", "plugin", "xpc",
        "photoslibrary", "photolibrary", "musiclibrary", "tvlibrary", "imovielibrary",
        "fcpbundle", "logicx", "band", "aplibrary", "lrdata",
        "rtfd", "pages", "numbers", "key", "sparsebundle", "dmgpart",
        "vmwarevm", "pvm", "utm", "xcarchive", "docarchive", "xcworkspace",
    ]

    let excluded: PathSet
    let allowOtherVolumes: Bool
    let maxConcurrency: Int
    var progress: ProgressReporter?

    func projects(under roots: [String]) async -> [Project] {
        var found: [Project] = []
        for root in roots {
            guard let status = FileSystem.status(atPath: root), status.isDirectory else { continue }
            found += await projects(under: root, device: status.device)
        }
        return found.sorted { $0.root < $1.root }
    }

    private func projects(under root: String, device: UInt64) async -> [Project] {
        // Split the top two levels into independent subtrees so they can be
        // walked in parallel; a home folder usually has a few big ones.
        var frontier: [String] = []
        var found: [Project] = []
        for child in subfolders(of: root, device: device) {
            switch visit(child, device: device) {
            case .project(let project): found.append(project)
            case .folder(let children): frontier += children
            case .skip: break
            }
        }

        let subtrees = await frontier.concurrentMap(maxConcurrency: maxConcurrency) { folder in
            await BlockingIO.run { walk(folder, device: device) }
        }
        return found + subtrees.flatMap { $0 }
    }

    private enum Visit {
        case project(Project)
        case folder(children: [String])
        case skip
    }

    /// Looks at one folder: either it's a project, or we keep looking inside.
    private func visit(_ folder: String, device: UInt64) -> Visit {
        guard let entries = try? FileSystem.entries(ofDirectory: folder) else { return .skip }
        let markers = entries.compactMap { entry -> String? in
            if Self.markerNames.contains(entry.name) { return entry.name }
            if let ext = Paths.fileExtension(of: entry.name), Self.markerExtensions.contains(ext) {
                return entry.name
            }
            return nil
        }
        progress?.searchedFolder(foundProject: !markers.isEmpty)
        if !markers.isEmpty {
            return .project(Project(root: folder, markers: markers.sorted()))
        }
        return .folder(children: subfolders(of: folder, entries: entries, device: device))
    }

    private func walk(_ start: String, device: UInt64) -> [Project] {
        var found: [Project] = []
        var stack = [start]
        while let folder = stack.popLast() {
            switch visit(folder, device: device) {
            case .project(let project): found.append(project)
            case .folder(let children): stack += children
            case .skip: break
            }
        }
        return found
    }

    private func subfolders(of folder: String, device: UInt64) -> [String] {
        guard let entries = try? FileSystem.entries(ofDirectory: folder) else { return [] }
        return subfolders(of: folder, entries: entries, device: device)
    }

    private func subfolders(of folder: String, entries: [DirectoryEntry], device: UInt64) -> [String] {
        entries.compactMap { entry in
            guard entry.kind == .directory || entry.kind == .unknown else { return nil }
            let name = entry.name
            // Hidden folders at this level belong to tools (~/.npm, ~/.nvm,
            // ~/.cargo); they hold installed packages, not your projects.
            if name.hasPrefix(".") || Self.dependencyFolderNames.contains(name) { return nil }
            if let ext = Paths.fileExtension(of: name), Self.packageExtensions.contains(ext) { return nil }

            let path = Paths.join(folder, name)
            if excluded.contains(path) { return nil }
            guard let status = FileSystem.status(atPath: path), status.isDirectory,
                  !status.isDataless,
                  allowOtherVolumes || status.device == device
            else { return nil }
            return path
        }
    }
}
