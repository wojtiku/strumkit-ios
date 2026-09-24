import SwiftUI

/// Hero component displaying the detected musical note, octave, frequency, and tune direction.
public struct NoteDisplayView: View {
    let note: MusicalNote
    let targetNote: MusicalNote?
    let frequency: Double
    let cents: Double
    let isInTune: Bool
    let isSignalPresent: Bool
    let tolerance: Double

    public init(
        note: MusicalNote,
        targetNote: MusicalNote? = nil,
        frequency: Double,
        cents: Double,
        isInTune: Bool,
        isSignalPresent: Bool,
        tolerance: Double = 3.0
    ) {
        self.note = note
        self.targetNote = targetNote
        self.frequency = frequency
        self.cents = cents
        self.isInTune = isInTune
        self.isSignalPresent = isSignalPresent
        self.tolerance = tolerance
    }

    private var activeNote: MusicalNote {
        targetNote ?? note
    }

    private var statusColor: Color {
        TunerTheme.statusColor(cents: cents, tolerance: tolerance, isSignalPresent: isSignalPresent)
    }

    public var body: some View {
        VStack(spacing: 6) {
            // Note & Octave Hero Display
            ZStack {
                // In-tune glowing aura
                if isInTune && isSignalPresent {
                    Circle()
                        .fill(TunerTheme.inTune.opacity(0.18))
                        .frame(width: 140, height: 140)
                        .blur(radius: 12)
                }

                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(isSignalPresent ? activeNote.noteName.rawValue : "--")
                        .font(.system(size: 84, weight: .heavy, design: .rounded))
                        .foregroundStyle(isSignalPresent ? statusColor : TunerTheme.neutral)

                    Text(isSignalPresent ? "\(activeNote.octave)" : "")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(isSignalPresent ? statusColor.opacity(0.8) : .clear)
                }
            }
            .frame(height: 100)

            // Tuning Direction Badge
            HStack(spacing: 6) {
                if !isSignalPresent {
                    Label("Listening", systemImage: "mic.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                } else if isInTune {
                    Label("IN TUNE", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.heavy))
                        .foregroundStyle(TunerTheme.inTune)
                } else if cents < -tolerance {
                    Label("TUNE UP", systemImage: "arrow.up.circle.fill")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(TunerTheme.flat)
                } else {
                    Label("TUNE DOWN", systemImage: "arrow.down.circle.fill")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(TunerTheme.sharp)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(TunerTheme.surfaceElevated)
            )

            // Frequency Readouts
            HStack(spacing: 16) {
                if isSignalPresent && frequency > 0 {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("DETECTED")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)
                        Text("\(String(format: "%.1f", frequency)) Hz")
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    }

                    Divider()
                        .frame(height: 24)

                    VStack(alignment: .trailing, spacing: 2) {
                        Text("TARGET")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)
                        Text("\(String(format: "%.1f", activeNote.frequency)) Hz")
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    }
                } else {
                    Text("Ready for instrument sound")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 6)
        }
    }
}
