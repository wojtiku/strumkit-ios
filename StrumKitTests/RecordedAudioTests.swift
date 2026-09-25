import Testing
import Foundation
@testable import StrumKit

@Suite("Recorded Real Audio Fixture Replay Tests (recorded.test.ts)")
struct RecordedAudioTests {

    @Test("replays licensed real ukulele sustains with acceptance count >= 10")
    func testUkuleleSustainsReplay() {
        let ukeFiles = ["uke_a", "uke_c", "uke_e", "uke_g"]
        let config = TunerConfig(instrument: .ukulele, tuningId: "high-g", mode: .chromatic)

        for name in ukeFiles {
            guard let wav = AudioTestHelpers.loadWav(name: name) else {
                Issue.record("Failed to load WAV fixture: \(name).wav")
                continue
            }

            let (readings, _) = AudioTestHelpers.replay(samples: wav.samples, sampleRate: wav.sampleRate, config: config)
            let freshReadings = readings.filter { $0.freshness == .fresh }

            // Usable-audio regression gate: ensures the tuner detects at least 10 valid pitch windows on real instruments
            #expect(freshReadings.count >= 10, "Expected at least 10 fresh readings for \(name).wav, got \(freshReadings.count)")
        }
    }

    @Test("a licensed real strummed guitar chord never completes a guided string")
    func testStrummedGuitarChordRejectionInGuidedMode() {
        guard let wav = AudioTestHelpers.loadWav(name: "guitar-chord") else {
            Issue.record("Failed to load WAV fixture: guitar-chord.wav")
            return
        }

        let config = TunerConfig(instrument: .guitar, tuningId: "standard", mode: .guided, guided: true)
        let (_, tracker) = AudioTestHelpers.replay(samples: wav.samples, sampleRate: wav.sampleRate, config: config)

        // A polyphonic chord must NEVER accidentally validate and complete a single-string guided tune!
        #expect(!tracker.guidedProgress.contains(true), "A strummed chord must not complete any guided string")
    }

    @Test("replays user-provided quiet ukulele plucks with valid pitch and sustain")
    func testUserQuietUkuleleReplay() {
        let quietFiles = ["quiet_a", "quiet_c", "quiet_e", "quiet_g"]
        let config = TunerConfig(instrument: .ukulele, tuningId: "high-g", mode: .chromatic)

        for name in quietFiles {
            guard let wav = AudioTestHelpers.loadWav(name: name) else {
                Issue.record("Failed to load WAV fixture: \(name).wav")
                continue
            }

            let (readings, _) = AudioTestHelpers.replay(samples: wav.samples, sampleRate: wav.sampleRate, config: config)
            let freshReadings = readings.filter { $0.freshness == .fresh }
            let heldReadings = readings.filter { $0.freshness == .held }

            print("[\(name)] Total: \(readings.count), Fresh: \(freshReadings.count), Held: \(heldReadings.count)")
            if let first = freshReadings.first {
                print("[\(name)] First detected note: \(first.note), freq: \(first.frequency) Hz")
            }
            #expect(freshReadings.count >= 5, "Expected at least 5 fresh readings for \(name).wav, got \(freshReadings.count)")
        }
    }

