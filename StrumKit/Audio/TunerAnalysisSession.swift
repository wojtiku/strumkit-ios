import Foundation
import QuartzCore

/// Coordinates DSP detection and pitch tracking on a single serial worker.
///
/// Features a bounded mailbox (at most one pending frame), generational invalidation
/// across preset/configuration changes, and monotonic capture-to-display timing.
public final class TunerAnalysisSession: @unchecked Sendable {
    // MARK: - Synchronized State
    private let lock = NSLock()
    private let workerQueue = DispatchQueue(label: "com.strumkit.analysis.worker", qos: .userInitiated)

    // Generation & Sequence
    private var activeGeneration: UInt64 = 1
    private var sequenceNumber: UInt64 = 0
    private var replacedFramesCount: UInt64 = 0

    // Configuration & Targets
    private var currentConfig: TunerConfig
    private var currentTargets: [StringTarget]

    // Bounded Mailbox (Capacity 1)
    private var pendingFrame: AnalysisFrame? = nil
    private var pendingEnqueuedAt: TimeInterval? = nil
    private var isWorkerRunning: Bool = false

    // DSP & Tracker (Single Worker Owned)
    private var detector: PitchDetector? = nil
    private let tracker: PitchTracker
    private let spectralScorer = SpectralPitchScorer()
    private var previousFrameRms: Double = 0.0

    /// Controls whether spectral harmonic recovery is active during sustain.
    public var isSpectralRecoveryEnabled: Bool = true

    // Test seam hook
    internal var analysisHook: (@Sendable (AnalysisFrame, Double) -> Void)? = nil

    // UI Publication Callback
    public var onSnapshotPublished: (@MainActor (AnalysisSnapshot) -> Void)? = nil

    public init(
        config: TunerConfig = TunerConfig(),
        targets: [StringTarget] = [],
        tracker: PitchTracker = PitchTracker()
    ) {
        self.currentConfig = config
        self.currentTargets = targets
        self.tracker = tracker
    }

