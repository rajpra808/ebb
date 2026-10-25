import Foundation
import Testing
@testable import ScanCore

@Suite("Active-work signals 3 to 5")
struct WorkSignalTests {
    /// An old project with leftovers, so only the signal under test can
    /// make it active.
    private func idleProject(_ fixture: Fixture, _ path: String = "code/app") throws -> String {
        let root = try fixture.project(path)
        try fixture.file("\(path)/node_modules/lib.js", size: 20_000)
        return root
    }

    @Test("Claude Code path encoding replaces everything but letters and digits")
    func claudeEncoding() {
        #expect(ClaudeCodeSessionSignal.encode("/Users/me/Desktop/personal_v2/POC /app")
            == "-Users-me-Desktop-personal-v2-POC--app")
        #expect(ClaudeCodeSessionSignal.encode("/Users/me/.config") == "-Users-me--config")
    }

    @Test("A recent Claude Code session protects the project and its subfolders")
    func claudeSession() async throws {
        let fixture = try Fixture()
        let root = try idleProject(fixture)
        let encoded = ClaudeCodeSessionSignal.encode(Paths.join(root, "packages/web"))
        let chat = try fixture.file(".claude/projects/\(encoded)/s1.jsonl")
        try fixture.ageEverything()
        try fixture.setAge(chat, days: 3)

        let result = try await fixture.scan()
        #expect(!result.reports(anythingOverlapping: root))
        let evidence = try #require(result.activeProjects.first?.signals)
        #expect(evidence.map(\.signal) == ["claude-code"])
        #expect(evidence.first?.detail == "Claude Code session 3 days ago")
    }

    @Test("An old Claude Code session doesn't count")
    func oldClaudeSession() async throws {
        let fixture = try Fixture()
        let root = try idleProject(fixture)
        try fixture.file(".claude/projects/\(ClaudeCodeSessionSignal.encode(root))/s1.jsonl")
        try fixture.ageEverything()

        let result = try await fixture.scan()
        #expect(result.activeProjects.isEmpty)
    }

    @Test("A recent Codex session with its cwd inside the project protects it")
    func codexSession() async throws {
        let fixture = try Fixture()
        let root = try idleProject(fixture)
        let session = try fixture.file(".codex/sessions/2026/10/22/rollout-1.jsonl")
        let meta = #"{"type":"session_meta","payload":{"id":"x","cwd":"\#(root)/api"}}"# + "\n{\"type\":\"message\"}\n"
        try meta.write(toFile: session, atomically: true, encoding: .utf8)
        let other = try fixture.file(".codex/sessions/2026/10/22/rollout-2.jsonl")
        try #"{"type":"session_meta","payload":{"cwd":"/somewhere/else"}}"#.write(toFile: other, atomically: true, encoding: .utf8)
        try fixture.ageEverything()
        try fixture.setAge(session, days: 2)
        try fixture.setAge(other, days: 2)

        let result = try await fixture.scan()
        #expect(!result.reports(anythingOverlapping: root))
        #expect(result.activeProjects.first?.signals.first?.detail == "Codex session in api 2 days ago")
    }

    @Test("A process running inside the project protects it")
    func runningProcess() async throws {
        let fixture = try Fixture()
        let root = try idleProject(fixture)
        try fixture.ageEverything()

        let processes = [
            RunningProcessSignal.Process(pid: 10, command: "node", workingFolder: Paths.join(root, "apps/web")),
            RunningProcessSignal.Process(pid: 11, command: "zsh", workingFolder: fixture.home),
        ]
        let result = try await fixture.scanner(processes: processes).scan()
        #expect(!result.reports(anythingOverlapping: root))
        #expect(result.activeProjects.first?.signals.first?.detail == "node is running in apps/web")
    }

    @Test("lsof cwd records are parsed into processes")
    func lsofCwdParsing() {
        let output = "p101\ncnode\nfcwd\nn/Users/me/code/app\np202\ncFinder\nfcwd\nn/\np303\nczsh\nfcwd\nn/Users/me\n"
        let processes = RunningProcessSignal.parse(Data(output.utf8))
        #expect(processes == [
            .init(pid: 101, command: "node", workingFolder: "/Users/me/code/app"),
            .init(pid: 303, command: "zsh", workingFolder: "/Users/me"),
        ])
    }

    @Test("A folder open in Cursor or VS Code recently protects the project")
    func editorRecents() async throws {
        let fixture = try Fixture()
        let root = try idleProject(fixture)
        #if os(macOS)
        let support = "Library/Application Support"
        #else
        let support = ".config"
        #endif
        let state = try fixture.file("\(support)/Cursor/User/workspaceStorage/h1/state.vscdb")
        let folderURL = URL(fileURLWithPath: root).absoluteString
        try #"{ "folder": "\#(folderURL)" }"#.write(
            toFile: Paths.join(Paths.parent(of: state), "workspace.json"), atomically: true, encoding: .utf8
        )
        try fixture.ageEverything()
        try fixture.setAge(state, days: 4)

        let result = try await fixture.scan()
        #expect(!result.reports(anythingOverlapping: root))
        #expect(result.activeProjects.first?.signals.first?.detail == "open in Cursor 4 days ago")
    }

    #if os(macOS)
    @Test("Xcode workspaces opened recently protect their project")
    func xcodeRecents() async throws {
        let fixture = try Fixture()
        let root = try fixture.project("code/App", marker: "App.xcodeproj/project.pbxproj")
        try fixture.file("code/App/build/out.o")
        let info: [String: Any] = [
            "WorkspacePath": Paths.join(root, "App.xcodeproj"),
            "LastAccessedDate": fixture.now.addingTimeInterval(-86_400 * 2),
        ]
        let plist = try fixture.file("Library/Developer/Xcode/DerivedData/App-x/info.plist")
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: URL(fileURLWithPath: plist))
        try fixture.ageEverything()

        let result = try await fixture.scan()
        #expect(result.activeProjects.map(\.path) == [root])
        #expect(result.activeProjects.first?.signals.first?.detail == "open in Xcode 2 days ago")
    }
    #endif
}
