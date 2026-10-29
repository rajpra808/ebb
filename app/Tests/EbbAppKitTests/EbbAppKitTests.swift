#if canImport(Darwin)
import Darwin
#endif
import EbbClean
import Foundation
import Testing
@testable import EbbAppKit
@testable import ScanCore

/// A Trash inside the test folder.
private struct FolderTrash: TrashBin {
    let folder: String

    func moveToTrash(_ path: String) throws -> String {
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let target = folder + "/" + UUID().uuidString + "-" + (path as NSString).lastPathComponent
        try FileManager.default.moveItem(atPath: path, toPath: target)
        return target
    }
}

private func item(_ path: String, _ category: String, _ bytes: Int64, preselected: Bool = true,
                  comesBack: ComesBack = .yes(howTo: "npm i"), project: String? = nil, source: String? = nil,
                  command: String? = nil) -> Item {
    Item(path: path, categoryID: category, allocatedBytes: bytes, sharedBytes: 0, isEstimated: false,
         fileCount: 1, lastUsed: nil, comesBack: comesBack, reason: "", preselected: preselected,
         projectPath: project, source: source, ruleID: nil, clearCommand: command, packageManaged: false)
}

@Suite("App presentation")
struct PresentationTests {
    @Test("Items read as a short title in their project")
    func titles() {
        let home = "/Users/me"
        let modules = ItemPresentation(item("/Users/me/code/site/node_modules", "node-leftovers", 1,
                                            project: "/Users/me/code/site"), home: home)
        #expect(modules.title == "node_modules")
        #expect(modules.context == "site")
        #expect(modules.path == "~/code/site/node_modules")
        #expect(modules.badge == .comesBack)

        let npm = ItemPresentation(item("/Users/me/.npm/_cacache", "package-caches", 1, source: "npm"), home: home)
        #expect(npm.title == "npm cache")
        let pnpm = ItemPresentation(item("/Users/me/Library/pnpm/store", "package-caches", 1, source: "pnpm store"),
                                    home: home)
        #expect(pnpm.title == "pnpm store")

        let docker = ItemPresentation(item("docker:build-cache", "docker", 1, source: "build cache"), home: home)
        #expect(docker.title == "Docker build cache")
        #expect(docker.path.isEmpty)

        #expect(ItemPresentation(item("/x", "duplicates", 1, comesBack: .no), home: home).badge == .goneForGood)
        #expect(ItemPresentation(item("/x", "local-models", 1, comesBack: .redownload), home: home).badge == .redownload)
    }

    @Test("Safe-to-clear line says honestly how items come back")
    func safeToClearDetail() {
        #expect(SafeToClearText.detail(for: []) == "0 items")
        #expect(SafeToClearText.detail(for: [item("/a", "x", 1)]) == "1 item · all regenerate")
        #expect(SafeToClearText.detail(for: [item("/a", "x", 1), item("/b", "y", 1, comesBack: .redownload)])
            == "2 items · 1 regenerate, 1 re-download")
    }

    @Test("Dates read as today, yesterday or a short date")
    func dates() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 21)))
        #expect(DateText.describe(now.addingTimeInterval(-3600), now: now, calendar: calendar).hasPrefix("today, "))
        #expect(DateText.describe(now.addingTimeInterval(-86_400), now: now, calendar: calendar).hasPrefix("yesterday, "))
        #expect(!DateText.describe(now.addingTimeInterval(-10 * 86_400), now: now, calendar: calendar).hasPrefix("yesterday"))
    }
}

@Suite("App selection")
struct SelectionTests {
    let result: ScanResult

    init() throws {
        result = try ScanResult.sample(items: [
        item("/a/node_modules", "node-leftovers", 3_000, project: "/a"),
        item("/b/.venv", "python-venvs", 2_000, project: "/b"),
        item("/m/model", "local-models", 5_000, preselected: false, comesBack: .redownload),
        item("/d/copy.pdf", "duplicates", 1_000, preselected: false, comesBack: .no),
        item("/s/store", "package-caches", 9_000, command: "ollama rm llama3"),
    ])
    }

    @Test("Starts from the pre-selection, without command-cleared items")
    func preselection() {
        let selection = Selection(preselectedFrom: result)
        #expect(selection.paths == ["/a/node_modules", "/b/.venv"])
        let totals = selection.totals(in: result)
        #expect(totals.count == 2)
        #expect(totals.bytes == 5_000)
        #expect(totals.comesBack == 5_000)
    }