    // MARK: - Public State Accessors
    public var generation: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return activeGeneration
    }

    public var replacedFrames: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return replacedFramesCount
    }

    public var continuityPrior: (frequency: Double, at: TimeInterval)? {
        lock.lock()
        defer { lock.unlock() }
        return tracker.continuityPrior
    }

    public var feedbackState: SignalFeedbackState {
        lock.lock()
        defer { lock.unlock() }
        return tracker.feedbackState
    }

    public var guidedProgress: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return tracker.guidedProgress
    }

    public var guidedTargetIndex: Int {
        lock.lock()
        defer { lock.unlock() }
        return tracker.guidedTargetIndex
    }

    // MARK: - Lifecycle & Configuration Invalidation
    public func start(config: TunerConfig, targets: [StringTarget]) {
        lock.lock()
        activeGeneration &+= 1
        currentConfig = config
        currentTargets = targets
        pendingFrame = nil
        pendingEnqueuedAt = nil
        tracker.reset(targetCount: targets.count)
        detector = nil
        previousFrameRms = 0.0
        lock.unlock()
    }

    public func stop() {
        lock.lock()
        activeGeneration &+= 1
        pendingFrame = nil
        pendingEnqueuedAt = nil
        tracker.reset(targetCount: currentTargets.count)
        detector = nil
        previousFrameRms = 0.0
        lock.unlock()
    }

    public func updateConfiguration(_ config: TunerConfig) {
        lock.lock()
        activeGeneration &+= 1
        currentConfig = config
        pendingFrame = nil
        pendingEnqueuedAt = nil
        tracker.reset(targetCount: currentTargets.count)
        previousFrameRms = 0.0
        lock.unlock()
    }

    public func updateTargets(_ targets: [StringTarget]) {
        lock.lock()
        activeGeneration &+= 1
        currentTargets = targets
        pendingFrame = nil
        pendingEnqueuedAt = nil
        tracker.reset(targetCount: targets.count)
        previousFrameRms = 0.0
        lock.unlock()
    }

    public func resetGuidedSession() {
        lock.lock()
        tracker.resetGuidedSession(targetCount: currentTargets.count)
        previousFrameRms = 0.0
        lock.unlock()
    }

    public func reset(targetCount: Int) {
        lock.lock()
        activeGeneration &+= 1
        pendingFrame = nil
        pendingEnqueuedAt = nil
        tracker.reset(targetCount: targetCount)
        previousFrameRms = 0.0
        lock.unlock()
    }

    // MARK: - Live Audio Ingestion (Bounded Mailbox)
    /// Submits a captured audio window to the analysis mailbox.
    ///
    /// If an analysis job is currently running on the worker queue, this frame is placed into
    /// the pending slot. If another frame arrives before the current job finishes, the older
    /// pending frame is replaced (mailbox capacity = 1).
    public func submitLiveAudio(
        window: [Float],
        sampleRate: Double,
        captureEndSeconds: TimeInterval,
        callbackFrameCount: Int = 0
    ) {
        let enqueuedAt = CACurrentMediaTime()
        lock.lock()
        sequenceNumber &+= 1
        let frame = AnalysisFrame(
            samples: window,
            sampleRate: sampleRate,
            captureEndSeconds: captureEndSeconds,
            sequence: sequenceNumber,
            generation: activeGeneration,
            callbackFrameCount: callbackFrameCount
        )

        if pendingFrame != nil {
            replacedFramesCount &+= 1
        }
        pendingFrame = frame
        pendingEnqueuedAt = enqueuedAt

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

    // MARK: - Synchronous Processing Seam (Replay & Tests)
    /// Analyzes a single frame synchronously on the caller's thread.
    ///
    /// Reuses detector and advances tracker state identically to live audio.
    public func processFrameSync(_ frame: AnalysisFrame) -> AnalysisSnapshot? {
        lock.lock()
        guard frame.generation == activeGeneration else {
            lock.unlock()
            return nil
        }
        lock.unlock()

        let workerStart = CACurrentMediaTime()
        return performAnalysis(frame: frame, queueDelayMs: 0.0, workerStart: workerStart)
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

            guard frame.generation == currentGen else { continue }

            let workerStart = CACurrentMediaTime()
            let queueDelayMs = (workerStart - enqueuedAt) * 1000.0

            if let hook = analysisHook {
                hook(frame, queueDelayMs)
            }

            if let snapshot = performAnalysis(frame: frame, queueDelayMs: queueDelayMs, workerStart: workerStart) {
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

    private func performAnalysis(
        frame: AnalysisFrame,
        queueDelayMs: Double,
        workerStart: Double
    ) -> AnalysisSnapshot? {
        lock.lock()
        let config = currentConfig
        let targets = currentTargets
        let gen = activeGeneration
        lock.unlock()

        guard frame.generation == gen else { return nil }

        // 1. Reuse or allocate PitchDetector if sampleRate or bufferSize changed
        let activeDetector: PitchDetector
        if let existing = detector, existing.sampleRate == frame.sampleRate, existing.bufferSize == frame.samples.count {
            activeDetector = existing
        } else {
            let newlyCreated = PitchDetector(sampleRate: frame.sampleRate, bufferSize: frame.samples.count)
            detector = newlyCreated
            activeDetector = newlyCreated
        }

        // 2. Query tracker recommendations for dynamic noise gate & YIN threshold
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

        // 3. Measure pure DSP CPU duration
        let dspStart = CACurrentMediaTime()

        var pitchResult = activeDetector.detectPitch(
            in: frame.samples,
            noiseGateRMS: noiseGate,
            yinThreshold: yinThreshold,
            referenceA4: config.a4,
            priorFrequency: prior?.frequency,
            priorAt: prior?.at,
            now: frame.captureEndSeconds
        )

        // 3b. Spectral Recovery Fallback (Task 5)
        let currentRms = pitchResult.amplitudeRMS
        let isOnset = (previousFrameRms > 0) && (currentRms >= previousFrameRms * 2.5) && (currentRms > 0.005)
        previousFrameRms = currentRms

        if isSpectralRecoveryEnabled,
           let prior = prior,
           !isOnset,
           (frame.captureEndSeconds >= prior.at),
           (frame.captureEndSeconds - prior.at) <= PitchTracker.priorGraceDuration {

            let yinFailed = !pitchResult.isSignalPresent || pitchResult.frequency <= 0
            let yinJumped: Bool
            if pitchResult.isSignalPresent && pitchResult.frequency > 0 {
                let jumpCents = abs(PitchMath.centsBetween(measured: pitchResult.frequency, reference: prior.frequency))
                yinJumped = (jumpCents > 70.0)
            } else {
                yinJumped = false
            }

            if yinFailed || yinJumped {
                let candidates = spectralScorer.scoreAudio(
                    samples: frame.samples,
                    sampleRate: frame.sampleRate
                )

                let candNearPrior = candidates.first { cand in
                    cand.frequency > 0 && abs(PitchMath.centsBetween(measured: cand.frequency, reference: prior.frequency)) <= 70.0
                }

                if let candidate = candNearPrior,
                   candidate.score >= 0.035,
                   currentRms >= 0.0003 {

                    let topCompetitor = candidates.first { cand in
                        cand.frequency > 0 && abs(PitchMath.centsBetween(measured: cand.frequency, reference: prior.frequency)) > 70.0
                    }

                    let isSeparated: Bool
                    if let topComp = topCompetitor {
                        isSeparated = (candidate.score >= topComp.score * 1.10)
                    } else {
                        isSeparated = true
                    }

                    if isSeparated {
                        let nearestMidi = PitchMath.nearestMidi(for: candidate.frequency, a4: config.a4)
                        let closestNote = nearestMidi.map { MusicalNote(midiNoteNumber: $0.midi, referenceA4: config.a4) }
                            ?? MusicalNote(midiNoteNumber: 69, referenceA4: config.a4)

                        pitchResult = PitchResult(
                            frequency: candidate.frequency,
                            closestNote: closestNote,
                            centsDeviation: nearestMidi?.cents ?? 0.0,
                            confidence: min(0.85, candidate.score / 2.0),
                            amplitudeRMS: currentRms,
                            isSignalPresent: true,
                            recovered: true
                        )
                    }
                }
            }
        }

        // 4. Update tracker state on the serial worker
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
        lock.unlock()

        let dspEnd = CACurrentMediaTime()
        let dspMs = (dspEnd - dspStart) * 1000.0

        // 5. Compute result age (time since physical capture trailing edge)
        let publishNow = CACurrentMediaTime()
        let resultAgeMs = max(0.0, (publishNow - frame.captureEndSeconds) * 1000.0)
        let analysisMs = queueDelayMs + dspMs

        let diagnostics = TunerDiagnostics(
            sampleRate: frame.sampleRate,
            analysisMs: analysisMs,
            dspMs: dspMs,
            queueDelayMs: queueDelayMs,
            resultAgeMs: resultAgeMs,
            replacedFrames: replaced,
            callbackFrameCount: frame.callbackFrameCount,
            dropped: 0,
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
            sequence: frame.sequence
        )
    }
}
