import EbbAppKit
import ScanCore
import SwiftUI

/// The full window: a sidebar and one pane.
struct MainWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(Navigation.self) private var navigation

    var body: some View {
        @Bindable var navigation = navigation
        NavigationSplitView {
            Sidebar(pane: $navigation.pane)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
        } detail: {
            Group {
                switch navigation.pane {
                case .overview: OverviewPane()
                case .recommendations: RecommendationsPane()
                case .activeProjects: ActiveProjectsPane()
                case .history: HistoryPane()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .tint(Theme.accent)
    }
}

private struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @Binding var pane: Navigation.Pane

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(selection: Binding(get: { pane }, set: { if let new = $0 { pane = new } })) {
                ForEach(Navigation.Pane.allCases) { item in
                    HStack {
                        Label(item.rawValue, systemImage: item.symbol)
                        Spacer()
                        Text(trailing(for: item)).font(.caption.weight(.semibold))
                            .foregroundStyle(item == .recommendations ? Theme.accent : .secondary)
                    }
                    .tag(item)
                }
            }
            .listStyle(.sidebar)
            DiskCard()
                .padding(12)
        }
    }

    private func trailing(for pane: Navigation.Pane) -> String {
        switch pane {
        case .recommendations: return model.safeToClearBytes > 0 ? ByteCount.format(model.safeToClearBytes) : ""
        case .activeProjects: return model.result.map { "\($0.activeProjects.count)" } ?? ""
        default: return ""
        }
    }
}

/// Free space on the home disk, at the bottom of the sidebar.
private struct DiskCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let space = model.freeSpace {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("This Mac").font(.caption.weight(.semibold))
                    Spacer()
                    Text("\(ByteCount.format(space.free)) free").font(.caption).foregroundStyle(.secondary)
                }
                ProgressView(value: Double(space.total - space.free), total: Double(max(1, space.total)))
                    .tint(Theme.accent)
                Text(model.isScanning ? "Scanning…" : "Scans when you open Ebb. The daily agent is coming.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(10)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
        }
    }
}

/// Title and subtitle at the top of each pane, with optional buttons.
struct PaneHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 26, weight: .bold))
                Text(subtitle).foregroundStyle(.secondary)
            }
            Spacer()
            trailing
        }
    }
}

extension PaneHeader where Trailing == EmptyView {
    init(title: String, subtitle: String) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// A short message under the header after a clean or put back.
struct NoticeBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let notice = model.notice {
            HStack {
                Image(systemName: "checkmark.circle").foregroundStyle(Theme.accent)
                Text(notice)
                Spacer()
                Button("Dismiss") { model.dismissNotice() }.buttonStyle(.link)
            }
            .font(.callout)
            .padding(10)
            .background(Theme.accentWash, in: RoundedRectangle(cornerRadius: 9))
        }
    }
}
