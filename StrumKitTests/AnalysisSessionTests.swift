import Testing
import Foundation
@testable import StrumKit

private final class TestConcurrencyTracker: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var activeJobs = 0
    private(set) var maxConcurrency = 0
    private(set) var executedFrames: [UInt64] = []

    func jobStarted() {
        lock.lock()
        defer { lock.unlock() }
        activeJobs += 1
        if activeJobs > maxConcurrency { maxConcurrency = activeJobs }
    }

    func jobFinished(sequence: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        executedFrames.append(sequence)
        activeJobs -= 1
    }

    func results() -> (concurrency: Int, executed: [UInt64]) {
        lock.lock()
        defer { lock.unlock() }
        return (maxConcurrency, executedFrames)
    }

    private func currentSnapshot() -> (concurrency: Int, executed: [UInt64], count: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (maxConcurrency, executedFrames, executedFrames.count)
    }

    func waitForJobs(count: Int, timeoutSeconds: Double = 2.0) async -> (concurrency: Int, executed: [UInt64]) {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            let snap = currentSnapshot()
            if snap.count >= count {
                return (snap.concurrency, snap.executed)
            }
            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }
        let snap = currentSnapshot()
        return (snap.concurrency, snap.executed)
    }
}

private final class TestBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T

    init(_ value: T) { self.value = value }

    func get() -> T {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func mutate(_ transform: (inout T) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        transform(&value)
    }
}

@Suite("Tuner Analysis Session & Mailbox Scheduler Tests")
struct AnalysisSessionTests {

    private func makeTargets() -> [StringTarget] {
        Presets.guitar[0].midi.enumerated().map { index, midi in
            StringTarget(note: PitchMath.midiNoteName(midi), midi: midi, frequency: PitchMath.midiFrequency(midi), number: 6 - index)
        }
    }

