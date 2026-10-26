import Foundation
import Testing
@testable import ScanCore

@Suite("Categories: AI tools and models")
struct AIToolCategoryTests {
    // MARK: 2. Claude Code history

    @Test("Old Claude Code chats are suggested, never pre-selected; memory stays")
    func claudeHistory() async throws {
        let fixture = try Fixture()
        let project = ".claude/projects/-Users-me-code-app"
        let old = try fixture.file("\(project)/aaaa.jsonl", size: 50_000)
        let oldFolder = try fixture.file("\(project)/aaaa/tool-results/1.txt")
        let recent = try fixture.file("\(project)/bbbb.jsonl")
        try fixture.file("\(project)/memory/notes.md")
        let snapshot = try fixture.file(".claude/shell-snapshots/snapshot-zsh-1.sh")
        try fixture.file(".claude/settings.json", size: 20)
        try fixture.file(".claude/CLAUDE.md")
        try fixture.ageEverything(days: 45)
        try fixture.setAge(recent, days: 10)

        let result = try await fixture.scan()
        let items = result.items(in: "claude-code-history")
        #expect(Set(items.map(\.path)) == [old, Paths.parent(of: Paths.parent(of: oldFolder)), snapshot])
        #expect(items.allSatisfy { !$0.preselected && $0.comesBack == .no })
        #expect(result.item(at: old)?.reason == "Chat last written 45 days ago. Claude Code keeps chats 30 days by default")
        #expect(!result.reports(anythingOverlapping: fixture.absolute("\(project)/memory")))
        #expect(!result.reports(anythingOverlapping: fixture.absolute(".claude/settings.json")))
        #expect(result.totals.safeToClearBytes == 0)
    }

    @Test("A longer cleanupPeriodDays keeps Ebb away from younger chats")
    func claudeCleanupPeriod() async throws {
        let fixture = try Fixture()
        let chat = try fixture.file(".claude/projects/-Users-me-app/aaaa.jsonl")
        let settings = fixture.absolute(".claude/settings.json")
        try fixture.folder(".claude")
        try #"{ "cleanupPeriodDays": 90 }"#.write(toFile: settings, atomically: true, encoding: .utf8)
        try fixture.ageEverything(days: 60)

        let result = try await fixture.scan()
        #expect(result.item(at: chat) == nil)
        #expect(ClaudeHistory.cleanupPeriodDays(home: fixture.home) == 90)

        try fixture.setAge(chat, days: 100)
        let later = try await fixture.scan()
        #expect(later.item(at: chat)?.reason.hasSuffix("Claude Code is set to keep chats 90 days") == true)
    }

    // MARK: 3. Other agent history

    @Test("Old Codex, Gemini and Cursor history is suggested; config and auth aren't")
    func agentHistory() async throws {
        let fixture = try Fixture()
        let codexDay = try fixture.file(".codex/sessions/2026/04/20/rollout-1.jsonl")
        let recentDay = try fixture.file(".codex/sessions/2026/10/20/rollout-2.jsonl")
        let gemini = try fixture.file(".gemini/tmp/project-a/chats/c.json")
        let cursor = try fixture.file("Library/Application Support/Cursor/User/workspaceStorage/abc123/state.vscdb")
        let workspace = Paths.join(Paths.parent(of: cursor), "workspace.json")
        try #"{ "folder": "file:///Users/me/code/old%20site" }"#.write(toFile: workspace, atomically: true, encoding: .utf8)
        for path in [".codex/config.toml", ".codex/auth.json", ".gemini/settings.json", ".gemini/oauth_creds.json"] {
            try fixture.file(path, size: 50)
        }
        try fixture.ageEverything(days: 60)
        try fixture.setAge(recentDay, days: 5)

        let result = try await fixture.scan()
        let found = Set(result.items(in: "agent-history").map(\.path))
        #expect(found == [Paths.parent(of: codexDay), Paths.parent(of: Paths.parent(of: gemini)), Paths.parent(of: cursor)])
        #expect(result.item(at: Paths.parent(of: codexDay))?.reason == "Codex sessions from 2026/04/20, last written 60 days ago")
        #expect(result.item(at: Paths.parent(of: cursor))?.reason == "Cursor chats and state for /Users/me/code/old site, last opened 60 days ago")
        for path in [".codex/config.toml", ".codex/auth.json", ".gemini/settings.json", ".gemini/oauth_creds.json"] {
            #expect(!result.reports(anythingOverlapping: fixture.absolute(path)), "\(path)")
        }
    }

    // MARK: 4. Local models

