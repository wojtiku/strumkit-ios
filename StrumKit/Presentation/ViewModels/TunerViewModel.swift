import Foundation
import Observation

/// What the tuner screen shows and what the player can change: the **Tuning** choice,
/// the preferences it is saved in, and the **Reading** on display.
///
/// Whether the tuner is listening at all is not decided here. That is the listening
/// lifecycle's, and this type only reports its status and clears the display when
/// listening stops.
@MainActor
@Observable
final class TunerViewModel {
    // MARK: - Configuration
    /// The player's choice, resolved: what the tuner will do, and the **Targets** it will
    /// measure readings against.
    ///
    /// The single source of both, so `config` and `targets` cannot describe different
    /// tunings. Every setter re-resolves rather than editing one without the other.
    private var resolved: Tuning.Resolved

    /// What the tuner will do. A read of `resolved`, the same value `targets` reads.
    var config: TunerConfig { resolved.config }
    var targets: [StringTarget] { resolved.targets }
    var preferences: TunerPreferences

    /// Whether the readout shows tenths of a cent. A display preference: it changes
    /// nothing about what is heard, so the analysis is not told and a **Reading** in
    /// progress carries on.
    var precision: Bool { preferences.precision }

    // MARK: - What is on display
    var currentReading: TunerReading? = nil
    /// The cents the readout prints. The needle takes every **Reading**; a number that
    /// changed as often would be unreadable, so this follows at a reading pace.
    private(set) var readoutCents: Double? = nil
    @ObservationIgnored private var readoutUpdatedAt: TimeInterval = -.infinity
    @ObservationIgnored private var readoutNote: String? = nil
    private static let readoutInterval: TimeInterval = 0.15
    var lastTone: ToneMemory? = nil
    var feedbackState: SignalFeedbackState = .inactive
    var diagnostics: TunerDiagnostics = TunerDiagnostics()
    var guidedProgress: [Bool] = []
    var guidedTargetIndex: Int = 0

    // MARK: - Listening
    var engineStatus: EngineStatus { lifecycle.status }
    var activeToneStringIndex: Int? { lifecycle.activeToneStringIndex }

    /// Measured level of the audio the capture tap is actually delivering.
    ///
    /// This is the first thing to check when a detector "does nothing": a simulator HAL
    /// client can start cleanly, report "Listening" with a live latency, and still deliver
    /// pure silence, which looks exactly like a broken algorithm.
    var inputLevel: TunerAnalysisSession.InputLevel {
        session.inputLevel
    }

    /// Opacity the gauge needle should render at, given the hold fade.
    ///
    /// The fade itself is the display's: it is derived from the Reading's last-fresh
    /// time and the display's own timeline, which is why this takes it as an argument
    /// rather than reading a clock. What is decided here is how the fade and the
    /// de-emphasis applied to Sustained evidence combine, so an inferred Reading never
    /// looks as authoritative as a measured one however far through the hold it is.
    func needleOpacity(holdFade: Double) -> Double {
        if currentReading?.evidence == .sustained {
            return min(holdFade, TunerPresentation.sustainedOpacity)
        }
        return holdFade
    }

    // MARK: - Collaborators
    private let preferencesStore: TunerPreferencesStore
    private let session: TunerAnalysisSession
    @ObservationIgnored private var lifecycle: ListeningLifecycle!

    /// The live app's wiring: a real microphone and the real synthesiser.
    ///
    /// The composition root's job, deliberately not the initialiser's default, so
    /// that no caller can reach the ViewModel without saying what it listens to.
    static func live(
        preferencesStore: TunerPreferencesStore = TunerPreferencesStore()
    ) -> TunerViewModel {
        TunerViewModel(
            source: AVAudioEngineMicrophone(),
            referenceTone: AcousticStringSynthesizer(),
            preferencesStore: preferencesStore
        )
    }

