// StrumKitTests/Parity/DevicePerformanceTests.swift
import Foundation
import Testing
@testable import StrumKit

/// Real-time latency profile and headroom metrics for an audio processing stage.
public struct LatencyProfile: Sendable, CustomStringConvertible {
    public let count: Int
    public let p50Ms: Double
    public let p95Ms: Double
    public let p99Ms: Double
    public let maxMs: Double
    public let meanMs: Double
    public let budgetMs: Double

    public var p50HeadroomPercent: Double { (1.0 - (p50Ms / budgetMs)) * 100.0 }
    public var p95HeadroomPercent: Double { (1.0 - (p95Ms / budgetMs)) * 100.0 }
    public var p99HeadroomPercent: Double { (1.0 - (p99Ms / budgetMs)) * 100.0 }
    public var maxHeadroomPercent: Double { (1.0 - (maxMs / budgetMs)) * 100.0 }

    public init(durationsMs: [Double], budgetMs: Double) {
        precondition(!durationsMs.isEmpty, "durationsMs must not be empty")
        let sorted = durationsMs.sorted()
        self.count = sorted.count
        self.budgetMs = budgetMs
        self.meanMs = sorted.reduce(0.0, +) / Double(sorted.count)
        self.p50Ms = Self.percentile(sorted: sorted, p: 0.50)
        self.p95Ms = Self.percentile(sorted: sorted, p: 0.95)
        self.p99Ms = Self.percentile(sorted: sorted, p: 0.99)
        self.maxMs = sorted.last ?? 0.0
    }

    private static func percentile(sorted: [Double], p: Double) -> Double {
        let index = Int(ceil(p * Double(sorted.count))) - 1
        return sorted[max(0, min(sorted.count - 1, index))]
    }

    public var description: String {
        String(
            format: "n=%d | p50: %.3f ms (%.1f%% headroom) | p95: %.3f ms (%.1f%% headroom) | p99: %.3f ms (%.1f%% headroom) | max: %.3f ms (%.1f%% headroom) | mean: %.3f ms",
            count, p50Ms, p50HeadroomPercent, p95Ms, p95HeadroomPercent, p99Ms, p99HeadroomPercent, maxMs, maxHeadroomPercent, meanMs
        )
    }
}

@Suite("Device Real-Time Headroom & Performance Profiling")
struct DevicePerformanceTests {

    // Real-time hop budgets (1024 samples per hop)
    private static let budget48kMs: Double = (1024.0 / 48000.0) * 1000.0 // 21.333 ms
    private static let budget44kMs: Double = (1024.0 / 44100.0) * 1000.0 // 23.220 ms
    private static let minimumRequiredHeadroomPercent: Double = 80.0 // > 80% headroom

    // MARK: - Signal Generation Helper

    /// Synthesizes a realistic multi-note audio stream with physical harmonic decay and noise floor.
    private func generateRealisticPlucks(
        notes: [(frequency: Double, durationSeconds: Double)],
        sampleRate: Double,
        baseAmplitude: Float = 0.2
    ) -> [Float] {
        var allSamples: [Float] = []
        var rng: UInt64 = 0x12345678_deadbeef

        for (fundamentalHz, duration) in notes {
            let noteSampleCount = Int(duration * sampleRate)
            var noteSamples = [Float](repeating: 0, count: noteSampleCount)

            for i in 0..<noteSampleCount {
                let t = Double(i) / sampleRate
                // Exponential decay envelope (decay constant ~ 1.2s)
                let envelope = exp(-t / 1.2)

                // Multi-harmonic pluck synthesis (1st, 2nd, 3rd, 4th harmonics)
                var val: Double = 0.0
                val += 1.00 * sin(2.0 * Double.pi * fundamentalHz * 1.0 * t)
                val += 0.50 * sin(2.0 * Double.pi * fundamentalHz * 2.0 * t)
                val += 0.25 * sin(2.0 * Double.pi * fundamentalHz * 3.0 * t)
                val += 0.12 * sin(2.0 * Double.pi * fundamentalHz * 4.0 * t)

                // Pseudorandom noise floor (-70 dB)
                rng = rng &* 6364136223846793005 &+ 1442695040888963407
                let noise = (Double(rng >> 32) / Double(UInt32.max) - 0.5) * 0.0003

                noteSamples[i] = Float((val * envelope * Double(baseAmplitude)) + noise)
            }
            allSamples.append(contentsOf: noteSamples)
        }

        return allSamples
    }

