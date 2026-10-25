import AppKit
import EbbAppKit
import ScanCore
import SwiftUI

/// Colors and type from the design (app/design/ebb-app-design.html).
enum Theme {
    /// The brand teal (#0E5E6F). In dark mode a lighter teal keeps text and
    /// bars readable.
    static let accent = adaptive(light: 0x0E5E6F, dark: 0x5FB3C0)
    /// The brand teal in both modes, behind white text.
    static let brand = adaptive(light: 0x0E5E6F, dark: 0x0E5E6F)
    static let accentMid = adaptive(light: 0x3B8F9A, dark: 0x3B8F9A)
    static let accentLight = adaptive(light: 0x8FC1C9, dark: 0x2C6670)
    static let accentWash = adaptive(light: 0xE4F1F3, dark: 0x173A40)
    static let warning = adaptive(light: 0xC2672E, dark: 0xE89A62)
    static let warningWash = adaptive(light: 0xFDF3E7, dark: 0x3B2A1C)
    static let card = Color(nsColor: .controlBackgroundColor)
    static let subtle = Color.primary.opacity(0.05)
    static let border = Color.primary.opacity(0.09)

    /// Bar segments for the safe-to-clear breakdown, darkest first.
    static let segments = [accent, accentMid, accentLight, Color.gray.opacity(0.45), Color.gray.opacity(0.25)]

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return color(isDark ? dark : light)
        })
    }

    private static func color(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// "3.1 GB", with "~" for estimates.
struct SizeText: View {
    let bytes: Int64
    var estimated = false
    var font: Font = .system(.body, weight: .semibold)

    var body: some View {
        Text((estimated ? "~" : "") + ByteCount.format(bytes))
            .font(font)
            .monospacedDigit()
    }
}

/// The comes-back label: teal for "comes back", grey for "re-download",
/// orange for "gone for good".
struct BadgeView: View {
    let badge: ItemPresentation.Badge

    var body: some View {
        Text(badge.rawValue)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(foreground)
            .background(background, in: Capsule())
    }

    private var foreground: Color {
        switch badge {
        case .comesBack: return Theme.accent
        case .redownload, .notApplicable: return .secondary
        case .goneForGood: return Theme.warning
        }
    }

    private var background: Color {
        switch badge {
        case .comesBack: return Theme.accentWash
        case .redownload, .notApplicable: return Theme.subtle
        case .goneForGood: return Theme.warningWash
        }
    }
}

/// A rounded panel with a hairline border.
struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
    }
}

/// One of the four numbers at the top of the Overview.
struct StatCard: View {
    let title: String
    let value: String
    let detail: String
    var highlighted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.callout).foregroundStyle(highlighted ? Theme.accent : .secondary)
            Text(value).font(.system(size: 28, weight: .bold)).monospacedDigit()
                .foregroundStyle(highlighted ? Theme.accent : .primary)
            Text(detail).font(.caption).foregroundStyle(highlighted ? Theme.accent : .secondary)
                .lineLimit(2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
        .background(highlighted ? Theme.accentWash : Theme.subtle, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// A thin stacked bar of sizes.
struct StackedBar: View {
    let parts: [Int64]
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geometry in
            let total = max(1, parts.reduce(0, +))
            HStack(spacing: 2) {
                ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                    Theme.segments[min(index, Theme.segments.count - 1)]
                        .frame(width: max(2, geometry.size.width * CGFloat(part) / CGFloat(total) - 2))
                }
            }
        }
        .frame(height: height)
        .clipShape(Capsule())
    }
}

/// The primary teal button.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .background(Theme.brand.opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4),
                        in: RoundedRectangle(cornerRadius: 9))
    }
}

/// The grey secondary button.
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(Color.primary.opacity(configuration.isPressed ? 0.12 : 0.07),
                        in: RoundedRectangle(cornerRadius: 9))
    }
}
