import Foundation
import Observation

@MainActor
@Observable
public final class TunerViewModel {
    // MARK: - State Properties
    public var selectedInstrument: Instrument
    public var selectedTuning: Tuning
    public var configuration: TunerConfiguration

    public var currentPitch: PitchResult = .idle
    public var smoothedCents: Double = 0.0
    public var targetString: TunedString? = nil
    public var isInTune: Bool = false
    public var isListening: Bool = false
    public var permissionStatus: AudioPermissionStatus = .notDetermined
    public var playingReferenceToneStringNumber: Int? = nil

    // Available instruments
    public var availableInstruments: [Instrument]

    // Dependencies
    private let captureService: AudioCaptureService
    private var pitchDetector: PitchDetector
    private let toneGenerator: ToneGenerator

    // Smoothing factor for gauge needle (0.0 to 1.0; higher = smoother/slower)
    private let smoothingFactor: Double = 0.65

    public init(
        captureService: AudioCaptureService = AudioCaptureService(),
        pitchDetector: PitchDetector = PitchDetector(),
        toneGenerator: ToneGenerator = ToneGenerator(),
        initialInstrumentType: InstrumentType = .guitar
    ) {
        let instruments = Instrument.presets()
        self.availableInstruments = instruments
        let instrument = instruments.first(where: { $0.type == initialInstrumentType }) ?? instruments[0]
        self.selectedInstrument = instrument
        self.selectedTuning = instrument.defaultTuning
        self.configuration = TunerConfiguration()

        self.captureService = captureService
        self.pitchDetector = pitchDetector
        self.toneGenerator = toneGenerator

        self.permissionStatus = captureService.checkPermissionStatus()
    }

    // MARK: - Lifecycle & Audio Control
    public func start() async {
        if permissionStatus == .notDetermined {
            let granted = await captureService.requestPermission()
            permissionStatus = granted ? .authorized : .denied
        }

        guard permissionStatus == .authorized else { return }

        do {
            try captureService.startCapture(bufferSize: 2048) { [weak self] buffer, sampleRate in
                guard let self else { return }
                self.processAudioBuffer(buffer, sampleRate: sampleRate)
            }
            self.isListening = true
        } catch {
            print("[StrumKit] Error starting capture: \(error.localizedDescription)")
            self.isListening = false
        }
    }

    public func stop() {
        captureService.stopCapture()
        stopPitchPipe()
        self.isListening = false
        self.currentPitch = .idle
        self.smoothedCents = 0.0
        self.isInTune = false
    }

    // MARK: - Buffer Processing (DSP -> UI)
    private nonisolated func processAudioBuffer(_ buffer: [Float], sampleRate: Double) {
        let detector = PitchDetector(sampleRate: sampleRate, bufferSize: buffer.count)

        // Read configuration safely
        Task { @MainActor [weak self] in
            guard let self else { return }
            let config = self.configuration
            let currentTuning = self.selectedTuning

            // Detect pitch on background task
            let result = await Task.detached(priority: .high) {
                detector.detectPitch(
                    in: buffer,
                    noiseGateRMS: config.noiseGateRMS,
                    yinThreshold: config.yinThreshold,
                    referenceA4: config.referenceA4
                )
            }.value

            self.handlePitchResult(result, tuning: currentTuning)
        }
    }

    private func handlePitchResult(_ result: PitchResult, tuning: Tuning) {
        guard result.isSignalPresent && result.frequency > 0 else {
            // Signal faded out
            if currentPitch.isSignalPresent {
                currentPitch = PitchResult(
                    frequency: 0,
                    closestNote: currentPitch.closestNote,
                    centsDeviation: currentPitch.centsDeviation,
                    confidence: 0,
                    amplitudeRMS: result.amplitudeRMS,
                    isSignalPresent: false
                )
            }
            return
        }

        self.currentPitch = result

        // Identify target string & cents deviation
        if configuration.autoDetectString && !tuning.strings.isEmpty {
            if let match = tuning.closestString(to: result.frequency) {
                self.targetString = match.string
                let centsFromTarget = 1200.0 * log2(result.frequency / match.string.note.frequency)
                updateNeedle(cents: centsFromTarget)
            } else {
                updateNeedle(cents: result.centsDeviation)
            }
        } else if let selectedNum = configuration.selectedStringNumber,
                  let target = tuning.strings.first(where: { $0.stringNumber == selectedNum }) {
            self.targetString = target
            let centsFromTarget = 1200.0 * log2(result.frequency / target.note.frequency)
            updateNeedle(cents: centsFromTarget)
        } else {
            // Chromatic mode or no string locked
            self.targetString = nil
            updateNeedle(cents: result.centsDeviation)
        }
    }

    private func updateNeedle(cents: Double) {
        // Clamp cents within display range (-50 to +50)
        let clamped = max(-50.0, min(50.0, cents))
        // Exponential moving average for liquid-smooth needle motion
        self.smoothedCents = (smoothingFactor * smoothedCents) + ((1.0 - smoothingFactor) * clamped)
        self.isInTune = abs(clamped) <= configuration.inTuneToleranceCents
    }

    // MARK: - Instrument & Tuning Selection
    public func selectInstrument(_ instrument: Instrument) {
        self.selectedInstrument = instrument
        self.selectedTuning = instrument.defaultTuning
        self.configuration.selectedStringNumber = nil
        self.targetString = nil
        self.stopPitchPipe()
    }

    public func selectTuning(_ tuning: Tuning) {
        self.selectedTuning = tuning
        self.configuration.selectedStringNumber = nil
        self.targetString = nil
        self.stopPitchPipe()
    }

    public func selectString(_ string: TunedString?) {
        if let string {
            if configuration.selectedStringNumber == string.stringNumber {
                // Toggling off returns to auto-detect
                configuration.selectedStringNumber = nil
                configuration.autoDetectString = true
            } else {
                configuration.selectedStringNumber = string.stringNumber
                configuration.autoDetectString = false
                targetString = string
            }
        } else {
            configuration.selectedStringNumber = nil
            configuration.autoDetectString = true
        }
    }

    // MARK: - Reference Tone (Pitch Pipe)
    public func togglePitchPipe(for string: TunedString) {
        if playingReferenceToneStringNumber == string.stringNumber {
            stopPitchPipe()
        } else {
            playingReferenceToneStringNumber = string.stringNumber
            toneGenerator.play(frequency: string.note.frequency)
        }
    }

    public func stopPitchPipe() {
        playingReferenceToneStringNumber = nil
        toneGenerator.stop()
    }

    // MARK: - Reference A4 Calibration
    public func updateReferenceA4(_ frequency: Double) {
        configuration.referenceA4 = frequency
        // Rebuild instruments with new reference frequency
        self.availableInstruments = Instrument.presets(referenceA4: frequency)
        if let updatedInstrument = availableInstruments.first(where: { $0.type == selectedInstrument.type }) {
            self.selectedInstrument = updatedInstrument
            if let updatedTuning = updatedInstrument.tunings.first(where: { $0.id == selectedTuning.id }) {
                self.selectedTuning = updatedTuning
            }
        }
    }
}
