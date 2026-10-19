// StrumKitTests/Parity/StatelessDetectorTests.swift
import Foundation
import Testing
@testable import StrumKit

@Suite("Stateless Pitch Detector Parity Tests")
struct StatelessDetectorTests {

    let budgets = ParityBudgets.frozen

    // MARK: - 1. Pure Tones (A4, C4, E4, G4 at 44.1k, 48k, 96k)

    @Test("detectPitch on pure A4 440 Hz at 48 kHz matches exact reference candidate")
    func pureA4At48kHz() {
        let rate = 48000.0
        var input = [Float](repeating: 0, count: 4096)
        for i in 0..<4096 {
            input[i] = Float(0.1 * sin(2.0 * Double.pi * 440.0 * Double(i) / rate))
        }

        let candidate = FaithfulStatelessDetector.detectPitch(input: input, sampleRate: rate)
        #expect(candidate != nil)
        guard let candidate = candidate else { return }

        // Expected reference values from Tools/parity-contract/reference-source
        let expectedFrequency = 440.00009547429073
        let expectedConfidence = 0.9980584325946034
        let expectedRms = 0.0705168182917098

        #expect(abs(candidate.frequency - expectedFrequency) < budgets.frequencyAbsoluteHz)
        #expect(abs(candidate.confidence - expectedConfidence) < budgets.confidenceAbsolute)
        #expect(abs(candidate.rms - expectedRms) < (budgets.rmsAbsolute + budgets.rmsRelative * expectedRms))
        // YIN candidate must have oddOnly == nil, never false
        #expect(candidate.oddOnly == nil)
        #expect(candidate.foregroundAgrees == nil)
    }

    @Test("detectPitch on standard ukulele strings (G4, C4, E4, A4) at 44.1 kHz")
    func ukuleleStringsAt441kHz() {
        let rate = 44100.0
        let testStrings: [(note: String, freq: Double)] = [
            ("G4", 391.995436),
            ("C4", 261.625565),
            ("E4", 329.627557),
            ("A4", 440.0)
        ]

        for (note, nominalHz) in testStrings {
            var input = [Float](repeating: 0, count: 4096)
            for i in 0..<4096 {
                input[i] = Float(0.1 * sin(2.0 * Double.pi * nominalHz * Double(i) / rate))
            }

            let candidate = FaithfulStatelessDetector.detectPitch(input: input, sampleRate: rate)
            #expect(candidate != nil, "Expected pitch detection for \(note)")
            guard let candidate = candidate else { continue }

            #expect(abs(candidate.frequency - nominalHz) < 0.05, "\(note) frequency within 0.05 Hz of nominal")
            #expect(candidate.confidence > 0.99)
            #expect(candidate.oddOnly == nil)
        }
    }

    @Test("detectPitch on pure A4 at 96 kHz decimation geometry")
    func pureA4At96kHz() {
        let rate = 96000.0
        var input = [Float](repeating: 0, count: 4096)
        for i in 0..<4096 {
            input[i] = Float(0.1 * sin(2.0 * Double.pi * 440.0 * Double(i) / rate))
        }

        let candidate = FaithfulStatelessDetector.detectPitch(input: input, sampleRate: rate)
        #expect(candidate != nil)
        guard let candidate = candidate else { return }

        #expect(abs(candidate.frequency - 440.0) < 0.01)
        #expect(candidate.confidence > 0.99)
        #expect(candidate.oddOnly == nil)
    }

    // MARK: - 2. Spectral Pitch Detection and Harmonics

    @Test("detectSpectralPitch on harmonic series (A4 + 2nd, 3rd, 4th partials) matches reference")
    func harmonicA4SpectralPitch() {
        let rate = 48000.0
        var input = [Float](repeating: 0, count: 4096)
        for i in 0..<4096 {
            let phase = 2.0 * Double.pi * 440.0 * Double(i) / rate
            input[i] = Float(0.05 * sin(phase) + 0.03 * sin(2.0 * phase) + 0.02 * sin(3.0 * phase) + 0.01 * sin(4.0 * phase))
        }

        let spectral = FaithfulStatelessDetector.detectSpectralPitch(input: input, sampleRate: rate)
        #expect(spectral != nil)
        guard let spectral = spectral else { return }

        let expectedFrequency = 440.0072675037559
        let expectedConfidence = 0.88
        #expect(abs(spectral.frequency - expectedFrequency) < 1e-4)
        #expect(abs(spectral.confidence - expectedConfidence) < 1e-6)
        #expect(spectral.oddOnly == false)

        let candidate = spectral.asCandidate(rms: 0.043865)
        #expect(candidate.frequency == spectral.frequency)
        #expect(candidate.confidence == spectral.confidence)
        #expect(candidate.rms == 0.043865)
        #expect(candidate.oddOnly == false)
    }

