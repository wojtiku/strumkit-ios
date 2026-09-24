import SwiftUI

/// High-precision arc tuner gauge displaying cents deviation from -50 to +50.
public struct TunerDialView: View {
    let cents: Double
    let isInTune: Bool
    let isSignalPresent: Bool
    let tolerance: Double

    public init(
        cents: Double,
        isInTune: Bool,
        isSignalPresent: Bool,
        tolerance: Double = 3.0
    ) {
        self.cents = cents
        self.isInTune = isInTune
        self.isSignalPresent = isSignalPresent
        self.tolerance = tolerance
    }

    private var statusColor: Color {
        TunerTheme.statusColor(cents: cents, tolerance: tolerance, isSignalPresent: isSignalPresent)
    }

    // Needle angle mapped from -50...+50 cents to -50°...+50°
    private var needleAngle: Double {
        let clamped = max(-50.0, min(50.0, cents))
        return clamped
    }

    public var body: some View {
        VStack(spacing: 8) {
            ZStack {
                // Background Arc Track & Ticks
                GaugeArcShape()
                    .stroke(TunerTheme.gaugeTrack, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .frame(height: 140)

                // In-tune target center zone arc
                InTuneArcZone(toleranceCents: tolerance)
                    .stroke(TunerTheme.inTune.opacity(isInTune ? 0.9 : 0.3), style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .frame(height: 140)

                // Ticks along the arc
                GaugeTicksView()
                    .frame(height: 140)

                // Animated Needle Indicator
                NeedleView(angle: isSignalPresent ? needleAngle : 0, color: statusColor)
                    .frame(height: 140)
                    .animation(.spring(response: 0.25, dampingFraction: 0.75), value: needleAngle)

                // Pivot Center Knob with dynamic glow
                Circle()
                    .fill(statusColor)
                    .frame(width: 16, height: 16)
                    .shadow(color: isInTune ? TunerTheme.inTune.opacity(0.8) : .clear, radius: 10)
                    .offset(y: 50)
            }
            .frame(height: 150)

            // Cents Deviation Readout
            HStack(spacing: 4) {
                if isSignalPresent {
                    Text(cents >= 0 ? "+\(String(format: "%.1f", cents))" : "\(String(format: "%.1f", cents))")
                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                        .foregroundStyle(statusColor)

                    Text("cents")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Play a string")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 4)
        }
    }
}

// MARK: - Arc Path Components

private struct GaugeArcShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.maxY - 20)
        let radius = rect.width * 0.42

        // Arc from 220° to 320° (trigonometric standard)
        path.addArc(
            center: center,
            radius: radius,
            startAngle: .degrees(220),
            endAngle: .degrees(320),
            clockwise: false
        )
        return path
    }
}

private struct InTuneArcZone: Shape {
    let toleranceCents: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.maxY - 20)
        let radius = rect.width * 0.42

        // Center is 270°. Map tolerance to angle delta
        let deltaDegrees = (toleranceCents / 50.0) * 50.0
        path.addArc(
            center: center,
            radius: radius,
            startAngle: .degrees(270 - deltaDegrees),
            endAngle: .degrees(270 + deltaDegrees),
            clockwise: false
        )
        return path
    }
}

private struct GaugeTicksView: View {
    let majorSteps = Array(stride(from: -50, through: 50, by: 10))

    var body: some View {
        GeometryReader { geo in
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height - 20)
            let radius = geo.size.width * 0.42

            // Normal tick marks
            Path { path in
                for step in majorSteps where step != 0 {
                    let radians = (270.0 + Double(step)) * .pi / 180.0
                    let outer = CGPoint(
                        x: center.x + CGFloat(cos(radians)) * (radius + 9),
                        y: center.y + CGFloat(sin(radians)) * (radius + 9)
                    )
                    let inner = CGPoint(
                        x: center.x + CGFloat(cos(radians)) * radius,
                        y: center.y + CGFloat(sin(radians)) * radius
                    )
                    path.move(to: inner)
                    path.addLine(to: outer)
                }
            }
            .stroke(TunerTheme.gaugeTickMinor, lineWidth: 1.5)

            // Center target 0-cent tick mark
            Path { path in
                let radians = 270.0 * .pi / 180.0
                let outer = CGPoint(
                    x: center.x + CGFloat(cos(radians)) * (radius + 14),
                    y: center.y + CGFloat(sin(radians)) * (radius + 14)
                )
                let inner = CGPoint(
                    x: center.x + CGFloat(cos(radians)) * radius,
                    y: center.y + CGFloat(sin(radians)) * radius
                )
                path.move(to: inner)
                path.addLine(to: outer)
            }
            .stroke(TunerTheme.inTune, lineWidth: 2.5)
        }
    }
}

private struct NeedleView: View {
    let angle: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height - 20)
            let needleLength = geo.size.width * 0.41

            Path { p in
                p.move(to: center)
                p.addLine(to: CGPoint(x: center.x, y: center.y - needleLength))
            }
            .stroke(color, style: StrokeStyle(lineWidth: 3.0, lineCap: .round))
            .shadow(color: color.opacity(0.6), radius: 6)
            .rotationEffect(.degrees(angle), anchor: .init(x: 0.5, y: (geo.size.height - 20) / geo.size.height))
        }
    }
}
