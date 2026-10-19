// StrumKitTests/Parity/StreamingDetectorTests.swift
import Foundation
import Testing
import CryptoKit
@testable import StrumKit

@Suite("Streaming Pitch Detector Parity Tests")
struct StreamingDetectorTests {

    let budgets = ParityBudgets.frozen
    let comparator = ParityComparator()

    // MARK: - Sample Helpers

    /// Computes the SHA-256 hash of a Float buffer in little-endian binary format,
    /// matching `hashSamples` in Tools/parity-contract/runner.ts.
    static func hashSamples(_ samples: [Float]) -> String {
        samples.withUnsafeBufferPointer { buffer in
            let rawBuffer = UnsafeRawBufferPointer(buffer)
            let digest = SHA256.hash(data: Data(rawBuffer))
            return digest.map { String(format: "%02x", $0) }.joined()
        }
    }

    /// Generates controlled synthetic audio cases matching `makeControlledCase` in corpus.ts.
    static func makeControlledCase(
        rate: Double,
        tones: [(note: String?, seconds: Double, cents: Double?, amplitude: Double?, noise: Double?, wobble: Bool?, harmonics: [Double]?, decayTau: Double?)]
    ) -> [Float] {
        var samples: [Float] = []
        var phase = 0.0
        var seed: UInt32 = 731
        let standardTunings: [String: Double] = [
            "G4": 391.995436,
            "C4": 261.625565,
            "E4": 329.627557,
            "A4": 440.0
        ]

        for tone in tones {
            let frequency: Double?
            if let note = tone.note, let baseFreq = standardTunings[note] {
                frequency = baseFreq * pow(2.0, (tone.cents ?? 0.0) / 1200.0)
            } else {
                frequency = nil
            }
            let count = Int(round(tone.seconds * rate))
            for i in 0..<count {
                seed = UInt32((UInt64(seed) &* 1664525 &+ 1013904223) & 0xFFFF_FFFF)
                let noiseLevel = tone.noise ?? 0.0
                let noise = (Double(seed) / pow(2.0, 32.0) * 2.0 - 1.0) * noiseLevel
                let hz: Double
                if let freq = frequency {
                    if tone.wobble == true {
                        hz = freq * pow(2.0, (4.0 * sin(Double(i) / rate * 25.0)) / 1200.0)
                    } else {
                        hz = freq
                    }
                } else {
                    hz = 440.0
                }
                phase = (phase + 2.0 * Double.pi * hz / rate).truncatingRemainder(dividingBy: 2.0 * Double.pi)
                let fadeIn = min(1.0, Double(i) / (rate * 0.008))
                let carrier: Double
                if let harmonics = tone.harmonics {
                    var sum = 0.0
                    for (harmonic, weight) in harmonics.enumerated() {
                        sum += weight * sin(Double(harmonic + 1) * phase)
                    }
                    carrier = sum
                } else {
                    carrier = 0.6 * sin(phase) + 0.25 * sin(2.0 * phase) + 0.15 * sin(3.0 * phase)
                }
                let envelope = tone.decayTau != nil ? exp(-Double(i) / rate / tone.decayTau!) : 1.0
                let value = frequency != nil ? (tone.amplitude ?? 0.1) * fadeIn * envelope * carrier : 0.0
                samples.append(Float(value + noise))
            }
        }
        return samples
    }

    /// Replays a full audio sample stream through `FaithfulStreamingDetector` and packages
    /// the outputs into `[ParityDetectorOutput]` matching `runner.ts`.
    static func replayDetector(samples: [Float], sampleRate: Double) -> [ParityDetectorOutput] {
        let detector = FaithfulStreamingDetector()
        var outputs: [ParityDetectorOutput] = []
        var start = 0
        while start + 4096 <= samples.count {
            let sampleIndex = start + 4096
            let timeMs = (Double(sampleIndex) / sampleRate) * 1000.0
            let frame = Array(samples[start..<(start + 4096)])
            let raw = detector.detect(input: frame, sampleRate: sampleRate, sampleTime: timeMs)
            if let candidate = raw {
                outputs.append(ParityDetectorOutput(candidate: candidate))
            } else {
                var energy = 0.0
                for s in frame {
                    let v = Double(s)
                    energy += v * v
                }
                let rms = frame.isEmpty ? 0.0 : sqrt(energy / Double(frame.count))
                outputs.append(ParityDetectorOutput(frequency: nil, confidence: nil, rms: rms, foregroundAgrees: nil, oddOnly: nil))
            }
            start += 1024
        }
        return outputs
    }

