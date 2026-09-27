import Foundation
import Observation
import QuartzCore

@MainActor
@Observable
public final class TunerViewModel {
    // MARK: - Configuration & Engine State
    /// The player's choice, resolved: what the tuner will do, and the **Targets** it will
    /// measure readings against.
    ///
    /// The single source of both, so `config` and `targets` cannot describe different
    /// tunings. Every setter re-resolves rather than editing one without the other.
    private var resolved: Tuning.Resolved

    /// What the tuner will do. A read of `resolved`, the same value `targets` reads.
    public var config: TunerConfig { resolved.config }
    public var preferences: TunerPreferences
    public var engineStatus: EngineStatus = .paused
    public var currentReading: TunerReading? = nil
    public var lastTone: ToneMemory? = nil
    public var feedbackState: SignalFeedbackState = .inactive
    public var diagnostics: TunerDiagnostics = TunerDiagnostics()
    public private(set) var holdOpacity: Double = 1.0

    /// Measured level of the audio the capture tap is actually delivering.
    ///
    /// This is the first thing to check when a detector "does nothing": a simulator HAL
    /// client can start cleanly, report "Listening" with a live latency, and still deliver
    /// pure silence, which looks exactly like a broken algorithm.
    public var inputLevel: TunerAnalysisSession.InputLevel {
        session.inputLevel
    }

    /// Opacity the gauge needle should render at.
    ///
    /// Combines the hold fade with the dimming applied to spectrally recovered
    /// evidence, so inferred readings never look as authoritative as confirmed ones.
    public var needleOpacity: Double {
        if currentReading?.recovered == true {
            return min(holdOpacity, TunerPresentation.recoveredOpacity)
        }
        return holdOpacity
    }

    // Hold Presentation
    private var holdPresentationTask: Task<Void, Never>? = nil
    private var activeHoldFreshAt: TimeInterval? = nil

    // Guided Mode
    public var guidedProgress: [Bool] = []
    public var guidedTargetIndex: Int = 0

    // Tone synthesis
    public var activeToneStringIndex: Int? = nil

    // Services
    private let captureService: AudioCaptureService
    private let stringSynth: AcousticStringSynthesizer
    private let tracker: PitchTracker
    private let preferencesStore: TunerPreferencesStore
    private let session: TunerAnalysisSession

    public init(
        captureService: AudioCaptureService = AudioCaptureService(),
        stringSynth: AcousticStringSynthesizer = AcousticStringSynthesizer(),
        tracker: PitchTracker = PitchTracker(),
        preferencesStore: TunerPreferencesStore = TunerPreferencesStore(),
        session: TunerAnalysisSession? = nil
    ) {
        self.captureService = captureService
        self.stringSynth = stringSynth
        self.tracker = tracker
        self.preferencesStore = preferencesStore

        let loaded = preferencesStore.load()
        self.preferences = loaded
        let initial = Tuning.resolve(loaded)
        self.resolved = initial

        self.session = session ?? TunerAnalysisSession(
            config: initial.config,
            targets: initial.targets,
            tracker: tracker
        )

        // Initialize guided progress for active instrument string count
        self.guidedProgress = Array(repeating: false, count: initial.config.customMidi.count)

        setupCaptureCallbacks()
    }

    private var listeningIntent: Bool = false

    private func setupCaptureCallbacks() {
        captureService.onInterruption = { [weak self] began, shouldResume in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if began {
                    // Stop capture, not just analysis: leaving the tap installed means
                    // the engine keeps delivering frames stamped with the new
                    // generation, so the "stop" would be cosmetic and the session
                    // would keep publishing through the interruption.
                    self.captureService.stopCapture()
                    self.session.stop()
                    self.engineStatus = .interrupted
                    self.feedbackState = .inactive
                } else if shouldResume && self.listeningIntent {
                    await self.start()
                }
            }
        }

