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
        self.mode = mode == .manual ? .auto : mode
        self.precision = precision
        self.guided = guided && mode != .chromatic
    }

    /// Derives the active TunerConfig for the currently selected instrument.
    public func activeConfig() -> TunerConfig {
        let instrument = selectedInstrument
        let rawTuningId = instrument == .guitar ? guitarTuningId : ukuleleTuningId
        let availablePresets = Presets.presets(for: instrument)

        let tuningId: String
        let midi: [Int]
        if rawTuningId == "custom" {
            tuningId = "custom"
            let customMidi = instrument == .guitar ? guitarCustomMidi : ukuleleCustomMidi
            let expectedCount = instrument == .guitar ? 6 : 4
            let isValid = customMidi.count == expectedCount && customMidi.allSatisfy {
                $0 >= TunerConstants.customMidiMin && $0 <= TunerConstants.customMidiMax
            }
            midi = isValid ? customMidi : (instrument == .guitar ? Self.defaultGuitarMidi : Self.defaultUkuleleMidi)
        } else if let matched = availablePresets.first(where: { $0.id == rawTuningId }) {
            tuningId = matched.id
            midi = matched.midi
        } else {
            let fallback = availablePresets.first ?? Presets.guitar[0]
            tuningId = fallback.id
            midi = fallback.midi
        }

        let safeMode: TunerMode = (mode == .chromatic) ? .chromatic : (guided ? .guided : .auto)

        return TunerConfig(
            instrument: instrument,
            tuningId: tuningId,
            customMidi: midi,
            a4: a4,
            mode: safeMode,
            selectedString: 0,
            precision: precision,
            guided: guided && safeMode != .chromatic
        )
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
