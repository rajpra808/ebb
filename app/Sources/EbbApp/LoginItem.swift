import ServiceManagement

/// Opening Ebb at login, through macOS's login items (System Settings ›
/// General › Login Items).
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Turns it on or off. Returns the state afterwards, which may differ
    /// from what was asked if macOS refused or wants the user's approval.
    @discardableResult
    static func set(_ enabled: Bool) -> Bool {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            // Left as it was; the toggle shows the real state.
        }
        return isEnabled
    }
}
