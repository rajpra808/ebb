import EbbAppKit
import ScanCore
import SwiftUI

/// The popover under the menu bar item: what one click clears, the top
/// categories, and the actions.
///
/// Confirmations happen inside the panel. A separate dialog would close
/// the panel when clicked, then reopen with the dialog still showing.
struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(Navigation.self) private var navigation
    @Environment(\.openWindow) private var openWindow
    @State private var confirmingMove = false

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
                if confirmingMove { confirmMove } else { actions }
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
        .onAppear {
            model.reloadHistory()
            confirmingMove = false
        }
        .animation(.easeOut(duration: 0.15), value: confirmingMove)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Ebb").font(.headline)
                Spacer()
                Text(statusLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            // The big number is what the button below clears in one click.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                SizeText(bytes: model.trashableBytes, font: .system(size: 32, weight: .bold))
                Text("ready to clear").foregroundStyle(.secondary)
            }
            StackedBar(parts: model.result.map { CategorySummary.safeToClear(in: $0, which: .trash).map(\.bytes) } ?? [])
            if model.toolCommandBytes > 0 {
                Text("+ \(ByteCount.format(model.toolCommandBytes)) more via tool commands, shown faded below")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let notice = model.notice {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                    Text(notice).font(.caption).foregroundStyle(Theme.accent)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button { model.dismissNotice() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
    }

    private var statusLine: String {
        if case .scanning(let what) = model.scanState { return what }
        guard let result = model.result else { return "" }
        return "Scanned " + DateText.describe(result.startedAt)
    }

    // MARK: Categories

    private func categories(_ result: ScanResult) -> some View {
        let trash = CategorySummary.safeToClear(in: result, which: .trash)
        let tools = CategorySummary.safeToClear(in: result, which: .toolCommand)
        return VStack(spacing: 0) {
            ForEach(Array(trash.prefix(4).enumerated()), id: \.element.id) { index, row in
                CategoryRow(row: row, color: Theme.segments[min(index, Theme.segments.count - 1)])
            }
            ForEach(tools.prefix(2)) { row in
                ToolCommandRow(row: row)
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

    // MARK: Actions

    private var actions: some View {
        HStack(spacing: 10) {
            Button("Review") {
                openMainWindow(openWindow, navigation: navigation, pane: .recommendations)
            }
            .buttonStyle(SecondaryButtonStyle())
            Button {
                confirmingMove = true
            } label: {
                Text(model.isCleaning ? "Moving…"
                     : model.selectionTotals.count == 0 ? "Nothing to move right now"
                     : "Move \(ByteCount.format(model.selectionTotals.bytes)) to Trash")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(model.selectionTotals.count == 0 || model.isCleaning || model.isScanning)
        }
        .padding(16)
    }

    /// The confirmation, in place of the buttons.
    private var confirmMove: some View {
        let totals = model.selectionTotals
        return VStack(alignment: .leading, spacing: 10) {
            Text("Move \(totals.count) item\(totals.count == 1 ? "" : "s") (\(ByteCount.format(totals.bytes))) to the Trash?")
                .font(.headline)
            Text(confirmDetail).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("Cancel") { confirmingMove = false }
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Move to Trash") {
                    confirmingMove = false
                    Task { await model.cleanSelection(source: "menu bar") }
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .background(Theme.accentWash.opacity(0.5))
    }

    private var confirmDetail: String {
        let commands = model.selectedToolCommands
        let base = "Each item is checked again first. Put anything back from History."
        guard !commands.isEmpty else { return base }
        return base + " Also runs " + commands.joined(separator: ", ") + ", which can't be put back."
    }

    // MARK: Footer

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
                EmptyTrashRow()
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
}

/// A category that Move to Trash clears.
private struct CategoryRow: View {
    let row: CategorySummary
    let color: Color

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title).font(.body.weight(.medium))
                Text(row.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            BadgeView(badge: row.badge)
            SizeText(bytes: row.bytes, estimated: row.isEstimated).frame(minWidth: 64, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

/// A category cleared by a tool's own command: faded, and on hover it says
/// what runs and why it isn't part of the button above.
private struct ToolCommandRow: View {
    let row: CategorySummary
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "terminal").font(.caption).frame(width: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.title).font(.body.weight(.medium))
                    Text(hovering ? "Needs a tool command" : row.detail + " · hover for details")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                SizeText(bytes: row.bytes, estimated: row.isEstimated).frame(minWidth: 64, alignment: .trailing)
            }
            if hovering {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(row.commands, id: \.self) { command in
                        Text(command).font(.caption.monospaced())
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Theme.subtle, in: RoundedRectangle(cornerRadius: 4))
                            .textSelection(.enabled)
                    }
                    Text("These files can't go to the Trash, so they aren't in the button above. Tick them in Review and Ebb runs the command, or run it yourself. It can't be put back; the tool downloads it again when needed.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, 18)
            }
        }
        .opacity(hovering ? 1 : 0.55)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}
