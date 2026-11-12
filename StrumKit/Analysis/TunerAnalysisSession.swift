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
        targets: [StringTarget] = []
    ) {
        self.currentConfig = config
        self.currentTargets = targets
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
                captureEndSeconds: win.timeMs / 1000.0,
                hostEndSeconds: win.hostTime,
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
        hostEndSeconds: TimeInterval? = nil,
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
            callbackFrameCount: callbackFrameCount,
            hostEndSeconds: hostEndSeconds
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

        // The tracker ran on the stream clock; a Reading is published on the host clock,
        // which is the one the display's hold fade compares against. See ADR 0001.
        let hostOffset = (frame.hostEndSeconds ?? frame.captureEndSeconds) - frame.captureEndSeconds
        let reading = output.reading.map { streamReading in
            TunerReading(
                at: streamReading.at + hostOffset,
                lastFreshAt: streamReading.lastFreshAt + hostOffset,
                frequency: streamReading.frequency,
                aim: streamReading.aim,
                cents: streamReading.cents,
                displayCents: streamReading.displayCents,
                freshness: streamReading.freshness,
                evidence: streamReading.evidence
            )
        }

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

        let resultAgeMs = max(0.0, (resultAgeReference - (frame.hostEndSeconds ?? frame.captureEndSeconds)) * 1000.0)
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

        return AnalysisSnapshot(
            reading: reading,
            feedbackState: feedback,
            guidedProgress: progress,
            guidedTargetIndex: targetIdx,
            diagnostics: diagnostics,
            generation: frame.generation,
            sequence: frame.sequence,
            action: output.action
        )
    }
}