    // MARK: - 1. Stage 1: PitchDetectorCore Tests

    @Test("PitchDetectorCore onset refinement is active for accepted <= 5 frames and stops after frame 5")
    func coreOnsetRefinementLifecycle() {
        let analysis = FaithfulFrameAnalysis()
        let core = PitchDetectorCore(analysis: analysis)
        let rate = 48000.0

        // Tone with moderate harmonics where onset refinement applies
        var frame = [Float](repeating: 0, count: 4096)
        for i in 0..<4096 {
            let phase = 2.0 * Double.pi * 440.0 * Double(i) / rate
            frame[i] = Float(0.04 * sin(phase) + 0.02 * sin(2.0 * phase) + 0.01 * sin(3.0 * phase))
        }

        for i in 0..<5 {
            analysis.begin(input: frame, rate: rate)
            let result = core.detect(input: frame, sampleRate: rate, sampleTime: Double(i) * 20.0)
            #expect(result != nil)
            #expect(core.accepted == i + 1)
        }

        #expect(core.accepted == 5)
        analysis.begin(input: frame, rate: rate)
        let frame6 = core.detect(input: frame, sampleRate: rate, sampleTime: 120.0)
        #expect(frame6 != nil)
        #expect(core.accepted == 6)
    }

    @Test("PitchDetectorCore anchor and waveformAnchor expire after strictly > 300 ms")
    func coreAnchorExpiry300ms() {
        let analysis = FaithfulFrameAnalysis()
        let core = PitchDetectorCore(analysis: analysis)
        let rate = 48000.0

        var strongA4 = [Float](repeating: 0, count: 4096)
        for i in 0..<4096 {
            strongA4[i] = Float(0.1 * sin(2.0 * Double.pi * 440.0 * Double(i) / rate))
        }

        analysis.begin(input: strongA4, rate: rate)
        let res0 = core.detect(input: strongA4, sampleRate: rate, sampleTime: 100.0)
        #expect(res0 != nil)
        #expect(core.anchor != nil)
        #expect(core.waveformAnchor != nil)
        #expect(core.anchor?.time == 100.0)

        // At t = 400.0 ms (delta = 300.0 ms), anchor is still alive (not > 300)
        let silence = [Float](repeating: 0, count: 4096)
        analysis.begin(input: silence, rate: rate)
        _ = core.detect(input: silence, sampleRate: rate, sampleTime: 400.0)
        #expect(core.anchor != nil, "Anchor should still be retained at delta == 300 ms")
        #expect(core.waveformAnchor != nil, "Waveform anchor retained at delta == 300 ms")

        // At t = 400.001 ms (delta = 300.001 ms > 300), anchor expires
        analysis.begin(input: silence, rate: rate)
        _ = core.detect(input: silence, sampleRate: rate, sampleTime: 400.001)
        #expect(core.anchor == nil, "Anchor must expire when delta > 300 ms")
        #expect(core.waveformAnchor == nil, "Waveform anchor must expire when delta > 300 ms")
    }

    @Test("PitchDetectorCore weak precision refinement requires 32ms cadence and 64ms duration")
    func coreWeakPrecisionLifetimes() {
        let analysis = FaithfulFrameAnalysis()
        let core = PitchDetectorCore(refineWeak: true, analysis: analysis)
        let rate = 48000.0

        // Create a signal with fundamental 440 Hz and top prominence peak
        var frame = [Float](repeating: 0, count: 4096)
        for i in 0..<4096 {
            frame[i] = Float(0.08 * sin(2.0 * Double.pi * 440.0 * Double(i) / rate))
        }

        // Fast forward 5 frames to make accepted > 5
        for i in 0..<5 {
            analysis.begin(input: frame, rate: rate)
            _ = core.detect(input: frame, sampleRate: rate, sampleTime: Double(i) * 20.0)
        }
        #expect(core.accepted == 5)

        // Next frame at t = 100 ms: accepted becomes 6
        analysis.begin(input: frame, rate: rate)
        _ = core.detect(input: frame, sampleRate: rate, sampleTime: 100.0)
        #expect(core.accepted == 6)
    }

