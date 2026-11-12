import Foundation
import Accelerate
import QuartzCore

/// Runs the Reading engine off the main thread and publishes what it hears.
///
/// This is concurrency and nothing else. Captured audio and configuration changes go
/// into one ordered queue; a single serial worker takes them out and is the only thing
/// that ever touches the engine; results are stamped with a generation so that anything
/// computed for a configuration the player has since left is dropped instead of shown.
///
/// The queue of audio is bounded. A worker that falls further behind than the bound has
/// lost the stream, and the engine is told so explicitly rather than being fed whatever
/// happens to be newest — see ADR 0002.
final class TunerAnalysisSession: @unchecked Sendable {
    /// How much captured audio may wait for the worker before the stream counts as lost:
    /// about 370 ms at 44.1 kHz.
    static let queueCapacitySamples = 16384

    struct InputLevel: Sendable, Equatable {
        var rms: Double = 0
        var peak: Double = 0
        /// Capture callbacks measured so far.
        var frames: UInt64 = 0
    }

    private enum Message {
        case audio(samples: [Float], sampleRate: Double, hostEnd: TimeInterval?, generation: UInt64, enqueuedAt: TimeInterval)
        case configure(ReadingEngine.Configuration, preservingGuidedProgress: Bool)
        case restartGuidedSequence
        case discontinuity
    }

    // MARK: - State behind the lock

    private let lock = NSLock()
    private var activeGeneration: UInt64 = 1
    private var mailbox: [Message] = []
    private var queuedSamples = 0
    private var isWorkerScheduled = false
    private var overloadCount = 0
    private var droppedCallbackCount = 0
    private var currentConfig: TunerConfig
    private var currentTargets: [StringTarget]
    private var _guidedProgress: [Bool]
    private var _guidedTargetIndex = 0
    private var _inputLevel = InputLevel()
    private var _analysisHook: (@Sendable (_ sampleCount: Int, _ queueDelayMs: Double) -> Void)?
    /// The microphone this session is listening to, whether or not its tap is running.
    private var activeSource: MicrophoneSource?

    // MARK: - State only the worker touches

    private let workerQueue = DispatchQueue(label: "com.strumkit.analysis.worker", qos: .userInitiated)
    private let engine: ReadingEngine
    private var sequenceNumber: UInt64 = 0

    // MARK: - Callbacks

    /// Called on the main actor for every hop that changes what the display shows.
    var onSnapshotPublished: (@MainActor (AnalysisSnapshot) -> Void)? = nil

    /// Notified on the main actor when the microphone reports something the tuner has
    /// to absorb. By the time this fires the source has already been stopped and this
    /// session's results invalidated; the callback decides whether to pick capture up
    /// again, which it can only do by calling `start(source:config:targets:)`.
    var onSourceEvent: (@MainActor (MicrophoneEvent) -> Void)? = nil

    /// Test seam: called on the worker before each stretch of audio is analysed.
    internal var analysisHook: (@Sendable (_ sampleCount: Int, _ queueDelayMs: Double) -> Void)? {
        get { withLock { _analysisHook } }
        set { withLock { _analysisHook = newValue } }
    }

    init(config: TunerConfig = TunerConfig(), targets: [StringTarget] = []) {
        self.currentConfig = config
        self.currentTargets = targets
        self._guidedProgress = Array(repeating: false, count: targets.count)
        self.engine = ReadingEngine(configuration: ReadingEngine.Configuration(config: config, targets: targets))
    }

    // MARK: - State accessors

    var generation: UInt64 { withLock { activeGeneration } }
    /// How many times the worker fell far enough behind that the stream was restarted.
    var overloads: Int { withLock { overloadCount } }
    /// Capture callbacks whose audio was discarded by an overload or a stop.
    var droppedCallbacks: Int { withLock { droppedCallbackCount } }
    var guidedProgress: [Bool] { withLock { _guidedProgress } }
    var guidedTargetIndex: Int { withLock { _guidedTargetIndex } }
    var inputLevel: InputLevel { withLock { _inputLevel } }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    // MARK: - Lifecycle and configuration