    @Test("detectSpectralPitch on single sine returns nil due to insufficient partials (<3)")
    func singleSineSpectralPitchReturnsNil() {
        let rate = 48000.0
        var input = [Float](repeating: 0, count: 4096)
        for i in 0..<4096 {
            input[i] = Float(0.1 * sin(2.0 * Double.pi * 440.0 * Double(i) / rate))
        }

        let spectral = FaithfulStatelessDetector.detectSpectralPitch(input: input, sampleRate: rate)
        #expect(spectral == nil)
    }

    // MARK: - 3. Silence, Sub-threshold Noise, and RMS Threshold

    @Test("detectPitch on all-zeros silence returns nil")
    func allZerosSilenceReturnsNil() {
        let input = [Float](repeating: 0, count: 4096)
        let candidate = FaithfulStatelessDetector.detectPitch(input: input, sampleRate: 48000.0)
        #expect(candidate == nil)
    }

    @Test("detectPitch on sub-threshold noise (< 0.000015 RMS) returns nil")
    func subthresholdNoiseReturnsNil() {
        let rate = 48000.0
        var seed: UInt64 = 42
        var input = [Float](repeating: 0, count: 4096)
        for i in 0..<4096 {
            seed = (seed &* 1664525 &+ 1013904223) & 0xFFFFFFFF
            let uniform = Double(seed) / Double(UInt32.max) * 2.0 - 1.0
            input[i] = Float(0.000010 * uniform) // RMS ~ 0.0000057 < 0.000015
        }

        let candidate = FaithfulStatelessDetector.detectPitch(input: input, sampleRate: rate)
        #expect(candidate == nil)
    }

    @Test("detectPitch threshold-adjacent: 0.0000149 RMS returns nil, 0.0000151 RMS returns candidate")
    func thresholdAdjacentRMS() {
        let rate = 48000.0
        let aBelow = Float(0.0000149 * sqrt(2.0))
        let aAbove = Float(0.0000151 * sqrt(2.0))

        var bufBelow = [Float](repeating: 0, count: 4096)
        var bufAbove = [Float](repeating: 0, count: 4096)
        for i in 0..<4096 {
            let phase = 2.0 * Double.pi * 440.0 * Double(i) / rate
            bufBelow[i] = aBelow * Float(sin(phase))
            bufAbove[i] = aAbove * Float(sin(phase))
        }

        let below = FaithfulStatelessDetector.detectPitch(input: bufBelow, sampleRate: rate)
        #expect(below == nil)

        let above = FaithfulStatelessDetector.detectPitch(input: bufAbove, sampleRate: rate)
        #expect(above != nil)
        if let above = above {
            let expectedFreq = 440.0000954608171
            let expectedConf = 0.9980584326041629
            let expectedRms = 0.000015058601875464
            #expect(abs(above.frequency - expectedFreq) < budgets.frequencyAbsoluteHz)
            #expect(abs(above.confidence - expectedConf) < budgets.confidenceAbsolute)
            #expect(abs(above.rms - expectedRms) < (budgets.rmsAbsolute + budgets.rmsRelative * expectedRms))
            #expect(above.oddOnly == nil)
        }
    }

    // MARK: - 4. Missing Fundamental and Odd-Partials Series (oddOnly == true)

