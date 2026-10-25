import Foundation
import IOKit
import IOKit.ps

/// The LaunchAgent that starts the daily agent:
/// `~/Library/LaunchAgents/com.serveka.ebb.agent.plist`.
///
/// launchd runs the app's own executable with `--agent` every hour and at
/// login. Each run decides for itself whether today's scan is due, so the
/// plist never needs to change when settings do.
public struct LaunchAgent: Sendable {
    public static let label = "com.serveka.ebb.agent"

    public let home: String

    public init(home: String) {
        self.home = home
    }

    public var plistURL: URL {
        URL(fileURLWithPath: home + "/Library/LaunchAgents/\(Self.label).plist")
    }

    public var logURL: URL {
        URL(fileURLWithPath: home + "/Library/Logs/Ebb/agent.log")
    }

    public func plist(executable: String) -> [String: Any] {
        [
            "Label": Self.label,
            "ProgramArguments": [executable, "--agent"],
            "StartInterval": 3600,
            "RunAtLoad": true,
            // A background job: low CPU and I/O priority, never in the way.
            "ProcessType": "Background",
            "LowPriorityIO": true,
            "Nice": 10,
            "StandardOutPath": logURL.path,
            "StandardErrorPath": logURL.path,
        ]
    }

    /// Whether the plist is installed and points at `executable`.
    public func isInstalled(executable: String) -> Bool {
        guard let data = try? Data(contentsOf: plistURL),
              let existing = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let arguments = existing["ProgramArguments"] as? [String]
        else { return false }
        return arguments.first == executable
    }

    /// Writes the plist and loads it into launchd for this user.
    public func install(executable: String) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: plist(executable: executable),
                                                      format: .xml, options: 0)
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = launchctl(["bootout", domain + "/" + Self.label])
        try data.write(to: plistURL, options: .atomic)
        let status = launchctl(["bootstrap", domain, plistURL.path])
        guard status == 0 else { throw LaunchAgentError.launchctlFailed(status) }
    }

    /// Unloads the agent and removes the plist Ebb wrote.
    public func uninstall() {
        _ = launchctl(["bootout", domain + "/" + Self.label])
        try? FileManager.default.removeItem(at: plistURL)
    }

    private var domain: String { "gui/\(getuid())" }

    private func launchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }
}

public enum LaunchAgentError: Error, CustomStringConvertible {
    case launchctlFailed(Int32)

    public var description: String {
        switch self {
        case .launchctlFailed(let status): return "launchctl couldn't load the agent (status \(status))"
        }
    }
}

/// Power and idle state from IOKit.
public struct MacConditions: SystemConditions {
    public init() {}

    public func power() -> (onAdapter: Bool, batteryPercent: Int?) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return (true, nil) }
        let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        let onAdapter = providing == kIOPMACPowerKey
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0
            else { continue }
            return (onAdapter, current * 100 / maximum)
        }
        return (onAdapter, nil)
    }

    public func idleSeconds() -> TimeInterval {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"), &iterator) == KERN_SUCCESS
        else { return .infinity }
        defer { IOObjectRelease(iterator) }
        let entry = IOIteratorNext(iterator)
        guard entry != 0 else { return .infinity }
        defer { IOObjectRelease(entry) }
        guard let value = IORegistryEntryCreateCFProperty(entry, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber
        else { return .infinity }
        return value.doubleValue / 1_000_000_000
    }
}

/// Whether Ebb has Full Disk Access. macOS has no API for this; the usual
/// test is to read a folder only Full Disk Access opens.
public enum FullDiskAccess {
    public static func isGranted(home: String = NSHomeDirectory()) -> Bool {
        let probes = ["/Library/Application Support/com.apple.TCC", home + "/Library/Safari", home + "/Library/Mail"]
        for probe in probes where FileManager.default.fileExists(atPath: probe) {
            return (try? FileManager.default.contentsOfDirectory(atPath: probe)) != nil
        }
        return true
    }

    /// Privacy & Security › Full Disk Access in System Settings.
    public static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
    ) ?? URL(fileURLWithPath: "/System/Applications/System Settings.app")
}