    // MARK: - 1. Profiling at 44.1 kHz (Ukulele Standard: G4, C4, E4, A4)

    @Test("Profile 44.1 kHz pipeline: detector, tracker, capture-to-pub across 500 hops with > 80% headroom")
    func testProfiling44100Hz() throws {
        let sampleRate = 44100.0
        let hopSamples = 1024
        let windowSize = 4096
        let totalHops = 500
        let totalSamples = windowSize + totalHops * hopSamples

        // 4 Ukulele strings: G4 (392.00 Hz), C4 (261.63 Hz), E4 (329.63 Hz), A4 (440.00 Hz)
        let noteDuration = Double(totalSamples) / (4.0 * sampleRate)
        let notes: [(frequency: Double, durationSeconds: Double)] = [
            (392.00, noteDuration),
            (261.63, noteDuration),
            (329.63, noteDuration),
            (440.00, noteDuration)
        ]
        let audioData = generateRealisticPlucks(notes: notes, sampleRate: sampleRate)
        #expect(audioData.count >= totalSamples)

        let config = TunerConfig(instrument: .ukulele, tuningId: "standard", a4: 440.0, mode: .auto)
        let resolved = Tuning.resolve(
            instrument: config.instrument,
            tuningId: config.tuningId,
            customMidi: config.customMidi,
            mode: config.mode,
            a4: config.a4,
            precision: config.precision,
            guided: config.guided,
            selectedString: config.selectedString
        )
        let targets = resolved.targets

        let profile = FaithfulEngineProfile.profile(for: config.instrument, tuningId: config.tuningId)
        let detector = createPitchDetector(profile: profile)
        let tracker = FaithfulTracker()
        tracker.tuning = config.tuningId
        tracker.auto = true
        tracker.targets = targets.map { Target(note: $0.note, frequency: $0.frequency, midi: $0.midi, stringNumber: $0.number) }

        let session = TunerAnalysisSession(config: config, targets: targets)

        var detectorDurationsMs: [Double] = []
        var trackerDurationsMs: [Double] = []
        var captureToPubDurationsMs: [Double] = []

        let clock = ContinuousClock()
        var hopCount = 0

        for endSample in stride(from: windowSize, to: windowSize + totalHops * hopSamples, by: hopSamples) {
            hopCount += 1
            let startSample = endSample - windowSize
            let window = Array(audioData[startSample..<endSample])
            let captureEndSeconds = Double(endSample) / sampleRate
            let timeMs = captureEndSeconds * 1000.0

            // 1. Measure Detector
            let d0 = clock.now
            let candidate = detector.detect(input: window, sampleRate: sampleRate, sampleTime: timeMs)
            let d1 = clock.now
            let dDuration = d1 - d0
            let dMs = Double(dDuration.components.seconds) * 1000.0 + Double(dDuration.components.attoseconds) / 1e15
            detectorDurationsMs.append(dMs)

            // 2. Measure Tracker
            let t0 = clock.now
            _ = tracker.push(pitch: candidate, time: timeMs)
            let t1 = clock.now
            let tDuration = t1 - t0
            let tMs = Double(tDuration.components.seconds) * 1000.0 + Double(tDuration.components.attoseconds) / 1e15
            trackerDurationsMs.append(tMs)

            // 3. Measure End-to-End Capture-to-Publication (via TunerAnalysisSession)
            let frame = AnalysisFrame(
                samples: window,
                sampleRate: sampleRate,
                captureEndSeconds: captureEndSeconds,
                sequence: UInt64(hopCount),
                generation: session.generation,
                callbackFrameCount: hopSamples
            )
            let p0 = clock.now
            let snapshot = session.processFrameSync(frame)
            let p1 = clock.now
            let pDuration = p1 - p0
            let pMs = Double(pDuration.components.seconds) * 1000.0 + Double(pDuration.components.attoseconds) / 1e15
            captureToPubDurationsMs.append(pMs)

            #expect(snapshot != nil, "Snapshot must not be nil at hop \(hopCount)")
        }

        #expect(detectorDurationsMs.count == totalHops)
        #expect(trackerDurationsMs.count == totalHops)
        #expect(captureToPubDurationsMs.count == totalHops)

        let dProfile = LatencyProfile(durationsMs: detectorDurationsMs, budgetMs: Self.budget44kMs)
        let tProfile = LatencyProfile(durationsMs: trackerDurationsMs, budgetMs: Self.budget44kMs)
        let pubProfile = LatencyProfile(durationsMs: captureToPubDurationsMs, budgetMs: Self.budget44kMs)

        print("[Profiling 44.1kHz] Detector:            \(dProfile)")
        print("[Profiling 44.1kHz] Tracker:             \(tProfile)")
        print("[Profiling 44.1kHz] Capture-to-Pub:      \(pubProfile)")

        // Headroom validation: must be well above 80% (latency < 20% of 23.22 ms = 4.644 ms)
        #expect(pubProfile.p50HeadroomPercent >= Self.minimumRequiredHeadroomPercent,
                "p50 headroom \(pubProfile.p50HeadroomPercent)% is below required \(Self.minimumRequiredHeadroomPercent)%")
        #expect(pubProfile.p95HeadroomPercent >= Self.minimumRequiredHeadroomPercent,
                "p95 headroom \(pubProfile.p95HeadroomPercent)% is below required \(Self.minimumRequiredHeadroomPercent)%")
        #expect(pubProfile.p99HeadroomPercent >= Self.minimumRequiredHeadroomPercent,
                "p99 headroom \(pubProfile.p99HeadroomPercent)% is below required \(Self.minimumRequiredHeadroomPercent)%")
        #expect(pubProfile.maxHeadroomPercent >= Self.minimumRequiredHeadroomPercent,
                "max headroom \(pubProfile.maxHeadroomPercent)% is below required \(Self.minimumRequiredHeadroomPercent)%")
    }

    // MARK: - 2. Profiling at 48.0 kHz (Guitar Extended: Low E 82.4 Hz to E4)

    @Test("Profile 48.0 kHz pipeline: detector, tracker, capture-to-pub across 500 hops with > 80% headroom")
    func testProfiling48000Hz() throws {
        let sampleRate = 48000.0
        let hopSamples = 1024
        let windowSize = 4096
        let totalHops = 500
        let totalSamples = windowSize + totalHops * hopSamples

        // 6 Guitar strings: E2 (82.41 Hz), A2 (110.00 Hz), D3 (146.83 Hz), G3 (196.00 Hz), B3 (246.94 Hz), E4 (329.63 Hz)
        let noteDuration = Double(totalSamples) / (6.0 * sampleRate)
        let notes: [(frequency: Double, durationSeconds: Double)] = [
            (82.41, noteDuration),
            (110.00, noteDuration),
            (146.83, noteDuration),
            (196.00, noteDuration),
            (246.94, noteDuration),
            (329.63, noteDuration)
        ]
        let audioData = generateRealisticPlucks(notes: notes, sampleRate: sampleRate)
        #expect(audioData.count >= totalSamples)

        let config = TunerConfig(instrument: .guitar, tuningId: "standard", a4: 440.0, mode: .auto)
        let resolved = Tuning.resolve(
            instrument: config.instrument,
            tuningId: config.tuningId,
            customMidi: config.customMidi,
            mode: config.mode,
            a4: config.a4,
            precision: config.precision,
            guided: config.guided,
            selectedString: config.selectedString
        )
        let targets = resolved.targets

        let profile = FaithfulEngineProfile.profile(for: config.instrument, tuningId: config.tuningId)
        let detector = createPitchDetector(profile: profile)
        let tracker = FaithfulTracker()
        tracker.tuning = config.tuningId
        tracker.auto = true
        tracker.targets = targets.map { Target(note: $0.note, frequency: $0.frequency, midi: $0.midi, stringNumber: $0.number) }

        let session = TunerAnalysisSession(config: config, targets: targets)

        var detectorDurationsMs: [Double] = []
        var trackerDurationsMs: [Double] = []
        var captureToPubDurationsMs: [Double] = []

        let clock = ContinuousClock()
        var hopCount = 0

        for endSample in stride(from: windowSize, to: windowSize + totalHops * hopSamples, by: hopSamples) {
            hopCount += 1
            let startSample = endSample - windowSize
            let window = Array(audioData[startSample..<endSample])
            let captureEndSeconds = Double(endSample) / sampleRate
            let timeMs = captureEndSeconds * 1000.0

            // 1. Measure Detector
            let d0 = clock.now
            let candidate = detector.detect(input: window, sampleRate: sampleRate, sampleTime: timeMs)
            let d1 = clock.now
            let dDuration = d1 - d0
            let dMs = Double(dDuration.components.seconds) * 1000.0 + Double(dDuration.components.attoseconds) / 1e15
            detectorDurationsMs.append(dMs)

            // 2. Measure Tracker
            let t0 = clock.now
            _ = tracker.push(pitch: candidate, time: timeMs)
            let t1 = clock.now
            let tDuration = t1 - t0
            let tMs = Double(tDuration.components.seconds) * 1000.0 + Double(tDuration.components.attoseconds) / 1e15
            trackerDurationsMs.append(tMs)

            // 3. Measure End-to-End Capture-to-Publication (via TunerAnalysisSession)
            let frame = AnalysisFrame(
                samples: window,
                sampleRate: sampleRate,
                captureEndSeconds: captureEndSeconds,
                sequence: UInt64(hopCount),
                generation: session.generation,
                callbackFrameCount: hopSamples
            )
            let p0 = clock.now
            let snapshot = session.processFrameSync(frame)
            let p1 = clock.now
            let pDuration = p1 - p0
            let pMs = Double(pDuration.components.seconds) * 1000.0 + Double(pDuration.components.attoseconds) / 1e15
            captureToPubDurationsMs.append(pMs)

            #expect(snapshot != nil, "Snapshot must not be nil at hop \(hopCount)")
        }

        #expect(detectorDurationsMs.count == totalHops)
        #expect(trackerDurationsMs.count == totalHops)
        #expect(captureToPubDurationsMs.count == totalHops)

        let dProfile = LatencyProfile(durationsMs: detectorDurationsMs, budgetMs: Self.budget48kMs)
        let tProfile = LatencyProfile(durationsMs: trackerDurationsMs, budgetMs: Self.budget48kMs)
        let pubProfile = LatencyProfile(durationsMs: captureToPubDurationsMs, budgetMs: Self.budget48kMs)

        print("[Profiling 48.0kHz] Detector:            \(dProfile)")
        print("[Profiling 48.0kHz] Tracker:             \(tProfile)")
        print("[Profiling 48.0kHz] Capture-to-Pub:      \(pubProfile)")

        // Headroom validation: must be well above 80% (latency < 20% of 21.33 ms = 4.266 ms)
        #expect(pubProfile.p50HeadroomPercent >= Self.minimumRequiredHeadroomPercent,
                "p50 headroom \(pubProfile.p50HeadroomPercent)% is below required \(Self.minimumRequiredHeadroomPercent)%")
        #expect(pubProfile.p95HeadroomPercent >= Self.minimumRequiredHeadroomPercent,
                "p95 headroom \(pubProfile.p95HeadroomPercent)% is below required \(Self.minimumRequiredHeadroomPercent)%")
        #expect(pubProfile.p99HeadroomPercent >= Self.minimumRequiredHeadroomPercent,
                "p99 headroom \(pubProfile.p99HeadroomPercent)% is below required \(Self.minimumRequiredHeadroomPercent)%")
        #expect(pubProfile.maxHeadroomPercent >= Self.minimumRequiredHeadroomPercent,
                "max headroom \(pubProfile.maxHeadroomPercent)% is below required \(Self.minimumRequiredHeadroomPercent)%")
    }

    // MARK: - Thread-Safe Test Helper

    private final class ThreadSafeCounter: @unchecked Sendable {
        private let condition = NSCondition()
        private var count: Int = 0

        func increment() {
            condition.lock()
            count += 1
            condition.signal()
            condition.unlock()
        }

        func waitUntilCount(atLeast target: Int, timeoutSeconds: TimeInterval = 1.0) -> Bool {
            condition.lock()
            defer { condition.unlock() }
            let deadline = Date(timeIntervalSinceNow: timeoutSeconds)
            while count < target {
                if !condition.wait(until: deadline) {
                    return count >= target
                }
            }
            return true
        }

        var value: Int {
            condition.lock()
            defer { condition.unlock() }
            return count
        }
    }

    // MARK: - 3. Sustained Streaming with Zero Dropped Frames (44.1 kHz & 48.0 kHz)

    @Test("Sustained 44.1 kHz capture stream across 300 hops maintains zero dropped and zero replaced windows")
    func testSustainedStreaming44100Hz() throws {
        let sampleRate = 44100.0
        let hopSamples = 1024
        let totalHops = 300

        let config = TunerConfig(instrument: .ukulele, tuningId: "standard", a4: 440.0, mode: .auto)
        let session = TunerAnalysisSession(config: config, targets: [])
        let source = ScriptedMicrophone(sampleRate: sampleRate)
        let counter = ThreadSafeCounter()

        session.analysisHook = { _, _ in
            counter.increment()
        }

        try session.start(source: source, config: config, targets: [])

        // Initial framing prefill: 3 chunks of 1024 samples (3072 samples < 4096 window size)
        let prefillSamples = 3072
        let totalSamples = prefillSamples + totalHops * hopSamples
        let notes = [(440.0, Double(totalSamples) / sampleRate)]
        let pcm = generateRealisticPlucks(notes: notes, sampleRate: sampleRate)

        for i in 0..<3 {
            let start = i * hopSamples
            let chunk = Array(pcm[start..<(start + hopSamples)])
            let captureTime = Double(start + hopSamples) / sampleRate
            source.emit(CapturedWindow(samples: chunk, sampleRate: sampleRate, captureEnd: captureTime))
        }
        #expect(counter.value == 0, "Framing prefill (< 4096 samples) must yield 0 windows")

        // Sustained 300 hops: each 1024-sample chunk produces exactly 1 window
        for hop in 0..<totalHops {
            let start = prefillSamples + hop * hopSamples
            let chunk = Array(pcm[start..<(start + hopSamples)])
            let captureTime = Double(start + hopSamples) / sampleRate

            source.emit(CapturedWindow(samples: chunk, sampleRate: sampleRate, captureEnd: captureTime))
            let success = counter.waitUntilCount(atLeast: hop + 1, timeoutSeconds: 1.0)
            #expect(success, "Worker must process hop \(hop + 1) without timeout")
        }

        let finalAnalyzed = counter.value
        session.stop()

        #expect(finalAnalyzed == totalHops, "All \(totalHops) frames must be analyzed, but got \(finalAnalyzed)")
        #expect(session.droppedFrames == 0, "Sustained operation must drop exactly zero frames (got \(session.droppedFrames))")
        #expect(session.replacedFrames == 0, "Sustained operation must replace exactly zero frames (got \(session.replacedFrames))")
    }

    @Test("Sustained 48.0 kHz capture stream across 300 hops maintains zero dropped and zero replaced windows")
    func testSustainedStreaming48000Hz() throws {
        let sampleRate = 48000.0
        let hopSamples = 1024
        let totalHops = 300

        let config = TunerConfig(instrument: .guitar, tuningId: "standard", a4: 440.0, mode: .auto)
        let session = TunerAnalysisSession(config: config, targets: [])
        let source = ScriptedMicrophone(sampleRate: sampleRate)
        let counter = ThreadSafeCounter()

        session.analysisHook = { _, _ in
            counter.increment()
        }

        try session.start(source: source, config: config, targets: [])

        let prefillSamples = 3072
        let totalSamples = prefillSamples + totalHops * hopSamples
        let notes = [(82.41, Double(totalSamples) / sampleRate)]
        let pcm = generateRealisticPlucks(notes: notes, sampleRate: sampleRate)

        for i in 0..<3 {
            let start = i * hopSamples
            let chunk = Array(pcm[start..<(start + hopSamples)])
            let captureTime = Double(start + hopSamples) / sampleRate
            source.emit(CapturedWindow(samples: chunk, sampleRate: sampleRate, captureEnd: captureTime))
        }
        #expect(counter.value == 0, "Framing prefill (< 4096 samples) must yield 0 windows")

        for hop in 0..<totalHops {
            let start = prefillSamples + hop * hopSamples
            let chunk = Array(pcm[start..<(start + hopSamples)])
            let captureTime = Double(start + hopSamples) / sampleRate

            source.emit(CapturedWindow(samples: chunk, sampleRate: sampleRate, captureEnd: captureTime))
            let success = counter.waitUntilCount(atLeast: hop + 1, timeoutSeconds: 1.0)
            #expect(success, "Worker must process hop \(hop + 1) without timeout")
        }

        let finalAnalyzed = counter.value
        session.stop()

        #expect(finalAnalyzed == totalHops, "All \(totalHops) frames must be analyzed, but got \(finalAnalyzed)")
        #expect(session.droppedFrames == 0, "Sustained operation must drop exactly zero frames (got \(session.droppedFrames))")
        #expect(session.replacedFrames == 0, "Sustained operation must replace exactly zero frames (got \(session.replacedFrames))")
    }

    // MARK: - 4. Release Bundle Resource Audit

    @Test("Compiled App target strictly excludes audio fixtures, traces, TypeScript reference sources, and oracles")
    func testReleaseBundleExclusions() throws {
        let fileManager = FileManager.default

        // Locate StrumKit.app: check Bundle.main as well as DerivedData build products
        var candidateURLs: [URL] = []
        if Bundle.main.bundleURL.pathExtension == "app" {
            candidateURLs.append(Bundle.main.bundleURL)
        }
        let possibleDerivedDataPaths = [
            "./DerivedData/Build/Products/Debug-iphonesimulator/StrumKit.app",
            "./DerivedDataO/Build/Products/Debug-iphonesimulator/StrumKit.app"
        ]
        for path in possibleDerivedDataPaths {
            if fileManager.fileExists(atPath: path) {
                candidateURLs.append(URL(fileURLWithPath: path))
            }
        }

        #expect(!candidateURLs.isEmpty, "At least one StrumKit.app bundle must be discovered")

        for bundleURL in candidateURLs {
            let resourceURL = bundleURL.appendingPathComponent("")
            let enumerator = fileManager.enumerator(at: resourceURL, includingPropertiesForKeys: nil)

            var forbiddenFiles: [String] = []

            while let fileURL = enumerator?.nextObject() as? URL {
                let name = fileURL.lastPathComponent.lowercased()
                let path = fileURL.path.lowercased()

                // Skip PlugIns or Frameworks if injected by test runners
                if path.contains("/plugins/") || path.contains("/frameworks/") {
                    continue
                }

                // Disallowed audio assets
                if name.hasSuffix(".wav") || name.hasSuffix(".m4a") || name.hasSuffix(".aiff") || name.hasSuffix(".mp3") {
                    forbiddenFiles.append(fileURL.lastPathComponent)
                }
                // Disallowed reference TS files
                if name.hasSuffix(".ts") {
                    forbiddenFiles.append(fileURL.lastPathComponent)
                }
                // Disallowed traces, corpora, oracles
                if name.contains("corpus") || name.contains("oracle") || name.contains("fixture") || name.contains("trace") {
                    forbiddenFiles.append(fileURL.lastPathComponent)
                }
            }

            #expect(forbiddenFiles.isEmpty, "Bundle at \(bundleURL.path) must not contain test assets: \(forbiddenFiles)")
        }
    }
}