    @Test("detectPitch on odd-partials series (missing fundamental) produces oddOnly == true")
    func oddPartialsSeriesProducesOddOnlyTrue() {
        let rate = 48000.0
        let fund = 261.625565 // C4
        var input = [Float](repeating: 0, count: 4096)
        for i in 0..<4096 {
            let phase = 2.0 * Double.pi * fund * Double(i) / rate
            // 3rd, 5th, 7th odd harmonics, no low partials (h <= 2 absent)
            input[i] = Float(0.05 * sin(3.0 * phase) + 0.03 * sin(5.0 * phase) + 0.02 * sin(7.0 * phase))
        }

        let candidate = FaithfulStatelessDetector.detectPitch(input: input, sampleRate: rate)
        #expect(candidate != nil)
        guard let candidate = candidate else { return }

        let expectedFrequency = 261.62575707450856
        let expectedConfidence = 0.8600000000000001
        let expectedRms = 0.04300574155192331

        #expect(abs(candidate.frequency - expectedFrequency) < 1e-4)
        #expect(abs(candidate.confidence - expectedConfidence) < budgets.confidenceAbsolute)
        #expect(abs(candidate.rms - expectedRms) < (budgets.rmsAbsolute + budgets.rmsRelative * expectedRms))
        // Must be exactly true, verifying the odd-only recovery path
        #expect(candidate.oddOnly == true)
    }

    @Test("oddOnly optional presence semantics: true vs nil, never false in YIN")
    func oddOnlyOptionalPresenceSemantics() {
        let rate = 48000.0

        // 1. Pure YIN tone: oddOnly must be nil (not false)
        var pureSine = [Float](repeating: 0, count: 4096)
        for i in 0..<4096 {
            pureSine[i] = Float(0.1 * sin(2.0 * Double.pi * 440.0 * Double(i) / rate))
        }
        let yinCandidate = FaithfulStatelessDetector.detectPitch(input: pureSine, sampleRate: rate)
        #expect(yinCandidate?.oddOnly == nil)

        // 2. Odd-partials tone: oddOnly must be .some(true)
        let fund = 261.625565 // C4
        var oddSine = [Float](repeating: 0, count: 4096)
        for i in 0..<4096 {
            let phase = 2.0 * Double.pi * fund * Double(i) / rate
            oddSine[i] = Float(0.05 * sin(3.0 * phase) + 0.03 * sin(5.0 * phase) + 0.02 * sin(7.0 * phase))
        }
        let oddCandidate = FaithfulStatelessDetector.detectPitch(input: oddSine, sampleRate: rate)
        #expect(oddCandidate?.oddOnly == true)

        // 3. ParityDetectorOutput mapping preserves nil and true
        if let yin = yinCandidate {
            let out = ParityDetectorOutput(candidate: yin)
            #expect(out.oddOnly == nil)
        }
        if let odd = oddCandidate {
            let out = ParityDetectorOutput(candidate: odd)
            #expect(out.oddOnly == true)
        }
    }

    // MARK: - 5. Out-of-Band Rejection and Anti-Aliasing Branch

    @Test("detectPitch rejects out-of-band 5 kHz tone alone")
    func outOfBand5kHzToneRejected() {
        let rate = 48000.0
        var input = [Float](repeating: 0, count: 4096)
        for i in 0..<4096 {
            input[i] = Float(0.1 * sin(2.0 * Double.pi * 5000.0 * Double(i) / rate))
        }

        let candidate = FaithfulStatelessDetector.detectPitch(input: input, sampleRate: rate)
        #expect(candidate == nil)
    }

    @Test("detectPitch anti-aliasing branch recovers quiet tone in presence of loud out-of-band interferer")
    func antiAliasingBranchRecoversQuietTone() {
        let rate = 48000.0
        let interferer = 11560.0
        let targetFreq = 440.0 * pow(2.0, 17.0 / 1200.0) // 444.341 Hz (A4 +17c)

        var input = [Float](repeating: 0, count: 4096)
        for i in 0..<4096 {
            let t = Double(i) / rate
            let interfererSample = 0.03 * sin(2.0 * Double.pi * interferer * t)
            let toneSample = 0.0006 * sin(2.0 * Double.pi * targetFreq * t)
            input[i] = Float(interfererSample + toneSample)
        }

        let candidate = FaithfulStatelessDetector.detectPitch(input: input, sampleRate: rate)
        #expect(candidate != nil)
        guard let candidate = candidate else { return }

        // Matches reference trace vector-alias-electronic-48000 frame 0
        let expectedFreq = 444.34131734513704
        let expectedConf = 0.9999988529152056
        let expectedRms = 0.0004241660813531007

        #expect(abs(candidate.frequency - expectedFreq) < budgets.frequencyAbsoluteHz)
        #expect(abs(candidate.confidence - expectedConf) < budgets.confidenceAbsolute)
        #expect(abs(candidate.rms - expectedRms) < (budgets.rmsAbsolute + budgets.rmsRelative * expectedRms))
    }