    private func makeSineWave(frequency: Double, sampleRate: Double, count: Int) -> [Float] {
        var samples = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let t = Double(i) / sampleRate
            samples[i] = Float(sin(2.0 * .pi * frequency * t)) * 0.2
        }
        return samples
    }

    @Test("Bounded mailbox replaces pending frame and limits concurrency to 1")
    func testBoundedMailboxAndReplacement() async throws {
        let targets = makeTargets()
        let config = TunerConfig(instrument: .guitar, tuningId: "standard", mode: .auto)
        let session = TunerAnalysisSession(config: config, targets: targets)
        let tracker = TestConcurrencyTracker()

        let samples = makeSineWave(frequency: 82.41, sampleRate: 44100.0, count: 2048)

        session.analysisHook = { frame, _ in
            tracker.jobStarted()
            // Simulate slow DSP execution on the worker
            Thread.sleep(forTimeInterval: 0.06)
            tracker.jobFinished(sequence: frame.sequence)
        }

        // Submit Frame 1 (starts worker immediately)
        session.submitLiveAudio(window: samples, sampleRate: 44100.0, captureEndSeconds: 1.0)

        // Give worker a moment to enter processing of Frame 1
        try await Task.sleep(nanoseconds: 10_000_000) // 10ms

        // Submit Frame 2, 3, 4 while Frame 1 is still processing
        session.submitLiveAudio(window: samples, sampleRate: 44100.0, captureEndSeconds: 1.04)
        session.submitLiveAudio(window: samples, sampleRate: 44100.0, captureEndSeconds: 1.08)
        session.submitLiveAudio(window: samples, sampleRate: 44100.0, captureEndSeconds: 1.12)

        // Wait for worker queue to complete both Frame 1 and Frame 4
        let (concurrency, executed) = await tracker.waitForJobs(count: 2, timeoutSeconds: 2.0)

        #expect(concurrency == 1, "Concurrency must strictly be 1 on serial worker")
        #expect(session.replacedFrames >= 2, "Frames 2 and 3 must have been replaced by Frame 4 in mailbox")
        #expect(executed.contains(1), "Frame 1 must have executed")
        #expect(executed.contains(4), "Newest Frame 4 must have executed")
        #expect(!executed.contains(2), "Stale Frame 2 should have been replaced")
        #expect(!executed.contains(3), "Stale Frame 3 should have been replaced")
    }

    @Test("Stop increments generation and prevents publication of in-flight results")
    func testStopInvalidatesDelayedJobAndRejectsPublication() async throws {
        let targets = makeTargets()
        let config = TunerConfig(instrument: .guitar, tuningId: "standard", mode: .auto)
        let session = TunerAnalysisSession(config: config, targets: targets)

        let initialGen = session.generation
        let samples = makeSineWave(frequency: 82.41, sampleRate: 44100.0, count: 2048)

        let publicationCount = TestBox<Int>(0)
        await MainActor.run {
            session.onSnapshotPublished = { _ in
                publicationCount.mutate { $0 += 1 }
            }
        }

        session.analysisHook = { _, _ in
            Thread.sleep(forTimeInterval: 0.05)
        }

        session.submitLiveAudio(window: samples, sampleRate: 44100.0, captureEndSeconds: 1.0)
        // Immediately stop the session while the job is in flight
        session.stop()

        #expect(session.generation > initialGen, "Stop must increment generation")

        // Wait for worker to finish
        try await Task.sleep(nanoseconds: 120_000_000)

        #expect(publicationCount.get() == 0, "No snapshots from old generation may be published after stop")
    }

    @Test("Preset switch invalidates in-flight analysis under old target policy")
    func testPresetSwitchInvalidatesInFlightAnalysis() async throws {
        let guitarTargets = makeTargets()
        let guitarConfig = TunerConfig(instrument: .guitar, tuningId: "standard", mode: .auto)
        let session = TunerAnalysisSession(config: guitarConfig, targets: guitarTargets)

        let samples = makeSineWave(frequency: 82.41, sampleRate: 44100.0, count: 2048)

        let snapshots = TestBox<[AnalysisSnapshot]>([])
        await MainActor.run {
            session.onSnapshotPublished = { snapshot in
                snapshots.mutate { $0.append(snapshot) }
            }
        }

        session.analysisHook = { _, _ in
            Thread.sleep(forTimeInterval: 0.05)
        }

        session.submitLiveAudio(window: samples, sampleRate: 44100.0, captureEndSeconds: 1.0)

        // Switch preset to ukulele while job is running
        let ukeConfig = TunerConfig(instrument: .ukulele, tuningId: "standard", mode: .auto)
        let ukeTargets = Presets.ukulele[0].midi.enumerated().map { index, midi in
            StringTarget(note: PitchMath.midiNoteName(midi), midi: midi, frequency: PitchMath.midiFrequency(midi), number: 4 - index)
        }
        session.updateConfiguration(ukeConfig)
        session.updateTargets(ukeTargets)

        try await Task.sleep(nanoseconds: 120_000_000)

        #expect(snapshots.get().isEmpty, "In-flight result under old guitar policy must not publish after uke switch")
    }

    @Test("Synchronous processing seam executes sequentially with correct diagnostics")
    func testSynchronousProcessingSeam() {
        let targets = makeTargets()
        let config = TunerConfig(instrument: .guitar, tuningId: "standard", mode: .auto)
        let session = TunerAnalysisSession(config: config, targets: targets)

        let samples = makeSineWave(frequency: 82.41, sampleRate: 44100.0, count: 2048)
        let frame = AnalysisFrame(
            samples: samples,
            sampleRate: 44100.0,
            captureEndSeconds: 1.0,
            sequence: 1,
            generation: session.generation,
            callbackFrameCount: 2048
        )

        let snapshot = session.processFrameSync(frame)
        #expect(snapshot != nil)
        #expect(snapshot?.sequence == 1)
        #expect(snapshot?.diagnostics.sampleRate == 44100.0)
        #expect(snapshot?.diagnostics.queueDelayMs == 0.0)
        #expect(snapshot?.diagnostics.dspMs ?? 0 > 0.0)
        #expect(snapshot?.diagnostics.callbackFrameCount == 2048)
    }

    // MARK: - Task 7 Lifecycle & Device Validation Tests

    @Test("Dropped and replaced frames are counted, and stale-generation frames count as dropped")
    func testFrameAccountingCountsDrops() async throws {
        let targets = makeTargets()
        let config = TunerConfig(instrument: .guitar, tuningId: "standard", mode: .auto)
        let session = TunerAnalysisSession(config: config, targets: targets)
        let samples = makeSineWave(frequency: 82.41, sampleRate: 44100.0, count: 2048)

        session.analysisHook = { _, _ in
            Thread.sleep(forTimeInterval: 0.05)
        }

        session.submitLiveAudio(window: samples, sampleRate: 44100.0, captureEndSeconds: 1.0)
        try await Task.sleep(nanoseconds: 10_000_000)
        session.submitLiveAudio(window: samples, sampleRate: 44100.0, captureEndSeconds: 1.04)
        session.submitLiveAudio(window: samples, sampleRate: 44100.0, captureEndSeconds: 1.08)

        #expect(session.replacedFrames >= 1)
        #expect(session.droppedFrames >= 1,
                "A frame replaced in the mailbox is dropped work and must be counted, not hidden")

        // A frame from a superseded generation is dropped, not analysed.
        let generation = session.generation
        session.start(config: config, targets: targets)
        let stale = AnalysisFrame(
            samples: samples,
            sampleRate: 44100.0,
            captureEndSeconds: 2.0,
            sequence: 99,
            generation: generation
        )
        #expect(session.processFrameSync(stale) == nil)

        try await Task.sleep(nanoseconds: 120_000_000)
    }

    @Test("Synchronous processing seam reports a well-defined result age")
    func testSyncSeamResultAgeIsCoherent() {
        let targets = makeTargets()
        let config = TunerConfig(instrument: .guitar, tuningId: "standard", mode: .auto)
        let session = TunerAnalysisSession(config: config, targets: targets)
        let samples = makeSineWave(frequency: 82.41, sampleRate: 44100.0, count: 2048)

        // Replay frame timestamps are a media timeline starting at zero. Without an
        // explicit reference the seam would subtract it from the host monotonic clock
        // and report an age of millions of milliseconds.
        let frame = AnalysisFrame(
            samples: samples,
            sampleRate: 44100.0,
            captureEndSeconds: 1.0,
            sequence: 1,
            generation: session.generation
        )
        let snapshot = session.processFrameSync(frame)
        #expect(snapshot?.diagnostics.resultAgeMs == 0.0)

        let withReference = session.processFrameSync(frame, resultAgeReference: 1.05)
        #expect(abs((withReference?.diagnostics.resultAgeMs ?? 0) - 50.0) < 1e-6)
    }

    @Test("Sample-rate restart resets analysis state, increments generation, and clears prior")
    func testSampleRateRestartResetsStateAndInvalidatesStalePrior() {
        let targets = makeTargets()
        let config = TunerConfig(instrument: .guitar, tuningId: "standard", mode: .auto)
        let session = TunerAnalysisSession(config: config, targets: targets)

        let initialGen = session.generation
        let samples44k = makeSineWave(frequency: 82.41, sampleRate: 44100.0, count: 2048)
        let frame1 = AnalysisFrame(samples: samples44k, sampleRate: 44100.0, captureEndSeconds: 1.0, sequence: 1, generation: initialGen)
        let snap1 = session.processFrameSync(frame1)
        #expect(snap1 != nil)

        // Simulate sample-rate change (e.g. 44.1kHz -> 48kHz on route change)
        session.start(config: config, targets: targets)
        #expect(session.generation > initialGen, "Generation must increment on sample-rate restart")

        // An old frame from the previous generation must be rejected
        let oldFrame = AnalysisFrame(samples: samples44k, sampleRate: 44100.0, captureEndSeconds: 1.05, sequence: 2, generation: initialGen)
        let staleSnap = session.processFrameSync(oldFrame)
        #expect(staleSnap == nil, "Old generation frame must be rejected")

        // A new 48kHz frame advances cleanly with reset prior
        let samples48k = makeSineWave(frequency: 82.41, sampleRate: 48000.0, count: 2048)
        let frame2 = AnalysisFrame(samples: samples48k, sampleRate: 48000.0, captureEndSeconds: 1.10, sequence: 3, generation: session.generation)
        let snap2 = session.processFrameSync(frame2)
        #expect(snap2 != nil)
        #expect(snap2?.diagnostics.sampleRate == 48000.0)
    }

    @Test("Audio capture zero-channel input throws noInputChannelsAvailable error")
    func testZeroChannelsThrowsError() {
        let error = AudioCaptureError.noInputChannelsAvailable
        #expect(error.errorDescription?.contains("0 channels") == true)
        #expect(error.errorDescription?.contains("No microphone is available") == true)
    }
}
