import SwiftUI

/// 21-tick hardware gauge inspired by chorder's SVG gauge.
/// Maps cents from -50 to +50 into an arc with needle angle -75° to +75°.
public struct HardwareGaugeView: View {
    let cents: Double
    let visible: Bool
    let inTune: Bool
    let needleOpacity: Double

    /// Set while a freshly-acquired note is still easing in from centre.
    ///
    /// The spring on `presentedAngle` can only interpolate between two values the view
    /// has already rendered. When a note is acquired the needle is *inserted*, and
    /// `PitchTracker` resets `displayCentsEma` to the raw reading at exactly that moment
    /// (`PitchTracker.swift`, the `targetChanged` branch) — so there is no previous angle
    /// to ease from and the needle would land at full deflection instantly. That is the
    /// "jumps straight to a weird reading" case, and it needs the entry to start at zero
    /// rather than at the measurement.
    @State private var enteringNote = false
    @State private var entryTask: Task<Void, Never>?

    public init(cents: Double, visible: Bool, inTune: Bool, needleOpacity: Double = 1.0) {
        self.cents = cents
        self.visible = visible
        self.inTune = inTune
        self.needleOpacity = needleOpacity
    }

    // Angle: -50...+50 cents mapped directly to -75°...+75° (cents * 1.5)
    private var needleAngle: Double {
        let clamped = max(-50.0, min(50.0, cents))
        return clamped * 1.5
    }

    /// What the needle actually renders: pinned to centre while a new note eases in.
    private var presentedAngle: Double {
        enteringNote ? 0 : needleAngle
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
                // Interpolate the needle between readings rather than snapping.
                //
                // This was `.animation(nil, ...)`, which opted out entirely. That was not
                // a fix for a bug, it was the bug: `PitchTracker` already smooths
                // `displayCents` with a tau=50 ms EMA (`PitchTracker.displayEmaTimeConstant`),
                // so the needle is being handed roughly 47 updates/second — and each one
                // was being drawn at its final position with no interpolation. The data
                // was continuous; the rendering threw that away and made it look like
                // the detector was snapping.
                //
                // The spring is deliberately soft (stiffness 220, damping 26, just under
                // critical) so the needle eases into a new reading instead of arriving
                // instantly, and damped enough not to overshoot: a tuner needle that
                // bounces past the pitch it is reporting would be actively misleading.
                //
                // GuitarTuna reaches the same calm with coarser data — its detector floors
                // `MeasuredPitchHz` to whole Hz, which at E2 is ~21 cents per step — and
                // hides it the same way, by animating the presentation rather than by
                // smoothing the signal.
                NeedlePointerView(angle: presentedAngle, inTune: inTune)
                    .opacity(needleOpacity)
                    .animation(.interpolatingSpring(stiffness: 220, damping: 26), value: presentedAngle)
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
        .onChange(of: visible) { _, isVisible in
            // Acquired a note: pin the needle to centre for one runloop, then release it
            // so the spring carries it out to the real reading. Without the pin the
            // first rendered frame is already the final angle, because the view was
            // inserted rather than moved.
            guard isVisible else {
                enteringNote = false
                return
            }
            entryTask?.cancel()
            entryTask = Task { @MainActor in
                enteringNote = true
                // One frame at centre, so the release below is a change the spring can
                // interpolate from rather than an insertion it cannot.
                await Task.yield()
                enteringNote = false
            }
        }
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