    // MARK: - 6. Noisy, Quiet, Clipped, and Degenerate Inputs

    @Test("detectPitch on quiet A4 with low SNR recovers pitch")
    func quietA4Detection() {
        let rate = 48000.0
        var seed: UInt64 = 731
        var input = [Float](repeating: 0, count: 4096)
        for i in 0..<4096 {
            seed = (seed &* 1664525 &+ 1013904223) & 0xFFFFFFFF
            let noise = (Double(seed) / Double(UInt32.max) * 2.0 - 1.0) * 0.0005
            let tone = 0.003 * sin(2.0 * Double.pi * 440.0 * Double(i) / rate)
            input[i] = Float(tone + noise)
        }

        let candidate = FaithfulStatelessDetector.detectPitch(input: input, sampleRate: rate)
        #expect(candidate != nil)
        if let candidate = candidate {
            #expect(abs(candidate.frequency - 440.0) < 0.2)
            #expect(candidate.confidence > 0.95)
        }
    }

    @Test("detectPitch on clipped 440 Hz waveform recovers valid fundamental")
    func clippedWaveformDetection() {
        let rate = 48000.0
        var input = [Float](repeating: 0, count: 4096)
        for i in 0..<4096 {
            let raw = 0.8 * sin(2.0 * Double.pi * 440.0 * Double(i) / rate)
            input[i] = Float(max(-0.25, min(0.25, raw))) // Severe clipping
        }

        let candidate = FaithfulStatelessDetector.detectPitch(input: input, sampleRate: rate)
        #expect(candidate != nil)
        if let candidate = candidate {
            #expect(abs(candidate.frequency - 440.0) < 0.05)
            #expect(candidate.confidence > 0.98)
        }
    }

    @Test("detectPitch on DC-offset A4 removes mean and detects accurate frequency")
    func dcOffsetRemoval() {
        let rate = 48000.0
        var input = [Float](repeating: 0, count: 4096)
        for i in 0..<4096 {
            input[i] = Float(0.4 + 0.1 * sin(2.0 * Double.pi * 440.0 * Double(i) / rate))
        }

        let candidate = FaithfulStatelessDetector.detectPitch(input: input, sampleRate: rate)
        #expect(candidate != nil)
        if let candidate = candidate {
            #expect(abs(candidate.frequency - 440.0) < 0.01)
            #expect(candidate.confidence > 0.99)
        }
    }

    @Test("detectPitch on degenerate inputs (empty, short, NaN, Inf) returns nil safely")
    func degenerateInputsSafeHandling() {
        let rate = 48000.0

        // Empty buffer
        #expect(FaithfulStatelessDetector.detectPitch(input: [], sampleRate: rate) == nil)

        // Single sample
        #expect(FaithfulStatelessDetector.detectPitch(input: [0.5], sampleRate: rate) == nil)

        // Short buffer (64 samples)
        let shortBuf = [Float](repeating: 0.1, count: 64)
        #expect(FaithfulStatelessDetector.detectPitch(input: shortBuf, sampleRate: rate) == nil)

        // Buffer of NaNs
        let nanBuf = [Float](repeating: Float.nan, count: 4096)
        #expect(FaithfulStatelessDetector.detectPitch(input: nanBuf, sampleRate: rate) == nil)

        // Buffer containing Infinity
        var infBuf = [Float](repeating: 0.1, count: 4096)
        infBuf[100] = Float.infinity
        #expect(FaithfulStatelessDetector.detectPitch(input: infBuf, sampleRate: rate) == nil)
    }

    // MARK: - 7. FrameAnalysis Scratch Isolation and Lazy Caching

