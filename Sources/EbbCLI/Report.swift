import Foundation
import ScanCore

/// Renders scan results as the aligned plain-text tables `ebb` prints.
struct Report {
    let result: ScanResult
    let home: String

    /// The summary: one line per category, then skipped, then the total.
    func summary() -> String {
        var rows: [[String]] = []
        for total in result.totals.byCategory {
            let size = (total.isEstimated ? "~" : "") + ByteCount.format(total.allocatedBytes)
            rows.append([total.categoryID, size, describe(total)])
        }

        let activeCount = result.activeProjects.count
        let otherSkips = result.skipped.filter { $0.reason.code != .activeProject }.count
        var skippedText = plural(activeCount, "active project")
        if otherSkips > 0 { skippedText += ", " + plural(otherSkips, "other item") }

        // One table, so the footer lines up with the categories above it.
        var out = rows.isEmpty ? "  Nothing to clear right now.\n\n" : ""
        if !rows.isEmpty { rows.append([]) }
        rows.append(["skipped", "", skippedText])
        rows.append(["safe to clear", ByteCount.format(result.totals.safeToClearBytes), ""])
        if result.totals.worthALookBytes > 0 {
            rows.append(["worth a look", ByteCount.format(result.totals.worthALookBytes), "not pre-selected"])
        }
        out += Table(rows: rows, rightAligned: [1]).render()
        out += "\n  Scanned in \(String(format: "%.1f", result.durationSeconds))s. Nothing was changed."
        if result.totals.byCategory.contains(where: \.isEstimated) {
            out += " ~ means estimated."
        }
        out += "\n"
        return out
    }

    /// Every item, grouped by category, for `ebb scan --details`.
    func details() -> String {
        var out = ""
        for total in result.totals.byCategory {
            out += "\n\(total.title)  (\(total.categoryID))\n"
            let items = result.items.filter { $0.categoryID == total.categoryID }
                .sorted { $0.allocatedBytes > $1.allocatedBytes }
            let rows = items.map { item -> [String] in
                [
                    (item.isEstimated ? "~" : "") + ByteCount.format(item.allocatedBytes),
                    abbreviate(item.path),
                    "\(item.comesBack.badge)",
                    item.reason,
                ]
            }
            out += Table(rows: rows, rightAligned: [0]).render()
        }
        return out
    }

    /// Everything skipped, grouped by reason, for `ebb scan --details`.
    func skipped() -> String {
        guard !result.skipped.isEmpty else { return "" }
        var out = "\nSkipped\n"
        let rows = result.skipped.map { [abbreviate($0.path), $0.reason.detail] }
        out += Table(rows: rows, rightAligned: []).render()
        return out
    }

    func warnings() -> String {
        result.warnings.map { "  note: \($0)\n" }.joined()
    }

    private func describe(_ total: CategoryTotal) -> String {
        let items = result.items.filter { $0.categoryID == total.categoryID }
        switch total.categoryID {
        case "python-venvs", "node-leftovers", "build-outputs":
            let projects = Set(items.compactMap(\.projectPath)).count
            return plural(projects, "inactive project")
        case "package-caches":
            return unique(items.compactMap(\.source)).joined(separator: ", ")
        default:
            return plural(total.itemCount, "item")
        }
    }

    private func abbreviate(_ path: String) -> String {
        EbbCLI.abbreviate(path, home: home)
    }
}

/// `/Users/me/code` → `~/code`.
func abbreviate(_ path: String, home: String) -> String {
    if path == home { return "~" }
    if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
    return path
}

func plural(_ count: Int, _ noun: String) -> String {
    "\(count) \(noun)\(count == 1 ? "" : "s")"
}

private func unique(_ values: [String]) -> [String] {
    var seen = Set<String>()
    return values.filter { seen.insert($0).inserted }
}

/// A plain-text table with two-space margins and padded columns.
struct Table {
    let rows: [[String]]
    /// Column indexes to right-align (sizes).
    let rightAligned: Set<Int>

    func render() -> String {
        guard let columnCount = rows.map(\.count).max() else { return "" }
        let widths = (0..<columnCount).map { column in
            rows.map { $0.indices.contains(column) ? $0[column].count : 0 }.max() ?? 0
        }
        return rows.map { row in
            let cells = row.enumerated().map { column, cell -> String in
                let padding = String(repeating: " ", count: widths[column] - cell.count)
                return rightAligned.contains(column) ? padding + cell : cell + padding
            }
            let line = "  " + cells.joined(separator: "   ")
            return line.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        }.joined(separator: "\n") + "\n"
    }
}
