import SwiftUI

/// Main musical note readout, cents indicator, guidance instructions, and the heard
/// frequency beside whatever the Reading is measured against.
struct HardwareReadoutView: View {
    let reading: TunerReading?
    let lastTone: ToneMemory?
    let feedback: SignalFeedbackState
    let precision: Bool
    let selectedTarget: StringTarget?
    let mode: TunerMode
    let holdOpacity: Double

    init(
        reading: TunerReading?,
        lastTone: ToneMemory?,
        feedback: SignalFeedbackState,
        precision: Bool,
        selectedTarget: StringTarget?,
        mode: TunerMode,
        holdOpacity: Double = 1.0
    ) {
        self.reading = reading
        self.lastTone = lastTone
        self.feedback = feedback
        self.precision = precision
        self.selectedTarget = selectedTarget
        self.mode = mode
        self.holdOpacity = holdOpacity
    }

    private var activeNoteName: String {
        reading?.note ?? lastTone?.note ?? "—"
    }

    private var noteParts: (name: String, octave: String) {
        PitchMath.splitNoteName(activeNoteName)
    }

    private var statusColor: Color {
        guard let reading else { return TunerTheme.neutral }
        // Green is a verdict about a String, so it is only available to a Reading that
        // carries one. A chromatic Reading is measured against equal temperament and is
        // coloured by which side of it the sound fell on, which is a fact rather than a
        // verdict — which is all the mode can honestly show.
        if reading.inTune == true {
            return TunerTheme.inTune
        } else if reading.cents < 0 {
            return TunerTheme.flat
        } else {
            return TunerTheme.sharp
        }
    }

    /// Opacity applied to evidence-derived readouts. Held readings fade with the
    /// hold timer; Sustained readings are dimmed to a fixed, still visible level so
    /// the player can tell inferred evidence from measured evidence at a glance.
    private var evidenceOpacity: Double {
        if reading?.freshness == .held { return holdOpacity }
        if reading?.evidence == .sustained { return TunerPresentation.recoveredOpacity }
        return 1.0
    }

    private var guidanceText: String {
        TunerPresentation.guidanceText(for: reading, feedback: feedback)
    }

    /// The in-tune confirmation is only ever shown for a fresh Reading backed by
    /// Measured evidence. A held Reading merely remembers the last verdict, and a
    /// Sustained one is not precise enough to confirm. A chromatic Reading has no
    /// verdict to remember in the first place, so the check is never reached.
    private var showsInTuneConfirmation: Bool {
        reading?.inTune == true && reading?.freshness == .fresh
            && reading?.evidence.mayAssertInTune == true
    }

    /// What the second column names, decided in `TunerPresentation` so the choice
    /// between "a String the player is aiming at" and "the pitch equal temperament
    /// says this was" is made once, in a testable place, rather than here.
    private var measuredAgainst: TunerPresentation.MeasuredAgainst {
        TunerPresentation.measuredAgainst(
            for: reading,
            selectedTarget: selectedTarget,
            mode: mode
        )
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

    var body: some View {
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
            .opacity(evidenceOpacity)

            // Cents Readout
            Text(formattedCents)
                .font(.system(size: 16, weight: .semibold, design: .monospaced))
                .foregroundStyle(reading != nil ? statusColor : .secondary)
                .opacity(evidenceOpacity)

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
            .opacity(evidenceOpacity)

            // Guidance Banner
            HStack(spacing: 6) {
                if showsInTuneConfirmation {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(TunerTheme.inTune)
                }
                Text(guidanceText)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(showsInTuneConfirmation ? TunerTheme.inTune : .primary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(TunerTheme.surfaceElevated)
            )
            .opacity(evidenceOpacity)

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

                // The thing this Reading is measured against: a String, or a Note in
                // equal temperament. The label says which.
                VStack(alignment: .trailing, spacing: 2) {
                    Text(measuredAgainst.label)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                    Text(measuredAgainst.value)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                }
            }
            .padding(.top, 4)
        }
    }
}
