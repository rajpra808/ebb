import EbbAppKit
import SwiftUI

/// What a running scan looks like: a moving tide, the phase, a progress bar
/// and the live detail line. Used in the menu bar and in first run, so a
/// scan never looks like nothing is happening.
struct ScanningView: View {
    @Environment(AppModel.self) private var model
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 14) {
            HStack(spacing: 12) {
                TideAnimation()
                    .frame(width: compact ? 44 : 56, height: compact ? 30 : 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.scanPhase.isEmpty ? "Scanning" : model.scanPhase)
                        .font(compact ? .headline : .title3.weight(.semibold))
                    Text("Read-only. Nothing is changed.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            ProgressView(value: model.scanFraction ?? 0.05)
                .tint(Theme.accent)
                .animation(.easeOut(duration: 0.4), value: model.scanFraction)
            if case .scanning(let detail) = model.scanState {
                Text(detail)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}

/// Three waves drifting, drawn with a time-driven path.
private struct TideAnimation: View {
    var body: some View {
        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                for (index, opacity) in [1.0, 0.7, 0.4].enumerated() {
                    var path = Path()
                    let baseline = size.height * (0.3 + 0.25 * Double(index))
                    let phase = time * (1.6 + Double(index) * 0.5)
                    path.move(to: CGPoint(x: 0, y: baseline))
                    for x in stride(from: 0, through: size.width, by: 1) {
                        let y = baseline + sin(Double(x) / size.width * .pi * 3 + phase) * size.height * 0.1
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                    context.stroke(path, with: .color(Theme.accent.opacity(opacity)),
                                   style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                }
            }
        }
        .accessibilityHidden(true)
    }
}
