import SwiftUI

/// 7-second live pitch history strip inspired by chorder's buildHistoryPath.
public struct PitchHistoryGraphView: View {
    let history: [HistoryPoint]
    let durationSeconds: Double

    public init(history: [HistoryPoint], durationSeconds: Double = TunerConstants.historyDurationSeconds) {
        self.history = history
        self.durationSeconds = durationSeconds
    }

    public var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                ZStack {
                    // Background & Border
                    RoundedRectangle(cornerRadius: 8)
                        .fill(TunerTheme.surface)

                    // Center 0 cents line
                    Path { p in
                        let y = geo.size.height / 2
                        p.move(to: CGPoint(x: 0, y: y))
                        p.addLine(to: CGPoint(x: geo.size.width, y: y))
                    }
                    .stroke(TunerTheme.gaugeTickMinor.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))

                    // History curve
                    if history.count >= 2, let endAt = history.last?.at {
                        HistoryCurvePath(
                            history: history,
                            endAt: endAt,
                            duration: durationSeconds,
                            size: geo.size
                        )
                        .stroke(TunerTheme.inTune, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    }
                }
            }
            .frame(height: 70)

            // Caption
            Text("−50 / 0 / +50 cents · last \(Int(durationSeconds)) seconds")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}

private struct HistoryCurvePath: Shape {
    let history: [HistoryPoint]
    let endAt: TimeInterval
    let duration: Double
    let size: CGSize

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard history.count >= 2 else { return path }

        func x(_ at: TimeInterval) -> CGFloat {
            let progress = (endAt - at) / duration
            let clamped = max(0.0, min(1.0, progress))
            return size.width - CGFloat(clamped) * size.width
        }

        func y(_ cents: Double) -> CGFloat {
            // Map -50 to +50 cents to height (top = +50, bottom = -50)
            let clamped = max(-50.0, min(50.0, cents))
            let normalized = 1.0 - ((clamped + 50.0) / 100.0)
            return CGFloat(normalized) * size.height
        }

        var inSegment = false
        for i in 1..<history.count {
            let prev = history[i - 1]
            let curr = history[i]

            let gap = curr.gapBefore || (curr.at - prev.at > 0.08) || (curr.targetIndex != prev.targetIndex)
            if gap {
                inSegment = false
                continue
            }

            if !inSegment {
                path.move(to: CGPoint(x: x(prev.at), y: y(prev.cents)))
                path.addLine(to: CGPoint(x: x(curr.at), y: y(curr.cents)))
                inSegment = true
            } else {
                path.addLine(to: CGPoint(x: x(curr.at), y: y(curr.cents)))
            }
        }
        return path
    }
}