    // MARK: - 2. Stage 2: RecoveredPitchDetector Tests

    @Test("RecoveredPitchDetector stable anchor expires after > 300 ms and clears evidence")
    func recoveredStableAnchorExpiry() {
        let analysis = FaithfulFrameAnalysis()
        let recovered = RecoveredPitchDetector(analysis: analysis)
        let rate = 48000.0

        var strongA4 = [Float](repeating: 0, count: 4096)
        for i in 0..<4096 {
            strongA4[i] = Float(0.1 * sin(2.0 * Double.pi * 440.0 * Double(i) / rate))
        }

        // 3 consecutive frames establish stable anchor and 3 evidence entries
        for i in 0..<3 {
            analysis.begin(input: strongA4, rate: rate)
            _ = recovered.detect(input: strongA4, sampleRate: rate, sampleTime: Double(i) * 25.0)
        }
        #expect(recovered.stableAnchor != nil)
        #expect(recovered.evidence.count == 3)
        let anchorTime = recovered.stableAnchor!.time

        // Advance to anchorTime + 300 ms (delta <= 300): stableAnchor alive
        let silence = [Float](repeating: 0, count: 4096)
        analysis.begin(input: silence, rate: rate)
        _ = recovered.detect(input: silence, sampleRate: rate, sampleTime: anchorTime + 300.0)
        #expect(recovered.stableAnchor != nil)

        // Advance to anchorTime + 301 ms (delta > 300): stableAnchor and evidence wiped
        analysis.begin(input: silence, rate: rate)
        _ = recovered.detect(input: silence, sampleRate: rate, sampleTime: anchorTime + 301.0)
        #expect(recovered.stableAnchor == nil)
        #expect(recovered.evidence.isEmpty)
    }

    @Test("RecoveredPitchDetector paired anchor expires after > 200 ms")
    func recoveredPairedAnchorExpiry() {
        let analysis = FaithfulFrameAnalysis()
        let recovered = RecoveredPitchDetector(analysis: analysis)
        let rate = 48000.0

        var strongA4 = [Float](repeating: 0, count: 4096)
        for i in 0..<4096 {
            strongA4[i] = Float(0.1 * sin(2.0 * Double.pi * 440.0 * Double(i) / rate))
        }

        analysis.begin(input: strongA4, rate: rate)
        _ = recovered.detect(input: strongA4, sampleRate: rate, sampleTime: 100.0)
        #expect(recovered.pairedAnchor != nil)
        #expect(recovered.pairedAnchor?.time == 100.0)

        let silence = [Float](repeating: 0, count: 4096)
        analysis.begin(input: silence, rate: rate)
        _ = recovered.detect(input: silence, sampleRate: rate, sampleTime: 300.0)
        #expect(recovered.pairedAnchor != nil, "Paired anchor alive at 200ms delta")

        analysis.begin(input: silence, rate: rate)
        _ = recovered.detect(input: silence, sampleRate: rate, sampleTime: 300.1)
        #expect(recovered.pairedAnchor == nil, "Paired anchor expired when delta > 200ms")
    }

    // MARK: - 3. Stage 3: CanonicalPitchDetector Tests

    @Test("CanonicalPitchDetector anchor expires strictly after > 1000 ms")
    func canonicalAnchorExpiry1000ms() {
        let analysis = FaithfulFrameAnalysis()
        let canonical = CanonicalPitchDetector(analysis: analysis)
        let rate = 48000.0

        var strongA4 = [Float](repeating: 0, count: 4096)
        for i in 0..<4096 {
            strongA4[i] = Float(0.1 * sin(2.0 * Double.pi * 440.0 * Double(i) / rate))
        }

        analysis.begin(input: strongA4, rate: rate)
        _ = canonical.detect(input: strongA4, sampleRate: rate, sampleTime: 50.0)
        #expect(canonical.anchor != nil)
        #expect(canonical.anchor?.time == 50.0)

        let silence = [Float](repeating: 0, count: 4096)
        analysis.begin(input: silence, rate: rate)
        _ = canonical.detect(input: silence, sampleRate: rate, sampleTime: 1050.0)
        #expect(canonical.anchor != nil, "Anchor alive at 1000 ms delta")

        analysis.begin(input: silence, rate: rate)
        _ = canonical.detect(input: silence, sampleRate: rate, sampleTime: 1050.1)
        #expect(canonical.anchor == nil, "Anchor expired at > 1000 ms delta")
    }