    @Test("Toggling adds to the right comes-back bucket; commands Ebb may not run can't be ticked")
    func toggling() {
        var selection = Selection(preselectedFrom: result)
        let items = result.items
        selection.toggle(items[2])
        selection.toggle(items[3])
        selection.toggle(items[4])
        selection.toggle(items[0])
        let totals = selection.totals(in: result)
        #expect(totals.count == 3)
        #expect(totals.comesBack == 2_000)
        #expect(totals.redownload == 5_000)
        #expect(totals.goneForGood == 1_000)
    }

    @Test("Filters split pre-selected from worth-a-look")
    func filters() {
        let items = result.items
        #expect(items.filter(RecommendationFilter.all.includes).count == 5)
        #expect(items.filter(RecommendationFilter.comesBack.includes).count == 3)
        #expect(items.filter(RecommendationFilter.needsALook.includes).count == 2)
    }

    @Test("Removing cleaned items recomputes the totals")
    func removing() {
        let after = result.removingItems(at: ["/a/node_modules"])
        #expect(after.items.count == 4)
        #expect(after.totals.safeToClearBytes == 11_000)
    }

    @Test("The menu splits what Move to Trash clears from what needs a tool command")
    func splitByKind() {
        let trash = CategorySummary.safeToClear(in: result, which: .trash)
        let tools = CategorySummary.safeToClear(in: result, which: .toolCommand)
        #expect(trash.map(\.id) == ["node-leftovers", "python-venvs"])
        #expect(tools.map(\.id) == ["package-caches"])
        #expect(tools.first?.commands == ["ollama rm llama3"])
        #expect(trash.allSatisfy { $0.commands.isEmpty })
    }

    @Test("Category summaries are pre-selected only, biggest first")
    func summaries() {
        let rows = CategorySummary.safeToClear(in: result)
        #expect(rows.map(\.id) == ["package-caches", "node-leftovers", "python-venvs"])
        #expect(rows.first?.detail == "")
        #expect(rows[1].detail == "1 inactive project")
    }
}

@Suite("App model")
@MainActor
struct AppModelTests {
    @Test("Scan, clean the selection, then put it back")
    func scanCleanPutBack() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ebb-app-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root + "/Users/me", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        // Canonical, like ScanCore's paths: /var/folders → /private/var/folders.
        let base = try canonical(root)
        let home = base + "/Users/me"
        let installer = home + "/Downloads/Tool.dmg"
        try FileManager.default.createDirectory(atPath: home + "/Downloads", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: base + "/tmp", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: installer, contents: Data(repeating: 7, count: 50_000))
        let old = Date().addingTimeInterval(-60 * 86_400)
        for path in [installer, home + "/Downloads"] {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: path)
        }

        let options = ScanOptions(home: home, temporaryDirectory: base + "/tmp", checkOpenFiles: false,
                                  queryTools: false, maxConcurrency: 2)
        let model = AppModel(options: options, trash: FolderTrash(folder: base + "/Trash"))
        #expect(model.result == nil)

        await model.scan()
        #expect(model.result?.items.map(\.path) == [installer])
        #expect(model.selectionTotals.count == 1)
        // The result is kept for the next launch.
        #expect(AppModel(options: options).result?.items.map(\.path) == [installer])

        await model.cleanSelection(source: "test")
        #expect(!FileManager.default.fileExists(atPath: installer))
        #expect(model.result?.items.isEmpty == true)
        #expect(model.selectionTotals.count == 0)
        #expect(model.history.count == 1)
        #expect(model.bytesInTrash > 0)
        #expect(model.freedThisMonth.cleans == 1)
        #expect(model.notice?.hasPrefix("Moved 1 item") == true)

        let record = try #require(model.history.first)
        model.putBack(record)
        #expect(FileManager.default.fileExists(atPath: installer))
        #expect(model.bytesInTrash == 0)
        #expect(model.freedThisMonth.bytes == 0)
    }
}

private func canonical(_ path: String) throws -> String {
    guard let resolved = realpath(path, nil) else { throw CocoaError(.fileNoSuchFile) }
    defer { free(resolved) }
    return String(cString: resolved)
}

extension ScanResult {
    static func sample(items: [Item]) throws -> ScanResult {
        let categories = ["node-leftovers", "python-venvs", "local-models", "duplicates", "package-caches"].map {
            Category(id: $0, number: 0, title: $0, summary: "", comesBack: .yes(howTo: ""), ruleDescription: "",
                     preselected: true)
        }
        return ScanResult(
            formatVersion: 1, startedAt: Date(), durationSeconds: 1, roots: [], activeDays: 14,
            categories: categories, items: items, skipped: [], activeProjects: [],
            totals: DiskScanner.totals(of: items, categories: categories), warnings: []
        )
    }
}