    @Test("FaithfulFrameAnalysis lazily caches and resets per-stream scratch across frames")
    func frameAnalysisCachingAndReset() {
        let rate = 48000.0
        let analysis = FaithfulFrameAnalysis()

        var frame1 = [Float](repeating: 0, count: 4096)
        for i in 0..<4096 {
            frame1[i] = Float(0.1 * sin(2.0 * Double.pi * 440.0 * Double(i) / rate))
        }

        // 1. Begin frame 1
        analysis.begin(input: frame1, rate: rate)

        // First access computes and caches
        let peaks1 = analysis.peaks(input: frame1, rate: rate)
        #expect(!peaks1.isEmpty)

        // Second access reuses cache (identical pointer/count)
        let peaks1Again = analysis.peaks(input: frame1, rate: rate)
        #expect(peaks1 == peaks1Again)

        let filtered1 = analysis.filtered(input: frame1, rate: rate)
        #expect(filtered1.count == 4096)

        let spectral1 = analysis.spectral(input: frame1, rate: rate)
        #expect(spectral1 == nil) // single sine has <3 partials

        // 2. Begin frame 2 with new contents -> cache invalidated
        var frame2 = [Float](repeating: 0, count: 4096)
        for i in 0..<4096 {
            let phase = 2.0 * Double.pi * 261.625565 * Double(i) / rate
            frame2[i] = Float(0.05 * sin(phase) + 0.03 * sin(2.0 * phase) + 0.02 * sin(3.0 * phase))
        }

        analysis.begin(input: frame2, rate: rate)
        let peaks2 = analysis.peaks(input: frame2, rate: rate)
        #expect(peaks2 != peaks1)

        let spectral2 = analysis.spectral(input: frame2, rate: rate)
        #expect(spectral2 != nil)
        #expect(abs(spectral2!.frequency - 261.625) < 0.1)

        // 3. Separate buffer (e.g. anti-aliased transform) bypasses analysis caches
        let separateBuf = [Float](repeating: 0.05, count: 4096)
        let filteredBypass = analysis.filtered(input: separateBuf, rate: rate)
        #expect(filteredBypass.count == 4096)
    }

    // MARK: - 8. Onset Refinement and Filtered Period Residual

    @Test("refineOnsetPitch refines weak onset [0.75, 0.98) with agreeing spectral candidate")
    func refineOnsetPitchWeakOnsetRefinement() {
        let rate = 48000.0
        var input = [Float](repeating: 0, count: 4096)
        for i in 0..<4096 {
            let phase = 2.0 * Double.pi * 440.0 * Double(i) / rate
            input[i] = Float(0.05 * sin(phase) + 0.03 * sin(2.0 * phase) + 0.02 * sin(3.0 * phase) + 0.01 * sin(4.0 * phase))
        }

        // Candidate with confidence 0.85 (in range [0.75, 0.98)) and frequency 442.0 Hz (within 50 cents of 440 Hz)
        let weakCandidate = FaithfulPitchCandidate(frequency: 442.0, confidence: 0.85, rms: 0.04)
        let refined = FaithfulStatelessDetector.refineOnsetPitch(input: input, sampleRate: rate, pitch: weakCandidate)
        #expect(refined != nil)
        #expect(refined!.frequency != 442.0)
        #expect(abs(refined!.frequency - 440.0) < 0.02)
        #expect(refined!.confidence == 0.85) // Confidence is preserved, not boosted
    }

    @Test("refineOnsetPitch leaves high confidence (>= 0.98) or weak (< 0.75) candidates untouched")
    func refineOnsetPitchLeavesOtherConfidencesUntouched() {
        let rate = 48000.0
        let input = [Float](repeating: 0.1, count: 4096)

        // Confidence 0.99 (>= 0.98)
        let highConf = FaithfulPitchCandidate(frequency: 442.0, confidence: 0.99, rms: 0.04)
        let resHigh = FaithfulStatelessDetector.refineOnsetPitch(input: input, sampleRate: rate, pitch: highConf)
        #expect(resHigh?.frequency == 442.0)

        // Confidence 0.70 (< 0.75)
        let lowConf = FaithfulPitchCandidate(frequency: 442.0, confidence: 0.70, rms: 0.04)
        let resLow = FaithfulStatelessDetector.refineOnsetPitch(input: input, sampleRate: rate, pitch: lowConf)
        #expect(resLow?.frequency == 442.0)
    }

