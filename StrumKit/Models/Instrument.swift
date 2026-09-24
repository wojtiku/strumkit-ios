import Foundation

/// Supported instrument types in StrumKit.
public enum InstrumentType: String, CaseIterable, Identifiable, Sendable {
    case guitar = "Guitar"
    case ukulele = "Ukulele"
    case chromatic = "Chromatic"

    public var id: String { rawValue }

    public var systemImage: String {
        switch self {
        case .guitar: "guitars.fill"
        case .ukulele: "music.note"
        case .chromatic: "waveform.path"
        }
    }
}

/// An instrument definition with associated tunings.
public struct Instrument: Identifiable, Hashable, Sendable {
    public let type: InstrumentType
    public let tunings: [Tuning]
    public let defaultTuning: Tuning

    public var id: String { type.rawValue }
    public var name: String { type.rawValue }

    public init(type: InstrumentType, tunings: [Tuning]) {
        self.type = type
        self.tunings = tunings
        self.defaultTuning = tunings.first ?? Tuning(id: "none", name: "None", strings: [])
    }

    /// Standard presets for Guitar, Ukulele, and Chromatic.
    public static func presets(referenceA4: Double = 440.0) -> [Instrument] {
        return [
            guitarInstrument(referenceA4: referenceA4),
            ukuleleInstrument(referenceA4: referenceA4),
            chromaticInstrument(referenceA4: referenceA4)
        ]
    }

    // MARK: - Guitar Presets
    public static func guitarInstrument(referenceA4: Double = 440.0) -> Instrument {
        // Standard Guitar: E2 (6), A2 (5), D3 (4), G3 (3), B3 (2), E4 (1)
        let standardStrings = [
            TunedString(stringNumber: 1, note: MusicalNote(noteName: .e, octave: 4, referenceA4: referenceA4)),
            TunedString(stringNumber: 2, note: MusicalNote(noteName: .b, octave: 3, referenceA4: referenceA4)),
            TunedString(stringNumber: 3, note: MusicalNote(noteName: .g, octave: 3, referenceA4: referenceA4)),
            TunedString(stringNumber: 4, note: MusicalNote(noteName: .d, octave: 3, referenceA4: referenceA4)),
            TunedString(stringNumber: 5, note: MusicalNote(noteName: .a, octave: 2, referenceA4: referenceA4)),
            TunedString(stringNumber: 6, note: MusicalNote(noteName: .e, octave: 2, referenceA4: referenceA4))
        ]

        let dropDStrings = [
            TunedString(stringNumber: 1, note: MusicalNote(noteName: .e, octave: 4, referenceA4: referenceA4)),
            TunedString(stringNumber: 2, note: MusicalNote(noteName: .b, octave: 3, referenceA4: referenceA4)),
            TunedString(stringNumber: 3, note: MusicalNote(noteName: .g, octave: 3, referenceA4: referenceA4)),
            TunedString(stringNumber: 4, note: MusicalNote(noteName: .d, octave: 3, referenceA4: referenceA4)),
            TunedString(stringNumber: 5, note: MusicalNote(noteName: .a, octave: 2, referenceA4: referenceA4)),
            TunedString(stringNumber: 6, note: MusicalNote(noteName: .d, octave: 2, referenceA4: referenceA4))
        ]

        let dadgadStrings = [
            TunedString(stringNumber: 1, note: MusicalNote(noteName: .d, octave: 4, referenceA4: referenceA4)),
            TunedString(stringNumber: 2, note: MusicalNote(noteName: .a, octave: 3, referenceA4: referenceA4)),
            TunedString(stringNumber: 3, note: MusicalNote(noteName: .g, octave: 3, referenceA4: referenceA4)),
            TunedString(stringNumber: 4, note: MusicalNote(noteName: .d, octave: 3, referenceA4: referenceA4)),
            TunedString(stringNumber: 5, note: MusicalNote(noteName: .a, octave: 2, referenceA4: referenceA4)),
            TunedString(stringNumber: 6, note: MusicalNote(noteName: .d, octave: 2, referenceA4: referenceA4))
        ]

        let halfStepDownStrings = [
            TunedString(stringNumber: 1, note: MusicalNote(noteName: .dSharp, octave: 4, referenceA4: referenceA4)),
            TunedString(stringNumber: 2, note: MusicalNote(noteName: .aSharp, octave: 3, referenceA4: referenceA4)),
            TunedString(stringNumber: 3, note: MusicalNote(noteName: .fSharp, octave: 3, referenceA4: referenceA4)),
            TunedString(stringNumber: 4, note: MusicalNote(noteName: .cSharp, octave: 3, referenceA4: referenceA4)),
            TunedString(stringNumber: 5, note: MusicalNote(noteName: .gSharp, octave: 2, referenceA4: referenceA4)),
            TunedString(stringNumber: 6, note: MusicalNote(noteName: .dSharp, octave: 2, referenceA4: referenceA4))
        ]

        let openGStrings = [
            TunedString(stringNumber: 1, note: MusicalNote(noteName: .d, octave: 4, referenceA4: referenceA4)),
            TunedString(stringNumber: 2, note: MusicalNote(noteName: .b, octave: 3, referenceA4: referenceA4)),
            TunedString(stringNumber: 3, note: MusicalNote(noteName: .g, octave: 3, referenceA4: referenceA4)),
            TunedString(stringNumber: 4, note: MusicalNote(noteName: .d, octave: 3, referenceA4: referenceA4)),
            TunedString(stringNumber: 5, note: MusicalNote(noteName: .g, octave: 2, referenceA4: referenceA4)),
            TunedString(stringNumber: 6, note: MusicalNote(noteName: .d, octave: 2, referenceA4: referenceA4))
        ]

        return Instrument(
            type: .guitar,
            tunings: [
                Tuning(id: "guitar-standard", name: "Standard (E A D G B E)", strings: standardStrings),
                Tuning(id: "guitar-drop-d", name: "Drop D (D A D G B E)", strings: dropDStrings),
                Tuning(id: "guitar-dadgad", name: "DADGAD", strings: dadgadStrings),
                Tuning(id: "guitar-half-step-down", name: "Half-Step Down (E♭)", strings: halfStepDownStrings),
                Tuning(id: "guitar-open-g", name: "Open G (D G D G B D)", strings: openGStrings)
            ]
        )
    }

