import AppKit
import EbbAppKit
import ScanCore
import SwiftUI

/// First run: welcome, Full Disk Access, first scan (spec §6a "First run").
struct FirstRunView: View {
    @Environment(AppModel.self) private var model
    @Environment(Navigation.self) private var navigation
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var step = Step.welcome
    @State private var hasAccess = FullDiskAccess.isGranted()

    enum Step: Int, CaseIterable {
        case welcome, diskAccess, firstScan

        var title: String {
            switch self {
            case .welcome: return "Welcome"
            case .diskAccess: return "Disk access"
            case .firstScan: return "First scan"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            stepper
            Divider()
            Group {
                switch step {
                case .welcome: welcome
                case .diskAccess: diskAccess
                case .firstScan: firstScan
                }
            }
            .padding(30)
        }
        .frame(width: 620)
        .task(id: step) {
            // Notice Full Disk Access being switched on in System Settings.
            while step == .diskAccess && !hasAccess && !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                hasAccess = FullDiskAccess.isGranted()
            }
        }
    }

    private var stepper: some View {
        HStack(spacing: 10) {
            ForEach(Step.allCases, id: \.self) { item in
                HStack(spacing: 6) {
                    ZStack {
                        Circle().fill(item.rawValue <= step.rawValue ? Theme.brand : Theme.subtle)
                            .frame(width: 18, height: 18)
                        if item.rawValue < step.rawValue {
                            Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                        } else {
                            Text("\(item.rawValue + 1)").font(.system(size: 10, weight: .bold))
                                .foregroundStyle(item == step ? .white : .secondary)
                        }
                    }
                    Text(item.title).font(.caption.weight(item == step ? .semibold : .regular))
                }
                if item != Step.allCases.last { Rectangle().fill(Theme.border).frame(width: 18, height: 1) }
            }
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
    }

    private var appIcon: some View {
        Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 18) {
                appIcon
                VStack(alignment: .leading, spacing: 8) {
                    Text("Your Mac's daily cleanup agent").font(.system(size: 24, weight: .bold))
                    Text("Ebb finds space that's safe to clear: old build folders, caches, installers and more. It knows what you're working on and never suggests anything in an active project.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            promises
            HStack {
                Spacer()
                Button("Continue") { step = hasAccess ? .firstScan : .diskAccess }
                    .buttonStyle(PrimaryButtonStyle()).fixedSize()
            }
        }
    }

    private var promises: some View {
        Grid(alignment: .leading, horizontalSpacing: 30, verticalSpacing: 8) {
            GridRow {
                promise("Reads sizes and dates only")
                promise("Nothing leaves your Mac")
            }
            GridRow {
                promise("Never deletes on its own")
                promise("Open source, MIT")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
    }

    private func promise(_ text: String) -> some View {
        Label(text, systemImage: "checkmark").font(.callout).labelStyle(.titleAndIcon)
    }

    private var diskAccess: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 18) {
                appIcon
                VStack(alignment: .leading, spacing: 8) {
                    Text("Let Ebb see your disk").font(.system(size: 24, weight: .bold))
                    Text("To measure caches in ~/Library and tool folders, macOS needs you to turn on Full Disk Access for Ebb.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                instruction(1, "Click **Open System Settings**")
                instruction(2, "Find **Ebb** under Privacy & Security › Full Disk Access")
                instruction(3, "Turn it on. Ebb notices and continues by itself.")
            }
            if hasAccess {
                Label("Full Disk Access is on.", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.accent)
            }
            promises
            HStack {
                Button("Scan without it (limited)") { step = .firstScan }.buttonStyle(.link)
                Spacer()
                if hasAccess {
                    Button("Continue") { step = .firstScan }.buttonStyle(PrimaryButtonStyle()).fixedSize()
                } else {
                    Button("Open System Settings") { NSWorkspace.shared.open(FullDiskAccess.settingsURL) }
                        .buttonStyle(PrimaryButtonStyle()).fixedSize()
                }
            }
        }
        .onChange(of: hasAccess) { _, granted in
            if granted { step = .firstScan }
        }
    }

    private func instruction(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)").font(.caption.weight(.bold)).frame(width: 20, height: 20)
                .background(Theme.subtle, in: Circle())
            Text(text)
        }
    }

    private var firstScan: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 18) {
            Text(model.result == nil || model.isScanning ? "Scanning your Mac" : "Here's what Ebb found")
                .font(.system(size: 24, weight: .bold))
            if case .scanning(let what) = model.scanState {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(what).foregroundStyle(.secondary)
                }
                Text("The first scan takes a minute or so. Nothing is changed.").font(.caption).foregroundStyle(.secondary)
            } else if let result = model.result {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    SizeText(bytes: result.totals.safeToClearBytes, font: .system(size: 34, weight: .bold))
                    Text("can be cleared safely").foregroundStyle(.secondary)
                }
                Text("\(result.activeProjects.count) active projects are protected, and \(ByteCount.format(result.totals.worthALookBytes)) more is worth a look.")
                    .foregroundStyle(.secondary)
                Toggle("Scan once a day and tell me when it's worth it", isOn: Binding(
                    get: { model.settings.agent.isEnabled },
                    set: { enabled in
                        guard let executable = Bundle.main.executablePath else { return }
                        model.setAgentEnabled(enabled, executable: executable)
                        if enabled { Task { _ = await SystemNotifier.requestPermission() } }
                    }
                ))
                HStack {
                    Spacer()
                    Button("Review") { finish() }.buttonStyle(PrimaryButtonStyle()).fixedSize()
                }
            }
        }
        .task {
            if model.result == nil || !Calendar.current.isDateInToday(model.result?.startedAt ?? .distantPast) {
                await model.scan()
            }
        }
    }

    private func finish() {
        model.settings.completedFirstRun = true
        navigation.pane = .recommendations
        openWindow(id: Navigation.windowID)
        dismissWindow(id: Navigation.welcomeID)
        NSApp.activate(ignoringOtherApps: true)
    }
}