    @Test("filteredPeriodResidual computes normalized residual on filtered signal")
    func filteredPeriodResidualComputation() {
        let rate = 48000.0
        var input = [Float](repeating: 0, count: 4096)
        for i in 0..<4096 {
            input[i] = Float(0.1 * sin(2.0 * Double.pi * 440.0 * Double(i) / rate))
        }

        let inTuneResidual = FaithfulStatelessDetector.filteredPeriodResidual(input: input, sampleRate: rate, frequency: 440.0)
        #expect(inTuneResidual < 1e-6)

        let slightOffTuneResidual = FaithfulStatelessDetector.filteredPeriodResidual(input: input, sampleRate: rate, frequency: 460.0)
        #expect(abs(slightOffTuneResidual - 0.036809) < 1e-4)

        let offTuneResidual = FaithfulStatelessDetector.filteredPeriodResidual(input: input, sampleRate: rate, frequency: 300.0)
        #expect(offTuneResidual > 0.5)
    }

    // MARK: - 9. Verification Against Golden Traces

    @Test("detectPitch reproduces exact golden trace detector frames across multiple test vectors")
    func goldenTraceDetectorFramesVerification() throws {
        // Test targeted golden traces
        let traceNames: [(name: String, category: String)] = [
            ("vector-rate-48000-A4", "targeted"),
            ("vector-silence-zeros-48000", "targeted"),
            ("vector-alias-electronic-48000", "targeted")
        ]

        for (name, category) in traceNames {
            let trace = try ParityTrace.load(named: name, in: category)
            #expect(!trace.frames.isEmpty)

            let sampleRate = trace.sampleRate
            let firstFrame = trace.frames[0]
            let expectedDetector = firstFrame.detector

            if name == "vector-rate-48000-A4" {
                var input = [Float](repeating: 0, count: 4096)
                for i in 0..<4096 {
                    input[i] = Float(0.1 * sin(2.0 * Double.pi * 440.0 * Double(i) / sampleRate))
                }
                let candidate = FaithfulStatelessDetector.detectPitch(input: input, sampleRate: sampleRate)
                #expect(candidate != nil)
                if let candidate = candidate {
                    #expect(abs(candidate.frequency - expectedDetector.frequency!) < budgets.frequencyAbsoluteHz)
                    #expect(abs(candidate.confidence - expectedDetector.confidence!) < budgets.confidenceAbsolute)
                    #expect(abs(candidate.rms - expectedDetector.rms) < (budgets.rmsAbsolute + budgets.rmsRelative * expectedDetector.rms))
                }
            } else if name == "vector-silence-zeros-48000" {
                let input = [Float](repeating: 0, count: 4096)
                let candidate = FaithfulStatelessDetector.detectPitch(input: input, sampleRate: sampleRate)
                #expect(candidate == nil)
                #expect(expectedDetector.frequency == nil)
                #expect(expectedDetector.confidence == nil)
            } else if name == "vector-alias-electronic-48000" {
                let interferer = 11560.0
                let targetFreq = 440.0 * pow(2.0, 17.0 / 1200.0)
                var input = [Float](repeating: 0, count: 4096)
                for i in 0..<4096 {
                    let t = Double(i) / sampleRate
                    input[i] = Float(0.03 * sin(2.0 * Double.pi * interferer * t) + 0.0006 * sin(2.0 * Double.pi * targetFreq * t))
                }
                let candidate = FaithfulStatelessDetector.detectPitch(input: input, sampleRate: sampleRate)
                #expect(candidate != nil)
                if let candidate = candidate {
                    #expect(abs(candidate.frequency - expectedDetector.frequency!) < budgets.frequencyAbsoluteHz)
                    #expect(abs(candidate.confidence - expectedDetector.confidence!) < budgets.confidenceAbsolute)
                    #expect(abs(candidate.rms - expectedDetector.rms) < (budgets.rmsAbsolute + budgets.rmsRelative * expectedDetector.rms))
                }
            }
        }
    }
}
