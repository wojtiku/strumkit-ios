import Foundation
import Accelerate
import QuartzCore

/// Coordinates DSP detection and pitch tracking on a single serial worker.
///
/// Features a bounded mailbox (at most one pending frame), generational invalidation
/// across preset/configuration changes, and monotonic capture-to-display timing.
/// Wires the faithful engine (framing -> streaming detector -> target tracker -> feedback -> publication).
final class TunerAnalysisSession: @unchecked Sendable {
    // MARK: - Synchronized State
    private let lock = NSLock()
    private let workerQueue = DispatchQueue(label: "com.strumkit.analysis.worker", qos: .userInitiated)

    // Generation & Sequence
    private var activeGeneration: UInt64 = 1
    private var sequenceNumber: UInt64 = 0
    private var replacedFramesCount: UInt64 = 0
    private var droppedFramesCount: Int = 0

    // Configuration & Targets
    private var currentConfig: TunerConfig
    private var currentTargets: [StringTarget]

    // Bounded Mailbox (Capacity 1)
    private var pendingFrame: AnalysisFrame? = nil
    private var pendingEnqueuedAt: TimeInterval? = nil
    private var isWorkerRunning: Bool = false

    // Faithful Engine Pipeline (Single Worker Owned)
    private var framer: FaithfulCaptureFraming
    private var detector: FaithfulStreamingDetector? = nil
    private let adapter: FaithfulReadingAdapter
    private var _guidedProgress: [Bool] = []
    private var _guidedTargetIndex: Int = 0
    private var _feedbackState: SignalFeedbackState = .ready

    // Legacy Investigation Seams (retained for offline replay and historical test suites)
    private let legacyTracker: PitchTracker?
    private var legacyDetector: PitchDetector?
    private let legacySpectralScorer = SpectralPitchScorer()
    private var previousFrameRms: Double = 0.0

    private static let onsetRmsRatio: Double = 2.5
    private static let onsetMinRMS: Double = 0.005
    private static let spectralRecoveryMinScore: Double = 0.035
    private static let spectralRecoveryMinRMS: Double = 0.0003
    private static let spectralRecoverySeparationRatio: Double = 1.25
    private static let spectralRecoveryMinHarmonics: Int = 2
    private static let spectralSupportFraction: Double = 0.15
    private static let spectralSearchRadiusCents: Double = 70.0

    /// Parameter kept for backwards compatibility with existing callers/tests.
    private let fundamentalEnergyScale: Double

