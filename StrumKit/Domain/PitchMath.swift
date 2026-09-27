import Foundation

/// Utility functions for MIDI note numbers, frequencies, and cents.
enum PitchMath {
    private static let noteNames = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]

    /// Returns note string with octave, e.g. "E2", "A4", "F♯3"
    static func midiNoteName(_ midi: Int) -> String {
        let normalized = ((midi % 12) + 12) % 12
        let octave = (midi / 12) - 1
        return "\(noteNames[normalized])\(octave)"
    }

    /// Splits note name into base and octave string, e.g. ("E", "2") or ("F♯", "3")
    static func splitNoteName(_ fullName: String) -> (name: String, octave: String) {
        let pattern = #"^(.*?)(-?\d+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: fullName, range: NSRange(fullName.startIndex..., in: fullName)),
              let nameRange = Range(match.range(at: 1), in: fullName),
              let octaveRange = Range(match.range(at: 2), in: fullName) else {
            return (fullName, "")
        }
        return (String(fullName[nameRange]), String(fullName[octaveRange]))
    }

    /// Calculates ideal frequency for a given MIDI note number and reference A4.
    static func midiFrequency(_ midi: Int, a4: Double = TunerConstants.defaultA4Hz) -> Double {
        return a4 * pow(2.0, Double(midi - 69) / 12.0)
    }

    /// Calculates cents difference from reference frequency to measured frequency: 1200 * log2(measured / reference).
    static func centsBetween(measured: Double, reference: Double) -> Double {
        guard measured > 0, reference > 0 else { return 0.0 }
        return 1200.0 * log2(measured / reference)
    }

    /// Finds nearest MIDI note and cents deviation for a given frequency.
    static func nearestMidi(for frequency: Double, a4: Double = TunerConstants.defaultA4Hz) -> (midi: Int, note: String, cents: Double)? {
        guard frequency >= TunerConstants.detectorMinHz && frequency <= TunerConstants.detectorMaxHz else { return nil }
        let exactMidi = 69.0 + 12.0 * log2(frequency / a4)
        let rounded = Int(round(exactMidi))
        let targetFreq = midiFrequency(rounded, a4: a4)
        let cents = centsBetween(measured: frequency, reference: targetFreq)
        return (rounded, midiNoteName(rounded), cents)
    }
}