    /// Begins a fresh stream under a configuration. Anything in flight is invalidated.
    func start(config: TunerConfig, targets: [StringTarget]) {
        lock.lock()
        activeGeneration &+= 1
        currentConfig = config
        currentTargets = targets
        _guidedProgress = Array(repeating: false, count: targets.count)
        _guidedTargetIndex = 0
        mailbox.removeAll()
        queuedSamples = 0
        mailbox.append(.configure(ReadingEngine.Configuration(config: config, targets: targets), preservingGuidedProgress: false))
        mailbox.append(.discontinuity)
        scheduleWorkerLocked()
        lock.unlock()
    }

    func start(source: MicrophoneSource, config: TunerConfig, targets: [StringTarget]) throws {
        detachSource()
        start(config: config, targets: targets)

        source.onEvent = { [weak self] event in
            self?.handleSourceEvent(event)
        }
        withLock { activeSource = source }

        do {
            try source.start { [weak self] window in
                self?.submit(window.samples, sampleRate: window.sampleRate, hostEnd: window.captureEnd)
            }
        } catch {
            detachSource()
            throw error
        }
    }

    func stop() {
        lock.lock()
        activeGeneration &+= 1
        // Configuration changes still waiting are kept; audio is not, and whatever
        // the engine was tracking belongs to a stream that has ended.
        dropQueuedAudioLocked()
        mailbox.append(.discontinuity)
        scheduleWorkerLocked()
        let source = activeSource
        lock.unlock()
        source?.stop()
    }

    func updateConfiguration(_ config: TunerConfig, preservingGuidedProgress: Bool = false) {
        let targets = withLock { currentTargets }
        reconfigure(config: config, targets: targets, preservingGuidedProgress: preservingGuidedProgress)
    }

    func adopt(_ resolved: Tuning.Resolved, preservingGuidedProgress: Bool = false) {
        reconfigure(config: resolved.config, targets: resolved.targets, preservingGuidedProgress: preservingGuidedProgress)
    }

    /// A configuration change while listening. The audio stream carries on; results
    /// computed for the old configuration are invalidated.
    private func reconfigure(config: TunerConfig, targets: [StringTarget], preservingGuidedProgress: Bool) {
        lock.lock()
        activeGeneration &+= 1
        currentConfig = config
        currentTargets = targets
        // Mirrors what the engine will do when the message reaches it, so a caller that
        // reads guided state straight after the change does not see the old sequence.
        if !preservingGuidedProgress || targets.count != _guidedProgress.count {
            _guidedProgress = Array(repeating: false, count: targets.count)
            _guidedTargetIndex = 0
        }
        mailbox.append(.configure(
            ReadingEngine.Configuration(config: config, targets: targets),
            preservingGuidedProgress: preservingGuidedProgress))
        scheduleWorkerLocked()
        lock.unlock()
    }

    func resetGuidedSession() {
        lock.lock()
        _guidedProgress = Array(repeating: false, count: currentTargets.count)
        _guidedTargetIndex = 0
        mailbox.append(.restartGuidedSequence)
        scheduleWorkerLocked()
        lock.unlock()
    }

    // MARK: - Microphone ownership

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

    // MARK: - Audio in

    /// Queues captured audio for the worker. Called from the capture callback: it
    /// never waits on analysis.
    internal func submit(_ samples: [Float], sampleRate: Double, hostEnd: TimeInterval?) {
        guard !samples.isEmpty else { return }
        lock.lock()
        if queuedSamples + samples.count > Self.queueCapacitySamples {
            // The worker has lost the stream. Say so, rather than hand it a stream with
            // a hole in it.
            overloadCount += 1
            dropQueuedAudioLocked()
            mailbox.append(.discontinuity)
        }
        mailbox.append(.audio(
            samples: samples, sampleRate: sampleRate, hostEnd: hostEnd,
            generation: activeGeneration, enqueuedAt: CACurrentMediaTime()))
        queuedSamples += samples.count
        scheduleWorkerLocked()
        lock.unlock()
    }

    private func dropQueuedAudioLocked() {
        let before = mailbox.count
        mailbox.removeAll { message in
            if case .audio = message { return true }
            return false
        }
        droppedCallbackCount += before - mailbox.count
        queuedSamples = 0
    }

    private func scheduleWorkerLocked() {
        guard !isWorkerScheduled else { return }
        isWorkerScheduled = true
        workerQueue.async { [weak self] in
            self?.drainMailbox()
        }
    }

    // MARK: - Synchronous seam (replay and tests)

