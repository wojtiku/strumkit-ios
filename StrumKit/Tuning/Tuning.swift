import Foundation

/// Resolves what the player has chosen into what the tuner will actually do.
///
/// A **Tuning** reaches the app in three shapes: the id of a shipped **Preset**, the id of a
/// **Custom tuning** plus the **Note**s the player entered for it, or an id that names
/// nothing at all — a **Preset** retired between releases, or a save written by an older
/// build. All three are answered here, in one pass, and the answer carries both halves: the
/// configuration the tuner runs under, and the **Targets** its **Strings** are measured
/// against. Answering both together is the point — a configuration that disagrees with the
/// **Targets** is not a state this app can be in.
enum Tuning {
    /// The id a player's own **Tuning** is stored under, alongside the shipped **Preset** ids.
    static let customTuningId = "custom"

    /// What the player has chosen, resolved: what the tuner will do, and the **Targets** it
    /// will measure readings against.
    struct Resolved: Sendable {
        let config: TunerConfig
        let targets: [StringTarget]

        init(config: TunerConfig, targets: [StringTarget]) {
            self.config = config
            self.targets = targets
        }
    }

    /// Resolves the **Tuning** the stored preferences describe.
    static func resolve(_ preferences: TunerPreferences) -> Resolved {
        let instrument = preferences.selectedInstrument
        return resolve(
            instrument: instrument,
            tuningId: preferences.tuningId(for: instrument),
            customMidi: preferences.customMidi(for: instrument),
            mode: preferences.mode,
            a4: preferences.a4,
            precision: preferences.precision,
            guided: preferences.guided
        )
    }

    /// Resolves a **Tuning** choice into a configuration and its **Targets**.
    ///
    /// Nothing here traps. A **Custom tuning** of the wrong length, a **Note** outside the
    /// range the tuner can name, and an id matching no **Preset** all resolve to the
    /// **Instrument**'s default **Tuning** — a tuning the tuner can always play — rather than
    /// to something it cannot.
    ///
    /// - Parameters:
    ///   - tuningId: a **Preset** id, or `customTuningId` for the player's own **Tuning**.
    ///   - customMidi: the **Note** numbers of the **Custom tuning**, unvalidated.
    ///   - selectedString: the locked **String**, carried through untouched. A resolution
    ///     describes a **Tuning**; whether a lock survives it is the caller's decision.
    static func resolve(
        instrument: InstrumentCategory,
        tuningId: String,
        customMidi: [Int],
        mode: TunerMode,
        a4: Double,
        precision: Bool,
        guided: Bool,
        selectedString: Int = 0
    ) -> Resolved {
        let tuning = resolveTuning(
            instrument: instrument,
            tuningId: tuningId,
            customMidi: customMidi
        )
        let config = TunerConfig(
            instrument: instrument,
            tuningId: tuning.tuningId,
            customMidi: tuning.midi,
            a4: a4,
            mode: mode,
            selectedString: selectedString,
            precision: precision,
            guided: guided && mode != .chromatic
        )
        return Resolved(config: config, targets: targets(forMidi: tuning.midi, a4: a4))
    }

    /// The **Tuning** the choice resolves to: the id it resolves *to*, and the **Note**
    /// numbers of the **Strings** it tunes.
    private static func resolveTuning(
        instrument: InstrumentCategory,
        tuningId: String,
        customMidi: [Int]
    ) -> (tuningId: String, midi: [Int]) {
        if tuningId == customTuningId {
            return (customTuningId, isUsable(customMidi, for: instrument) ? customMidi : defaultMidi(for: instrument))
        }
        let presets = Presets.presets(for: instrument)
        let preset = presets.first(where: { $0.id == tuningId }) ?? presets.first ?? Presets.guitar[0]
        return (preset.id, preset.midi)
    }

    /// Whether a **Custom tuning** is one the tuner can play, and the only place that says.
    ///
    /// It has to name a **String** for every position the **Instrument** tunes, and every one
    /// of them has to be a **Note** inside the range the tuner can name — a half-filled array
    /// or a note off the end of the keyboard is a tuning the instrument does not have.
    private static func isUsable(_ customMidi: [Int], for instrument: InstrumentCategory) -> Bool {
        customMidi.count == stringCount(for: instrument)
            && customMidi.allSatisfy { $0 >= TunerConstants.customMidiMin && $0 <= TunerConstants.customMidiMax }
    }

    /// How many **Strings** an **Instrument** tunes. The default **Tuning** is one **Note**
    /// per **String**, so its length is the count — written once, not guessed twice.
    private static func stringCount(for instrument: InstrumentCategory) -> Int {
        defaultMidi(for: instrument).count
    }

    /// The **Tuning** an **Instrument** falls back to: standard for a guitar, High G for a
    /// ukulele. What a choice resolves to when it names nothing the tuner can play.
    private static func defaultMidi(for instrument: InstrumentCategory) -> [Int] {
        switch instrument {
        case .guitar: TunerPreferences.defaultGuitarMidi
        case .ukulele: TunerPreferences.defaultUkuleleMidi
        }
    }

    /// The **Targets** a resolved **Tuning** is measured against, one per **String** in
    /// playing order — string 6 down to 1 on a guitar.
    private static func targets(forMidi midi: [Int], a4: Double) -> [StringTarget] {
        let stringCount = midi.count
        return midi.enumerated().map { index, note in
            StringTarget(
                note: PitchMath.midiNoteName(note),
                midi: note,
                frequency: PitchMath.midiFrequency(note, a4: a4),
                number: stringCount - index
            )
        }
    }
}
