import Foundation

/// Persistent user preferences for the StrumKit instrument tuner.
/// Remembers instrument choice, tuning presets per instrument, reference pitch calibration,
/// detection mode, and precision settings across app launches.
public struct TunerPreferences: Sendable, Equatable, Codable {
    public var selectedInstrument: InstrumentCategory
    public var guitarTuningId: String
    public var ukuleleTuningId: String
    public var guitarCustomMidi: [Int]
    public var ukuleleCustomMidi: [Int]
    public var a4: Double
    public var mode: TunerMode
    public var precision: Bool
    public var guided: Bool

    public static let defaultGuitarMidi: [Int] = [40, 45, 50, 55, 59, 64]
    public static let defaultUkuleleMidi: [Int] = [67, 60, 64, 69]

    public init(
        selectedInstrument: InstrumentCategory = .guitar,
        guitarTuningId: String = "standard",
        ukuleleTuningId: String = "high-g",
        guitarCustomMidi: [Int] = defaultGuitarMidi,
        ukuleleCustomMidi: [Int] = defaultUkuleleMidi,
        a4: Double = TunerConstants.defaultA4Hz,
        mode: TunerMode = .auto,
        precision: Bool = false,
        guided: Bool = false
    ) {
        self.selectedInstrument = selectedInstrument
        self.guitarTuningId = guitarTuningId
        self.ukuleleTuningId = ukuleleTuningId
        self.guitarCustomMidi = guitarCustomMidi
        self.ukuleleCustomMidi = ukuleleCustomMidi
        self.a4 = max(TunerConstants.minCalibrationHz, min(TunerConstants.maxCalibrationHz, a4))
        self.precision = precision

        // `guided` is the flag; the mode is what the player is shown. They cannot disagree
        // across a save, because a saved **String** lock names an index into a **Tuning**
        // that may not be loaded yet. A lock is live state, not a preference, so a stored
        // `.manual` never survives a launch — but `.manual` set while the app is running
        // does, and that path never comes through here.
        self.guided = guided && mode != .chromatic
        self.mode = Self.storableMode(mode, guided: self.guided)
    }

    /// The mode a **Tuning** choice is stored under: Chromatic, Guided, or Auto. Anything
    /// else — a lock, or a mode that disagrees with `guided` — is not a durable choice.
    private static func storableMode(_ mode: TunerMode, guided: Bool) -> TunerMode {
        if mode == .chromatic { return .chromatic }
        return guided ? .guided : .auto
    }

    /// The **Tuning** stored for one **Instrument**: a **Preset** id, or `Tuning.customTuningId`.
    public func tuningId(for instrument: InstrumentCategory) -> String {
        switch instrument {
        case .guitar: guitarTuningId
        case .ukulele: ukuleleTuningId
        }
    }

    /// The **Note** numbers entered for a **Custom tuning** on one **Instrument**.
    ///
    /// As stored, unvalidated: whether they name a tuning the player can play is
    /// `Tuning`'s decision, not this struct's.
    public func customMidi(for instrument: InstrumentCategory) -> [Int] {
        switch instrument {
        case .guitar: guitarCustomMidi
        case .ukulele: ukuleleCustomMidi
        }
    }

    /// Records a **Tuning** choice for one **Instrument**, leaving the other one alone.
    ///
    /// - Parameter customMidi: the **Note** numbers of a **Custom tuning**. Left as it was
    ///   when omitted, so choosing a shipped **Preset** does not disturb a **Custom tuning**
    ///   the player may still want back.
    public mutating func setTuning(_ tuningId: String, customMidi: [Int]? = nil, for instrument: InstrumentCategory) {
        switch instrument {
        case .guitar:
            guitarTuningId = tuningId
            if let customMidi { guitarCustomMidi = customMidi }
        case .ukulele:
            ukuleleTuningId = tuningId
            if let customMidi { ukuleleCustomMidi = customMidi }
        }
    }

    /// The configuration the tuner will run under for the stored choices.
    ///
    /// A read of the one resolution in `Tuning` — the same resolution the **Targets** come
    /// from, so the two cannot describe different tunings.
    public func activeConfig() -> TunerConfig {
        Tuning.resolve(self).config
    }
}

/// Storage interface for saving and loading TunerPreferences via UserDefaults.
public final class TunerPreferencesStore: @unchecked Sendable {
    public static let storageKey = "com.strumkit.tuner.preferences.v1"
    private let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    public func load() -> TunerPreferences {
        guard let data = userDefaults.data(forKey: Self.storageKey) else {
            return TunerPreferences()
        }
        do {
            let decoder = JSONDecoder()
            let decoded = try decoder.decode(TunerPreferences.self, from: data)
            // Normalize calibration and mode on load
            return TunerPreferences(
                selectedInstrument: decoded.selectedInstrument,
                guitarTuningId: decoded.guitarTuningId,
                ukuleleTuningId: decoded.ukuleleTuningId,
                guitarCustomMidi: decoded.guitarCustomMidi,
                ukuleleCustomMidi: decoded.ukuleleCustomMidi,
                a4: decoded.a4,
                mode: decoded.mode,
                precision: decoded.precision,
                guided: decoded.guided
            )
        } catch {
            print("[StrumKit] Failed to decode saved preferences: \(error). Falling back to defaults.")
            return TunerPreferences()
        }
    }

    public func save(_ preferences: TunerPreferences) {
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(preferences)
            userDefaults.set(data, forKey: Self.storageKey)
        } catch {
            print("[StrumKit] Failed to encode preferences: \(error)")
        }
    }

    public func clear() {
        userDefaults.removeObject(forKey: Self.storageKey)
    }
}
