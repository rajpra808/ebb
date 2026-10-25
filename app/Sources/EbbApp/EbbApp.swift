import AppKit
import ScanCore
import EbbAppKit
import SwiftUI

@main
struct EbbApp: App {
    @State private var model = AppModel()
    @State private var navigation = Navigation()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(model)
                .environment(navigation)
        } label: {
            MenuBarLabel(model: model, navigation: navigation)
        }
        .menuBarExtraStyle(.window)

        Window("Ebb", id: Navigation.windowID) {
            MainWindow()
                .environment(model)
                .environment(navigation)
                .frame(minWidth: 940, minHeight: 640)
        }
        .defaultSize(width: 1120, height: 760)
        .windowResizability(.contentMinSize)
    }
}

/// Which pane the main window shows. Shared so the menu bar can open the
/// window on a given pane.
@Observable
final class Navigation {
    static let windowID = "main"

    enum Pane: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case recommendations = "Recommendations"
        case activeProjects = "Active projects"
        case history = "History"

        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .overview: return "square.grid.2x2"
            case .recommendations: return "list.bullet.indent"
            case .activeProjects: return "shield"
            case .history: return "clock"
            }
        }
    }

    var pane: Pane = .overview
}

/// The menu bar item: the wave and how much can be cleared.
struct MenuBarLabel: View {
    let model: AppModel
    let navigation: Navigation
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: model.isScanning ? "water.waves.and.arrow.down" : "water.waves")
            if model.safeToClearBytes > 0 {
                Text(ByteCount.format(model.safeToClearBytes)).monospacedDigit()
            }
        }
        .task {
            // `open Ebb.app --args --show-window [pane]` opens the window right
            // away, e.g. `--show-window history`.
            let arguments = CommandLine.arguments
            if let flag = arguments.firstIndex(of: "--show-window") {
                let name = arguments.indices.contains(flag + 1) ? arguments[flag + 1].lowercased() : ""
                navigation.pane = Navigation.Pane.allCases.first { $0.rawValue.lowercased().hasPrefix(name) && !name.isEmpty }
                    ?? .overview
                openWindow(id: Navigation.windowID)
                NSApp.activate(ignoringOtherApps: true)
            }
            // Scan at launch when there's no result yet or it's from an
            // earlier day. The daily agent will take this over.
            let stale = model.result.map { !Calendar.current.isDateInToday($0.startedAt) } ?? true
            if stale { await model.scan() }
        }
    }
}

extension View {
    /// Brings the main window forward on `pane`. Ebb runs as a menu bar
    /// app, so it has to activate itself for the window to come to the front.
    func openMainWindow(_ openWindow: OpenWindowAction, navigation: Navigation,
                        pane: Navigation.Pane) {
        navigation.pane = pane
        openWindow(id: Navigation.windowID)
        NSApp.activate(ignoringOtherApps: true)
    }
}