    /// The microphone and the reference-tone player are required, not defaulted. A
    /// default here would hand a test a real microphone by omission, and a test that
    /// drives real audio hardware is a test that cannot assert anything.
    init(
        source: MicrophoneSource,
        referenceTone: ReferenceTonePlayer,
        preferencesStore: TunerPreferencesStore = TunerPreferencesStore(),
        session: TunerAnalysisSession? = nil
    ) {
        self.preferencesStore = preferencesStore

        let loaded = preferencesStore.load()
        self.preferences = loaded
        let initial = Tuning.resolve(loaded)
        self.resolved = initial

        let session = session ?? TunerAnalysisSession(config: initial.config, targets: initial.targets)
        self.session = session
        self.guidedProgress = Array(repeating: false, count: initial.targets.count)

        let lifecycle = ListeningLifecycle(
            source: source,
            referenceTone: referenceTone,
            session: session,
            tuning: { initial }
        )
        self.lifecycle = lifecycle

        lifecycle.tuning = { [unowned self] in self.resolved }
        lifecycle.onStatusChange = { [weak self] status in
            self?.listeningStatusChanged(to: status)
        }
        session.onSnapshotPublished = { [weak self] snapshot in
            self?.handleSnapshot(snapshot)
        }
    }

    // MARK: - Listening
    func start() async {
        await lifecycle.start()
    }

    func stop() {
        lifecycle.stop()
    }

    /// What the display does when listening starts or stops. A **Reading** is a claim
    /// about what is sounding; with the microphone off there is nothing to claim.
    private func listeningStatusChanged(to status: EngineStatus) {
        if status == .listening {
            feedbackState = .ready
            diagnostics.sampleRate = lifecycle.sampleRate
        } else {
            currentReading = nil
            feedbackState = .inactive
        }
    }

    // MARK: - Snapshot Handler (Session -> UI)
    internal func handleSnapshot(_ snapshot: AnalysisSnapshot) {
        guard snapshot.generation == session.generation else { return }
        diagnostics = snapshot.diagnostics
        feedbackState = snapshot.feedbackState
        guidedProgress = snapshot.guidedProgress
        guidedTargetIndex = snapshot.guidedTargetIndex

        // A snapshot with no Reading means the hold has expired: the engine owns the
        // one-second hold and says when it is over.
        currentReading = snapshot.reading
        if let reading = snapshot.reading {
            if readoutCents == nil || reading.note != readoutNote
                || reading.at - readoutUpdatedAt >= Self.readoutInterval || reading.at < readoutUpdatedAt {
                readoutCents = reading.displayCents
                readoutUpdatedAt = reading.at
                readoutNote = reading.note
            }
        } else {
            readoutCents = nil
        }
        if let reading = snapshot.reading, reading.freshness == .fresh {
            lastTone = ToneMemory(
                note: reading.note,
                frequency: reading.frequency,
                source: .detected,
                reading: reading
            )
        }
    }

    // MARK: - Resolution
    /// Re-resolves the player's tuning choice, after `edit` adjusts the parts of the
    /// configuration that are not the choice itself.
    ///
    /// The choice — which **Instrument**, which **Tuning** id, which **Note**s for a
    /// **Custom tuning** — is read from `preferences`, which is where the player's selection
    /// is recorded; the resolution then decides what that choice actually means. `edit`'s
    /// `tuningId` and `customMidi` are therefore ignored: only `config` and `targets` come
    /// out of `Tuning.resolve`, so there is nothing for a caller to keep in step by hand.
    private func applyResolution(_ edit: (inout TunerConfig) -> Void = { _ in }) {
        var config = resolved.config
        edit(&config)
        let instrument = config.instrument
        resolved = Tuning.resolve(
            instrument: instrument,
            tuningId: preferences.tuningId(for: instrument),
            customMidi: preferences.customMidi(for: instrument),
            mode: config.mode,
            a4: config.a4,
            selectedString: config.selectedString
        )
    }

    /// Adopts the current resolution, clears the display, and pulls the guided
    /// state back.
    ///
    /// The tail of every change that alters *which Strings the tuner is aiming at*:
    /// those are the changes that make a reading in flight describe a tuning that no
    /// longer exists, so the held Reading is dropped rather than re-aimed, and the
    /// player's completed strings do not survive.
    private func adoptResolutionAndClearDisplay() {
        session.adopt(resolved)
        currentReading = nil
        syncGuidedStateFromSession()
    }

