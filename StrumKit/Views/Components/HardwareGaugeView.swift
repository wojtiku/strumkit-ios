import SwiftUI

/// 21-tick hardware gauge inspired by chorder's SVG gauge.
/// Maps cents from -50 to +50 into an arc with needle angle -75° to +75°.
public struct HardwareGaugeView: View {
    let cents: Double
    let visible: Bool
    let inTune: Bool

    public init(cents: Double, visible: Bool, inTune: Bool) {
        self.cents = cents
        self.visible = visible
        self.inTune = inTune
    }

    // Angle: -50...+50 cents mapped directly to -75°...+75° (cents * 1.5)
    private var needleAngle: Double {
        let clamped = max(-50.0, min(50.0, cents))
        return clamped * 1.5
    }

    public var body: some View {
        ZStack {
            // Background Track Arc & 21 Ticks
            GaugeBackgroundView()

            // Target in-tune center arc highlight
            InTuneCenterArc()
                .stroke(
                    inTune ? TunerTheme.inTune : TunerTheme.inTune.opacity(0.35),
                    style: StrokeStyle(lineWidth: 6, lineCap: .round)
                )

            // Animated Needle
            if visible {
                NeedlePointerView(angle: needleAngle, inTune: inTune)
                    .animation(.spring(response: 0.22, dampingFraction: 0.72), value: needleAngle)
            }

            // Labels: -50, 0, +50
            VStack {
                Text("0")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(inTune ? TunerTheme.inTune : .secondary)
                    .padding(.top, 4)

                Spacer()

                HStack {
                    Text("−50")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("+50")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 2)
            }
        }
        .frame(height: 120)
    }
}

private struct GaugeBackgroundView: View {
    var body: some View {
        GeometryReader { geo in
            let radius = min(geo.size.width * 0.40, geo.size.height - 8)
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height + 4)

            // Arc track
            Path { path in
                path.addArc(
                    center: center,
                    radius: radius,
                    startAngle: .degrees(195), // 270 - 75
                    endAngle: .degrees(345),   // 270 + 75
                    clockwise: false
                )
            }
            .stroke(TunerTheme.gaugeTrack, style: StrokeStyle(lineWidth: 3, lineCap: .round))

            // 21 Ticks (i = 0...20, angle = -75 + i * 7.5)
            Path { path in
                for i in 0...20 {
                    let angleDeg = -75.0 + Double(i) * 7.5
                    let radians = (270.0 + angleDeg) * .pi / 180.0
                    let isCenter = (i == 10)
                    let isMajor = (i % 5 == 0)

                    let tickLength: CGFloat = isCenter ? 12 : (isMajor ? 8 : 5)

                    let outer = CGPoint(
                        x: center.x + CGFloat(cos(radians)) * (radius + tickLength),
                        y: center.y + CGFloat(sin(radians)) * (radius + tickLength)
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
        }
    }
}

private struct InTuneCenterArc: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let radius = min(rect.width * 0.40, rect.height - 8)
        let center = CGPoint(x: rect.midX, y: rect.height + 4)

        // Center zone: +/- 7.5 degrees (approx +/- 5 cents)
        path.addArc(
            center: center,
            radius: radius,
            startAngle: .degrees(270 - 7.5),
            endAngle: .degrees(270 + 7.5),
            clockwise: false
        )
        return path
    }
}

private struct NeedlePointerView: View {
    let angle: Double
    let inTune: Bool

    var body: some View {
        GeometryReader { geo in
            let radius = min(geo.size.width * 0.40, geo.size.height - 8)
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height + 4)
            let needleLength = radius * 0.95

            Path { path in
                path.move(to: center)
                path.addLine(to: CGPoint(x: center.x, y: center.y - needleLength))
            }
            .stroke(
                inTune ? TunerTheme.inTune : (angle < 0 ? TunerTheme.flat : TunerTheme.sharp),
                style: StrokeStyle(lineWidth: 3.0, lineCap: .round)
            )
            .shadow(
                color: inTune ? TunerTheme.inTune.opacity(0.8) : Color.clear,
                radius: 8
            )
            .rotationEffect(
                .degrees(angle),
                anchor: .init(x: 0.5, y: (geo.size.height + 4) / geo.size.height)
            )
        }
    }
}