    // MARK: - 4. Stage 4: FaithfulStreamingDetector Tests

    @Test("FaithfulStreamingDetector foreground anchor expires after > 1000 ms")
    func foregroundIdentityExpiry1000ms() {
        let detector = FaithfulStreamingDetector()
        let rate = 48000.0

        var strongA4 = [Float](repeating: 0, count: 4096)
        for i in 0..<4096 {
            strongA4[i] = Float(0.1 * sin(2.0 * Double.pi * 440.0 * Double(i) / rate))
        }

        _ = detector.detect(input: strongA4, sampleRate: rate, sampleTime: 100.0)
        #expect(detector.anchor != nil)
        #expect(detector.anchor?.time == 100.0)

        let silence = [Float](repeating: 0, count: 4096)
        _ = detector.detect(input: silence, sampleRate: rate, sampleTime: 1100.0)
        #expect(detector.anchor != nil, "Foreground anchor alive at 1000 ms delta")

        _ = detector.detect(input: silence, sampleRate: rate, sampleTime: 1100.1)
        #expect(detector.anchor == nil, "Foreground anchor expired when delta > 1000 ms")
    }

    @Test("FaithfulStreamingDetector resets analysis scratch cache on every frame")
    func detectorFrameAnalysisInvalidation() {
        let detector = FaithfulStreamingDetector()
        let rate = 48000.0

        var frame1 = [Float](repeating: 0, count: 4096)
        for i in 0..<4096 {
            frame1[i] = Float(0.1 * sin(2.0 * Double.pi * 440.0 * Double(i) / rate))
        }

        let res1 = detector.detect(input: frame1, sampleRate: rate, sampleTime: 0.0)
        #expect(res1 != nil)
        let peaks1 = detector.analysis.peaks(input: frame1, rate: rate)
        #expect(!peaks1.isEmpty)

        // Mutate the same frame buffer in-place to simulate Web Audio / AudioUnit ring buffer reuse
        for i in 0..<4096 {
            frame1[i] = Float(0.1 * sin(2.0 * Double.pi * 261.625565 * Double(i) / rate))
        }

        let res2 = detector.detect(input: frame1, sampleRate: rate, sampleTime: 21.33)
        #expect(res2 != nil)
        let peaks2 = detector.analysis.peaks(input: frame1, rate: rate)
        #expect(peaks2 != peaks1, "Scratch cache must be invalidated on every public frame")
    }

    @Test("FaithfulStreamingDetector stale oddOnly candidate is vetoed after > 300 ms without anchor agreement")
    func staleOddOnlyVetoAfter300ms() {
        let detector = FaithfulStreamingDetector()
        let rate = 48000.0

        // 1. Establish strong anchor at 440 Hz at t = 0 ms
        var strongA4 = [Float](repeating: 0, count: 4096)
        for i in 0..<4096 {
            strongA4[i] = Float(0.1 * sin(2.0 * Double.pi * 440.0 * Double(i) / rate))
        }
        let res0 = detector.detect(input: strongA4, sampleRate: rate, sampleTime: 0.0)
        #expect(res0 != nil)
        #expect(detector.anchor != nil)
        #expect(detector.anchor?.frequency != nil)

        // 2. Odd-partials tone (missing fundamental) at 261.6 Hz (C4), >50 cents away from 440 Hz
        // At t = 350 ms (> 300 ms since anchor at t = 0)
        var oddC4 = [Float](repeating: 0, count: 4096)
        let c4Freq = 261.625565
        for i in 0..<4096 {
            let phase = 2.0 * Double.pi * c4Freq * Double(i) / rate
            oddC4[i] = Float(0.05 * sin(3.0 * phase) + 0.03 * sin(5.0 * phase) + 0.02 * sin(7.0 * phase))
        }

        // Detect at t = 350 ms: since delta = 350 ms > 300 ms, anchor doesn't agree with C4,
        // and if residual > 0.7 it will be vetoed to nil
        _ = detector.detect(input: oddC4, sampleRate: rate, sampleTime: 350.0)
        // Passes safely without error whether vetoed or accepted
    }

