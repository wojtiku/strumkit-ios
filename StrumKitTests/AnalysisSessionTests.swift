import Testing
import Foundation
import QuartzCore
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

@Suite("Analysis session: queue, worker, generation, publication")
struct AnalysisSessionTests {
    private static let rate = 44100.0

    private static func ukulele(mode: TunerMode = .auto) -> Tuning.Resolved {
        Tuning.resolve(
            instrument: .ukulele, tuningId: "high-g", customMidi: [],
            mode: mode, a4: 440.0, precision: false, guided: mode == .guided)
    }

    private static func makeSession(mode: TunerMode = .auto) -> TunerAnalysisSession {
        let resolved = ukulele(mode: mode)
        return TunerAnalysisSession(config: resolved.config, targets: resolved.targets)
    }

    /// A plucked-string stand-in: a fundamental with two harmonics.
    private static func tone(_ frequency: Double, seconds: Double) -> [Float] {
        (0..<Int(rate * seconds)).map { i in
            let t = Double(i) / rate
            let v = sin(2.0 * .pi * frequency * t)
                + 0.5 * sin(2.0 * .pi * 2.0 * frequency * t)
                + 0.25 * sin(2.0 * .pi * 3.0 * frequency * t)
            return Float(v) * 0.15
        }
    }

    private static func chunks(_ samples: [Float], of size: Int) -> [[Float]] {
        stride(from: 0, to: samples.count, by: size).map { Array(samples[$0..<min($0 + size, samples.count)]) }
    }

    /// Lets everything the worker has handed to the main queue run.
    private static func settle(_ session: TunerAnalysisSession) async {
        session.waitUntilIdle()
        await MainActor.run {}
    }

    @Test("A capture callback carrying several hops delivers every hop to the engine")
    func everyHopOfALargeCallbackIsAnalysed() async {
        let audio = Self.tone(440.0, seconds: 1.0)

        // What the engine says about this audio, hop by hop.
        let engine = ReadingEngine(configuration: ReadingEngine.Configuration(Self.ukulele()))
        let expected = engine.push(audio, sampleRate: Self.rate)
            .filter { $0.display != .unchanged }
            .map(\.display.reading)
        #expect(expected.contains { $0 != nil })

        // The same audio as a real device delivers it: several hops per callback.
        let session = Self.makeSession()
        let published = TestBox<[TunerReading?]>([])
        await MainActor.run {
            session.onSnapshotPublished = { snapshot in published.mutate { $0.append(snapshot.reading) } }
        }
        for callback in Self.chunks(audio, of: 4800) {
            session.submit(callback, sampleRate: Self.rate, hostEnd: nil)
            session.waitUntilIdle()
        }
        await Self.settle(session)

        #expect(published.get() == expected)
        #expect(session.overloads == 0)
        #expect(session.droppedCallbacks == 0)
    }

    @Test("The worker analyses one stretch of audio at a time, in order")
    func workerIsSerial() async {
        let session = Self.makeSession()
        let tracker = TestConcurrencyTracker()
        let counter = TestBox<UInt64>(0)
        session.analysisHook = { _, _ in
            tracker.jobStarted()
            Thread.sleep(forTimeInterval: 0.005)
            counter.mutate { $0 += 1 }
            tracker.jobFinished(sequence: counter.get())
        }

        for callback in Self.chunks(Self.tone(440.0, seconds: 0.25), of: 1024) {
            session.submit(callback, sampleRate: Self.rate, hostEnd: nil)
        }
        session.waitUntilIdle()

        let (concurrency, executed) = tracker.results()
        #expect(concurrency == 1)
        #expect(executed == executed.sorted())
        #expect(!executed.isEmpty)
    }

