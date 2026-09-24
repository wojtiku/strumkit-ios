import Foundation

/// Represents the twelve pitch classes in standard Western chromatic scale.
public enum NoteName: String, CaseIterable, Identifiable, Sendable {
    case c = "C"
    case cSharp = "C♯"
    case d = "D"
    case dSharp = "D♯"
    case e = "E"
    case f = "F"
    case fSharp = "F♯"
    case g = "G"
    case gSharp = "G♯"
    case a = "A"
    case aSharp = "A♯"
    case b = "B"

    public var id: String { rawValue }

    /// Semitone offset from C (C=0, C#=1, ..., B=11)
    public var semitoneOffset: Int {
        switch self {
        case .c: 0
        case .cSharp: 1
        case .d: 2
        case .dSharp: 3
        case .e: 4
        case .f: 5
        case .fSharp: 6
        case .g: 7
        case .gSharp: 8
        case .a: 9
        case .aSharp: 10
        case .b: 11
        }
    }

    public static func from(semitoneOffset: Int) -> NoteName {
        let normalized = ((semitoneOffset % 12) + 12) % 12
        return NoteName.allCases[normalized]
    }
}

/// Represents a specific musical note with pitch class and octave (e.g., A4, E2).
public struct MusicalNote: Identifiable, Hashable, Sendable {
    public let noteName: NoteName
    public let octave: Int
    public let midiNoteNumber: Int
    public let frequency: Double

    public var id: Int { midiNoteNumber }

    /// Human-readable label like "E2", "A4", "G♯3"
    public var displayName: String {
        "\(noteName.rawValue)\(octave)"
    }

    /// Initializes a MusicalNote from MIDI note number and reference pitch A4.
    public init(midiNoteNumber: Int, referenceA4: Double = 440.0) {
        self.midiNoteNumber = midiNoteNumber
        let semitone = midiNoteNumber % 12
        self.noteName = NoteName.from(semitoneOffset: semitone)
        self.octave = (midiNoteNumber / 12) - 1
        // Frequency formula: f = A4 * 2^((midi - 69) / 12)
        self.frequency = referenceA4 * pow(2.0, Double(midiNoteNumber - 69) / 12.0)
    }

    /// Initializes a MusicalNote directly from note name and octave.
    public init(noteName: NoteName, octave: Int, referenceA4: Double = 440.0) {
        self.noteName = noteName
        self.octave = octave
        // MIDI 69 is A4: octave 4, A is semitone 9. (4 + 1) * 12 + 9 = 69.
        self.midiNoteNumber = (octave + 1) * 12 + noteName.semitoneOffset
        self.frequency = referenceA4 * pow(2.0, Double(self.midiNoteNumber - 69) / 12.0)
    }

    /// Finds the closest musical note and cents deviation for an arbitrary frequency.
    public static func closest(to frequency: Double, referenceA4: Double = 440.0) -> (note: MusicalNote, cents: Double)? {
        guard frequency > 10.0 && frequency < 10000.0 else { return nil }

        // Fractional MIDI note: 69 + 12 * log2(f / A4)
        let exactMidi = 69.0 + 12.0 * log2(frequency / referenceA4)
        let roundedMidi = Int(round(exactMidi))
        let closestNote = MusicalNote(midiNoteNumber: roundedMidi, referenceA4: referenceA4)

        // Cents formula: 1200 * log2(f / f_target)
        let cents = 1200.0 * log2(frequency / closestNote.frequency)
        return (closestNote, cents)
    }
}

/// Represents the analyzed pitch state emitted by the DSP pipeline.
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
        closestNote: MusicalNote(noteName: .a, octave: 4),
        centsDeviation: 0,
        confidence: 0,
        amplitudeRMS: 0,
        isSignalPresent: false
    )
}