    /// Analyses audio on the worker and waits for it: the live path, minus the queue
    /// and the hop to the main actor. Returns a snapshot for every hop that changed
    /// the display. Nothing is published to `onSnapshotPublished`.
    internal func processSync(_ samples: [Float], sampleRate: Double, hostEnd: TimeInterval? = nil) -> [AnalysisSnapshot] {
        let generation = self.generation
        return workerQueue.sync {
            drainMailbox()
            return analyse(
                samples, sampleRate: sampleRate, hostEnd: hostEnd,
                generation: generation, queueDelayMs: 0.0, publish: false)
        }
    }

    /// Waits until everything queued so far has been analysed.
    internal func waitUntilIdle() {
        workerQueue.sync { drainMailbox() }
    }

    // MARK: - The worker

    private func drainMailbox() {
        while true {
            lock.lock()
            guard !mailbox.isEmpty else {
                isWorkerScheduled = false
                lock.unlock()
                return
            }
            let message = mailbox.removeFirst()
            if case .audio(let samples, _, _, _, _) = message {
                queuedSamples = max(0, queuedSamples - samples.count)
            }
            lock.unlock()

            switch message {
            case .configure(let configuration, let preservingGuidedProgress):
                engine.configure(configuration, preservingGuidedProgress: preservingGuidedProgress)
            case .restartGuidedSequence:
                engine.restartGuidedSequence()
            case .discontinuity:
                engine.discontinuity()
            case .audio(let samples, let sampleRate, let hostEnd, let generation, let enqueuedAt):
                let queueDelayMs = (CACurrentMediaTime() - enqueuedAt) * 1000.0
                analysisHook?(samples.count, queueDelayMs)
                _ = analyse(
                    samples, sampleRate: sampleRate, hostEnd: hostEnd,
                    generation: generation, queueDelayMs: queueDelayMs, publish: true)
            }
        }
    }

    /// Runs one stretch of audio through the engine. Worker only.
    ///
    /// Audio captured under a configuration the player has since left still goes
    /// through — the stream is continuous and the engine needs every hop of it — but
    /// what it produces is neither published nor allowed to touch the guided state.
    private func analyse(
        _ samples: [Float],
        sampleRate: Double,
        hostEnd: TimeInterval?,
        generation: UInt64,
        queueDelayMs: Double,
        publish: Bool
    ) -> [AnalysisSnapshot] {
        guard !samples.isEmpty else { return [] }
        var rms: Float = 0
        var peak: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(samples.count))

        let dspStart = CACurrentMediaTime()
        let hops = engine.push(samples, sampleRate: sampleRate, hostEnd: hostEnd)
        let dspEnd = CACurrentMediaTime()
        let dspMs = (dspEnd - dspStart) * 1000.0

        lock.lock()
        _inputLevel = InputLevel(rms: Double(rms), peak: Double(peak), frames: _inputLevel.frames &+ 1)
        let isCurrent = generation == activeGeneration
        if isCurrent, let last = hops.last {
            _guidedProgress = last.guidedProgress
            _guidedTargetIndex = last.guidedTargetIndex
        }
        let overloads = overloadCount
        let dropped = droppedCallbackCount
        lock.unlock()

        guard isCurrent else { return [] }

        var snapshots: [AnalysisSnapshot] = []
        for hop in hops where hop.display != .unchanged {
            sequenceNumber &+= 1
            snapshots.append(AnalysisSnapshot(
                reading: hop.display.reading,
                feedbackState: hop.feedback,
                guidedProgress: hop.guidedProgress,
                guidedTargetIndex: hop.guidedTargetIndex,
                diagnostics: TunerDiagnostics(
                    sampleRate: sampleRate,
                    analysisMs: queueDelayMs + dspMs,
                    dspMs: dspMs,
                    queueDelayMs: queueDelayMs,
                    resultAgeMs: hostEnd.map { max(0.0, (dspEnd - $0) * 1000.0) } ?? 0.0,
                    overloads: overloads,
                    callbackFrameCount: samples.count,
                    dropped: dropped,
                    level: hop.level
                ),
                generation: generation,
                sequence: sequenceNumber
            ))
        }

        if publish, !snapshots.isEmpty {
            let published = snapshots
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                for snapshot in published where snapshot.generation == self.generation {
                    self.onSnapshotPublished?(snapshot)
                }
            }
        }
        return snapshots
    }
}
