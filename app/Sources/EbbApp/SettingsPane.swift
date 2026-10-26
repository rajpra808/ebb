import AppKit
import EbbAppKit
import ScanCore
import ServiceManagement
import SwiftUI

/// Settings: daily agent, active work, folders, never touch, rules,
/// categories, about.
struct SettingsPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PaneHeader(title: "Settings", subtitle: "Changes apply from the next scan.")
                NoticeBar()
                DailyAgentSection()
                ActiveWorkSection()
                FoldersSection()
                NeverTouchSection()
                RulesSection()
                CategoriesSection()
                AboutSection()
            }
            .padding(28)
            .frame(maxWidth: 820, alignment: .leading)
        }
    }
}

/// A titled card of settings rows.
private struct SettingsSection<Content: View>: View {
    let title: String
    var footnote: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Card {
                VStack(alignment: .leading, spacing: 12) { content }
            }
            if let footnote {
                Text(footnote).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct DailyAgentSection: View {
    @Environment(AppModel.self) private var model
    @State private var launchAtLogin = LoginItem.isEnabled

    var body: some View {
        @Bindable var model = model
        SettingsSection(title: "Daily agent",
                        footnote: "The agent only scans. Cleaning always needs a click from you.") {
            Toggle("Scan once a day and notify me when it's worth it", isOn: Binding(
                get: { model.settings.agent.isEnabled },
                set: { enabled in
                    guard let executable = Bundle.main.executablePath else { return }
                    model.setAgentEnabled(enabled, executable: executable)
                    if enabled { Task { _ = await SystemNotifier.requestPermission() } }
                }
            ))
            if model.settings.agent.isEnabled, let minute = model.settings.agent.earliestMinuteOfDay {
                Text("Scans after \(String(format: "%02d:%02d", minute / 60, minute % 60)) each day, once the Mac is idle, "
                    + "and catches up after sleep.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let paused = model.pauseDescription {
                HStack {
                    Label(paused, systemImage: "pause.circle").foregroundStyle(Theme.warning)
                    Spacer()
                    Button("Resume") { model.resumeDailyScans() }
                }
            } else if model.settings.agent.isEnabled {
                Menu("Pause daily scans") {
                    Button("For a day") { model.pauseDailyScans(days: 1) }
                    Button("For a week") { model.pauseDailyScans(days: 7) }
                    Button("Until I resume") { model.pauseDailyScans(days: nil) }
                }
                .fixedSize()
            }
            Picker("Notify when at least", selection: $model.settings.agent.notifyThresholdGB) {
                ForEach([1.0, 2, 5, 10, 20], id: \.self) { Text("\(Int($0)) GB").tag($0) }
            }
            .frame(maxWidth: 320)
            Picker("On battery, only above", selection: $model.settings.agent.minimumBatteryPercent) {
                ForEach([20, 30, 50, 80], id: \.self) { Text("\($0)%").tag($0) }
            }
            .frame(maxWidth: 320)
            Divider()
            Toggle("Show the size in the menu bar", isOn: $model.settings.showSizeInMenuBar)
            Toggle("Open Ebb at login", isOn: Binding(
                get: { launchAtLogin },
                set: { enabled in
                    launchAtLogin = LoginItem.set(enabled)
                    if launchAtLogin != enabled { NSSound.beep() }
                }
            ))
        }
    }
}

private struct ActiveWorkSection: View {
    @Environment(AppModel.self) private var model

    private static let signals: [(id: String, title: String)] = [
        ("recent-edit", "File edits"), ("git", "Git activity"), ("claude-code", "Claude Code sessions"),
        ("codex", "Codex sessions"), ("process", "Running processes"), ("editor", "Open in an editor"),
    ]

    var body: some View {
        @Bindable var model = model
        SettingsSection(title: "Active work",
                        footnote: "A project with any of these signals is skipped completely.") {
            Picker("A project is active if it was used in the last", selection: $model.settings.activeDays) {
                Text("7 days").tag(7)
                Text("14 days").tag(14)
                Text("30 days").tag(30)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 520)
            ForEach(Self.signals, id: \.id) { signal in
                Toggle(signal.title, isOn: Binding(
                    get: { !model.settings.disabledSignals.contains(signal.id) },
                    set: { on in
                        model.settings.disabledSignals.removeAll { $0 == signal.id }
                        if !on { model.settings.disabledSignals.append(signal.id) }
                    }
                ))
            }
        }
    }
}

private struct FoldersSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        SettingsSection(title: "Folders") {
            Text("Look for projects in").font(.callout.weight(.medium))
            PathList(paths: $model.settings.scanFolders, home: model.home)
            Text("Never look in").font(.callout.weight(.medium))
            PathList(paths: $model.settings.excludedFolders, home: model.home)
            Divider()
            Toggle("Include external disks and network volumes", isOn: $model.settings.includeOtherVolumes)
            Toggle("Include app caches in ~/Library/Caches", isOn: $model.settings.includeLibraryCaches)
        }
    }
}

/// A list of folders with remove buttons and an Add Folder button.
private struct PathList: View {
    @Binding var paths: [String]
    let home: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(paths, id: \.self) { path in
                HStack {
                    Text(ItemPresentation.abbreviate(path == "~" ? home : path, home: home)).font(.callout.monospaced())
                    Spacer()
                    Button("Remove") { paths.removeAll { $0 == path } }.buttonStyle(.link)
                }
            }
            Button("Add Folder…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.allowsMultipleSelection = true
                panel.directoryURL = URL(fileURLWithPath: home)
                guard panel.runModal() == .OK else { return }
                for url in panel.urls where !paths.contains(url.path) { paths.append(url.path) }
            }
        }
    }
}

