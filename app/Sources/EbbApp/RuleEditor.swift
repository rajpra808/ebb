import AppKit
import EbbAppKit
import ScanCore
import SwiftUI

/// Add a custom rule without the terminal: name, folders, pattern, limits,
/// what happens to matches, and a live preview of what it would match.
struct RuleEditor: View {
    @Environment(\.dismiss) private var dismiss
    let home: String
    let onSave: (Rule) -> Void

    @State private var name = ""
    @State private var folders: [String] = []
    @State private var pattern = ""
    @State private var fullPath = false
    @State private var useAge = true
    @State private var olderThanDays = 30
    @State private var useSize = false
    @State private var largerThanMB = 50
    @State private var neverTouch = false
    @State private var comesBack = "no"
    @State private var preview = RulePreview.Result()
    @State private var previewTask: Task<Void, Never>?

    private static let presets: [(label: String, pattern: String)] = [
        ("Screen recordings", #"^Screen Recording .*\.mov$"#),
        ("Log files", #"\.log(\.\d+)?$"#),
        ("Videos", #"\.(mp4|mov)$"#),
        ("Old archives", #"\.(zip|tar\.gz|tgz)$"#),
    ]

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            form
                .frame(width: 400)
                .padding(22)
            Divider()
            previewPane
                .frame(width: 300)
                .padding(22)
        }
        .frame(height: 560)
        .onAppear { if folders.isEmpty { folders = [home + "/Downloads"] } }
        .onChange(of: previewKey) { _, _ in schedulePreview() }
    }

    // MARK: Form

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New custom rule").font(.title2.weight(.bold))
            labeled("Name") {
                TextField("Old screen recordings", text: $name).textFieldStyle(.roundedBorder)
            }
            labeled("Look in") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(folders, id: \.self) { folder in
                        HStack {
                            Text(ItemPresentation.abbreviate(folder, home: home)).font(.callout.monospaced())
                            Spacer()
                            Button { folders.removeAll { $0 == folder } } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                        }
                    }
                    Button("Add Folder…", action: addFolder).buttonStyle(.link)
                }
            }
            labeled("Pattern (regex)") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        TextField(#"\.mov$"#, text: $pattern).textFieldStyle(.roundedBorder).font(.body.monospaced())
                        Picker("", selection: $fullPath) {
                            Text("File name").tag(false)
                            Text("Full path").tag(true)
                        }
                        .labelsHidden().pickerStyle(.segmented).fixedSize()
                    }
                    HStack(spacing: 6) {
                        ForEach(Self.presets, id: \.pattern) { preset in
                            Button(preset.label) {
                                pattern = preset.pattern
                                if name.isEmpty { name = preset.label }
                            }
                            .buttonStyle(.link).font(.caption)
                        }
                    }
                    if let problem = patternProblem {
                        Text(problem).font(.caption).foregroundStyle(Theme.warning)
                    }
                }
            }
            labeled("Only when") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Toggle("Older than", isOn: $useAge)
                        Stepper("\(olderThanDays) days", value: $olderThanDays, in: 1...3650).disabled(!useAge)
                    }
                    HStack {
                        Toggle("Larger than", isOn: $useSize)
                        Stepper("\(largerThanMB) MB", value: $largerThanMB, in: 1...100_000, step: 10).disabled(!useSize)
                    }
                }
            }
            labeled("When it matches") {
                VStack(alignment: .leading, spacing: 6) {
                    Picker("", selection: $neverTouch) {
                        Text("Suggest for cleaning (never pre-selected)").tag(false)
                        Text("Never touch (protect from everything)").tag(true)
                    }
                    .labelsHidden().pickerStyle(.radioGroup)
                    if !neverTouch {
                        Picker("Comes back?", selection: $comesBack) {
                            Text("Gone for good").tag("no")
                            Text("Re-download").tag("redownload")
                        }
                        .fixedSize()
                    }
                }
            }
            Spacer()
            HStack {
                Text(cliEquivalent).font(.caption.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(2).textSelection(.enabled)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save rule") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(PrimaryButtonStyle()).fixedSize()
                    .disabled(rule == nil)
            }
        }
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.callout.weight(.semibold))
            content()
        }
    }

    // MARK: Preview

    private var previewPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Live preview").font(.headline)
                Spacer()
                if preview.isRunning { ProgressView().controlSize(.small) }
            }
            if neverTouch {
                Text("Matches will be protected from every category and rule.").font(.callout).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                SizeText(bytes: preview.bytes, font: .system(size: 30, weight: .bold))
                Text("\(preview.matches.count)\(preview.isTruncated ? "+" : "") matches").foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(preview.matches.prefix(6), id: \.path) { match in
                    HStack {
                        Text((match.path as NSString).lastPathComponent).font(.caption.monospaced()).lineLimit(1)
                        Spacer()
                        SizeText(bytes: match.bytes, font: .caption.weight(.semibold))
                    }
                    .padding(.vertical, 5)
                    Divider()
                }
                if preview.matches.count > 6 {
                    Text("+ \(preview.matches.count - 6) more").font(.caption).foregroundStyle(.secondary).padding(.top, 5)
                }
            }
            if preview.skipped > 0 {
                Text("\(preview.skipped) more matched but are protected, changed in the last day, or too new.")
                    .font(.caption).padding(10)
                    .background(Theme.warningWash, in: RoundedRectangle(cornerRadius: 8))
            }
            Spacer()
            Label("Rules never clean by themselves. Built-in protections always win: .git, .env, active projects, open files.",
                  systemImage: "checkmark.shield")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Logic

    private var patternProblem: String? {
        guard !pattern.isEmpty else { return nil }
        return (try? NSRegularExpression(pattern: pattern)) == nil ? "That isn't a valid regular expression." : nil
    }

    private var rule: Rule? {
        guard !pattern.isEmpty, patternProblem == nil, neverTouch || !folders.isEmpty else { return nil }
        let rule = Rule(
            name: name.trimmingCharacters(in: .whitespaces).isEmpty ? pattern : name,
            pattern: pattern,
            matchOn: fullPath ? .fullPath : .fileName,
            roots: folders.map { ItemPresentation.abbreviate($0, home: home) },
            olderThanDays: useAge ? olderThanDays : nil,
            largerThanMB: useSize ? Double(largerThanMB) : nil,
            action: neverTouch ? .neverTouch : .suggest,
            comesBack: comesBack == "redownload" ? .redownload : .no
        )
        do {
            try rule.validate()
            return rule
        } catch {
            return nil
        }
    }

    private var cliEquivalent: String {
        var parts = ["ebbctl rule add '\(pattern)'"]
        parts += folders.map { "--in " + ItemPresentation.abbreviate($0, home: home) }
        if useAge && !neverTouch { parts.append("--older \(olderThanDays)d") }
        if useSize && !neverTouch { parts.append("--larger \(largerThanMB)MB") }
        if neverTouch { parts.append("--never-touch") }
        if fullPath { parts.append("--full-path") }
        return "$ " + parts.joined(separator: " ")
    }

    private var previewKey: String {
        [pattern, folders.joined(separator: "|"), "\(fullPath)", "\(useAge)", "\(olderThanDays)",
         "\(useSize)", "\(largerThanMB)", "\(neverTouch)"].joined(separator: "·")
    }

    private func schedulePreview() {
        previewTask?.cancel()
        guard let rule else {
            preview = RulePreview.Result()
            return
        }
        previewTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            preview.isRunning = true
            let result = await RulePreview.run(rule, home: home)
            guard !Task.isCancelled else { return }
            preview = result
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: home)
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !folders.contains(url.path) { folders.append(url.path) }
    }

    private func save() {
        guard let rule else { return }
        onSave(rule)
        dismiss()
    }
}