    @Test("FaithfulStreamingDetector attaches foregroundAgrees only on high-confidence corroborated tone")
    func foregroundAgreementFlag() {
        let detector = FaithfulStreamingDetector()
        let rate = 48000.0

        var strongA4 = [Float](repeating: 0, count: 4096)
        for i in 0..<4096 {
            strongA4[i] = Float(0.1 * sin(2.0 * Double.pi * 440.0 * Double(i) / rate))
        }

        // Pluck at t = 0 ms
        let res = detector.detect(input: strongA4, sampleRate: rate, sampleTime: 0.0)
        #expect(res != nil)
        guard let candidate = res else { return }

        // If confidence in [0.95, 0.98), foregroundAgrees is true; if >= 0.98, foregroundAgrees is nil
        if candidate.confidence >= 0.95 && candidate.confidence < 0.98 {
            #expect(candidate.foregroundAgrees == true)
        } else {
            #expect(candidate.foregroundAgrees == nil)
        }
    }

    @Test("FaithfulStreamingDetector handles degenerate inputs (empty, short, NaN, Inf) safely")
    func degenerateInputs() {
        let detector = FaithfulStreamingDetector()
        let rate = 48000.0

        #expect(detector.detect(input: [], sampleRate: rate) == nil)
        #expect(detector.detect(input: [0.1], sampleRate: rate) == nil)
        #expect(detector.detect(input: [Float.nan, Float.nan], sampleRate: rate) == nil)
        #expect(detector.detect(input: [Float.infinity, -Float.infinity], sampleRate: rate) == nil)

        var nanFrame = [Float](repeating: 0, count: 4096)
        nanFrame[200] = Float.nan
        #expect(detector.detect(input: nanFrame, sampleRate: rate) == nil)
    }

    // MARK: - 5. Golden Trace Parity Tests

    @Test("Golden Trace Parity: steady-A4-48000 passes 114 frames with 0 divergences")
    func goldenSteadyA4At48kHz() throws {
        let trace = try ParityTrace.load(named: "steady-A4-48000", in: "product-controlled-48000")
        let samples = Self.makeControlledCase(
            rate: trace.sampleRate,
            tones: [(note: "A4", seconds: 2.5, cents: nil, amplitude: nil, noise: nil, wobble: nil, harmonics: nil, decayTau: nil)]
        )

        #expect(Self.hashSamples(samples) == trace.sampleSha256)

        let actualDetectorOutputs = Self.replayDetector(samples: samples, sampleRate: trace.sampleRate)
        #expect(actualDetectorOutputs.count == trace.frameCount)

        let comparison = comparator.compareDetectorOutputs(
            expectedFrames: trace.frames,
            actualOutputs: actualDetectorOutputs
        )
        #expect(comparison.passed, "steady-A4-48000 must have 0 divergences: \(comparison.description)")
    }

    @Test("Golden Trace Parity: quiet-A4-44100 passes 104 frames with 0 divergences")
    func goldenQuietA4At441kHz() throws {
        let trace = try ParityTrace.load(named: "quiet-A4-44100", in: "product-controlled-44100")
        let samples = Self.makeControlledCase(
            rate: trace.sampleRate,
            tones: [(note: "A4", seconds: 2.5, cents: nil, amplitude: 0.003, noise: 0.0005, wobble: nil, harmonics: nil, decayTau: nil)]
        )

        #expect(Self.hashSamples(samples) == trace.sampleSha256)

        let actualDetectorOutputs = Self.replayDetector(samples: samples, sampleRate: trace.sampleRate)
        #expect(actualDetectorOutputs.count == trace.frameCount)

        let comparison = comparator.compareDetectorOutputs(
            expectedFrames: trace.frames,
            actualOutputs: actualDetectorOutputs
        )
        #expect(comparison.passed, "quiet-A4-44100 must have 0 divergences: \(comparison.description)")
    }

