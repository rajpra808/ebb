import AppKit
import EbbAppKit
import EbbClean
import ScanCore
import SwiftUI

/// Projects Ebb won't touch, and the signals behind each.
struct ActiveProjectsPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PaneHeader(title: "Active projects",
                           subtitle: "Ebb skips these completely. Nothing inside them is ever suggested.")
                if let projects = model.result?.activeProjects, !projects.isEmpty {
                    Card(padding: 0) {
                        VStack(spacing: 0) {
                            ForEach(Array(projects.enumerated()), id: \.element.path) { index, project in
                                if index > 0 { Divider() }
                                row(project)
                            }
                        }
                    }
                } else {
                    Text(model.result == nil ? "Run a scan first." : "No active projects right now.")
                        .foregroundStyle(.secondary)
                }
                howEbbDecides
            }
            .padding(28)
        }
    }

    private func row(_ project: ActiveProject) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text((project.path as NSString).lastPathComponent).font(.body.weight(.semibold))
                Text(ItemPresentation.abbreviate(project.path, home: model.home))
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            .frame(width: 260, alignment: .leading)
            FlowChips(texts: project.signals.map(\.detail))
            Spacer()
            if model.isKept(project.path) {
                Button("Unpin") { model.stopKeeping(project.path) }.buttonStyle(.link)
            } else {
                Button("Always keep") { model.alwaysKeep(project.path) }.buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(14)
    }

    private var howEbbDecides: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("How Ebb decides").font(.headline)
            HStack(spacing: 10) {
                rule("pencil", "File edits", "Source changed in \(model.result?.activeDays ?? 14) days")
                rule("arrow.triangle.branch", "Git", "HEAD, index or log moved")
                rule("terminal", "Agent sessions", "Claude Code, Codex")
                rule("waveform.path.ecg", "Running", "A process works inside it")
                rule("macwindow", "Editor", "VS Code, Cursor, Xcode")
                rule("pin", "Pinned", "You chose Always keep")
            }
        }
    }

    private func rule(_ symbol: String, _ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: symbol).foregroundStyle(Theme.accent)
            Text(title).font(.callout.weight(.semibold))
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .background(Theme.subtle, in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Small grey chips that wrap onto new lines.
private struct FlowChips: View {
    let texts: [String]

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(texts, id: \.self) { text in
                Text(text).font(.caption)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Theme.subtle, in: RoundedRectangle(cornerRadius: 5))
            }
        }
    }
}

/// Lays children out left to right, wrapping when a row is full.
private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: rows.map(\.width).max() ?? 0,
                      height: rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}

/// Every clean, with put back.
struct HistoryPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PaneHeader(title: "History", subtitle: "Every clean is logged. Anything still in Trash can be put back.") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Freed this month").font(.caption).foregroundStyle(.secondary)
                        SizeText(bytes: model.freedThisMonth.bytes, font: .system(size: 22, weight: .bold))
                    }
                }
                NoticeBar()
                if model.bytesInTrash > 0 { trashBanner }
                if model.history.isEmpty {
                    Text("No cleans yet.").foregroundStyle(.secondary)
                }
                ForEach(model.history) { record in
                    CleanCard(record: record)
                }
            }
            .padding(28)
        }
        .onAppear { model.reloadHistory() }
    }

    private var trashBanner: some View {
        HStack {
            Image(systemName: "trash").foregroundStyle(Theme.warning)
            Text("Trash holds **\(ByteCount.format(model.bytesInTrash))** from Ebb cleans. The space is freed once it's emptied. Your own files in the Trash are never touched.")
                .font(.callout)
            Spacer()
            Button("Open Trash") {
                NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/.Trash"))
            }
            .buttonStyle(SecondaryButtonStyle())
            EmptyTrashButton()
        }
        .padding(12)
        .background(Theme.warningWash, in: RoundedRectangle(cornerRadius: 10))
    }
}

/// "Empty Ebb's items", confirmed in place: the button turns into a short
/// question with Cancel and Empty, because removing for good can't be undone.
struct EmptyTrashButton: View {
    @Environment(AppModel.self) private var model
    var compact = false
    @State private var confirming = false

    var body: some View {
        if confirming {
            HStack(spacing: 8) {
                Text("Remove for good?").font(compact ? .caption.weight(.semibold) : .callout.weight(.semibold))
                Button("Cancel") { confirming = false }
                    .buttonStyle(SecondaryButtonStyle(compact: true))
                Button("Empty") {
                    confirming = false
                    model.emptyEbbTrash()
                }
                .buttonStyle(DangerButtonStyle())
            }
        } else {
            Button {
                confirming = true
            } label: {
                Label(compact ? "Empty" : "Empty Ebb's items", systemImage: "trash.slash")
            }
            .buttonStyle(SecondaryButtonStyle(compact: compact))
            .disabled(model.bytesInTrash == 0)
            .help("Removes only what Ebb moved to the Trash. Your own files there stay. Can't be undone.")
        }
    }
}

/// The menu bar's Trash line, with its Empty button.
struct EmptyTrashRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "trash").foregroundStyle(.secondary)
            Text("\(ByteCount.format(model.bytesInTrash)) from Ebb is in the Trash")
                .foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            EmptyTrashButton(compact: true)
        }
        .font(.caption)
    }
}

private struct CleanCard: View {
    @Environment(AppModel.self) private var model
    let record: CleanRecord
    @State private var expanded = false

    var body: some View {
        let waiting = record.entries.filter(\.isWaitingInTrash)
        Card(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(DateText.describe(record.date).capitalizedFirst).font(.headline)
                        Text(summary(waiting: waiting.count)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    SizeText(bytes: record.totalBytes)
                    if waiting.count > 1 {
                        Button("Put all back") { model.putBack(record) }.buttonStyle(SecondaryButtonStyle())
                    }
                    Button(expanded ? "Hide items" : "Show items") { expanded.toggle() }.buttonStyle(.link)
                }
                .padding(14)
                .background(Theme.subtle)
                if expanded {
                    ForEach(record.entries, id: \.originalPath) { entry in
                        Divider()
                        HStack {
                            Text(ItemPresentation.abbreviate(entry.originalPath, home: model.home))
                                .font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            SizeText(bytes: entry.allocatedBytes, font: .callout)
                            status(entry)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 8)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func status(_ entry: CleanRecord.Entry) -> some View {
        if entry.restoredAt != nil {
            Text("Put back").font(.caption).foregroundStyle(.secondary).frame(width: 90, alignment: .trailing)
        } else if entry.emptiedAt != nil {
            Text("Emptied").font(.caption).foregroundStyle(.secondary).frame(width: 90, alignment: .trailing)
        } else if FileManager.default.fileExists(atPath: entry.trashPath) {
            Button("Put back") { model.putBack(record, paths: [entry.originalPath]) }
                .buttonStyle(.link).frame(width: 90, alignment: .trailing)
        } else {
            Text("Trash emptied").font(.caption).foregroundStyle(.secondary).frame(width: 90, alignment: .trailing)
        }
    }

    private func summary(waiting: Int) -> String {
        let total = record.entries.count
        let restored = record.entries.filter { $0.restoredAt != nil }.count
        var parts = ["\(total) item\(total == 1 ? "" : "s")", "from \(record.source)"]
        if restored > 0 { parts.append("\(restored) put back") }
        if waiting + restored < total { parts.append("Trash emptied, can't be put back") }
        return parts.joined(separator: " · ")
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
