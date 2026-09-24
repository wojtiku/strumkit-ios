import Testing
import Foundation
@testable import StrumKit

@Suite("Tuner Preferences and Persistence Tests")
struct PreferencesTests {

    private func makeIsolatedStore() -> (TunerPreferencesStore, UserDefaults) {
        let suiteName = "com.strumkit.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = TunerPreferencesStore(userDefaults: defaults)
        return (store, defaults)
    }

    @Test("Default preferences match specification")
    func testDefaultPreferences() {
        let prefs = TunerPreferences()
        #expect(prefs.selectedInstrument == .guitar)
        #expect(prefs.guitarTuningId == "standard")
        #expect(prefs.ukuleleTuningId == "high-g")
        #expect(prefs.guitarCustomMidi == [40, 45, 50, 55, 59, 64])
        #expect(prefs.ukuleleCustomMidi == [67, 60, 64, 69])
        #expect(prefs.a4 == 440.0)
        #expect(prefs.mode == .auto)
        #expect(prefs.precision == false)
        #expect(prefs.guided == false)
    }

    @Test("Active config generation reflects selected instrument and tuning")
    func testActiveConfigGeneration() {
        var prefs = TunerPreferences()
        let guitarConfig = prefs.activeConfig()
        #expect(guitarConfig.instrument == .guitar)
        #expect(guitarConfig.tuningId == "standard")
        #expect(guitarConfig.customMidi == [40, 45, 50, 55, 59, 64])

        prefs.selectedInstrument = .ukulele
        prefs.ukuleleTuningId = "d-tuning"
        let ukeConfig = prefs.activeConfig()
        #expect(ukeConfig.instrument == .ukulele)
        #expect(ukeConfig.tuningId == "d-tuning")
        #expect(ukeConfig.customMidi == [69, 62, 66, 71])
    }

    @Test("Preferences store persists and reloads all settings correctly")
    func testPersistenceRoundTrip() {
        let (store, _) = makeIsolatedStore()

        var prefs = TunerPreferences()
        prefs.selectedInstrument = .ukulele
        prefs.guitarTuningId = "drop-d"
        prefs.ukuleleTuningId = "low-g"
        prefs.a4 = 432.0
        prefs.mode = .chromatic
        prefs.precision = true

        store.save(prefs)
        let loaded = store.load()

        #expect(loaded.selectedInstrument == .ukulele)
        #expect(loaded.guitarTuningId == "drop-d")
        #expect(loaded.ukuleleTuningId == "low-g")
        #expect(loaded.a4 == 432.0)
        #expect(loaded.mode == .chromatic)
        #expect(loaded.precision == true)
    }

    @Test("Calibration outside 415-466 Hz is safely clamped")
    func testCalibrationClamping() {
        let low = TunerPreferences(a4: 300.0)
        #expect(low.a4 == 415.0)

        let high = TunerPreferences(a4: 500.0)
        #expect(high.a4 == 466.0)

        let (store, _) = makeIsolatedStore()
        store.save(TunerPreferences(a4: 432.0))
        let loaded = store.load()
        #expect(loaded.a4 == 432.0)
    }

    @Test("Corrupted data in UserDefaults safely falls back to defaults")
    func testCorruptedDataFallback() {
        let (store, defaults) = makeIsolatedStore()
        defaults.set(Data("invalid json payload".utf8), forKey: TunerPreferencesStore.storageKey)

        let loaded = store.load()
        #expect(loaded.selectedInstrument == .guitar)
        #expect(loaded.a4 == 440.0)
        #expect(loaded.guitarTuningId == "standard")
    }

    @Test("TunerViewModel restores saved preferences on initialization")
    @MainActor
    func testViewModelRestoresSavedState() {
        let (store, _) = makeIsolatedStore()

        var saved = TunerPreferences()
        saved.selectedInstrument = .ukulele
        saved.ukuleleTuningId = "baritone"
        saved.a4 = 442.0
        saved.precision = true
        saved.mode = .chromatic
        store.save(saved)

        let viewModel = TunerViewModel(preferencesStore: store)

        #expect(viewModel.config.instrument == .ukulele)
        #expect(viewModel.config.tuningId == "baritone")
        #expect(viewModel.config.customMidi == [50, 55, 59, 64])
        #expect(viewModel.config.a4 == 442.0)
        #expect(viewModel.config.precision == true)
        #expect(viewModel.config.mode == .chromatic)
        #expect(viewModel.targets.count == 4)
    }

    @Test("TunerViewModel preserves separate tunings when toggling between instruments")
    @MainActor
    func testPerInstrumentTuningPersistenceInViewModel() {
        let (store, _) = makeIsolatedStore()
        let viewModel = TunerViewModel(preferencesStore: store)

        // Set Guitar to Drop D
        viewModel.setTuningPreset(id: "drop-d")
        #expect(viewModel.config.tuningId == "drop-d")
        #expect(viewModel.config.customMidi == [38, 45, 50, 55, 59, 64])

        // Switch to Ukulele and set to D-Tuning
        viewModel.setInstrument(.ukulele)
        #expect(viewModel.config.instrument == .ukulele)
        #expect(viewModel.config.tuningId == "high-g") // Ukulele default
        viewModel.setTuningPreset(id: "d-tuning")
        #expect(viewModel.config.tuningId == "d-tuning")
        #expect(viewModel.config.customMidi == [69, 62, 66, 71])

        // Switch back to Guitar - it should remember Drop D!
        viewModel.setInstrument(.guitar)
        #expect(viewModel.config.instrument == .guitar)
        #expect(viewModel.config.tuningId == "drop-d")
        #expect(viewModel.config.customMidi == [38, 45, 50, 55, 59, 64])

        // Switch back to Ukulele - it should remember D-Tuning!
        viewModel.setInstrument(.ukulele)
        #expect(viewModel.config.instrument == .ukulele)
        #expect(viewModel.config.tuningId == "d-tuning")
        #expect(viewModel.config.customMidi == [69, 62, 66, 71])

        // Create a new ViewModel instance to simulate restarting the app
        let freshViewModel = TunerViewModel(preferencesStore: store)
        #expect(freshViewModel.config.instrument == .ukulele)
        #expect(freshViewModel.config.tuningId == "d-tuning")

        freshViewModel.setInstrument(.guitar)
        #expect(freshViewModel.config.tuningId == "drop-d")
    }

    @Test("TunerViewModel saves calibration, precision, and custom notes on modification")
    @MainActor
    func testViewModelMutationsPersist() {
        let (store, _) = makeIsolatedStore()
        let viewModel = TunerViewModel(preferencesStore: store)

        viewModel.updateA4(432.0)
        viewModel.togglePrecision()
        viewModel.updateCustomMidi(stringIndex: 0, midi: 36) // Drop C low string

        let reloaded = store.load()
        #expect(reloaded.a4 == 432.0)
        #expect(reloaded.precision == true)
        #expect(reloaded.guitarTuningId == "custom")
        #expect(reloaded.guitarCustomMidi[0] == 36)
    }
}
