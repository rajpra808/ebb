import Foundation

/// Category 9, DerivedData: Xcode's build folders, one per workspace.
///
/// Each folder's `info.plist` names the workspace it was built from, so it
/// is judged by that project: kept while the project is active, suggested
/// once it's inactive or gone. Folders for projects outside the scanned
/// roots are left alone because their activity is unknown.
struct DerivedDataCollector: Sendable {
    let category: Category
    let folder: String
    let options: ScanOptions
    let projects: [ProjectAssessment]

    func collect() -> Findings {
        let root = ScanOptions.canonical(options.expand(folder))
        guard let entries = try? FileSystem.entries(ofDirectory: root) else { return Findings() }
        let known = ProjectIndex(roots: projects.map(\.project.root))
        let byRoot = Dictionary(projects.map { ($0.project.root, $0) }, uniquingKeysWith: { first, _ in first })

        var findings = Findings()
        for entry in entries.sorted(by: { $0.name < $1.name }) where !entry.name.hasPrefix(".") {
            let path = Paths.join(root, entry.name)
            guard let status = FileSystem.status(atPath: path), status.isDirectory else { continue }

            guard let workspace = Self.workspacePath(of: path) else {
                // ModuleCache.noindex and friends: shared, rebuilt on demand.
                findings.candidates.append(candidate(path, reason: "Shared Xcode build cache, rebuilt as needed"))
                continue
            }
            let shown = abbreviated(workspace)
            if !FileSystem.exists(workspace) {
                findings.candidates.append(candidate(path, reason: "Built from \(shown), which no longer exists"))
                continue
            }
            guard let projectRoot = known.project(containing: workspace), let project = byRoot[projectRoot] else {
                findings.skipped.append(SkippedItem(
                    path: path, categoryID: category.id,
                    reason: SkipReason(.unverified, "\(shown) is outside the scanned folders")
                ))
                continue
            }
            if project.isActive {
                findings.skipped.append(SkippedItem(
                    path: path, categoryID: category.id,
                    reason: SkipReason(.activeProject, "in active project \(Paths.lastComponent(of: projectRoot))")
                ))
                continue
            }
            let inactive = project.lastActivity.map { "inactive \(Age.describe(from: $0, to: options.now))" }
                ?? "shows no activity"
            findings.candidates.append(candidate(path, reason: "Project \(Paths.lastComponent(of: projectRoot)) \(inactive)",
                                                 project: projectRoot))
        }
        return findings
    }

    private func candidate(_ path: String, reason: String, project: String? = nil) -> Candidate {
        Candidate(
            path: path, categoryID: category.id, comesBack: category.comesBack,
            preselected: category.preselected, projectPath: project, source: "DerivedData",
            describe: { _, _ in reason }
        )
    }

    private func abbreviated(_ path: String) -> String {
        path.hasPrefix(options.home + "/") ? "~" + path.dropFirst(options.home.count) : path
    }

    static func workspacePath(of derivedData: String) -> String? {
        let plist = Paths.join(derivedData, "info.plist")
        guard let status = FileSystem.status(atPath: plist), status.isRegularFile, status.logicalSize < 1_000_000,
              let data = FileManager.default.contents(atPath: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let workspace = info["WorkspacePath"] as? String, workspace.hasPrefix("/")
        else { return nil }
        return Paths.normalized(workspace)
    }
}

/// Category 9, simulators: devices whose iOS runtime is no longer installed.
/// They can't boot, so nothing is lost; `xcrun simctl delete` removes them.
struct UnavailableSimulatorCollector: Sendable {
    let category: Category

    func collect() async -> Findings {
        guard let xcrun = Self.xcrunWithXcode() else { return Findings() }
        let arguments = ["simctl", "list", "devices", "unavailable", "--json"]
        guard let output = await Subprocess.run(xcrun, arguments: arguments, timeout: 30), output.status == 0
        else { return Findings() }

        var findings = Findings()
        for device in Self.devices(fromJSON: output.stdout) {
            let name = device.name
            findings.candidates.append(Candidate(
                path: device.folder, categoryID: category.id, comesBack: .no,
                preselected: category.preselected, source: "Simulators",
                clearCommand: "xcrun simctl delete \(device.udid)",
                describe: { _, _ in "Simulator \(name); its runtime is no longer installed" }
            ))
        }
        return findings
    }

    struct Device: Equatable {
        let udid: String
        let name: String
        /// `.../CoreSimulator/Devices/<udid>`
        let folder: String
    }

    static func devices(fromJSON data: Data) -> [Device] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let runtimes = object["devices"] as? [String: [[String: Any]]]
        else { return [] }
        return runtimes.values.flatMap { $0 }.compactMap { device in
            guard device["isAvailable"] as? Bool == false,
                  let udid = device["udid"] as? String, !udid.contains("/"),
                  let dataPath = device["dataPath"] as? String, dataPath.hasPrefix("/")
            else { return nil }
            let folder = Paths.parent(of: Paths.normalized(dataPath))
            guard Paths.lastComponent(of: folder) == udid else { return nil }
            return Device(udid: udid, name: device["name"] as? String ?? udid, folder: folder)
        }.sorted { $0.folder < $1.folder }
    }

    /// `xcrun`, but only when full Xcode is the active developer folder:
    /// the Command Line Tools have no simulators, and on a Mac without
    /// either, `xcrun` opens an install dialog.
    static func xcrunWithXcode() -> String? {
        #if os(macOS)
        guard let output = Subprocess.runBlocking("/usr/bin/xcode-select", arguments: ["-p"], timeout: 5),
              output.status == 0,
              String(decoding: output.stdout, as: UTF8.self).contains(".app/Contents/Developer")
        else { return nil }
        return "/usr/bin/xcrun"
        #else
        return nil
        #endif
    }
}
