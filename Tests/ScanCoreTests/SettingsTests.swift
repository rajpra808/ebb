import Foundation
import Testing
@testable import ScanCore

@Suite("Settings")
struct SettingsTests {
    @Test("A partial settings file keeps defaults for everything it doesn't mention")
    func partialFile() throws {
        let json = #"{ "activeDays": 30, "agent": { "isEnabled": true } }"#
        let settings = try JSONDecoder().decode(EbbSettings.self, from: Data(json.utf8))
        #expect(settings.activeDays == 30)
        #expect(settings.agent.isEnabled)
        #expect(settings.agent.notifyThresholdGB == 2)
        #expect(settings.agent.minimumBatteryPercent == 30)
        #expect(settings.scanFolders == ["~"])
        #expect(settings.showSizeInMenuBar)
        #expect(!settings.completedFirstRun)
    }

    @Test("Settings round-trip, and a broken file falls back to defaults")
    func store() throws {
        let fixture = try Fixture()
        let store = SettingsStore(fileURL: URL(fileURLWithPath: fixture.absolute("support/settings.json")))
        #expect(store.load() == EbbSettings())

        var settings = EbbSettings()
        settings.activeDays = 7
        settings.alwaysKeep = ["~/code/keep"]
        settings.agent.earliestMinuteOfDay = 600
        try store.save(settings)
        #expect(store.load() == settings)

        try "{ not json".write(to: store.fileURL, atomically: true, encoding: .utf8)
        #expect(store.load() == EbbSettings())
    }

    @Test("Switched-off categories and signals are left out of the scan")
    func disabling() async throws {
        let fixture = try Fixture()
        try fixture.project("code/app")
        try fixture.file("code/app/node_modules/x.js")
        try fixture.file("Downloads/old.dmg")
        let edit = try fixture.file("code/app/main.ts")
        try fixture.ageEverything()
        try fixture.setAge(edit, days: 2)

        var settings = EbbSettings()
        settings.disabledCategories = ["old-installers"]
        settings.disabledSignals = ["recent-edit"]
        var options = fixture.options()
        options.projectRoots = [fixture.home]
        let scanner = DiskScanner.configured(settings: settings, options: options,
                                             catalog: try CategoryCatalog.builtIn(), rules: [])
        #expect(!scanner.signals.contains { $0.id == "recent-edit" })
        #expect(!scanner.catalog.definitions.contains { $0.category.id == "old-installers" })

        let result = await scanner.scan()
        // Without the edit signal the project is inactive, and installers are off.
        #expect(result.items.map(\.categoryID) == ["node-leftovers"])
    }

    @Test("Always keep protects a project and any path")
    func alwaysKeep() async throws {
        let fixture = try Fixture()
        let project = try fixture.project("code/keep")
        try fixture.file("code/keep/node_modules/x.js")
        let installer = try fixture.file("Downloads/License.dmg")
        try fixture.file("Downloads/other.dmg")
        try fixture.ageEverything()

        var settings = EbbSettings()
        settings.alwaysKeep = ["~/code/keep", installer]
        let scanner = DiskScanner.configured(settings: settings, options: fixture.options(),
                                             catalog: try CategoryCatalog.builtIn(), rules: [])
        let result = await scanner.scan()
        #expect(!result.reports(anythingOverlapping: project))
        #expect(result.activeProjects.first?.signals.map(\.signal) == ["pinned"])
        #expect(result.item(at: installer) == nil)
        #expect(result.skip(at: installer)?.reason.detail == "you chose Always keep for it")
        #expect(result.item(at: fixture.absolute("Downloads/other.dmg")) != nil)
    }
}
