import Foundation

/// Storage interface for saving and loading TunerPreferences via UserDefaults.
final class TunerPreferencesStore: @unchecked Sendable {
    static let storageKey = "com.strumkit.tuner.preferences.v1"
    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func load() -> TunerPreferences {
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

    func save(_ preferences: TunerPreferences) {
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(preferences)
            userDefaults.set(data, forKey: Self.storageKey)
        } catch {
            print("[StrumKit] Failed to encode preferences: \(error)")
        }
    }

    func clear() {
        userDefaults.removeObject(forKey: Self.storageKey)
    }
}
