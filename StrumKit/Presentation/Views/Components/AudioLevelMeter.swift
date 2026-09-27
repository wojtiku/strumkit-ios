import SwiftUI

/// Discreet audio input meter displaying real-time RMS amplitude and noise gate threshold.
///
/// No view constructs this — `TunerView` shows the level through
/// `HardwareReadoutView` instead — so it is file-private, and the only thing that
/// can ever reach it is this file. Left in place rather than deleted: removing a
/// view is not a visibility change.
private struct AudioLevelMeter: View {
    let amplitudeRMS: Double
    let noiseGateThreshold: Float
    let isListening: Bool

    init(amplitudeRMS: Double, noiseGateThreshold: Float, isListening: Bool) {
        self.amplitudeRMS = amplitudeRMS
        self.noiseGateThreshold = noiseGateThreshold
        self.isListening = isListening
    }

    private var normalizedLevel: Double {
        guard isListening else { return 0.0 }
        // Non-linear dB scaling for natural perception
        let clamped = max(0.0, min(0.3, amplitudeRMS))
        return clamped / 0.3
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isListening ? "mic.fill" : "mic.slash.fill")
                .font(.caption2)
                .foregroundStyle(isListening ? Color.secondary : Color.red)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // Background track
                    Capsule()
                        .fill(TunerTheme.surfaceElevated)

                    // Active signal bar
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [TunerTheme.flat, TunerTheme.inTune],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(4, geo.size.width * normalizedLevel))
                        .animation(.linear(duration: 0.08), value: normalizedLevel)

                    // Noise gate threshold indicator marker
                    Rectangle()
                        .fill(Color.white.opacity(0.4))
                        .frame(width: 2, height: geo.size.height)
                        .offset(x: geo.size.width * Double(noiseGateThreshold / 0.3))
                }
            }
            .frame(height: 6)
        }
        .frame(height: 12)
        .padding(.horizontal, 24)
    }
}