    /// Backward compatibility flag.
    private var _isSpectralRecoveryEnabled: Bool = true
    var isSpectralRecoveryEnabled: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _isSpectralRecoveryEnabled
        }
        set {
            lock.lock()
            _isSpectralRecoveryEnabled = newValue
            lock.unlock()
        }
    }

    // Test seam hook
    private var _analysisHook: (@Sendable (AnalysisFrame, Double) -> Void)?
    internal var analysisHook: (@Sendable (AnalysisFrame, Double) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _analysisHook
        }
        set {
            lock.lock()
            _analysisHook = newValue
            lock.unlock()
        }
    }

    // UI Publication Callback
    var onSnapshotPublished: (@MainActor (AnalysisSnapshot) -> Void)? = nil

    /// Notified on the main actor when the microphone reports something the tuner has
    /// to absorb. By the time this fires the source has already been stopped and this
    /// session's results invalidated; the callback decides whether to pick capture up
    /// again, which it can only do by calling `start(source:config:targets:)`.
    var onSourceEvent: (@MainActor (MicrophoneEvent) -> Void)? = nil

    /// The microphone this session is listening to, whether or not its tap is running.
    private var activeSource: MicrophoneSource?

    init(
        config: TunerConfig = TunerConfig(),
        targets: [StringTarget] = [],
        tracker: PitchTracker? = nil,
        fundamentalEnergyScale: Double = PitchDetector.defaultFundamentalEnergyScale
    ) {
        self.legacyTracker = tracker
        self.currentConfig = config
        self.currentTargets = targets
        self.fundamentalEnergyScale = fundamentalEnergyScale
        self.framer = FaithfulCaptureFraming(sampleRate: 44100.0, bufferCapacity: 16384, initialGeneration: 1)
        self.adapter = FaithfulReadingAdapter(
            mode: config.mode,
            calibrationA4: config.a4
        )
        self.adapter.tuning = config.tuningId
        self.adapter.targets = targets.map { Target(note: $0.note, frequency: $0.frequency, midi: $0.midi, stringNumber: $0.number) }
        self.adapter.tracker.auto = (config.mode == .auto || config.mode == .guided || config.mode == .chromatic)
        self.adapter.tracker.selected = config.selectedString
        let profile = FaithfulEngineProfile.profile(for: config.instrument, tuningId: config.tuningId)
        self.detector = createPitchDetector(profile: profile)
        self._guidedProgress = Array(repeating: false, count: targets.count)
        self._guidedTargetIndex = 0
    }

    // MARK: - State Accessors
    var generation: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return activeGeneration
    }

    var replacedFrames: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return replacedFramesCount
    }

    var droppedFrames: Int {
        lock.lock()
        defer { lock.unlock() }
        return droppedFramesCount
    }

    var continuityPrior: (frequency: Double, at: TimeInterval)? {
        return legacyTracker?.continuityPrior
    }

    var feedbackState: SignalFeedbackState {
        lock.lock()
        defer { lock.unlock() }
        return _feedbackState
    }

    var guidedProgress: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return _guidedProgress
    }

    var guidedTargetIndex: Int {
        lock.lock()
        defer { lock.unlock() }
        return _guidedTargetIndex
    }

    // MARK: - Lifecycle & Configuration Invalidation
    func start(config: TunerConfig, targets: [StringTarget]) {
        lock.lock()
        activeGeneration &+= 1
        currentConfig = config
        currentTargets = targets
        pendingFrame = nil
        pendingEnqueuedAt = nil
        framer.reset()
        adapter.reset()
        adapter.mode = config.mode
        adapter.calibrationA4 = config.a4
        adapter.tuning = config.tuningId
        adapter.targets = targets.map { Target(note: $0.note, frequency: $0.frequency, midi: $0.midi, stringNumber: $0.number) }
        adapter.tracker.auto = (config.mode == .auto || config.mode == .guided || config.mode == .chromatic)
        adapter.tracker.selected = config.selectedString
        let profile = FaithfulEngineProfile.profile(for: config.instrument, tuningId: config.tuningId)
        detector = createPitchDetector(profile: profile)
        _guidedProgress = Array(repeating: false, count: targets.count)
        _guidedTargetIndex = 0
        _feedbackState = .ready
        lock.unlock()
    }

    func start(
        source: MicrophoneSource,
        config: TunerConfig,
        targets: [StringTarget]
    ) throws {
        detachSource()
        start(config: config, targets: targets)

        source.onEvent = { [weak self] event in
            self?.handleSourceEvent(event)
        }
        lock.lock()
        activeSource = source
        lock.unlock()

        do {
            try source.start { [weak self] window in
                self?.ingestCapturedAudio(
                    samples: window.samples,
                    sampleRate: window.sampleRate,
                    captureEndSeconds: window.captureEnd
                )
            }
        } catch {
            detachSource()
            throw error
        }
    }

    private func ingestCapturedAudio(
        samples: [Float],
        sampleRate: Double,
        captureEndSeconds: TimeInterval
    ) {
        lock.lock()
        if framer.sampleRate != sampleRate {
            framer.setSampleRate(sampleRate)
        }
        let windows = framer.process(channel: samples, hostTime: captureEndSeconds)
        guard !windows.isEmpty else {
            lock.unlock()
            return
        }

        let enqueuedAt = CACurrentMediaTime()
        for win in windows {
            enqueueFrameLocked(
                samples: win.samples,
                sampleRate: win.sampleRate,
                captureEndSeconds: win.hostTime ?? (win.timeMs / 1000.0),
                callbackFrameCount: win.samples.count,
                enqueuedAt: enqueuedAt
            )
        }

        if !isWorkerRunning {
            isWorkerRunning = true
            lock.unlock()
            workerQueue.async { [weak self] in
                self?.drainWorkerLoop()
            }
        } else {
            lock.unlock()
        }
    }

    func stop() {
        lock.lock()
        activeGeneration &+= 1
        pendingFrame = nil
        pendingEnqueuedAt = nil
        framer.reset()
        adapter.reset()
        detector = nil
        _feedbackState = .inactive
        lock.unlock()
        stopCapture()
    }

    func updateConfiguration(_ config: TunerConfig, preservingGuidedProgress: Bool = false) {
        lock.lock()
        activeGeneration &+= 1
        currentConfig = config
        pendingFrame = nil
        pendingEnqueuedAt = nil
        framer.reset()
        adapter.reset()
        adapter.mode = config.mode
        adapter.calibrationA4 = config.a4
        adapter.tuning = config.tuningId
        adapter.tracker.auto = (config.mode == .auto || config.mode == .guided || config.mode == .chromatic)
        adapter.tracker.selected = config.selectedString
        let profile = FaithfulEngineProfile.profile(for: config.instrument, tuningId: config.tuningId)
        detector = createPitchDetector(profile: profile)
        if !preservingGuidedProgress {
            _guidedProgress = Array(repeating: false, count: currentTargets.count)
            _guidedTargetIndex = 0
        }
        lock.unlock()
    }

    func adopt(_ resolved: Tuning.Resolved, preservingGuidedProgress: Bool = false) {
        lock.lock()
        activeGeneration &+= 1
        currentConfig = resolved.config
        currentTargets = resolved.targets
        pendingFrame = nil
        pendingEnqueuedAt = nil
        framer.reset()
        adapter.reset()
        adapter.mode = resolved.config.mode
        adapter.calibrationA4 = resolved.config.a4
        adapter.tuning = resolved.config.tuningId
        adapter.targets = resolved.targets.map { Target(note: $0.note, frequency: $0.frequency, midi: $0.midi, stringNumber: $0.number) }
        adapter.tracker.auto = (resolved.config.mode == .auto || resolved.config.mode == .guided || resolved.config.mode == .chromatic)
        adapter.tracker.selected = resolved.config.selectedString
        let profile = FaithfulEngineProfile.profile(for: resolved.config.instrument, tuningId: resolved.config.tuningId)
        detector = createPitchDetector(profile: profile)
        if !preservingGuidedProgress {
            _guidedProgress = Array(repeating: false, count: resolved.targets.count)
            _guidedTargetIndex = 0
        }
        lock.unlock()
    }

    func resetGuidedSession() {
        lock.lock()
        _guidedProgress = Array(repeating: false, count: currentTargets.count)
        _guidedTargetIndex = 0
        adapter.feedback.reset()
        lock.unlock()
    }

    func reset(targetCount: Int) {
        lock.lock()
        activeGeneration &+= 1
        pendingFrame = nil
        pendingEnqueuedAt = nil
        framer.reset()
        adapter.reset()
        detector = nil
        _guidedProgress = Array(repeating: false, count: targetCount)
        _guidedTargetIndex = 0
        lock.unlock()
    }

    // MARK: - Audio Edge Ownership
    private func stopCapture() {
        lock.lock()
        let source = activeSource
        lock.unlock()
        source?.stop()
    }

    private func detachSource() {
        lock.lock()
        let source = activeSource
        activeSource = nil
        lock.unlock()

        guard let source else { return }
        source.onEvent = nil
        source.stop()
    }

    private func handleSourceEvent(_ event: MicrophoneEvent) {
        Task { @MainActor [weak self] in
            self?.absorbSourceEvent(event)
        }
    }

    @MainActor
    private func absorbSourceEvent(_ event: MicrophoneEvent) {
        stop()
        onSourceEvent?(event)
    }

    // MARK: - Live Audio Ingestion (Bounded Mailbox)
    internal func submitLiveAudio(
        window: [Float],
        sampleRate: Double,
        captureEndSeconds: TimeInterval
    ) {
        lock.lock()
        let enqueuedAt = CACurrentMediaTime()
        enqueueFrameLocked(
            samples: window,
            sampleRate: sampleRate,
            captureEndSeconds: captureEndSeconds,
            callbackFrameCount: window.count,
            enqueuedAt: enqueuedAt
        )

        if !isWorkerRunning {
            isWorkerRunning = true
            lock.unlock()
            workerQueue.async { [weak self] in
                self?.drainWorkerLoop()
            }
        } else {
            lock.unlock()
        }
    }

    private func enqueueFrameLocked(
        samples: [Float],
        sampleRate: Double,
        captureEndSeconds: TimeInterval,
        callbackFrameCount: Int,
        enqueuedAt: TimeInterval
    ) {
        sequenceNumber &+= 1
        let frame = AnalysisFrame(
            samples: samples,
            sampleRate: sampleRate,
            captureEndSeconds: captureEndSeconds,
            sequence: sequenceNumber,
            generation: activeGeneration,
            callbackFrameCount: callbackFrameCount
        )

        if pendingFrame != nil {
            replacedFramesCount &+= 1
            droppedFramesCount += 1
        }
        pendingFrame = frame
        pendingEnqueuedAt = enqueuedAt
    }

    // MARK: - Synchronous Processing Seam (Replay & Tests)
    internal func processFrameSync(
        _ frame: AnalysisFrame,
        resultAgeReference: TimeInterval? = nil
    ) -> AnalysisSnapshot? {
        lock.lock()
        guard frame.generation == activeGeneration else {
            lock.unlock()
            return nil
        }
        lock.unlock()

        let workerStart = CACurrentMediaTime()
        return performAnalysis(
            frame: frame,
            queueDelayMs: 0.0,
            workerStart: workerStart,
            resultAgeReference: resultAgeReference ?? frame.captureEndSeconds
        )
    }

    private var _inputRMS: Double = 0
    private var _inputPeak: Double = 0
    private var _inputFrameCount: UInt64 = 0

    struct InputLevel: Sendable, Equatable {
        var rms: Double = 0
        var peak: Double = 0
        var frames: UInt64 = 0
    }

    var inputLevel: InputLevel {
        lock.lock()
        defer { lock.unlock() }
        return InputLevel(rms: _inputRMS, peak: _inputPeak, frames: _inputFrameCount)
    }

    private static func rms(of samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        var value: Float = 0
        vDSP_rmsqv(samples, 1, &value, vDSP_Length(samples.count))
        return Double(value)
    }

    // MARK: - Private Worker Loop & DSP Execution
    private func drainWorkerLoop() {
        while true {
            lock.lock()
            guard let frame = pendingFrame, let enqueuedAt = pendingEnqueuedAt else {
                isWorkerRunning = false
                lock.unlock()
                break
            }
            pendingFrame = nil
            pendingEnqueuedAt = nil
            let currentGen = activeGeneration
            lock.unlock()

            guard frame.generation == currentGen else {
                lock.lock()
                droppedFramesCount += 1
                lock.unlock()
                continue
            }

            let workerStart = CACurrentMediaTime()
            let queueDelayMs = (workerStart - enqueuedAt) * 1000.0

            if let hook = analysisHook {
                hook(frame, queueDelayMs)
            }

            if let snapshot = performAnalysis(
                frame: frame,
                queueDelayMs: queueDelayMs,
                workerStart: workerStart,
                resultAgeReference: CACurrentMediaTime()
            ) {
                if !snapshot.action.isSkipped {
                    lock.lock()
                    let publicationGen = activeGeneration
                    lock.unlock()

                    // Drop snapshot if generation changed while DSP was running
                    if snapshot.generation == publicationGen {
                        DispatchQueue.main.async { [weak self] in
                            guard let self else { return }
                            self.onSnapshotPublished?(snapshot)
                        }
                    }
                }
            }
        }
    }

    private func performAnalysis(
        frame: AnalysisFrame,
        queueDelayMs: Double,
        workerStart: Double,
        resultAgeReference: TimeInterval
    ) -> AnalysisSnapshot? {
        lock.lock()
        let config = currentConfig
        let targets = currentTargets
        let gen = activeGeneration
        lock.unlock()

        guard frame.generation == gen else { return nil }

        let inputRMS = Self.rms(of: frame.samples)
        var inputPeak: Float = 0
        vDSP_maxmgv(frame.samples, 1, &inputPeak, vDSP_Length(frame.samples.count))
        lock.lock()
        _inputRMS = inputRMS
        _inputPeak = Double(inputPeak)
        _inputFrameCount &+= 1
        lock.unlock()

        if let tracker = legacyTracker {
            // Legacy investigation path (used exclusively by AudioTestHelpers.replayTrace)
            let activeDetector: PitchDetector
            if let existing = legacyDetector, existing.sampleRate == frame.sampleRate, existing.bufferSize == frame.samples.count {
                activeDetector = existing
            } else {
                let newlyCreated = PitchDetector(
                    sampleRate: frame.sampleRate, bufferSize: frame.samples.count,
                    fundamentalEnergyScale: fundamentalEnergyScale)
                legacyDetector = newlyCreated
                activeDetector = newlyCreated
            }

            let isSustaining: Bool
            let prior: (frequency: Double, at: TimeInterval)?
            let noiseGate: Float
            let yinThreshold: Float

            lock.lock()
            prior = tracker.continuityPrior
            isSustaining = (prior != nil)
            noiseGate = tracker.recommendedNoiseGate(isSustaining: isSustaining)
            yinThreshold = tracker.recommendedYinThreshold(isSustaining: isSustaining)
            lock.unlock()

            let livePrior: (frequency: Double, at: TimeInterval)?
            if let prior,
               frame.captureEndSeconds >= prior.at,
               (frame.captureEndSeconds - prior.at) <= PitchTracker.priorGraceDuration {
                livePrior = prior
            } else {
                livePrior = nil
            }

            let dspStart = CACurrentMediaTime()

            var pitchResult = activeDetector.detectPitch(
                in: frame.samples,
                noiseGateRMS: noiseGate,
                yinThreshold: yinThreshold,
                referenceA4: config.a4,
                livePriorFrequency: livePrior?.frequency
            )

            let currentRms = pitchResult.amplitudeRMS
            let isOnset = (previousFrameRms > 0)
                && (currentRms >= previousFrameRms * Self.onsetRmsRatio)
                && (currentRms > Self.onsetMinRMS)
            previousFrameRms = currentRms

            if isSpectralRecoveryEnabled,
               let prior = livePrior,
               !isOnset {

                let yinFailed = !pitchResult.isSignalPresent || pitchResult.frequency <= 0
                let yinJumped: Bool
                if pitchResult.isSignalPresent && pitchResult.frequency > 0 {
                    let jumpCents = abs(PitchMath.centsBetween(measured: pitchResult.frequency, reference: prior.frequency))
                    yinJumped = (jumpCents > Self.spectralSearchRadiusCents)
                } else {
                    yinJumped = false
                }

                if (yinFailed || yinJumped) && currentRms >= Self.spectralRecoveryMinRMS {
                    if let analysis = legacySpectralScorer.analyzeAudio(
                        samples: frame.samples,
                        sampleRate: frame.sampleRate
                    ) {
                        applySpectralRecovery(
                            analysis: analysis,
                            prior: prior,
                            config: config,
                            currentRms: currentRms,
                            to: &pitchResult
                        )
                    }
                }
            }

            lock.lock()
            let reading = tracker.process(
                pitchResult: pitchResult,
                at: frame.captureEndSeconds,
                config: config,
                targets: targets
            )
            let feedback = tracker.feedbackState
            let progress = tracker.guidedProgress
            let targetIdx = tracker.guidedTargetIndex
            let replaced = replacedFramesCount
            let dropped = droppedFramesCount
            lock.unlock()

            let dspEnd = CACurrentMediaTime()
            let dspMs = (dspEnd - dspStart) * 1000.0

            let resultAgeMs = max(0.0, (resultAgeReference - frame.captureEndSeconds) * 1000.0)
            let analysisMs = queueDelayMs + dspMs

            let diagnostics = TunerDiagnostics(
                sampleRate: frame.sampleRate,
                analysisMs: analysisMs,
                dspMs: dspMs,
                queueDelayMs: queueDelayMs,
                resultAgeMs: resultAgeMs,
                replacedFrames: replaced,
                callbackFrameCount: frame.callbackFrameCount,
                dropped: dropped,
                level: pitchResult.amplitudeRMS
            )

            return AnalysisSnapshot(
                reading: reading,
                pitchResult: pitchResult,
                feedbackState: feedback,
                guidedProgress: progress,
                guidedTargetIndex: targetIdx,
                diagnostics: diagnostics,
                generation: frame.generation,
                sequence: frame.sequence,
                action: .empty
            )
        }

        let profile = FaithfulEngineProfile.profile(for: config.instrument, tuningId: config.tuningId)
        let activeDetector: FaithfulStreamingDetector
        if let existing = detector, existing.profile == profile {
            activeDetector = existing
        } else {
            let newlyCreated = createPitchDetector(profile: profile)
            detector = newlyCreated
            activeDetector = newlyCreated
        }

        let dspStart = CACurrentMediaTime()
        let timeMs = frame.captureEndSeconds * 1000.0

        let candidate = activeDetector.detect(
            input: frame.samples,
            sampleRate: frame.sampleRate,
            sampleTime: timeMs
        )

        adapter.mode = config.mode
        adapter.calibrationA4 = config.a4
        adapter.tuning = config.tuningId
        adapter.targets = targets.map { Target(note: $0.note, frequency: $0.frequency, midi: $0.midi, stringNumber: $0.number) }
        adapter.tracker.auto = (config.mode == .auto || config.mode == .guided || config.mode == .chromatic)
        adapter.tracker.selected = config.selectedString

        let output = adapter.process(candidate: candidate, timeMs: timeMs)

        let reading = output.reading

        lock.lock()
        if config.mode == .guided,
           let reading = reading,
           reading.inTune == true,
           reading.evidence == .measured,
           reading.freshness == .fresh,
           let target = reading.aim.target {
            if let targetIdx = targets.firstIndex(where: { $0.midi == target.midi && $0.number == target.number }),
               targetIdx == _guidedTargetIndex {
                if targetIdx < _guidedProgress.count {
                    _guidedProgress[targetIdx] = true
                }
                if _guidedTargetIndex + 1 < targets.count {
                    _guidedTargetIndex += 1
                }
            }
        }

        let feedback: SignalFeedbackState
        if reading != nil {
            feedback = .tracking
        } else if candidate != nil {
            feedback = .checking
        } else {
            feedback = .ready
        }
        _feedbackState = feedback

        let progress = _guidedProgress
        let targetIdx = _guidedTargetIndex
        let replaced = replacedFramesCount
        let dropped = droppedFramesCount
        lock.unlock()

        let dspEnd = CACurrentMediaTime()
        let dspMs = (dspEnd - dspStart) * 1000.0

        let resultAgeMs = max(0.0, (resultAgeReference - frame.captureEndSeconds) * 1000.0)
        let analysisMs = queueDelayMs + dspMs

        let diagnostics = TunerDiagnostics(
            sampleRate: frame.sampleRate,
            analysisMs: analysisMs,
            dspMs: dspMs,
            queueDelayMs: queueDelayMs,
            resultAgeMs: resultAgeMs,
            replacedFrames: replaced,
            callbackFrameCount: frame.callbackFrameCount,
            dropped: dropped,
            level: candidate?.rms ?? inputRMS
        )

        let targetMidi = reading?.aim.target?.midi ?? 60
        let pitchResult = PitchResult(
            frequency: candidate?.frequency ?? 0.0,
            closestNote: MusicalNote(midiNoteNumber: targetMidi, referenceA4: config.a4),
            centsDeviation: reading?.cents ?? 0.0,
            confidence: candidate?.confidence ?? 0.0,
            amplitudeRMS: candidate?.rms ?? inputRMS,
            isSignalPresent: candidate != nil,
            evidence: reading?.evidence ?? .measured
        )

        return AnalysisSnapshot(
            reading: reading,
            pitchResult: pitchResult,
            feedbackState: feedback,
            guidedProgress: progress,
            guidedTargetIndex: targetIdx,
            diagnostics: diagnostics,
            generation: frame.generation,
            sequence: frame.sequence,
            action: output.action
        )
    }

    private func applySpectralRecovery(
        analysis: SpectralPitchScorer.WindowAnalysis,
        prior: (frequency: Double, at: TimeInterval),
        config: TunerConfig,
        currentRms: Double,
        to pitchResult: inout PitchResult
    ) {
        let radius = Self.spectralSearchRadiusCents
        let candidates = analysis.candidates

        guard let index = candidates.firstIndex(where: { candidate in
            candidate.frequency > 0
                && abs(PitchMath.centsBetween(measured: candidate.frequency, reference: prior.frequency)) <= radius
        }) else { return }

        let candidate = candidates[index]
        guard candidate.score >= Self.spectralRecoveryMinScore else { return }

        guard index < analysis.evidence.count else { return }
        let evidence = analysis.evidence[index]
        let strongest = evidence.map { Double($0.peakMagnitude) }.max() ?? 0
        guard strongest > 0 else { return }
        let supporting = evidence.filter {
            $0.peakFrequency != nil && Double($0.peakMagnitude) >= strongest * Self.spectralSupportFraction
        }
        guard supporting.count >= Self.spectralRecoveryMinHarmonics else { return }

        if let competitor = candidates.first(where: {
            $0.frequency > 0
                && abs(PitchMath.centsBetween(measured: $0.frequency, reference: prior.frequency)) > radius
        }) {
            guard candidate.score >= competitor.score * Self.spectralRecoverySeparationRatio else { return }
        }

        guard let nearestMidi = PitchMath.nearestMidi(for: candidate.frequency, a4: config.a4) else { return }

        pitchResult = PitchResult(
            frequency: candidate.frequency,
            closestNote: MusicalNote(midiNoteNumber: nearestMidi.midi, referenceA4: config.a4),
            centsDeviation: nearestMidi.cents,
            confidence: min(0.70, candidate.score / 2.0),
            amplitudeRMS: currentRms,
            isSignalPresent: true,
            evidence: .sustained
        )
    }
}
