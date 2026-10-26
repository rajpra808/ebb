import Foundation

/// Where macOS puts Ebb's menu bar item.
///
/// A new item lands at the left end of the right-hand group of menu bar
/// items. On a MacBook with a busy menu bar that spot is behind the notch,
/// so Ebb looks missing. Before the item is created the first time, ask for
/// a spot near the clock instead. macOS keeps the position from then on,
/// including after the user ⌘-drags it somewhere else.
enum MenuBarPlacement {
    /// The key AppKit uses for the first status item of an app. Its value
    /// is the distance from the right edge of the screen, in points.
    private static let key = "NSStatusItem Preferred Position Item-0"
    private static let nearTheClock = 220.0

    static func prepare(defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: key) == nil else { return }
        defaults.set(nearTheClock, forKey: key)
    }
}