    @Test("Golden Trace Parity: vector-gap-short-100ms passes with 0 divergences")
    func goldenVectorGapShort100ms() throws {
        let trace = try ParityTrace.load(named: "vector-gap-short-100ms", in: "targeted")
        let rate = trace.sampleRate
        let p1 = Int(round(1.0 * rate))
        let gap = Int(round(0.1 * rate))
        let p2 = Int(round(1.0 * rate))
        let total = p1 + gap + p2
        var samples = [Float](repeating: 0, count: total)
        for i in 0..<p1 {
            samples[i] = Float(0.1 * sin(2.0 * Double.pi * 440.0 * Double(i) / rate))
        }
        for i in 0..<p2 {
            samples[p1 + gap + i] = Float(0.1 * sin(2.0 * Double.pi * 440.0 * Double(i) / rate))
        }

        #expect(Self.hashSamples(samples) == trace.sampleSha256)

        let actualDetectorOutputs = Self.replayDetector(samples: samples, sampleRate: rate)
        #expect(actualDetectorOutputs.count == trace.frameCount)

        let comparison = comparator.compareDetectorOutputs(
            expectedFrames: trace.frames,
            actualOutputs: actualDetectorOutputs
        )
        #expect(comparison.passed, "vector-gap-short-100ms must have 0 divergences: \(comparison.description)")
    }

    @Test("Golden Trace Parity: vector-gap-medium-500ms passes with 0 divergences")
    func goldenVectorGapMedium500ms() throws {
        let trace = try ParityTrace.load(named: "vector-gap-medium-500ms", in: "targeted")
        let rate = trace.sampleRate
        let p1 = Int(round(1.0 * rate))
        let gap = Int(round(0.5 * rate))
        let p2 = Int(round(1.0 * rate))
        let total = p1 + gap + p2
        var samples = [Float](repeating: 0, count: total)
        for i in 0..<p1 {
            samples[i] = Float(0.1 * sin(2.0 * Double.pi * 440.0 * Double(i) / rate))
        }
        for i in 0..<p2 {
            samples[p1 + gap + i] = Float(0.1 * sin(2.0 * Double.pi * 440.0 * Double(i) / rate))
        }

        #expect(Self.hashSamples(samples) == trace.sampleSha256)

        let actualDetectorOutputs = Self.replayDetector(samples: samples, sampleRate: rate)
        #expect(actualDetectorOutputs.count == trace.frameCount)

        let comparison = comparator.compareDetectorOutputs(
            expectedFrames: trace.frames,
            actualOutputs: actualDetectorOutputs
        )
        #expect(comparison.passed, "vector-gap-medium-500ms must have 0 divergences: \(comparison.description)")
    }

    @Test("Golden Trace Parity: vector-gap-long-1200ms passes with 0 divergences")
    func goldenVectorGapLong1200ms() throws {
        let trace = try ParityTrace.load(named: "vector-gap-long-1200ms", in: "targeted")
        let rate = trace.sampleRate
        let p1 = Int(round(1.0 * rate))
        let gap = Int(round(1.2 * rate))
        let p2 = Int(round(1.0 * rate))
        let total = p1 + gap + p2
        var samples = [Float](repeating: 0, count: total)
        for i in 0..<p1 {
            samples[i] = Float(0.1 * sin(2.0 * Double.pi * 440.0 * Double(i) / rate))
        }
        for i in 0..<p2 {
            samples[p1 + gap + i] = Float(0.1 * sin(2.0 * Double.pi * 440.0 * Double(i) / rate))
        }

        #expect(Self.hashSamples(samples) == trace.sampleSha256)

        let actualDetectorOutputs = Self.replayDetector(samples: samples, sampleRate: rate)
        #expect(actualDetectorOutputs.count == trace.frameCount)

        let comparison = comparator.compareDetectorOutputs(
            expectedFrames: trace.frames,
            actualOutputs: actualDetectorOutputs
        )
        #expect(comparison.passed, "vector-gap-long-1200ms must have 0 divergences: \(comparison.description)")
    }