    @Test("Ollama models count only blobs no other model shares")
    func ollamaModels() async throws {
        let fixture = try Fixture()
        let models = ".ollama/models"
        let shared = try fixture.file("\(models)/blobs/sha256-shared", size: 300_000)
        let onlyA = try fixture.file("\(models)/blobs/sha256-aaaa", size: 200_000)
        try fixture.file("\(models)/blobs/sha256-bbbb", size: 100_000)
        func manifest(_ blobs: [String]) -> String {
            let layers = blobs.map { #"{ "digest": "sha256:\#($0)", "size": 1 }"# }.joined(separator: ",")
            return #"{ "schemaVersion": 2, "layers": [\#(layers)] }"#
        }
        let manifestA = try fixture.file("\(models)/manifests/registry.ollama.ai/library/llama3.2/3b")
        let manifestB = try fixture.file("\(models)/manifests/registry.ollama.ai/library/llama3.2/1b")
        try manifest(["shared", "aaaa"]).write(toFile: manifestA, atomically: true, encoding: .utf8)
        try manifest(["shared", "bbbb"]).write(toFile: manifestB, atomically: true, encoding: .utf8)
        try fixture.ageEverything(days: 60)
        // Model B was loaded last week.
        try fixture.setLastRead("\(models)/blobs/sha256-bbbb", days: 7)

        let result = try await fixture.scan()
        let items = result.items(in: "local-models")
        #expect(items.map(\.path) == [manifestA])
        let item = try #require(items.first)
        let expectedSize = try #require(FileSystem.status(atPath: onlyA)).allocatedSize
        #expect(item.allocatedBytes == expectedSize)
        #expect(item.clearCommand == "ollama rm llama3.2:3b")
        #expect(item.comesBack == .redownload)
        #expect(!item.preselected)
        _ = shared
    }

    @Test("Ollama model names drop the default registry and namespace")
    func ollamaNames() {
        let root = "/m/manifests"
        #expect(OllamaCollector.modelName(manifest: "\(root)/registry.ollama.ai/library/qwen3/8b", manifestsRoot: root)
            == "qwen3:8b")
        #expect(OllamaCollector.modelName(manifest: "\(root)/registry.ollama.ai/someone/tool/latest", manifestsRoot: root)
            == "someone/tool:latest")
        #expect(OllamaCollector.modelName(manifest: "\(root)/hf.co/org/model/Q4_K_M", manifestsRoot: root)
            == "hf.co/org/model:Q4_K_M")
    }

    @Test("A model read recently counts as used even if downloaded long ago")
    func huggingFaceAccessTime() async throws {
        let fixture = try Fixture()
        let idle = try fixture.file(".cache/huggingface/hub/models--org--idle/blobs/a", size: 100_000)
        let used = try fixture.file(".cache/huggingface/hub/models--org--used/blobs/b", size: 100_000)
        try fixture.file(".cache/huggingface/hub/version.txt")
        try fixture.ageEverything(days: 90)
        try fixture.setLastRead(used, days: 3)

        let result = try await fixture.scan()
        let items = result.items(in: "local-models")
        let idleRepo = Paths.parent(of: Paths.parent(of: idle))
        #expect(items.map(\.path) == [idleRepo])
        #expect(result.item(at: idleRepo)?.reason == "Hugging Face download org/idle, last used 90 days ago")
    }
}

@Suite("Categories: build tools")
struct BuildToolCategoryTests {
    // MARK: 7. Other build outputs

    @Test("Rust, Swift and Gradle build folders in inactive projects are reported")
    func buildOutputs() async throws {
        let fixture = try Fixture()
        try fixture.project("code/rusty", marker: "Cargo.toml")
        try fixture.file("code/rusty/target/debug/rusty", size: 90_000)
        try fixture.project("code/swifty", marker: "Package.swift")
        try fixture.file("code/swifty/.build/debug/swifty", size: 40_000)
        try fixture.project("code/droid", marker: "build.gradle")
        try fixture.file("code/droid/.gradle/8.0/cache.bin")
        try fixture.file("code/droid/build/outputs/app.apk", size: 30_000)
        // `target` without Cargo.toml is somebody's folder.
        try fixture.project("code/site", marker: "package.json")
        try fixture.file("code/site/target/notes.md")
        try fixture.ageEverything()

        let result = try await fixture.scan()
        let found = Set(result.items(in: "build-outputs").map { Paths.relative($0.path, to: fixture.home) })
        #expect(found == ["code/rusty/target", "code/swifty/.build", "code/droid/.gradle", "code/droid/build"])
    }

    // MARK: 9. Xcode

