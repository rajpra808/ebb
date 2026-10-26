import EbbAppKit
import ScanCore
import SwiftUI

/// The popover under the menu bar item: the total, the top categories and
/// the two buttons.
struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(Navigation.self) private var navigation
    @Environment(\.openWindow) private var openWindow
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if model.isScanning {
                ScanningView(compact: true)
                    .padding(16)
            } else if let result = model.result {
                categories(result)
                skippedNote(result)
                Divider()
                actions
            } else {
                Text("No scan yet. Press Scan now to see what can go.")
                    .foregroundStyle(.secondary)
                    .padding(16)
            }
            Divider()
            footer
        }
        .frame(width: 420)
        // The Trash may have been emptied in Finder since; keep the total honest.
        .onAppear { model.reloadHistory() }
        .confirmationDialog(confirmTitle, isPresented: $confirming) {
            Button("Move to Trash") { Task { await model.cleanSelection(source: "menu bar") } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Nothing is deleted. You can put anything back from History.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Ebb").font(.headline)
                Spacer()
                Text(statusLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                SizeText(bytes: model.safeToClearBytes, font: .system(size: 32, weight: .bold))
                Text("can be cleared safely").foregroundStyle(.secondary)
            }
            StackedBar(parts: model.result.map { CategorySummary.safeToClear(in: $0).map(\.bytes) } ?? [])
            if model.commandOnlyBytes > 0 {
                Text("\(ByteCount.format(model.commandOnlyBytes)) of it is cleared with a command such as `go clean -modcache`, not moved to Trash. See Review.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let notice = model.notice {
                Text(notice).font(.caption).foregroundStyle(Theme.accent)
            }
        }
        .padding(16)
    }

    private var statusLine: String {
        if case .scanning(let what) = model.scanState { return what }
        guard let result = model.result else { return "" }
        return "Scanned " + DateText.describe(result.startedAt)
    }

    private func categories(_ result: ScanResult) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(CategorySummary.safeToClear(in: result).prefix(4).enumerated()), id: \.element.id) { index, row in
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Theme.segments[min(index, Theme.segments.count - 1)])
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.title).font(.body.weight(.medium))
                        Text(row.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    BadgeView(badge: row.badge)
                    SizeText(bytes: row.bytes, estimated: row.isEstimated)
                        .frame(minWidth: 64, alignment: .trailing)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
        .padding(.vertical, 4)
    }

    private func skippedNote(_ result: ScanResult) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.shield").foregroundStyle(Theme.accent)
            Text("**\(result.activeProjects.count) active projects skipped** · edits, git, agent sessions or editors in the last \(result.activeDays) days")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.subtle)
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button("Review") {
                openMainWindow(openWindow, navigation: navigation, pane: .recommendations)
            }
            .buttonStyle(SecondaryButtonStyle())
            Button {
                confirming = true
            } label: {
                Text(model.isCleaning ? "Moving…" : "Move \(ByteCount.format(model.selectionTotals.bytes)) to Trash")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(model.selectionTotals.count == 0 || model.isCleaning || model.isScanning)
        }
        .padding(16)
    }

    /// Always shown, scanning or not: scan, open the window, pause, quit,
    /// and what's waiting in the Trash.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button {
                    Task { await model.scan() }
                } label: {
                    Label(model.isScanning ? "Scanning…" : "Scan now", systemImage: "arrow.clockwise")
                }
                .buttonStyle(SecondaryButtonStyle(compact: true))
                .disabled(model.isScanning)
                Button {
                    openMainWindow(openWindow, navigation: navigation, pane: .overview)
                } label: {
                    Label("Open Ebb", systemImage: "macwindow")
                }
                .buttonStyle(SecondaryButtonStyle(compact: true))
                Spacer()
                pauseMenu
            }
            if model.bytesInTrash > 0 && !model.isScanning {
                HStack(spacing: 8) {
                    Image(systemName: "trash").foregroundStyle(.secondary)
                    Text("\(ByteCount.format(model.bytesInTrash)) from Ebb is waiting in the Trash")
                        .foregroundStyle(.secondary)
                    Spacer()
                    EmptyTrashButton(compact: true)
                }
                .font(.caption)
            }
            HStack {
                if let paused = model.pauseDescription {
                    Label(paused, systemImage: "pause.circle").foregroundStyle(Theme.warning)
                } else if model.worthALookBytes > 0 && !model.isScanning {
                    Button("+ \(ByteCount.format(model.worthALookBytes)) worth a look") {
                        openMainWindow(openWindow, navigation: navigation, pane: .recommendations)
                    }
                    .buttonStyle(.link)
                }
                Spacer()
                Button("Quit Ebb") { NSApp.terminate(nil) }.buttonStyle(.link).foregroundStyle(.secondary)
            }
            .font(.caption)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// Pause or resume the daily scans.
    private var pauseMenu: some View {
        Menu {
            if model.pauseDescription != nil {
                Button("Resume daily scans") { model.resumeDailyScans() }
            } else {
                Button("Pause for a day") { model.pauseDailyScans(days: 1) }
                Button("Pause for a week") { model.pauseDailyScans(days: 7) }
                Button("Pause until I resume") { model.pauseDailyScans(days: nil) }
            }
        } label: {
            Image(systemName: model.pauseDescription == nil ? "pause.circle" : "play.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(model.pauseDescription == nil ? "Pause daily scans" : "Resume daily scans")
    }

    private var confirmTitle: String {
        let totals = model.selectionTotals
        return "Move \(totals.count) item\(totals.count == 1 ? "" : "s") (\(ByteCount.format(totals.bytes))) to the Trash?"
    }
}
