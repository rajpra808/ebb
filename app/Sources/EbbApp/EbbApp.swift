import AppKit
import ScanCore
import EbbAppKit
import SwiftUI

struct EbbApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var model = AppModel()
    @State private var navigation = Navigation()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(model)
                .environment(navigation)
        } label: {
            MenuBarLabel(model: model, navigation: navigation)
                .onAppear { delegate.navigation = navigation }
        }
        .menuBarExtraStyle(.window)

        Window("Welcome to Ebb", id: Navigation.welcomeID) {
            FirstRunView()
                .environment(model)
                .environment(navigation)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)

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
    static let welcomeID = "welcome"

    enum Pane: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case recommendations = "Recommendations"
        case activeProjects = "Active projects"
        case history = "History"
        case settings = "Settings"

        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .overview: return "square.grid.2x2"
            case .recommendations: return "list.bullet.indent"
            case .activeProjects: return "shield"
            case .history: return "clock"
            case .settings: return "slider.horizontal.3"
            }
        }
    }

    var pane: Pane = .overview
    /// Set from outside SwiftUI (a notification click) to open the window.
    var openRequested = false
}

/// The menu bar item: the wave and how much can be cleared.
struct MenuBarLabel: View {
    let model: AppModel
    let navigation: Navigation
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: model.isScanning ? "water.waves.and.arrow.down" : "water.waves")
            if model.settings.showSizeInMenuBar && model.safeToClearBytes > 0 {
                Text(ByteCount.format(model.safeToClearBytes)).monospacedDigit()
            }
        }
        .onChange(of: navigation.openRequested) { _, requested in
            guard requested else { return }
            navigation.openRequested = false
            openWindow(id: Navigation.windowID)
            NSApp.activate(ignoringOtherApps: true)
        }
        .task {
            if let executable = Bundle.main.executablePath {
                model.repairAgentIfNeeded(executable: executable)
            }
            if !model.settings.completedFirstRun {
                openWindow(id: Navigation.welcomeID)
                NSApp.activate(ignoringOtherApps: true)
                return
            }
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