    @Test("Replay trace baseline measurements for quiet ukulele plucks in auto and chromatic modes")
    func testQuietUkuleleTraceBaseline() {
        let fixtures: [(name: String, note: String, freq: Double, midi: Int)] = [
            ("quiet_a", "A4", 440.0, 69),
            ("quiet_c", "C4", 261.63, 60),
            ("quiet_e", "E4", 329.63, 64),
            ("quiet_g", "G4", 392.00, 67)
        ]

        for fix in fixtures {
            guard let wav = AudioTestHelpers.loadWav(name: fix.name) else {
                Issue.record("Failed to load WAV fixture: \(fix.name).wav")
                continue
            }

            // 1. Auto mode (primary user flow)
            let autoConfig = TunerConfig(instrument: .ukulele, tuningId: "high-g", mode: .auto)
            let (autoFrames, _) = AudioTestHelpers.replayTrace(samples: wav.samples, sampleRate: wav.sampleRate, config: autoConfig)

            let autoFresh = autoFrames.compactMap { $0.reading }.filter { $0.freshness == .fresh }
            let autoCorrectFresh = autoFresh.filter { AudioTestHelpers.isCorrectRecordedPitch($0.frequency, reference: fix.freq) }
            let autoWrongFresh = autoFresh.filter { !AudioTestHelpers.isCorrectRecordedPitch($0.frequency, reference: fix.freq) }
            let autoHeld = autoFrames.compactMap { $0.reading }.filter { $0.freshness == .held }
            let autoCoverage = AudioTestHelpers.freshCoverageSeconds(frames: autoFrames, reference: fix.freq, intervalStart: 0.20, intervalEnd: 1.30)
            let firstCorrectAt = autoCorrectFresh.first?.at
            let lastCorrectAt = autoCorrectFresh.last?.at

            print("BASELINE [\(fix.name) AUTO]: TotalFrames=\(autoFrames.count), Fresh=\(autoFresh.count), CorrectFresh=\(autoCorrectFresh.count), WrongFresh=\(autoWrongFresh.count), Held=\(autoHeld.count), Coverage=\(String(format: "%.3f", autoCoverage))s, First=\(String(format: "%.3f", firstCorrectAt ?? -1)), Last=\(String(format: "%.3f", lastCorrectAt ?? -1))")

            #expect(autoWrongFresh.isEmpty, "Auto mode must produce zero wrong fresh notes for \(fix.name)")
            #expect(!autoCorrectFresh.isEmpty, "Auto mode must detect at least one correct fresh reading for \(fix.name)")

            // 2. Chromatic mode (diagnostic broad-spectrum flow)
            let chromConfig = TunerConfig(instrument: .ukulele, tuningId: "high-g", mode: .chromatic)
            let (chromFrames, _) = AudioTestHelpers.replayTrace(samples: wav.samples, sampleRate: wav.sampleRate, config: chromConfig)
            let chromFresh = chromFrames.compactMap { $0.reading }.filter { $0.freshness == .fresh }
            let chromCorrectFresh = chromFresh.filter { AudioTestHelpers.isCorrectRecordedPitch($0.frequency, reference: fix.freq) }
            let chromWrongFresh = chromFresh.filter { !AudioTestHelpers.isCorrectRecordedPitch($0.frequency, reference: fix.freq) }

            print("BASELINE [\(fix.name) CHROMATIC]: Fresh=\(chromFresh.count), CorrectFresh=\(chromCorrectFresh.count), WrongFresh=\(chromWrongFresh.count)")

            // Auto mode is the primary user flow and must be clean. Chromatic mode
            // is diagnostic: it reports whatever note it hears, with no target set
            // to anchor it, so a decaying fundamental sliding between semitones can
            // surface as a different note. That is a real open defect (see
            // docs/tuner-reliability/RESULTS.md) rather than a passing condition,
            // so it is bounded and printed here to keep it from regressing
            // silently, but it is not asserted to zero.
            #expect(chromWrongFresh.count <= 24,
                    "\(fix.name): chromatic wrong-note count \(chromWrongFresh.count) exceeds the recorded bound of 24")
        }
    }

    // MARK: - Task 5 Acceptance Gate (Verified with Spectral Recovery)
    @Test("Task 5 Acceptance Gate: quiet A4 sustain coverage >= 0.40s and late fresh detection >= 0.90s")
    func testQuietASustainAcceptanceTarget() {
        guard let wav = AudioTestHelpers.loadWav(name: "quiet_a") else {
            Issue.record("Failed to load quiet_a.wav")
            return
        }

        // Evaluated at the live request cadence, not a coarser one: the gate is only
        // meaningful if it is measured the way the app actually runs.
        for hop in [AudioTestHelpers.productionHopSamples, 2048] {
            let config = TunerConfig(instrument: .ukulele, tuningId: "high-g", mode: .auto)
            let (frames, _) = AudioTestHelpers.replayTrace(
                samples: wav.samples,
                sampleRate: wav.sampleRate,
                config: config,
                hopSamples: hop
            )

            let freshReadings = frames.compactMap { $0.reading }.filter { $0.freshness == .fresh }
            let correctFresh = freshReadings.filter { AudioTestHelpers.isCorrectRecordedPitch($0.frequency, reference: 440.0) }
            let wrongFresh = freshReadings.filter { !AudioTestHelpers.isCorrectRecordedPitch($0.frequency, reference: 440.0) }

            let coverage = AudioTestHelpers.freshCoverageSeconds(frames: frames, reference: 440.0, intervalStart: 0.20, intervalEnd: 1.30)
            let lastFreshAt = correctFresh.last?.at ?? 0

            print(String(format: "TASK5-GATE hop=%lld: coverage=%.3fs lastCorrect=%.3fs fresh=%lld wrong=%lld",
                         hop, coverage, lastFreshAt, freshReadings.count, wrongFresh.count))

            #expect(wrongFresh.isEmpty, "Must have zero wrong fresh notes at hop \(hop)")
            #expect(coverage >= 0.40, "Coverage in [0.20, 1.30] must be >= 0.40s at hop \(hop), got \(coverage)s")
            #expect(lastFreshAt >= 0.90, "Must have a correct fresh output at or after 0.90s at hop \(hop), got \(lastFreshAt)s")
        }
    }

    // MARK: - Task 5 Transition & Robustness Tests

    @Test("Synthetic string transition A4 to C4 acquires new string within 200ms without stale prior")
    func testSyntheticStringTransitionA4ToC4() {
        let sampleRate = 44100.0
        let a4Pluck = AudioTestHelpers.pluck(rate: sampleRate, frequency: 440.0, seconds: 0.8, snr: 30.0, initialSeed: 101)
        let c4Pluck = AudioTestHelpers.pluck(rate: sampleRate, frequency: 261.63, seconds: 0.8, snr: 30.0, initialSeed: 202)
        let transitionAudio = a4Pluck + c4Pluck

        let config = TunerConfig(instrument: .ukulele, tuningId: "high-g", mode: .auto)
        let (frames, _) = AudioTestHelpers.replayTrace(samples: transitionAudio, sampleRate: sampleRate, config: config)

        // 1. Initial string (A4) must be tracked in the first half
        let a4Fresh = frames.filter { $0.captureEndSeconds < 0.8 }.compactMap { $0.reading }.filter { $0.freshness == .fresh }
        let a4Correct = a4Fresh.filter { AudioTestHelpers.isCorrectRecordedPitch($0.frequency, reference: 440.0) }
        #expect(!a4Correct.isEmpty, "A4 must be detected during the first 0.8s")

        // 2. Next string (C4) onset begins at t = 0.8s; must acquire within 200ms (t <= 1.0s)
        let c4Window = frames.filter { $0.captureEndSeconds >= 0.8 && $0.captureEndSeconds <= 1.0 }
        let c4Acquired = c4Window.compactMap { $0.reading }.filter {
            $0.freshness == .fresh && AudioTestHelpers.isCorrectRecordedPitch($0.frequency, reference: 261.63)
        }
        #expect(!c4Acquired.isEmpty, "C4 must be acquired within 200ms of onset (by t=1.0s)")

        // 3. After C4 acquisition (t >= 1.0s), zero fresh frames may be labeled as the old A4 string
        let afterOnset = frames.filter { $0.captureEndSeconds > 1.0 }
        let staleA4 = afterOnset.compactMap { $0.reading }.filter {
            $0.freshness == .fresh && AudioTestHelpers.isCorrectRecordedPitch($0.frequency, reference: 440.0)
        }
        #expect(staleA4.isEmpty, "Must have zero continued fresh A4 readings after C4 is acquired")
    }

    @Test("Guitar transition E2 to A2 acquires String 5 within 200ms with zero stale E2 continuation")
    func testGuitarTransitionE2ToA2() {
        let sampleRate = 44100.0
        let e2Pluck = AudioTestHelpers.pluck(rate: sampleRate, frequency: 82.41, seconds: 0.8, snr: 30.0, initialSeed: 303)
        let a2Pluck = AudioTestHelpers.pluck(rate: sampleRate, frequency: 110.0, seconds: 0.8, snr: 30.0, initialSeed: 404)
        let guitarAudio = e2Pluck + a2Pluck

        let config = TunerConfig(instrument: .guitar, tuningId: "standard", mode: .auto)
        let (frames, _) = AudioTestHelpers.replayTrace(samples: guitarAudio, sampleRate: sampleRate, config: config)

        let e2Fresh = frames.filter { $0.captureEndSeconds < 0.8 }.compactMap { $0.reading }.filter { $0.freshness == .fresh }
        let e2Correct = e2Fresh.filter { AudioTestHelpers.isCorrectRecordedPitch($0.frequency, reference: 82.41) }
        #expect(!e2Correct.isEmpty, "E2 must be detected during first 0.8s")

        let a2Window = frames.filter { $0.captureEndSeconds >= 0.8 && $0.captureEndSeconds <= 1.0 }
        let a2Acquired = a2Window.compactMap { $0.reading }.filter {
            $0.freshness == .fresh && AudioTestHelpers.isCorrectRecordedPitch($0.frequency, reference: 110.0)
        }
        #expect(!a2Acquired.isEmpty, "A2 must be acquired within 200ms of onset (by t=1.0s)")

        let afterOnset = frames.filter { $0.captureEndSeconds > 1.0 }
        let staleE2 = afterOnset.compactMap { $0.reading }.filter {
            $0.freshness == .fresh && AudioTestHelpers.isCorrectRecordedPitch($0.frequency, reference: 82.41)
        }
        #expect(staleE2.isEmpty, "Must have zero continued fresh E2 readings after A2 is acquired")
    }

    @Test("Synthetic silence and seeded broadband noise produce zero accepted fresh tuner readings")
    func testSilenceAndBroadbandNoiseRejection() {
        let sampleRate = 44100.0
        let length = Int(sampleRate * 1.0)

        // 1. Digital silence
        let silence = [Float](repeating: 0.0, count: length)
        for mode in [TunerMode.auto, TunerMode.chromatic] {
            let config = TunerConfig(instrument: .ukulele, tuningId: "high-g", mode: mode)
            let (frames, _) = AudioTestHelpers.replayTrace(samples: silence, sampleRate: sampleRate, config: config)
            let fresh = frames.compactMap { $0.reading }.filter { $0.freshness == .fresh }
            #expect(fresh.isEmpty, "Digital silence in \(mode.rawValue) mode must produce 0 fresh readings")
        }

        // 2. Broadband noise without instrument (amplitude 0.02)
        var seed: UInt64 = 987654321
        var noise = [Float](repeating: 0.0, count: length)
        for i in 0..<length {
            seed = (seed &* 48271) % 2147483647
            let randNorm = (Float(seed) / 2147483647.0) * 2.0 - 1.0
            noise[i] = 0.02 * randNorm
        }

        for mode in [TunerMode.auto, TunerMode.chromatic] {
            let config = TunerConfig(instrument: .ukulele, tuningId: "high-g", mode: mode)
            let (frames, _) = AudioTestHelpers.replayTrace(samples: noise, sampleRate: sampleRate, config: config)
            let fresh = frames.compactMap { $0.reading }.filter { $0.freshness == .fresh }
            #expect(fresh.isEmpty, "Broadband noise in \(mode.rawValue) mode must produce 0 fresh readings, got \(fresh.count)")
        }
    }

    @Test("60 Hz electrical hum mixed with instrument tone never switches from instrument to hum")
    func testHumMixedWithInstrumentTone() {
        let sampleRate = 44100.0
        let instrumentAudio = AudioTestHelpers.pluck(rate: sampleRate, frequency: 440.0, seconds: 1.2, snr: 25.0, initialSeed: 555)

        // Add 60 Hz hum (amplitude 0.02)
        var mixed = instrumentAudio
        for i in 0..<mixed.count {
            let t = Double(i) / sampleRate
            let hum = 0.02 * Float(sin(2.0 * Double.pi * 60.0 * t))
            mixed[i] += hum
        }

        let config = TunerConfig(instrument: .ukulele, tuningId: "high-g", mode: .chromatic)
        let (frames, _) = AudioTestHelpers.replayTrace(samples: mixed, sampleRate: sampleRate, config: config)

        let freshReadings = frames.compactMap { $0.reading }.filter { $0.freshness == .fresh }
        let correctInstrument = freshReadings.filter { AudioTestHelpers.isCorrectRecordedPitch($0.frequency, reference: 440.0) }
        let humReadings = freshReadings.filter { AudioTestHelpers.isCorrectRecordedPitch($0.frequency, reference: 60.0) }

        #expect(!correctInstrument.isEmpty, "Tuner must detect the 440 Hz instrument note")
        #expect(humReadings.isEmpty, "Tuner must NEVER lock onto or switch to 60 Hz hum")
    }

    @Test("Deterministic clean tones achieve median error <= 2 cents and 95th-percentile error <= 5 cents")
    func testDeterministicCleanToneAccuracy() {
        let testTones: [(freq: Double, note: String, instrument: InstrumentCategory, tuning: String)] = [
            (440.0, "A4", .ukulele, "high-g"),
            (82.41, "E2", .guitar, "standard"),
            (261.63, "C4", .ukulele, "high-g")
        ]

        let sampleRate = 44100.0
        let duration = 1.0
        let length = Int(sampleRate * duration)

        for item in testTones {
            var sineAudio = [Float](repeating: 0, count: length)
            for i in 0..<length {
                let t = Double(i) / sampleRate
                sineAudio[i] = 0.1 * Float(sin(2.0 * Double.pi * item.freq * t))
            }

            let config = TunerConfig(instrument: item.instrument, tuningId: item.tuning, mode: .auto)
            let (frames, _) = AudioTestHelpers.replayTrace(samples: sineAudio, sampleRate: sampleRate, config: config)

            // Exclude initial 150 ms acquisition period
            let stableFrames = frames.filter { $0.captureEndSeconds > 0.15 }
            let fresh = stableFrames.compactMap { $0.reading }.filter { $0.freshness == .fresh }

            #expect(!fresh.isEmpty, "Must produce fresh readings for clean tone \(item.note)")

            let errors = fresh.map { abs(1200.0 * log2($0.frequency / item.freq)) }.sorted()
            guard !errors.isEmpty else { continue }

            let medianError = errors[errors.count / 2]
            let p95Index = min(errors.count - 1, Int(ceil(0.95 * Double(errors.count))) - 1)
            let p95Error = errors[p95Index]

            print("ACCURACY [\(item.note) \(item.freq)Hz]: Median Error = \(String(format: "%.2f", medianError)) cents, P95 Error = \(String(format: "%.2f", p95Error)) cents")

            #expect(medianError <= 2.0, "Median error for \(item.note) must be <= 2.0 cents, got \(medianError) cents")
            #expect(p95Error <= 5.0, "95th-percentile error for \(item.note) must be <= 5.0 cents, got \(p95Error) cents")
        }
    }
}

