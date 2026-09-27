import Foundation
import Accelerate
import QuartzCore

/// Coordinates DSP detection and pitch tracking on a single serial worker.
///
/// Features a bounded mailbox (at most one pending frame), generational invalidation
/// across preset/configuration changes, and monotonic capture-to-display timing.
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

    // DSP & Tracker (Single Worker Owned)
    private var detector: PitchDetector? = nil
    private let tracker: PitchTracker
    private let spectralScorer = SpectralPitchScorer()

    /// The one knob behind `PitchDetector`'s three fundamental-energy gates.
    /// See `PitchDetector.fundamentalEnergyBase`; `1.0` is the pre-2026-09-25
    /// behaviour and is what the detector uses when this is left at its default.
    private let fundamentalEnergyScale: Double

    // MARK: - Spectral Recovery Tuning
    //
    // These are experimental acceptance settings, not calibrated probabilities.
    // They were chosen against the recorded quiet-pluck fixtures and are
    // documented in docs/tuner-reliability/RESULTS.md.

    /// Minimum absolute evidence score for a recovered candidate.
    private static let spectralRecoveryMinScore: Double = 0.035

    /// Minimum pre-whitening RMS for a recovered candidate.
    ///
    /// Deliberately above `PitchDetector.minAnalysisRMS` (0.00006) — five times as
    /// loud, not lower. Recovery runs only against a live prior, on a frame that is
    /// not an onset and where YIN has failed or jumped, so it can only ever extend a
    /// Note already heard, never name one. That Note is carried in the prior, not
    /// necessarily in this window, so the window itself still has to hold real
    /// energy from it — which is why the floor sits above the fresh path's.
    private static let spectralRecoveryMinRMS: Double = 0.0003

    /// A recovered candidate must beat the best candidate outside the prior's
    /// local-search window by this ratio.
    ///
    /// One of the ratios the plan's acceptance sweep called for. 1.10 was measured
    /// to be too permissive: at the live request cadence it admitted a fabricated
    /// 445 Hz "A4" out of a 0.0008-amplitude noise tail, 21 cents sharp. 1.25 keeps
    /// the measured real-signal separation (1.36-1.44x on the quiet fixtures) while
    /// rejecting that case.
    private static let spectralRecoverySeparationRatio: Double = 1.25

    /// A recovered candidate must be explained by at least this many distinct
    /// harmonic peaks, each carrying at least `spectralSupportFraction` of the
    /// strongest one.
    ///
    /// A lone spectral peak inside the search window is far more often a noise
    /// artefact than a decaying note, and admitting it produced the largest
    /// single-frame errors (up to ~19 cents) seen in fixture replay.
    private static let spectralRecoveryMinHarmonics: Int = 2
    private static let spectralSupportFraction: Double = 0.15

    /// RMS multiple above the previous frame that marks an onset.
    private static let onsetRmsRatio: Double = 2.5
    private static let onsetMinRMS: Double = 0.005

    /// Half-width of the local search around the continuity prior.
    ///
    /// A local-search setting, not an instrument-wide acceptance range: candidate
    /// *acceptance* still depends on the score, RMS and competitor evidence below.
    private static let spectralSearchRadiusCents: Double = 70.0

    private var previousFrameRms: Double = 0.0

    /// Controls whether spectral harmonic recovery is active during sustain.
    private var _isSpectralRecoveryEnabled: Bool = true

    /// Whether spectral harmonic recovery is active during sustain.
    ///
    /// Guarded because it is read on the analysis worker and written from the
    /// caller's thread.
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

    /// Invoked on the analysis worker immediately before DSP runs.
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
    ///
    /// A callback that re-arms must not gate that on any status of its own: this
    /// session has already stopped the source, so a status saying it is listening is
    /// the thing that is out of date.
    var onSourceEvent: (@MainActor (MicrophoneEvent) -> Void)? = nil

    /// The microphone this session is listening to, whether or not its tap is
    /// running.
    ///
    /// Kept wired across a stop on purpose: an interruption is reported whether or
    /// not the tap is installed, so the notification that it *ended* — the one that
    /// invites a resume — can only reach the tuner if the source is still listened
    /// to after the stop that the interruption itself caused.
    private var activeSource: MicrophoneSource?

    init(
        config: TunerConfig = TunerConfig(),
        targets: [StringTarget] = [],
        tracker: PitchTracker = PitchTracker(),
        fundamentalEnergyScale: Double = PitchDetector.defaultFundamentalEnergyScale
    ) {
        self.currentConfig = config
        self.currentTargets = targets
        self.tracker = tracker
        self.fundamentalEnergyScale = fundamentalEnergyScale
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

    /// Frames discarded without ever being analysed: stale-generation frames, and
    /// frames dropped by a generation change while queued.
    var droppedFrames: Int {
        lock.lock()
        defer { lock.unlock() }
        return droppedFramesCount
    }

    var continuityPrior: (frequency: Double, at: TimeInterval)? {
        lock.lock()
        defer { lock.unlock() }
        return tracker.continuityPrior
    }

    var feedbackState: SignalFeedbackState {
        lock.lock()
        defer { lock.unlock() }
        return tracker.feedbackState
    }

    var guidedProgress: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return tracker.guidedProgress
    }

    var guidedTargetIndex: Int {
        lock.lock()
        defer { lock.unlock() }
        return tracker.guidedTargetIndex
    }

    // MARK: - Lifecycle & Configuration Invalidation
    func start(config: TunerConfig, targets: [StringTarget]) {
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

    /// Starts analysis *and* capture as one act, wired together.
    ///
    /// This is the only verb a caller needs: the source's windows are stamped with
    /// this session's own sequence and generation as they arrive, so an
    /// implementation cannot get invalidation wrong, and the source is stopped again
    /// by `stop()` and by any event it reports. A caller no longer has to remember
    /// to stop capture, stop analysis, and re-arm both.
    ///
    /// - Throws: whatever the source throws if capture cannot be started. Nothing is
    ///   left wired in that case — no event handler, no half-started source.
    func start(
        source: MicrophoneSource,
        config: TunerConfig,
        targets: [StringTarget]
    ) throws {
        // A source already in place is stopped rather than left running: re-arming
        // means one source, not two.
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
                self?.submitLiveAudio(
                    window: window.samples,
                    sampleRate: window.sampleRate,
                    captureEndSeconds: window.captureEnd
                )
            }
        } catch {
            detachSource()
            throw error
        }
    }

    func stop() {
        lock.lock()
        activeGeneration &+= 1
        pendingFrame = nil
        pendingEnqueuedAt = nil
        tracker.reset(targetCount: currentTargets.count)
        detector = nil
        previousFrameRms = 0.0
        lock.unlock()
        stopCapture()
    }

    /// Applies a configuration change, invalidating in-flight results computed
    /// under the old policy.
    ///
    /// - Parameter preservingGuidedProgress: pass `true` for changes that only
    ///   affect how a pitch is judged (mode, precision, string lock), so the
    ///   player's completed strings survive. Pass `false` when the strings
    ///   themselves change.
    func updateConfiguration(_ config: TunerConfig, preservingGuidedProgress: Bool = false) {
        lock.lock()
        activeGeneration &+= 1
        currentConfig = config
        pendingFrame = nil
        pendingEnqueuedAt = nil
        tracker.reset(targetCount: currentTargets.count, preservingGuidedProgress: preservingGuidedProgress)
        previousFrameRms = 0.0
        lock.unlock()
    }

    func updateTargets(_ targets: [StringTarget]) {
        lock.lock()
        activeGeneration &+= 1
        currentTargets = targets
        pendingFrame = nil
        pendingEnqueuedAt = nil
        tracker.reset(targetCount: targets.count)
        previousFrameRms = 0.0
        lock.unlock()
    }

    func resetGuidedSession() {
        lock.lock()
        tracker.resetGuidedSession(targetCount: currentTargets.count)
        previousFrameRms = 0.0
        lock.unlock()
    }

    func reset(targetCount: Int) {
        lock.lock()
        activeGeneration &+= 1
        pendingFrame = nil
        pendingEnqueuedAt = nil
        tracker.reset(targetCount: targetCount)
        previousFrameRms = 0.0
        lock.unlock()
    }

    // MARK: - Audio Edge Ownership

    /// Stops the tap, and only the tap.
    ///
    /// The source stays wired, so an event it reports after this — an interruption
    /// that ended, a route that changed again — still reaches the tuner, which is the
    /// only layer that can decide whether to pick capture up again.
    private func stopCapture() {
        lock.lock()
        let source = activeSource
        lock.unlock()

        source?.stop()
    }

    /// Stops the tap *and* stops listening to the source: what a start that failed,
    /// or a source being replaced, has to do.
    ///
    /// Stopping the *source* and not just the analysis is the point: leaving the tap
    /// installed means the engine keeps delivering frames stamped with the new
    /// generation, so the stop would be cosmetic and this session would keep
    /// publishing through the interruption.
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
        // Hop to the main actor before touching the source. A session notification can
        // arrive on the very thread that is delivering audio, and stopping the source
        // from inside it would be waiting on the queue it is running on.
        Task { @MainActor [weak self] in
            self?.absorbSourceEvent(event)
        }
    }

    /// Turns a microphone event into the stop it implies, then tells the caller.
    ///
    /// The caller hears about it only once the source is genuinely stopped and stale
    /// results can no longer publish. Whether capture is picked up again is the
    /// caller's decision, since only it knows whether the player meant to be listening.
    @MainActor
    private func absorbSourceEvent(_ event: MicrophoneEvent) {
        stop()
        onSourceEvent?(event)
    }

    // MARK: - Live Audio Ingestion (Bounded Mailbox)
    /// Submits a captured audio window to the analysis mailbox.
    ///
    /// If an analysis job is currently running on the worker queue, this frame is placed into
    /// the pending slot. If another frame arrives before the current job finishes, the older
    /// pending frame is replaced (mailbox capacity = 1).
    ///
    /// The tap's frame count is not a parameter. It is a fact about the audio
    /// engine's delivery, it does not cross the microphone seam, and nothing here
    /// can act on it — so the live diagnostic stays at its zero default and only
    /// replay, which knows its own hop size, stamps a real one.
    ///
    /// `internal` rather than private because the live path reaches it from the
    /// source's delivery closure and `AnalysisSessionTests` reaches it from outside
    /// the microphone seam, which is a recorded reach-through rather than a reason
    /// to widen anything.
    internal func submitLiveAudio(
        window: [Float],
        sampleRate: Double,
        captureEndSeconds: TimeInterval
    ) {
        let enqueuedAt = CACurrentMediaTime()
        lock.lock()
        sequenceNumber &+= 1
        let frame = AnalysisFrame(
            samples: window,
            sampleRate: sampleRate,
            captureEndSeconds: captureEndSeconds,
            sequence: sequenceNumber,
            generation: activeGeneration
        )

        if pendingFrame != nil {
            replacedFramesCount &+= 1
            droppedFramesCount += 1
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
    ///
    /// `resultAgeReference` is supplied by the caller because replay frame
    /// timestamps come from the media timeline rather than the host monotonic
    /// clock; passing the frame's own capture time yields a well-defined age of
    /// zero instead of an arbitrary number.
    ///
    /// - Note: this seam bypasses the serial worker. Call it from a single thread;
    ///   concurrent use alongside `submitLiveAudio` would interleave detector and
    ///   tracker state updates out of frame order.
    ///
    /// Nothing in the app calls this: "replay" happens only in the test suite, so
    /// this is a test seam end to end. `internal` because that is the honest width
    /// for it — recorded as a reach-through, not widened for.
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

    /// Measured level of the audio the capture tap is actually delivering.
    ///
    /// This is the first thing to check when a detector "does nothing": a simulator HAL
    /// client can start cleanly, report "Listening" with a live latency, and still deliver
    /// pure silence, which looks exactly like a broken algorithm.
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

    /// Decides whether the spectral scorer may replace a failed or implausible YIN
    /// estimate during sustain, and if so substitutes a Sustained result.
    ///
    /// Acceptance requires all of: a candidate inside the prior's local search
    /// window, absolute evidence, at least `spectralRecoveryMinHarmonics`
    /// supporting partials, and separation from the best competing candidate.
    /// Proximity to the prior alone is never sufficient.
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

        // Require multiple supporting partials: a lone peak in the search window
        // is much more often noise than a decaying note.
        guard index < analysis.evidence.count else { return }
        let evidence = analysis.evidence[index]
        let strongest = evidence.map { Double($0.peakMagnitude) }.max() ?? 0
        guard strongest > 0 else { return }
        let supporting = evidence.filter {
            $0.peakFrequency != nil && Double($0.peakMagnitude) >= strongest * Self.spectralSupportFraction
        }
        guard supporting.count >= Self.spectralRecoveryMinHarmonics else { return }

        // Separation from the best candidate outside the search window.
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
            // Salience is not periodicity. The tracker only reads confidence for the
            // ambient-floor foreground test, so this stays in the non-foreground
            // range rather than claiming a YIN-like periodicity value.
            confidence: min(0.70, candidate.score / 2.0),
            amplitudeRMS: currentRms,
            isSignalPresent: true,
            // The candidate was found in a search window around a Note already
            // being tracked, which is what makes it safe to extend: Sustained
            // evidence names nothing fresh.
            evidence: .sustained
        )
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
        workerStart: Double,
        resultAgeReference: TimeInterval
    ) -> AnalysisSnapshot? {
        lock.lock()
        let config = currentConfig
        let targets = currentTargets
        let gen = activeGeneration
        lock.unlock()

        guard frame.generation == gen else { return nil }

        // Exposed so the UI can show whether the input is actually delivering signal.
        let inputRMS = Self.rms(of: frame.samples)
        var inputPeak: Float = 0
        vDSP_maxmgv(frame.samples, 1, &inputPeak, vDSP_Length(frame.samples.count))
        lock.lock()
        _inputRMS = inputRMS
        _inputPeak = Double(inputPeak)
        _inputFrameCount &+= 1
        lock.unlock()

        // 1. Reuse or allocate PitchDetector if sampleRate or bufferSize changed
        let activeDetector: PitchDetector
        if let existing = detector, existing.sampleRate == frame.sampleRate, existing.bufferSize == frame.samples.count {
            activeDetector = existing
        } else {
            let newlyCreated = PitchDetector(
                sampleRate: frame.sampleRate, bufferSize: frame.samples.count,
                fundamentalEnergyScale: fundamentalEnergyScale)
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

        // How long a prior stays live is tracker state, so it is settled here, once,
        // with the same clock everything else in this frame is measured against. Both
        // consumers below need that answer — the estimator's subharmonic arbitration
        // and this module's own recovery branch — and both need it before the frame is
        // analysed, so a prior crosses into the detector only when it is already known
        // to be live. `frame.captureEndSeconds` is the capture edge, which is the
        // tracker's own clock; the replay seam's `resultAgeReference` deliberately is
        // not (see `processFrameSync`).
        let livePrior: (frequency: Double, at: TimeInterval)?
        if let prior,
           frame.captureEndSeconds >= prior.at,
           (frame.captureEndSeconds - prior.at) <= PitchTracker.priorGraceDuration {
            livePrior = prior
        } else {
            livePrior = nil
        }

        // 3. Measure pure DSP CPU duration
        let dspStart = CACurrentMediaTime()

        var pitchResult = activeDetector.detectPitch(
            in: frame.samples,
            noiseGateRMS: noiseGate,
            yinThreshold: yinThreshold,
            referenceA4: config.a4,
            livePriorFrequency: livePrior?.frequency
        )

        // 3b. Spectral Recovery Fallback (Task 5)
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
                if let analysis = spectralScorer.analyzeAudio(
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
        let dropped = droppedFramesCount
        lock.unlock()

        let dspEnd = CACurrentMediaTime()
        let dspMs = (dspEnd - dspStart) * 1000.0

        // 5. Compute result age (time since the physical capture trailing edge).
        //    The reference comes from the caller so replay, whose frame timestamps
        //    are a media timeline starting at zero rather than the host monotonic
        //    clock, does not report a meaningless age.
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
            sequence: frame.sequence
        )
    }
}
