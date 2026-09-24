import SwiftUI

/// Main musical note readout, cents indicator, guidance instructions, and heard/target frequencies.
public struct HardwareReadoutView: View {
    let reading: TunerReading?
    let lastTone: ToneMemory?
    let feedback: SignalFeedbackState
    let precision: Bool
    let selectedTarget: StringTarget?
    let mode: TunerMode

    public init(
        reading: TunerReading?,
        lastTone: ToneMemory?,
        feedback: SignalFeedbackState,
        precision: Bool,
        selectedTarget: StringTarget?,
        mode: TunerMode
    ) {
        self.reading = reading
        self.lastTone = lastTone
        self.feedback = feedback
        self.precision = precision
        self.selectedTarget = selectedTarget
        self.mode = mode
    }

    private var activeNoteName: String {
        reading?.note ?? lastTone?.note ?? "—"
    }

    private var noteParts: (name: String, octave: String) {
        PitchMath.splitNoteName(activeNoteName)
    }

    private var statusColor: Color {
        guard let reading else { return TunerTheme.neutral }
        if reading.inTune {
            return TunerTheme.inTune
        } else if reading.cents < 0 {
            return TunerTheme.flat
        } else {
            return TunerTheme.sharp
        }
    }

    private var guidanceText: String {
        if let reading {
            if reading.inTune {
                return "In tune"
            } else if reading.cents < 0 {
                return "Tune up"
            } else {
                return "Tune down"
            }
        }
        return feedback.advisoryMessage
    }

    private var formattedCents: String {
        guard let reading else {
            if let lastTone {
                switch lastTone.source {
                case .reference: return "Reference tone"
                case .target: return "Target tone"
                case .detected: return "Last note"
                }
            }
            return "—"
        }
        let mag = String(format: precision ? "%.1f" : "%.0f", abs(reading.cents))
        let sign = reading.cents > 0 ? "+" : "−"
        return "\(sign)\(mag) cents"
    }

    public var body: some View {
        VStack(spacing: 8) {
            // Hero Note Display with Superscript Octave
            HStack(alignment: .top, spacing: 2) {
                Text(noteParts.name)
                    .font(.system(size: 64, weight: .heavy, design: .rounded))
                    .foregroundStyle(reading != nil ? statusColor : TunerTheme.neutral)
                    .minimumScaleFactor(0.7)

                if !noteParts.octave.isEmpty {
                    Text(noteParts.octave)
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(reading != nil ? statusColor.opacity(0.85) : TunerTheme.neutral)
                        .offset(y: 6)
                }
            }
            .frame(height: 70)

            // Cents Readout
            Text(formattedCents)
                .font(.system(size: 16, weight: .semibold, design: .monospaced))
                .foregroundStyle(reading != nil ? statusColor : .secondary)

            // Flat / Sharp indicator tags
            HStack {
                Text("Flat")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(TunerTheme.flat.opacity(reading?.cents ?? 0 < 0 ? 1.0 : 0.4))
                Spacer()
                Text("Sharp")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(TunerTheme.sharp.opacity(reading?.cents ?? 0 > 0 ? 1.0 : 0.4))
            }
            .padding(.horizontal, 48)

            // Guidance Banner
            HStack(spacing: 6) {
                if reading?.inTune == true {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(TunerTheme.inTune)
                }
                Text(guidanceText)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(reading?.inTune == true ? TunerTheme.inTune : .primary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(TunerTheme.surfaceElevated)
            )

            // Frequency Comparison
            HStack(spacing: 24) {
                // Heard Frequency
                VStack(alignment: .leading, spacing: 2) {
                    Text("HEARD")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                    Text(reading?.frequency != nil ? "\(String(format: "%.1f", reading!.frequency)) Hz" : (lastTone != nil ? "\(String(format: "%.1f", lastTone!.frequency)) Hz" : "—"))
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                }

                Divider()
                    .frame(height: 20)

                // Target Frequency
                VStack(alignment: .trailing, spacing: 2) {
                    Text("TARGET")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                    if let reading {
                        Text("\(reading.target.note) · \(String(format: "%.1f", reading.target.frequency)) Hz")
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    } else if mode == .chromatic {
                        Text("Nearest note")
                            .font(.system(size: 13, weight: .medium))
                    } else if let selectedTarget {
                        Text("\(selectedTarget.note) · \(String(format: "%.1f", selectedTarget.frequency)) Hz")
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    } else {
                        Text("Any open string")
                            .font(.system(size: 13, weight: .medium))
                    }
                }
            }
            .padding(.top, 4)
        }
    }
}