        captureService.onRouteChange = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.listeningIntent else { return }
                self.captureService.stopCapture()
                self.session.stop()
                await self.start()
            }
        }
    }

    // MARK: - String Targets
    public var targets: [StringTarget] {
        resolved.targets
    }

    // MARK: - Audio Capture Lifecycle
    public func start() async {
        listeningIntent = true
        guard engineStatus != .listening && engineStatus != .requesting else { return }

        let permStatus = captureService.checkPermissionStatus()
        if permStatus == .notDetermined {
            engineStatus = .requesting
            let granted = await captureService.requestPermission()
            if !granted {
                engineStatus = .denied
                return
            }
        } else if permStatus == .denied {
            engineStatus = .denied
            return
        }

        do {
            stopReferenceTone()
            session.start(config: config, targets: targets)
            session.onSnapshotPublished = { [weak self] snapshot in
                self?.handleSnapshot(snapshot)
            }
            // Capture the session by value rather than reaching through `self` from
            // the audio tap: the tap is real-time, and touching a MainActor-isolated
            // object there means a weak-reference load and retain/release per
            // callback. `TunerAnalysisSession` is `Sendable`, so this is safe.
            let analysisSession = session
            NSLog("[VM] starting capture")
            try captureService.startCapture(bufferSize: 1024) { window, sampleRate, captureEndSeconds, callbackFrameCount, _ in
                analysisSession.submitLiveAudio(
                    window: window,
                    sampleRate: sampleRate,
                    captureEndSeconds: captureEndSeconds,
                    callbackFrameCount: callbackFrameCount
                )
            }
            self.engineStatus = .listening
            self.feedbackState = .ready
            self.diagnostics.sampleRate = captureService.sampleRate
        } catch let err as AudioCaptureError {
            NSLog("[VM] capture FAILED: %@", err.localizedDescription)
            session.stop()
            switch err {
            case .noInputChannelsAvailable, .inputNodeUnavailable:
                self.engineStatus = .missing
            case .permissionDenied:
                self.engineStatus = .denied
            case .sessionActivationFailed, .engineFailed:
                self.engineStatus = .failed
            }
            self.feedbackState = .inactive
        } catch {
            print("[StrumKit] Error starting audio capture: \(error)")
            session.stop()
            self.engineStatus = .failed
            self.feedbackState = .inactive
        }
    }

    public func stop() {
        listeningIntent = false
        captureService.stopCapture()
        stopReferenceTone()
        session.stop()
        holdPresentationTask?.cancel()
        holdPresentationTask = nil
        activeHoldFreshAt = nil
        holdOpacity = 1.0
        self.engineStatus = .paused
        self.currentReading = nil
        self.feedbackState = .inactive
    }

    public func toggleListening() async {
        if engineStatus == .listening || engineStatus == .requesting {
            stop()
        } else {
            await start()
        }
    }

    // MARK: - Snapshot Handler (Serial Session -> UI)
    internal func handleSnapshot(_ snapshot: AnalysisSnapshot) {
        guard snapshot.generation == session.generation else { return }
        self.diagnostics = snapshot.diagnostics
        self.applyReadingUpdate(snapshot.reading, at: snapshot.reading?.at ?? CACurrentMediaTime())
        self.feedbackState = snapshot.feedbackState
        self.guidedProgress = snapshot.guidedProgress
        self.guidedTargetIndex = snapshot.guidedTargetIndex
    }

    private func applyReadingUpdate(_ reading: TunerReading?, at now: TimeInterval) {
        if let reading {
            self.currentReading = reading
            if reading.freshness == .fresh {
                holdPresentationTask?.cancel()
                holdPresentationTask = nil
                activeHoldFreshAt = nil
                holdOpacity = 1.0
                self.lastTone = ToneMemory(
                    note: reading.note,
                    frequency: reading.frequency,
                    source: .detected,
                    reading: reading
                )
            } else {
                // reading.freshness == .held
                holdOpacity = TunerPresentation.holdOpacity(for: reading, now: now)
                startHoldPresentationTimerIfNeeded(for: reading)
            }
        } else {
            // Signal expired or no reading
            holdPresentationTask?.cancel()
            holdPresentationTask = nil
            activeHoldFreshAt = nil
            holdOpacity = 1.0
            self.currentReading = nil
        }
    }

    private func startHoldPresentationTimerIfNeeded(for reading: TunerReading) {
        guard activeHoldFreshAt != reading.lastFreshAt else { return }
        holdPresentationTask?.cancel()
        let holdFreshAt = reading.lastFreshAt
        activeHoldFreshAt = holdFreshAt

        holdPresentationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 33_000_000) // ~30 fps
                guard let self else { break }
                guard self.activeHoldFreshAt == holdFreshAt else { break }
                guard let current = self.currentReading, current.freshness == .held, current.lastFreshAt == holdFreshAt else { break }
                let currentTime = CACurrentMediaTime()
                let elapsed = currentTime - holdFreshAt
                if elapsed >= TunerPresentation.displayHoldDuration {
                    self.currentReading = nil
                    self.holdOpacity = 1.0
                    self.activeHoldFreshAt = nil
                    self.holdPresentationTask = nil
                    break
                } else {
                    self.holdOpacity = TunerPresentation.holdOpacity(for: current, now: currentTime)
                }
            }
        }
    }

    /// Re-resolves the player's tuning choice, after `edit` adjusts the parts of the
    /// configuration that are not the choice itself.
    ///
    /// The choice — which **Instrument**, which **Tuning** id, which **Note**s for a
    /// **Custom tuning** — is read from `preferences`, which is where the player's selection
    /// is recorded; the resolution then decides what that choice actually means. `edit`'s
    /// `tuningId` and `customMidi` are therefore ignored: only `config` and `targets` come
    /// out of `Tuning.resolve`, so there is nothing for a caller to keep in step by hand.
    private func applyResolution(_ edit: (inout TunerConfig) -> Void) {
        var config = resolved.config
        edit(&config)
        let instrument = config.instrument
        resolved = Tuning.resolve(
            instrument: instrument,
            tuningId: preferences.tuningId(for: instrument),
            customMidi: preferences.customMidi(for: instrument),
            mode: config.mode,
            a4: config.a4,
            precision: config.precision,
            guided: config.guided,
            selectedString: config.selectedString
        )
    }

    // MARK: - Instrument & Preset Selection
    public func setInstrument(_ instrument: InstrumentCategory) {
        guard instrument != config.instrument else { return }
        preferences.selectedInstrument = instrument

        applyResolution { config in
            config.instrument = instrument
            config.selectedString = 0
            if config.mode == .manual {
                config.mode = .auto
            }
        }
        resetTrackerAndHold()
        self.guidedProgress = session.guidedProgress
        self.guidedTargetIndex = session.guidedTargetIndex
        stopReferenceTone()
        savePreferences()
    }

    private func resetTrackerAndHold() {
        session.updateConfiguration(config)
        session.updateTargets(targets)
        holdPresentationTask?.cancel()
        holdPresentationTask = nil
        activeHoldFreshAt = nil
        holdOpacity = 1.0
        currentReading = nil
    }

    /// Pulls guided state back from the session after a configuration change, so
    /// the view does not briefly render a stale progress array.
    private func syncGuidedStateFromSession() {
        self.guidedProgress = session.guidedProgress
        self.guidedTargetIndex = session.guidedTargetIndex
    }

    public func setTuningPreset(id: String) {
        let instrument = config.instrument
        preferences.setTuning(id, for: instrument)

        applyResolution { config in
            config.selectedString = 0
            if config.mode == .manual {
                config.mode = .auto
            }
        }
        resetTrackerAndHold()
        self.guidedProgress = session.guidedProgress
        self.guidedTargetIndex = session.guidedTargetIndex
        stopReferenceTone()
        savePreferences()
    }

    // MARK: - Mode Controls
    public func setMode(_ mode: TunerMode) {
        applyResolution { config in
            config.mode = mode
            config.guided = (mode == .guided)
        }
        session.updateConfiguration(config, preservingGuidedProgress: true)
        syncGuidedStateFromSession()
        if mode != .manual {
            preferences.mode = mode
            preferences.guided = config.guided
            savePreferences()
        }
    }

    public func togglePrecision() {
        applyResolution { $0.precision.toggle() }
        session.updateConfiguration(config, preservingGuidedProgress: true)
        syncGuidedStateFromSession()
        preferences.precision = config.precision
        savePreferences()
    }

    public func toggleStringLock(index: Int) {
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
        session.updateConfiguration(config, preservingGuidedProgress: true)
        syncGuidedStateFromSession()
    }

    public func unlockString() {
        applyResolution { $0.mode = .auto }
        session.updateConfiguration(config, preservingGuidedProgress: true)
        syncGuidedStateFromSession()
        preferences.mode = .auto
        savePreferences()
    }

    public func resetGuidedSession() {
        session.resetGuidedSession()
        holdPresentationTask?.cancel()
        holdPresentationTask = nil
        activeHoldFreshAt = nil
        holdOpacity = 1.0
        currentReading = nil
        self.guidedProgress = session.guidedProgress
        self.guidedTargetIndex = session.guidedTargetIndex
    }

    // MARK: - Reference Tones (Acoustic Pluck)
    public func playReferenceTone(index: Int) {
        guard index < targets.count else { return }
        let target = targets[index]
        lastTone = ToneMemory(note: target.note, frequency: target.frequency, source: .reference)

        if activeToneStringIndex == index {
            stopReferenceTone()
        } else {
            activeToneStringIndex = index
            stringSynth.playString(
                frequency: target.frequency,
                stringIndex: index,
                instrument: config.instrument
            )
        }
    }

    public func stopReferenceTone() {
        activeToneStringIndex = nil
        stringSynth.stop()
    }

    // MARK: - Calibration & Custom Tuning
    public func updateA4(_ newA4: Double) {
        let clamped = max(TunerConstants.minCalibrationHz, min(TunerConstants.maxCalibrationHz, newA4))
        applyResolution { $0.a4 = clamped }
        session.updateConfiguration(config)
        session.updateTargets(targets)
        preferences.a4 = clamped
        savePreferences()
    }

    public func updateCustomMidi(stringIndex: Int, midi: Int) {
        // Bounded by the *resolved* tuning's string count, so the string the player is
        // editing is one the tuner is actually showing them.
        guard stringIndex < resolved.config.customMidi.count else { return }
        var customMidi = resolved.config.customMidi
        customMidi[stringIndex] = midi
        preferences.setTuning(Tuning.customTuningId, customMidi: customMidi, for: config.instrument)

        applyResolution { _ in }
        resetTrackerAndHold()
        savePreferences()
    }

    private func savePreferences() {
        preferencesStore.save(preferences)
    }
}