    /// The tail of every change that alters *how* the tuner listens without changing
    /// the **Strings**: the player's completed strings survive it.
    private func applyModeChange() {
        session.updateConfiguration(config, preservingGuidedProgress: true)
        syncGuidedStateFromSession()
    }

    /// Pulls guided state back from the session after a configuration change, so
    /// the view does not briefly render a stale progress array.
    private func syncGuidedStateFromSession() {
        guidedProgress = session.guidedProgress
        guidedTargetIndex = session.guidedTargetIndex
    }

    // MARK: - Instrument & Preset Selection
    func setInstrument(_ instrument: InstrumentCategory) {
        guard instrument != config.instrument else { return }
        preferences.selectedInstrument = instrument

        applyResolution { config in
            config.instrument = instrument
            config.selectedString = 0
            if config.mode == .manual {
                config.mode = .auto
            }
        }
        adoptResolutionAndClearDisplay()
        lifecycle.stopReferenceTone()
        savePreferences()
    }

    func setTuningPreset(id: String) {
        let instrument = config.instrument
        preferences.setTuning(id, for: instrument)

        applyResolution { config in
            config.selectedString = 0
            if config.mode == .manual {
                config.mode = .auto
            }
        }
        adoptResolutionAndClearDisplay()
        lifecycle.stopReferenceTone()
        savePreferences()
    }

    // MARK: - Mode Controls
    func setMode(_ mode: TunerMode) {
        applyResolution { $0.mode = mode }
        applyModeChange()
        if mode != .manual {
            preferences.mode = mode
            preferences.guided = (mode == .guided)
            savePreferences()
        }
    }

    func togglePrecision() {
        preferences.precision.toggle()
        savePreferences()
    }

    func toggleStringLock(index: Int) {
        if config.mode == .manual && config.selectedString == index {
            applyResolution { $0.mode = .auto }
        } else {
            applyResolution { config in
                config.mode = .manual
                config.selectedString = index
            }
            let target = targets[index]
            lastTone = ToneMemory(note: target.note, frequency: target.frequency, source: .target)
        }
        applyModeChange()
    }

    func unlockString() {
        applyResolution { $0.mode = .auto }
        applyModeChange()
        preferences.mode = .auto
        savePreferences()
    }

    func resetGuidedSession() {
        session.resetGuidedSession()
        currentReading = nil
        syncGuidedStateFromSession()
    }

    // MARK: - Reference Tones
    func playReferenceTone(index: Int) {
        guard index < targets.count else { return }
        let target = targets[index]
        lastTone = ToneMemory(note: target.note, frequency: target.frequency, source: .reference)
        lifecycle.toggleReferenceTone(
            stringIndex: index,
            frequency: target.frequency,
            instrument: config.instrument
        )
    }

    // MARK: - Calibration & Custom Tuning
    func updateA4(_ newA4: Double) {
        let clamped = max(TunerConstants.minCalibrationHz, min(TunerConstants.maxCalibrationHz, newA4))
        applyResolution { $0.a4 = clamped }
        // Deliberately not clearing the display: a calibration change re-reads every
        // String, but it is made while the player is aiming at a String they can still
        // see, so the held Reading is left to expire on its own schedule rather than
        // vanishing mid-adjustment.
        session.adopt(resolved)
        preferences.a4 = clamped
        savePreferences()
    }

    func updateCustomMidi(stringIndex: Int, midi: Int) {
        // Bounded by the *resolved* tuning's string count, so the string the player is
        // editing is one the tuner is actually showing them.
        guard stringIndex < resolved.config.customMidi.count else { return }
        var customMidi = resolved.config.customMidi
        customMidi[stringIndex] = midi
        preferences.setTuning(Tuning.customTuningId, customMidi: customMidi, for: config.instrument)

        // The **Note**s are the choice, and they were just written to `preferences`, so
        // there is nothing for the closure to adjust — the re-resolve *is* the work.
        applyResolution()
        adoptResolutionAndClearDisplay()
        savePreferences()
    }

    private func savePreferences() {
        preferencesStore.save(preferences)
    }
}