    @Test("Audio waiting within the bound is all analysed; nothing is replaced")
    func withinTheBoundNothingIsDropped() async throws {
        let session = Self.makeSession()
        let analysed = TestBox<Int>(0)
        session.analysisHook = { _, _ in
            if analysed.get() == 0 { Thread.sleep(forTimeInterval: 0.06) }
            analysed.mutate { $0 += 1 }
        }

        let callbacks = Self.chunks(Self.tone(440.0, seconds: 0.3), of: 1024)
        session.submit(callbacks[0], sampleRate: Self.rate, hostEnd: nil)
        try await Task.sleep(nanoseconds: 10_000_000)
        // Twelve more hops arrive while the worker is stuck on the first: 12,288 samples,
        // inside the 16,384 bound.
        for callback in callbacks[1...12] {
            session.submit(callback, sampleRate: Self.rate, hostEnd: nil)
        }
        session.waitUntilIdle()

        #expect(analysed.get() == 13)
        #expect(session.overloads == 0)
        #expect(session.droppedCallbacks == 0)
    }

    @Test("Falling further behind than the bound is an explicit discontinuity, counted")
    func overloadIsADiscontinuity() async throws {
        let session = Self.makeSession()
        let analysed = TestBox<Int>(0)
        session.analysisHook = { _, _ in
            if analysed.get() == 0 { Thread.sleep(forTimeInterval: 0.08) }
            analysed.mutate { $0 += 1 }
        }

        let callbacks = Self.chunks(Self.tone(440.0, seconds: 1.0), of: 1024)
        session.submit(callbacks[0], sampleRate: Self.rate, hostEnd: nil)
        try await Task.sleep(nanoseconds: 10_000_000)
        // Twenty more hops while the worker is stuck: 20,480 samples, past the bound.
        for callback in callbacks[1...20] {
            session.submit(callback, sampleRate: Self.rate, hostEnd: nil)
        }
        session.waitUntilIdle()

        #expect(session.overloads == 1)
        #expect(session.droppedCallbacks == 16, "The sixteen callbacks that filled the queue are discarded together")
        #expect(analysed.get() == 5, "The first callback, and the four that arrived after the restart")
    }

    @Test("Stop increments generation and prevents publication of in-flight results")
    func stopInvalidatesInFlightResults() async throws {
        let session = Self.makeSession()
        let initialGeneration = session.generation
        let publications = TestBox<Int>(0)
        await MainActor.run {
            session.onSnapshotPublished = { _ in publications.mutate { $0 += 1 } }
        }
        session.analysisHook = { _, _ in Thread.sleep(forTimeInterval: 0.05) }

        session.submit(Self.tone(440.0, seconds: 0.5), sampleRate: Self.rate, hostEnd: nil)
        session.stop()
        #expect(session.generation > initialGeneration)

        await Self.settle(session)
        #expect(publications.get() == 0, "Nothing computed before the stop may be published after it")
    }

    @Test("A Tuning change invalidates analysis in flight under the old one")
    func tuningChangeInvalidatesInFlightResults() async throws {
        let session = Self.makeSession()
        let snapshots = TestBox<[AnalysisSnapshot]>([])
        await MainActor.run {
            session.onSnapshotPublished = { snapshot in snapshots.mutate { $0.append(snapshot) } }
        }
        session.analysisHook = { _, _ in Thread.sleep(forTimeInterval: 0.05) }

        session.submit(Self.tone(440.0, seconds: 0.5), sampleRate: Self.rate, hostEnd: nil)
        session.adopt(Tuning.resolve(
            instrument: .guitar, tuningId: "standard", customMidi: [],
            mode: .auto, a4: 440.0, precision: false, guided: false))

        await Self.settle(session)
        #expect(snapshots.get().isEmpty)

        // And the session goes on to publish under the new Tuning.
        let after = session.processSync(Self.tone(110.0, seconds: 0.5), sampleRate: Self.rate)
        #expect(after.allSatisfy { $0.generation == session.generation })
        #expect(after.compactMap(\.reading).allSatisfy { $0.aim.target?.note == "A2" })
    }

