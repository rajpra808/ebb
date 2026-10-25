import EbbAppKit
import ScanCore
import SwiftUI

/// The summary pane: four numbers and the biggest recommendations.
struct OverviewPane: View {
    @Environment(AppModel.self) private var model
    @Environment(Navigation.self) private var navigation

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PaneHeader(title: "Overview", subtitle: subtitle) {
                    HStack {
                        Button(model.isScanning ? "Scanning…" : "Scan now") { Task { await model.scan() } }
                            .buttonStyle(SecondaryButtonStyle())
                            .disabled(model.isScanning)
                        Button("Review \(ByteCount.format(model.safeToClearBytes))") {
                            navigation.pane = .recommendations
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .fixedSize()
                        .disabled(model.result == nil)
                    }
                }
                NoticeBar()
                stats
                if let result = model.result {
                    topRecommendations(result)
                    if !result.warnings.isEmpty { warnings(result.warnings) }
                }
            }
            .padding(28)
        }
    }

    private var subtitle: String {
        if case .scanning(let what) = model.scanState { return what }
        guard let result = model.result else { return "No scan yet." }
        return "Scanned \(DateText.describe(result.startedAt)) · took \(Int(result.durationSeconds.rounded())) s · "
            + "\(result.activeProjects.count) active projects protected"
    }

    private var stats: some View {
        HStack(spacing: 14) {
            let space = model.freeSpace
            StatCard(title: "Free space", value: space.map { ByteCount.format($0.free) } ?? "–",
                     detail: space.map { "of \(ByteCount.format($0.total))" } ?? "")
            StatCard(title: "Safe to clear", value: ByteCount.format(model.safeToClearBytes),
                     detail: SafeToClearText.detail(for: model.result?.items.filter(\.preselected) ?? []),
                     highlighted: true)
            StatCard(title: "Worth a look", value: ByteCount.format(model.worthALookBytes),
                     detail: "models, old history, duplicates")
            let freed = model.freedThisMonth
            StatCard(title: "Freed this month", value: ByteCount.format(freed.bytes),
                     detail: "\(freed.cleans) clean\(freed.cleans == 1 ? "" : "s")")
        }
    }

    private func topRecommendations(_ result: ScanResult) -> some View {
        let rows = CategorySummary.safeToClear(in: result)
        return Card(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Top recommendations").font(.headline)
                    Spacer()
                    Button("See all") { navigation.pane = .recommendations }.buttonStyle(.link)
                }
                .padding(16)
                ForEach(rows.prefix(5)) { row in
                    Divider()
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.title).font(.body.weight(.medium))
                            Text(row.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        BadgeView(badge: row.badge)
                        SizeText(bytes: row.bytes, estimated: row.isEstimated).frame(minWidth: 70, alignment: .trailing)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
                if rows.isEmpty {
                    Text("Nothing to clear right now.").foregroundStyle(.secondary).padding(16)
                }
            }
        }
    }

    private func warnings(_ warnings: [String]) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                Text("Notes from the last scan").font(.headline)
                ForEach(warnings, id: \.self) { Text($0).font(.callout).foregroundStyle(.secondary) }
            }
        }
    }
}