    // MARK: - Ukulele Presets
    public static func ukuleleInstrument(referenceA4: Double = 440.0) -> Instrument {
        // Standard Ukulele (Re-entrant High-G): 1: A4, 2: E4, 3: C4, 4: G4
        let standardStrings = [
            TunedString(stringNumber: 1, note: MusicalNote(noteName: .a, octave: 4, referenceA4: referenceA4)),
            TunedString(stringNumber: 2, note: MusicalNote(noteName: .e, octave: 4, referenceA4: referenceA4)),
            TunedString(stringNumber: 3, note: MusicalNote(noteName: .c, octave: 4, referenceA4: referenceA4)),
            TunedString(stringNumber: 4, note: MusicalNote(noteName: .g, octave: 4, referenceA4: referenceA4))
        ]

        // Low-G Ukulele: 1: A4, 2: E4, 3: C4, 4: G3
        let lowGStrings = [
            TunedString(stringNumber: 1, note: MusicalNote(noteName: .a, octave: 4, referenceA4: referenceA4)),
            TunedString(stringNumber: 2, note: MusicalNote(noteName: .e, octave: 4, referenceA4: referenceA4)),
            TunedString(stringNumber: 3, note: MusicalNote(noteName: .c, octave: 4, referenceA4: referenceA4)),
            TunedString(stringNumber: 4, note: MusicalNote(noteName: .g, octave: 3, referenceA4: referenceA4))
        ]

        // Baritone Ukulele: 1: E4, 2: B3, 3: G3, 4: D3 (same as top 4 strings of guitar)
        let baritoneStrings = [
            TunedString(stringNumber: 1, note: MusicalNote(noteName: .e, octave: 4, referenceA4: referenceA4)),
            TunedString(stringNumber: 2, note: MusicalNote(noteName: .b, octave: 3, referenceA4: referenceA4)),
            TunedString(stringNumber: 3, note: MusicalNote(noteName: .g, octave: 3, referenceA4: referenceA4)),
            TunedString(stringNumber: 4, note: MusicalNote(noteName: .d, octave: 3, referenceA4: referenceA4))
        ]

        // D-Tuning (Traditional Soprano): 1: B4, 2: F#4, 3: D4, 4: A4
        let dTuningStrings = [
            TunedString(stringNumber: 1, note: MusicalNote(noteName: .b, octave: 4, referenceA4: referenceA4)),
            TunedString(stringNumber: 2, note: MusicalNote(noteName: .fSharp, octave: 4, referenceA4: referenceA4)),
            TunedString(stringNumber: 3, note: MusicalNote(noteName: .d, octave: 4, referenceA4: referenceA4)),
            TunedString(stringNumber: 4, note: MusicalNote(noteName: .a, octave: 4, referenceA4: referenceA4))
        ]

        return Instrument(
            type: .ukulele,
            tunings: [
                Tuning(id: "ukulele-standard", name: "Standard (g C E A)", strings: standardStrings),
                Tuning(id: "ukulele-low-g", name: "Low-G (G C E A)", strings: lowGStrings),
                Tuning(id: "ukulele-baritone", name: "Baritone (D G B E)", strings: baritoneStrings),
                Tuning(id: "ukulele-d-tuning", name: "D-Tuning (a D F♯ B)", strings: dTuningStrings)
            ]
        )
    }

    // MARK: - Chromatic Preset
    public static func chromaticInstrument(referenceA4: Double = 440.0) -> Instrument {
        return Instrument(
            type: .chromatic,
            tunings: [
                Tuning(id: "chromatic-all", name: "All 12 Semitones", strings: [])
            ]
        )
    }
}