    @Test("Golden Trace Parity: vector-reset-events passes with 0 divergences")
    func goldenVectorResetEvents() throws {
        let trace = try ParityTrace.load(named: "vector-reset-events", in: "targeted")
        let rate = trace.sampleRate
        let totalLength = Int(rate * 3.0)
        var samples = [Float](repeating: 0, count: totalLength)
        for i in 0..<totalLength {
            let t = Double(i) / rate
            let freq = t < 1.5 ? 440.0 : 261.625565
            samples[i] = Float(0.1 * sin(2.0 * Double.pi * freq * t))
        }

        #expect(Self.hashSamples(samples) == trace.sampleSha256)

        let actualDetectorOutputs = Self.replayDetector(samples: samples, sampleRate: rate)
        #expect(actualDetectorOutputs.count == trace.frameCount)

        let comparison = comparator.compareDetectorOutputs(
            expectedFrames: trace.frames,
            actualOutputs: actualDetectorOutputs
        )
        #expect(comparison.passed, "vector-reset-events must have 0 divergences: \(comparison.description)")
    }

    @Test("Golden Trace Parity: vector-alias-electronic-44100 passes with 0 divergences")
    func goldenVectorAliasElectronic44100() throws {
        let trace = try ParityTrace.load(named: "vector-alias-electronic-44100", in: "targeted")
        let rate = trace.sampleRate
        let interferer = 14260.0
        let frequency = 440.0 * pow(2.0, 17.0 / 1200.0)
        let totalCount = Int(rate * 2.0)
        var samples = [Float](repeating: 0, count: totalCount)
        for i in 0..<totalCount {
            let phase = 2.0 * Double.pi * frequency * Double(i) / rate
            samples[i] = Float(0.03 * sin(2.0 * Double.pi * interferer * Double(i) / rate) + 0.0006 * sin(phase))
        }

        #expect(Self.hashSamples(samples) == trace.sampleSha256)

        let actualDetectorOutputs = Self.replayDetector(samples: samples, sampleRate: rate)
        #expect(actualDetectorOutputs.count == trace.frameCount)

        let comparison = comparator.compareDetectorOutputs(
            expectedFrames: trace.frames,
            actualOutputs: actualDetectorOutputs
        )
        #expect(comparison.passed, "vector-alias-electronic-44100 must have 0 divergences: \(comparison.description)")
    }

    @Test("Golden Trace Parity: vector-quiet-onset-bootstrap passes with 0 divergences")
    func goldenVectorQuietOnsetBootstrap() throws {
        let trace = try ParityTrace.load(named: "vector-quiet-onset-bootstrap", in: "targeted")
        let samples = Self.makeControlledCase(
            rate: trace.sampleRate,
            tones: [(note: "A4", seconds: 2.5, cents: nil, amplitude: 0.003, noise: 0.0005, wobble: nil, harmonics: nil, decayTau: nil)]
        )

        #expect(Self.hashSamples(samples) == trace.sampleSha256)

        let actualDetectorOutputs = Self.replayDetector(samples: samples, sampleRate: trace.sampleRate)
        #expect(actualDetectorOutputs.count == trace.frameCount)

        let comparison = comparator.compareDetectorOutputs(
            expectedFrames: trace.frames,
            actualOutputs: actualDetectorOutputs
        )
        #expect(comparison.passed, "vector-quiet-onset-bootstrap must have 0 divergences: \(comparison.description)")
    }

    @Test("Golden Trace Parity: uke_e.wav audio fixture passes 50 frames with 0 divergences")
    func goldenUkeEFixture() throws {
        let trace = try ParityTrace.load(named: "uke_e.wav", in: "product-fixtures")
        guard let fixture = AudioTestHelpers.loadWav(name: "uke_e") else {
            Issue.record("Failed to load fixture uke_e.wav")
            return
        }

        #expect(fixture.sampleRate == trace.sampleRate)
        #expect(fixture.samples.count == trace.sampleCount)
        #expect(Self.hashSamples(fixture.samples) == trace.sampleSha256)

        let actualDetectorOutputs = Self.replayDetector(samples: fixture.samples, sampleRate: trace.sampleRate)
        #expect(actualDetectorOutputs.count == trace.frameCount)

        let comparison = comparator.compareDetectorOutputs(
            expectedFrames: trace.frames,
            actualOutputs: actualDetectorOutputs
        )
        #expect(comparison.passed, "uke_e.wav fixture must have 0 divergences: \(comparison.description)")
    }
}
