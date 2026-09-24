import Foundation

/// Supported instruments matching chorder specification.
public enum InstrumentCategory: String, CaseIterable, Identifiable, Sendable {
    case guitar = "guitar"
    case ukulele = "ukulele"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .guitar: "Guitar"
        case .ukulele: "Ukulele"
        }
    }
}

/// The standard tuning calibration frequency constants.
public enum TunerConstants {
    public static let defaultA4Hz: Double = 440.0
    public static let minCalibrationHz: Double = 415.0
    public static let maxCalibrationHz: Double = 466.0

    public static let customMidiMin: Int = 33 // A1
    public static let customMidiMax: Int = 83 // B5

    public static let detectorMinHz: Double = 60.0
    public static let detectorMaxHz: Double = 1200.0

    public static let maxDetuningCents: Double = 200.0
    public static let historyDurationSeconds: Double = 7.0
}

/// Utility functions for MIDI note numbers, frequencies, and cents.
public enum PitchMath {
    private static let noteNames = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]

    /// Returns note string with octave, e.g. "E2", "A4", "F♯3"
    public static func midiNoteName(_ midi: Int) -> String {
        let normalized = ((midi % 12) + 12) % 12
        let octave = (midi / 12) - 1
        return "\(noteNames[normalized])\(octave)"
    }

    /// Splits note name into base and octave string, e.g. ("E", "2") or ("F♯", "3")
    public static func splitNoteName(_ fullName: String) -> (name: String, octave: String) {
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
    public static func midiFrequency(_ midi: Int, a4: Double = TunerConstants.defaultA4Hz) -> Double {
        return a4 * pow(2.0, Double(midi - 69) / 12.0)
    }

    /// Calculates cents difference from reference frequency to measured frequency: 1200 * log2(measured / reference).
    public static func centsBetween(measured: Double, reference: Double) -> Double {
        guard measured > 0, reference > 0 else { return 0.0 }
        return 1200.0 * log2(measured / reference)
    }

    /// Finds nearest MIDI note and cents deviation for a given frequency.
    public static func nearestMidi(for frequency: Double, a4: Double = TunerConstants.defaultA4Hz) -> (midi: Int, note: String, cents: Double)? {
        guard frequency >= TunerConstants.detectorMinHz && frequency <= TunerConstants.detectorMaxHz else { return nil }
        let exactMidi = 69.0 + 12.0 * log2(frequency / a4)
        let rounded = Int(round(exactMidi))
        let targetFreq = midiFrequency(rounded, a4: a4)
        let cents = centsBetween(measured: frequency, reference: targetFreq)
        return (rounded, midiNoteName(rounded), cents)
    }
}

/// Represents a specific musical note with pitch class and octave (e.g., A4, E2).
public struct MusicalNote: Identifiable, Hashable, Sendable {
    public let midiNoteNumber: Int
    public let frequency: Double
    public let displayName: String

    public var id: Int { midiNoteNumber }

    public init(midiNoteNumber: Int, referenceA4: Double = TunerConstants.defaultA4Hz) {
        self.midiNoteNumber = midiNoteNumber
        self.frequency = PitchMath.midiFrequency(midiNoteNumber, a4: referenceA4)
        self.displayName = PitchMath.midiNoteName(midiNoteNumber)
    }

    public static func closest(to frequency: Double, referenceA4: Double = TunerConstants.defaultA4Hz) -> (note: MusicalNote, cents: Double)? {
        guard let nearest = PitchMath.nearestMidi(for: frequency, a4: referenceA4) else { return nil }
        return (MusicalNote(midiNoteNumber: nearest.midi, referenceA4: referenceA4), nearest.cents)
    }
}

/// Analyzed pitch state from the DSP pipeline.
public struct PitchResult: Sendable, Equatable {
    public let frequency: Double
    public let closestNote: MusicalNote
    public let centsDeviation: Double
    public let confidence: Double
    public let amplitudeRMS: Double
    public let isSignalPresent: Bool

    public init(
        frequency: Double,
        closestNote: MusicalNote,
        centsDeviation: Double,
        confidence: Double,
        amplitudeRMS: Double,
        isSignalPresent: Bool
    ) {
        self.frequency = frequency
        self.closestNote = closestNote
        self.centsDeviation = centsDeviation
        self.confidence = confidence
        self.amplitudeRMS = amplitudeRMS
        self.isSignalPresent = isSignalPresent
    }

    public static let idle = PitchResult(
        frequency: 0,
        closestNote: MusicalNote(midiNoteNumber: 69),
        centsDeviation: 0,
        confidence: 0,
        amplitudeRMS: 0,
        isSignalPresent: false
    )
}

