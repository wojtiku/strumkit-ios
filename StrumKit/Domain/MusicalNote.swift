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
