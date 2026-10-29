import AppKit
import EbbAppKit
import ScanCore
import SwiftUI

/// The review screen: every item with a checkbox, what it is, whether it
/// comes back and why it's safe, plus a side panel with the selected total.
struct RecommendationsPane: View {
    @Environment(AppModel.self) private var model
    @Environment(Navigation.self) private var navigation
    @State private var filter = RecommendationFilter.all
    @State private var confirming = false

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    PaneHeader(title: "Recommendations",
                               subtitle: "Every item says what it is, whether it regenerates, and why it's safe.")
                    NoticeBar()
                    filterBar
                    if let result = model.result {
                        section("Safe to clear", note: "pre-selected", items: result.items.filter(\.preselected), result: result)
                        section("Worth a look", note: "never pre-selected", items: result.items.filter { !$0.preselected },
                                result: result)
                    } else {
                        Text(model.isScanning ? "Scanning…" : "Run a scan to see recommendations.")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(28)
            }
            SelectionPanel(confirming: $confirming)
                .frame(width: 290)
                .padding(.top, 28)
                .padding(.trailing, 28)
        }
    }

    private var filterBar: some View {
        Picker("Show", selection: $filter) {
            ForEach(RecommendationFilter.allCases) { option in
                Text("\(option.rawValue) · \(model.result?.items.filter(option.includes).count ?? 0)").tag(option)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    @ViewBuilder
    private func section(_ title: String, note: String, items: [Item], result: ScanResult) -> some View {
        let shown = items.filter(filter.includes).sorted { $0.allocatedBytes > $1.allocatedBytes }
        if !shown.isEmpty {
            Card(padding: 0) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text(title).font(.headline) + Text(" · \(note)").foregroundStyle(.secondary)
                        Spacer()
                        let selectable = shown.filter(Selection.isSelectable)
                        let allTicked = !selectable.isEmpty && selectable.allSatisfy(model.selection.contains)
                        Button(allTicked ? "Select none" : "Select all") {
                            model.selection.set(selectable, selected: !allTicked)
                        }
                        .buttonStyle(.link)
                        .disabled(selectable.isEmpty)
                        SizeText(bytes: shown.reduce(0) { $0 + $1.allocatedBytes })
                            .foregroundStyle(Theme.accent)
                    }
                    .padding(14)
                    .background(Theme.subtle)
                    ForEach(shown, id: \.path) { item in
                        Divider()
                        ItemRow(item: item, home: model.home)
                    }
                }
            }
        }
    }
}

/// One item: checkbox, title, path, reason, badge and size.
private struct ItemRow: View {
    @Environment(AppModel.self) private var model
    let item: Item
    let home: String

    var body: some View {
        let presentation = ItemPresentation(item, home: home)
        HStack(alignment: .top, spacing: 12) {
            Toggle("", isOn: Binding(get: { model.selection.contains(item) }, set: { _ in model.selection.toggle(item) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(!Selection.isSelectable(item))
            VStack(alignment: .leading, spacing: 3) {
                (Text(presentation.title).fontWeight(.medium)
                    + Text(presentation.context.map { " in \($0)" } ?? "").foregroundColor(.secondary))
                if !presentation.path.isEmpty {
                    HStack(spacing: 6) {
                        Text(presentation.path).font(.caption.monospaced()).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                            .textSelection(.enabled)
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
                        } label: {
                            Image(systemName: "arrow.up.forward.square")
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .foregroundStyle(Theme.accent)
                        .help("Show in Finder")
                    }
                }
                Text(item.reason).font(.caption)
                if case .yes(let howTo) = item.comesBack {
                    Text("To get it back: \(howTo)").font(.caption).foregroundStyle(Theme.accent)
                }
                if let command = item.clearCommand {
                    Text(Selection.isSelectable(item)
                         ? "Cleared by running `\(command)`. Not via the Trash, so it can't be put back."
                         : "Cleared with `\(command)`. Install the tool to clear it from Ebb.")
                        .font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 12)
            BadgeView(badge: presentation.badge)
            SizeText(bytes: item.allocatedBytes, estimated: item.isEstimated)
                .frame(minWidth: 72, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { model.selection.toggle(item) }
        .contextMenu {
            if let project = item.projectPath {
                Button("Always keep \((project as NSString).lastPathComponent)") { model.alwaysKeep(project) }
            }
            if item.isTrashable {
                Button("Always keep this item") { model.alwaysKeep(item.path) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)]) }
                Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: item.path)) }
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.path, forType: .string)
                }
            }
        }
    }
}

/// The right-hand panel: selected total by comes-back label, and the button.
private struct SelectionPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(Navigation.self) private var navigation
    @Binding var confirming: Bool

    var body: some View {
        let totals = model.selectionTotals
        VStack(alignment: .leading, spacing: 14) {
            Text("Selected").font(.callout).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                SizeText(bytes: totals.bytes, font: .system(size: 30, weight: .bold))
                Text("\(totals.count) item\(totals.count == 1 ? "" : "s")").foregroundStyle(.secondary)
            }
            VStack(spacing: 6) {
                breakdown("Regenerates", totals.comesBack, Theme.accent)
                breakdown("Re-download", totals.redownload, .gray)
                breakdown("Gone for good", totals.goneForGood, Theme.warning)
            }
            if confirming {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Move \(totals.count) item\(totals.count == 1 ? "" : "s") to the Trash?").font(.callout.weight(.semibold))
                    Text(confirmDetail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Cancel") { confirming = false }
                            .buttonStyle(SecondaryButtonStyle(compact: true))
                            .keyboardShortcut(.cancelAction)
                        Button("Move to Trash") {
                            confirming = false
                            Task { await model.cleanSelection(source: "review") }
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(12)
                .background(Theme.accentWash, in: RoundedRectangle(cornerRadius: 10))
            } else {
                Button(model.isCleaning ? "Moving…" : "Move \(ByteCount.format(totals.bytes)) to Trash") {
                    confirming = true
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(totals.count == 0 || model.isCleaning || model.isScanning)
                Text("Goes to Trash, not deleted. Put back any item from History.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let result = model.result, !result.activeProjects.isEmpty {
                Divider()
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "shield").foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(result.activeProjects.count) active projects skipped.").font(.caption.weight(.semibold))
                        Button("See why") { navigation.pane = .activeProjects }.buttonStyle(.link).font(.caption)
                    }
                }
            }
        }
        .padding(18)
        .background(Theme.subtle, in: RoundedRectangle(cornerRadius: 14))
    }

    private var confirmDetail: String {
        let commands = model.selectedToolCommands
        let base = "Each item is checked again first. Put anything back from History."
        guard !commands.isEmpty else { return base }
        return base + " Also runs " + commands.joined(separator: ", ") + ", which can't be put back."
    }

    private func breakdown(_ label: String, _ bytes: Int64, _ color: Color) -> some View {
        HStack {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(.callout)
            Spacer()
            SizeText(bytes: bytes, font: .callout.weight(bytes > 0 ? .semibold : .regular))
                .foregroundStyle(bytes > 0 ? .primary : .secondary)
        }
    }
}