private struct NeverTouchSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SettingsSection(title: "Never touch",
                        footnote: "Built-in entries can't be turned off, not even by your own rules.") {
            if !model.settings.alwaysKeep.isEmpty {
                Text("Always keep").font(.callout.weight(.medium))
                ForEach(model.settings.alwaysKeep, id: \.self) { path in
                    HStack {
                        Image(systemName: "pin").foregroundStyle(Theme.accent)
                        Text(ItemPresentation.abbreviate(path, home: model.home)).font(.callout.monospaced())
                        Spacer()
                        Button("Unpin") { model.stopKeeping(path) }.buttonStyle(.link)
                    }
                }
                Divider()
            }
            Text("Built in").font(.callout.weight(.medium))
            let entries = NeverTouchList(home: model.home).entries
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                      spacing: 6) {
                ForEach(entries, id: \.pattern) { entry in
                    HStack(spacing: 6) {
                        Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary)
                        Text(ItemPresentation.abbreviate(entry.pattern, home: model.home)).font(.caption.monospaced())
                        Text(entry.why).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
    }
}

private struct RulesSection: View {
    @Environment(AppModel.self) private var model
    @State private var rules: [Rule] = []

    var body: some View {
        SettingsSection(title: "Custom rules",
                        footnote: "Add rules with `ebb rule add <regex> --in <dir>`. Suggestions from rules are never pre-selected.") {
            if rules.isEmpty {
                Text("No custom rules.").foregroundStyle(.secondary)
            }
            ForEach(rules) { rule in
                HStack {
                    Text(rule.action == .neverTouch ? "Never touch" : "Suggest")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Theme.subtle, in: Capsule())
                    VStack(alignment: .leading, spacing: 1) {
                        Text(rule.name).font(.callout.weight(.medium))
                        Text("/\(rule.pattern)/ in \(rule.roots.isEmpty ? "every folder" : rule.roots.joined(separator: ", "))")
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Remove") {
                        try? store.remove(id: rule.id)
                        reload()
                    }
                    .buttonStyle(.link)
                }
            }
        }
        .onAppear(perform: reload)
    }

    private var store: RuleStore { RuleStore(fileURL: RuleStore.defaultLocation(home: model.home)) }

    private func reload() {
        rules = (try? store.load().rules) ?? []
    }
}

private struct CategoriesSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SettingsSection(title: "Categories") {
            let definitions = (try? CategoryCatalog.builtIn().definitions) ?? []
            ForEach(definitions, id: \.category.id) { definition in
                let category = definition.category
                Toggle(isOn: Binding(
                    get: { !model.settings.disabledCategories.contains(category.id) },
                    set: { on in
                        model.settings.disabledCategories.removeAll { $0 == category.id }
                        if !on { model.settings.disabledCategories.append(category.id) }
                    }
                )) {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(category.title)
                            Text(category.ruleDescription).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        BadgeView(badge: ItemPresentation.Badge(category.comesBack))
                    }
                }
            }
        }
    }
}

private struct AboutSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SettingsSection(title: "About") {
            HStack(alignment: .top, spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Ebb \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
                        .font(.headline)
                    Text("Free and open source under the MIT license. No account, nothing leaves your Mac.")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("Ebb has freed \(ByteCount.format(model.freedSinceInstall)) on this Mac.")
                        .font(.callout)
                }
            }
            if !SupportLinks.all.isEmpty {
                HStack {
                    ForEach(SupportLinks.all, id: \.title) { link in
                        Link(link.title, destination: link.url)
                    }
                }
            }
        }
    }
}

/// Where people can support the project. Shown only here and in the README,
/// never in the menu bar or notifications. Filled in once the
/// accounts exist.
enum SupportLinks {
    static let all: [(title: String, url: URL)] = []
}