    private func derivedData(_ fixture: Fixture, _ name: String, workspace: String) throws -> String {
        let folder = try fixture.folder("Library/Developer/Xcode/DerivedData/\(name)")
        try fixture.file("Library/Developer/Xcode/DerivedData/\(name)/Build/Products/app", size: 50_000)
        let info: [String: Any] = ["WorkspacePath": workspace, "LastAccessedDate": fixture.now.addingTimeInterval(-90 * 86_400)]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: Paths.join(folder, "info.plist")))
        return folder
    }

    @Test("DerivedData follows its project: inactive or gone is suggested, active or unknown is kept")
    func derivedData() async throws {
        let fixture = try Fixture()
        try fixture.project("code/OldApp", marker: "OldApp.xcodeproj/project.pbxproj")
        let busy = try fixture.project("code/BusyApp", marker: "BusyApp.xcodeproj/project.pbxproj")
        let old = try derivedData(fixture, "OldApp-abc", workspace: fixture.absolute("code/OldApp/OldApp.xcodeproj"))
        let active = try derivedData(fixture, "BusyApp-def", workspace: Paths.join(busy, "BusyApp.xcodeproj"))
        let gone = try derivedData(fixture, "Gone-ghi", workspace: fixture.absolute("code/Deleted/Gone.xcodeproj"))
        let unknown = try derivedData(fixture, "Far-jkl", workspace: Paths.join(fixture.outside, "Far/Far.xcodeproj"))
        try fixture.folder(Paths.join(fixture.outside, "Far/Far.xcodeproj"))
        let moduleCache = try fixture.file("Library/Developer/Xcode/DerivedData/ModuleCache.noindex/x.pcm")
        try fixture.ageEverything()
        try fixture.setAge(Paths.join(busy, "BusyApp.xcodeproj/project.pbxproj"), days: 2)

        let result = try await fixture.scan()
        let found = Set(result.items(in: "xcode").map(\.path))
        #expect(found == [old, gone, Paths.parent(of: moduleCache)])
        #expect(result.skip(at: active)?.reason.code == .activeProject)
        #expect(result.skip(at: unknown)?.reason.code == .unverified)
        #expect(result.item(at: old)?.reason == "Project OldApp inactive 60 days")
        #expect(result.item(at: gone)?.reason == "Built from ~/code/Deleted/Gone.xcodeproj, which no longer exists")
    }

    @Test("Device support keeps the newest version")
    func deviceSupport() async throws {
        let fixture = try Fixture()
        let base = "Library/Developer/Xcode/iOS DeviceSupport"
        let older = try fixture.file("\(base)/16.4 (20E247)/Symbols/dyld", size: 40_000)
        let newest = try fixture.file("\(base)/17.5 (21F79)/Symbols/dyld", size: 40_000)
        try fixture.ageEverything(days: 100)
        try fixture.setAge(Paths.parent(of: Paths.parent(of: newest)), days: 40)

        let result = try await fixture.scan()
        let found = result.items(in: "xcode").map(\.path)
        #expect(found == [Paths.parent(of: Paths.parent(of: older))])
    }

    @Test("Unavailable simulators are read from simctl's JSON")
    func simulators() {
        let json = """
        { "devices": {
          "com.apple.CoreSimulator.SimRuntime.iOS-16-4": [
            { "udid": "AAAA-1111", "name": "iPhone 14", "isAvailable": false,
              "dataPath": "/Users/me/Library/Developer/CoreSimulator/Devices/AAAA-1111/data" },
            { "udid": "BBBB-2222", "name": "iPhone 15", "isAvailable": true,
              "dataPath": "/Users/me/Library/Developer/CoreSimulator/Devices/BBBB-2222/data" },
            { "udid": "../evil", "name": "x", "isAvailable": false, "dataPath": "/tmp/x/data" }
          ] } }
        """
        let devices = UnavailableSimulatorCollector.devices(fromJSON: Data(json.utf8))
        #expect(devices == [.init(udid: "AAAA-1111", name: "iPhone 14",
                                  folder: "/Users/me/Library/Developer/CoreSimulator/Devices/AAAA-1111")])
    }

    @Test("Old archives are suggested, never pre-selected")
    func archives() async throws {
        let fixture = try Fixture()
        let old = try fixture.file("Library/Developer/Xcode/Archives/2026-01-10/App 1.0.xcarchive/Info.plist")
        let recent = try fixture.file("Library/Developer/Xcode/Archives/2026-09-10/App 1.1.xcarchive/Info.plist")
        try fixture.ageEverything(days: 120)
        try fixture.setAge(Paths.parent(of: recent), days: 40)
        try fixture.setAge(recent, days: 40)

        let result = try await fixture.scan()
        let items = result.items(in: "xcode-archives")
        #expect(items.map(\.path) == [Paths.parent(of: old)])
        #expect(items.allSatisfy { !$0.preselected && $0.comesBack == .no })
    }

    // MARK: 11. Docker

    @Test("Docker: only untagged, unused images and idle build cache count")
    func dockerParsing() throws {
        let json = """
        { "Images": [
            { "Repository": "<none>", "Tag": "<none>", "Containers": "0", "UniqueSize": "1.5GB",
              "CreatedAt": "2026-09-01 10:00:00 +0000 UTC" },
            { "Repository": "<none>", "Tag": "<none>", "Containers": "1", "UniqueSize": "900MB",
              "CreatedAt": "2026-09-01 10:00:00 +0000 UTC" },
            { "Repository": "<none>", "Tag": "<none>", "Containers": "0", "UniqueSize": "700MB",
              "CreatedAt": "2026-10-25 09:00:00 +0000 UTC" },
            { "Repository": "swift", "Tag": "6.0", "Containers": "0", "UniqueSize": "4.1GB",
              "CreatedAt": "2026-09-01 10:00:00 +0000 UTC" }
          ],
          "BuildCache": [
            { "InUse": false, "Size": "250MB", "LastUsedAt": "2026-10-01 10:00:00 +0000 UTC" },
            { "InUse": true, "Size": "100MB", "LastUsedAt": "2026-10-01 10:00:00 +0000 UTC" },
            { "InUse": false, "Size": "50MB" }
          ] }
        """
        let cutoff = try #require(DockerCollector.date("2026-10-24 12:00:00 +0000 UTC"))
        let usage = try #require(DockerCollector.parse(Data(json.utf8), recentlyChangedSince: cutoff))
        #expect(usage.danglingImages.bytes == 1_500_000_000)
        #expect(usage.danglingImages.count == 1)
        #expect(usage.buildCache.bytes == 250_000_000)
        #expect(usage.buildCache.count == 1)
    }

    @Test("Docker items pass the gate without touching the file system")
    func dockerVirtualItems() throws {
        let fixture = try Fixture()
        let gate = SafetyGate(
            neverTouch: NeverTouchList(home: fixture.home), neverTouchRules: [],
            activeProjects: ProjectIndex(roots: []), openFiles: OpenFiles(paths: []),
            userID: getuid(), now: fixture.now, recentlyChangedSince: fixture.now.addingTimeInterval(-86_400)
        )
        let candidate = Candidate(
            path: DockerCollector.buildCachePath, categoryID: "docker", comesBack: .yes(howTo: "rebuild"),
            preselected: true, clearCommand: "docker builder prune --all --force --filter until=24h", isEstimated: true,
            precomputed: PrecomputedSize(allocatedBytes: 250_000_000, fileCount: 3,
                                         lastUsed: fixture.now.addingTimeInterval(-5 * 86_400), paths: [], isVirtual: true),
            describe: { _, _ in "" }
        )
        guard case .accepted(let measurement) = gate.check(candidate) else {
            Issue.record("the Docker build cache item was rejected")
            return
        }
        #expect(measurement.privateBytes == 250_000_000)
    }

    // MARK: 13. Duplicates

    #if canImport(CryptoKit)
    @Test("Duplicates keep the oldest copy and skip projects, links and small files")
    func duplicates() async throws {
        let fixture = try Fixture()
        let original = try fixture.file("Documents/report.pdf", size: 2_000_000)
        let data = try Data(contentsOf: URL(fileURLWithPath: original))
        let copies = ["Downloads/report (1).pdf", "Desktop/old/report-copy.pdf"].map(fixture.absolute)
        for copy in copies {
            try fixture.folder(Paths.parent(of: Paths.relative(copy, to: fixture.home)))
            try data.write(to: URL(fileURLWithPath: copy))
        }
        // Same size, different contents after the first 64 KB.
        var different = data
        different[1_500_000] ^= 0xFF
        let lookalike = fixture.absolute("Downloads/report-v2.pdf")
        try different.write(to: URL(fileURLWithPath: lookalike))
        // A hard link is the same file, and a copy inside a project is source.
        try fixture.hardLink("Documents/report-link.pdf", to: original)
        try fixture.project("Desktop/app")
        let inProject = fixture.absolute("Desktop/app/assets/report.pdf")
        try fixture.folder("Desktop/app/assets")
        try data.write(to: URL(fileURLWithPath: inProject))
        // Small duplicates aren't worth it.
        let small = try fixture.file("Downloads/tiny.txt", size: 1000)
        try FileManager.default.copyItem(atPath: small, toPath: fixture.absolute("Documents/tiny.txt"))
        try fixture.ageEverything(days: 30)
        try fixture.setAge(original, days: 400)

        let result = try await fixture.scan()
        let items = result.items(in: "duplicates")
        #expect(Set(items.map(\.path)) == Set(copies))
        #expect(items.allSatisfy { !$0.preselected && $0.comesBack == .no })
        // The original and its hard link are one file; either name is right.
        let kept = ["~/Documents/report.pdf", "~/Documents/report-link.pdf"]
            .map { "Same contents as \($0), which is kept" }
        #expect(items.allSatisfy { kept.contains($0.reason) })
        #expect(result.item(at: original) == nil)
        #expect(result.item(at: lookalike) == nil)
        #expect(result.item(at: inProject) == nil)
    }
    #endif
}