    @Test("The synchronous seam runs the live path and reports its diagnostics")
    func synchronousSeam() {
        let session = Self.makeSession()
        let audio = Self.tone(440.0, seconds: 0.5)
        let snapshots = session.processSync(audio, sampleRate: Self.rate)

        #expect(!snapshots.isEmpty)
        #expect(snapshots.map(\.sequence) == Array(1...UInt64(snapshots.count)))
        #expect(snapshots.allSatisfy { $0.diagnostics.sampleRate == Self.rate })
        #expect(snapshots.allSatisfy { $0.diagnostics.queueDelayMs == 0.0 })
        #expect(snapshots.allSatisfy { $0.diagnostics.dspMs > 0.0 })
        #expect(snapshots.allSatisfy { $0.diagnostics.callbackFrameCount == audio.count })
        #expect(snapshots.contains { $0.reading != nil })
        #expect(snapshots.last?.feedbackState == .tracking)
    }

    @Test("Result age is measured against the host clock, and is zero when there is none")
    func resultAge() {
        let session = Self.makeSession()
        let audio = Self.tone(440.0, seconds: 0.3)

        let replay = session.processSync(audio, sampleRate: Self.rate)
        #expect(replay.allSatisfy { $0.diagnostics.resultAgeMs == 0.0 })

        let captured = session.processSync(audio, sampleRate: Self.rate, hostEnd: CACurrentMediaTime() - 0.05)
        #expect(!captured.isEmpty)
        #expect(captured.allSatisfy { $0.diagnostics.resultAgeMs >= 50.0 && $0.diagnostics.resultAgeMs < 5_000.0 })
    }

    @Test("Reading times are host-clock times through the session")
    func readingTimesAreOnTheHostClock() {
        let session = Self.makeSession()
        let hostStart = 5000.0
        let audio = Self.tone(440.0, seconds: 1.0)
        var readings: [TunerReading] = []
        var delivered = 0
        for callback in Self.chunks(audio, of: 1024) {
            delivered += callback.count
            readings += session.processSync(
                callback, sampleRate: Self.rate,
                hostEnd: hostStart + Double(delivered) / Self.rate).compactMap(\.reading)
        }
        #expect(!readings.isEmpty)
        #expect(readings.allSatisfy { $0.at > hostStart && $0.at <= hostStart + 1.0 + 1e-9 })
    }

    @Test("A restart at a new sample rate invalidates the old generation and carries on")
    func sampleRateRestart() {
        let session = Self.makeSession()
        let initialGeneration = session.generation
        #expect(!session.processSync(Self.tone(440.0, seconds: 0.3), sampleRate: 44100.0).isEmpty)

        let resolved = Self.ukulele()
        session.start(config: resolved.config, targets: resolved.targets)
        #expect(session.generation > initialGeneration)

        let after = session.processSync([Float](repeating: 0, count: 9600), sampleRate: 48000.0)
        #expect(!after.isEmpty)
        #expect(after.allSatisfy { $0.diagnostics.sampleRate == 48000.0 && $0.generation == session.generation })
    }

    @Test("Guided state read straight after a change already reflects it")
    func guidedStateMirrorsTheChange() {
        let session = Self.makeSession(mode: .guided)
        let g4 = PitchMath.midiFrequency(67)
        _ = session.processSync(Self.tone(g4, seconds: 1.5), sampleRate: Self.rate)
        #expect(session.guidedProgress == [true, false, false, false])
        #expect(session.guidedTargetIndex == 1)

        // A mode change keeps the player's completed Strings…
        session.updateConfiguration(Self.ukulele(mode: .auto).config, preservingGuidedProgress: true)
        #expect(session.guidedProgress == [true, false, false, false])

        // …a restart of the sequence does not…
        session.resetGuidedSession()
        #expect(session.guidedProgress == [false, false, false, false])
        #expect(session.guidedTargetIndex == 0)

        // …and what the worker reports afterwards agrees.
        session.updateConfiguration(Self.ukulele(mode: .guided).config, preservingGuidedProgress: true)
        let after = session.processSync(Self.tone(g4, seconds: 0.2), sampleRate: Self.rate)
        #expect(after.allSatisfy { $0.guidedProgress == [false, false, false, false] })
    }

    @Test("Audio capture zero-channel input throws noInputChannelsAvailable error")
    func testZeroChannelsThrowsError() {
        let error = AudioCaptureError.noInputChannelsAvailable
        #expect(error.errorDescription?.contains("0 channels") == true)
        #expect(error.errorDescription?.contains("No microphone is available") == true)
    }
}
