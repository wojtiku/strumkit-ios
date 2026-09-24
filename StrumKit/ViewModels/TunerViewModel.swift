import Foundation
import Observation

@MainActor
@Observable
public final class TunerViewModel {
    // MARK: - Configuration & Engine State
    public var config: TunerConfig = TunerConfig()
    public var engineStatus: EngineStatus = .paused
    public var currentReading: TunerReading? = nil
    public var lastTone: ToneMemory? = nil
    public var feedbackState: SignalFeedbackState = .inactive
    public var diagnostics: TunerDiagnostics = TunerDiagnostics()

    // Guided Mode & History
    public var guidedProgress: [Bool] = []
    public var guidedTargetIndex: Int = 0
    public var history: [HistoryPoint] = []

    // Tone synthesis
    public var activeToneStringIndex: Int? = nil

    // Services
    private let captureService: AudioCaptureService
    private let pitchDetector: PitchDetector
    private let stringSynth: AcousticStringSynthesizer
    private let tracker: PitchTracker

    public init(
        captureService: AudioCaptureService = AudioCaptureService(),
        pitchDetector: PitchDetector = PitchDetector(),
        stringSynth: AcousticStringSynthesizer = AcousticStringSynthesizer(),
        tracker: PitchTracker = PitchTracker()
    ) {
        self.captureService = captureService
        self.pitchDetector = pitchDetector
        self.stringSynth = stringSynth
        self.tracker = tracker

        // Initialize guided progress for default guitar strings
        self.guidedProgress = Array(repeating: false, count: 6)
    }

    // MARK: - String Targets
    public var targets: [StringTarget] {
        let midiList: [Int]
        if config.tuningId == "custom" {
            midiList = config.customMidi
        } else {
            let available = Presets.presets(for: config.instrument)
            let preset = available.first(where: { $0.id == config.tuningId }) ?? available[0]
            midiList = preset.midi
        }

        let totalStrings = midiList.count
        return midiList.enumerated().map { index, midi in
            StringTarget(
                note: PitchMath.midiNoteName(midi),
                midi: midi,
                frequency: PitchMath.midiFrequency(midi, a4: config.a4),
                number: totalStrings - index // String 6 down to 1
            )
        }
    }

    // MARK: - Audio Capture Lifecycle
    public func start() async {
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
            try captureService.startCapture(bufferSize: 2048) { [weak self] buffer, sampleRate in
                guard let self else { return }
                self.processAudioBuffer(buffer, sampleRate: sampleRate)
            }
            self.engineStatus = .listening
            self.feedbackState = .ready
            self.diagnostics.sampleRate = captureService.sampleRate
        } catch {
            print("[StrumKit] Error starting audio capture: \(error)")
            self.engineStatus = .failed
        }
    }

    public func stop() {
        captureService.stopCapture()
        stopReferenceTone()
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

    // MARK: - Buffer Analysis (DSP -> Tracker -> UI)
    private nonisolated func processAudioBuffer(_ buffer: [Float], sampleRate: Double) {
        let startTime = CFAbsoluteTimeGetCurrent()
        let detector = PitchDetector(sampleRate: sampleRate, bufferSize: buffer.count)

        Task { @MainActor [weak self] in
            guard let self else { return }
            let currentConfig = self.config
            let currentTargets = self.targets
            let prior = self.tracker.continuityPrior
            let now = Date().timeIntervalSinceReferenceDate

            let pitchResult = await Task.detached(priority: .high) {
                detector.detectPitch(
                    in: buffer,
                    noiseGateRMS: 0.008,
                    yinThreshold: 0.15,
                    referenceA4: currentConfig.a4,
                    priorFrequency: prior?.frequency,
                    priorAt: prior?.at,
                    now: now
                )
            }.value

            let elapsedMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
            self.diagnostics.analysisMs = elapsedMs
            self.diagnostics.level = pitchResult.amplitudeRMS

            let reading = self.tracker.process(
                pitchResult: pitchResult,
                at: now,
                config: currentConfig,
                targets: currentTargets
            )

            self.currentReading = reading
            self.feedbackState = self.tracker.feedbackState
            self.guidedProgress = self.tracker.guidedProgress
            self.guidedTargetIndex = self.tracker.guidedTargetIndex
            self.history = self.tracker.history

            if let reading {
                self.lastTone = ToneMemory(
                    note: reading.note,
                    frequency: reading.frequency,
                    source: .detected,
                    reading: reading
                )
            }
        }
    }

    // MARK: - Instrument & Preset Selection
    public func setInstrument(_ instrument: InstrumentCategory) {
        guard instrument != config.instrument else { return }
        config.instrument = instrument
        let available = Presets.presets(for: instrument)
        config.tuningId = available.first?.id ?? "standard"
        config.customMidi = available.first?.midi ?? (instrument == .guitar ? [40, 45, 50, 55, 59, 64] : [67, 60, 64, 69])
        config.selectedString = 0
        config.mode = .auto
        tracker.reset(targetCount: targets.count)
        self.guidedProgress = tracker.guidedProgress
        self.guidedTargetIndex = tracker.guidedTargetIndex
        stopReferenceTone()
    }

    public func setTuningPreset(id: String) {
        config.tuningId = id
        if id != "custom" {
            let available = Presets.presets(for: config.instrument)
            if let match = available.first(where: { $0.id == id }) {
                config.customMidi = match.midi
            }
        }
        config.selectedString = 0
        tracker.reset(targetCount: targets.count)
        self.guidedProgress = tracker.guidedProgress
        self.guidedTargetIndex = tracker.guidedTargetIndex
        stopReferenceTone()
    }

    // MARK: - Mode Controls
    public func setMode(_ mode: TunerMode) {
        config.mode = mode
        if mode == .guided {
            config.guided = true
        } else {
            config.guided = false
        }
    }

    public func togglePrecision() {
        config.precision.toggle()
    }

    public func toggleStringLock(index: Int) {
        if config.mode == .manual && config.selectedString == index {
            config.mode = .auto
        } else {
            config.mode = .manual
            config.selectedString = index
            let target = targets[index]
            lastTone = ToneMemory(note: target.note, frequency: target.frequency, source: .target)
        }
    }

    public func unlockString() {
        config.mode = .auto
    }

    public func resetGuidedSession() {
        tracker.resetGuidedSession(targetCount: targets.count)
        self.guidedProgress = tracker.guidedProgress
        self.guidedTargetIndex = tracker.guidedTargetIndex
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
        config.a4 = max(TunerConstants.minCalibrationHz, min(TunerConstants.maxCalibrationHz, newA4))
    }

    public func updateCustomMidi(stringIndex: Int, midi: Int) {
        guard stringIndex < config.customMidi.count else { return }
        config.customMidi[stringIndex] = midi
        config.tuningId = "custom"
        tracker.reset(targetCount: targets.count)
    }
}
