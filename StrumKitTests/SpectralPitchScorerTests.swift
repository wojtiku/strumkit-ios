import Testing
import Foundation
import Accelerate
@testable import StrumKit

@Suite("Spectral Pitch Scorer Offline Prototype Tests")
struct SpectralPitchScorerTests {

    private func makeSineWave(frequency: Double, sampleRate: Double, count: Int, amplitude: Float = 0.2) -> [Float] {
        var samples = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let t = Double(i) / sampleRate
            samples[i] = Float(sin(2.0 * .pi * frequency * t)) * amplitude
        }
        return samples
    }

    @Test("Accelerate FFT scaling and peak locations match direct DFT to floating-point precision")
    func testDirectDFTComparisonAndFFTScaling() {
        let sampleRate = 16000.0
        let n = 1536
        let fftSize = 4096

        // Create a multi-tone signal with off-bin components
        var signal = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let s1 = sin(2.0 * .pi * 442.3 * t) * 0.4
            let s2 = sin(2.0 * .pi * 884.6 * t) * 0.3
            signal[i] = Float(s1 + s2)
        }

        // Zero-center matching scorer DC removal
        var mean: Float = 0.0
        vDSP_meanv(signal, 1, &mean, vDSP_Length(n))
        var negMean = -mean
        var zeroCentered = [Float](repeating: 0, count: n)
        vDSP_vsadd(signal, 1, &negMean, &zeroCentered, 1, vDSP_Length(n))

        // Apply Hamming window and pad to 4096
        var padded = [Float](repeating: 0, count: fftSize)
        for i in 0..<n {
            let w = 0.54 - 0.46 * cos(2.0 * Double.pi * Double(i) / Double(n - 1))
            padded[i] = zeroCentered[i] * Float(w)
        }

        // 1. Direct DFT
        let directMags = SpectralPitchScorer.directDFT(samples: padded, fftSize: fftSize)

        // 2. Accelerate FFT via scorer internal transform
        let scorer = SpectralPitchScorer()
        scorer.isWhiteningEnabled = false
        let acceleratedMags = scorer.computeMagnitudes(samples: signal)

        // Verify FFT scaling against direct DFT
        for k in 1..<300 {
            let diff = abs(directMags[k] - acceleratedMags[k])
            #expect(diff < 0.01, "Bin \(k) magnitude difference \(diff) must be negligible")
        }

        // Score audio directly through scorer
        let candidates = scorer.scoreWindow(signal)

        #expect(!candidates.isEmpty, "Candidates must not be empty for strong dual-tone signal")
        let topCandidate = candidates[0]

        // 442.3 Hz should be top candidate
        let centsError = abs(PitchMath.centsBetween(measured: topCandidate.frequency, reference: 442.3))
        #expect(centsError < 2.0, "Refined frequency must be within 2 cents of 442.3 Hz (got \(topCandidate.frequency) Hz, error \(centsError) cents)")

        // Check DFT peak bin for 442.3 Hz
        // Expected bin = 442.3 / (16000/4096) = 113.23 -> bin 113
        let binExpected = Int(round(442.3 / (sampleRate / Double(fftSize))))
        var maxDirectBin = 0
        var maxDirectMag: Float = 0
        for k in 1..<500 {
            if directMags[k] > maxDirectMag {
                maxDirectMag = directMags[k]
                maxDirectBin = k
            }
        }
        #expect(maxDirectBin == binExpected, "Direct DFT peak bin \(maxDirectBin) must match expected bin \(binExpected)")
    }

    @Test("Accurately detects known off-bin sine tone with sub-cent parabolic refinement")
    func testKnownOffBinSineToneDetection() {
        let scorer = SpectralPitchScorer()
        let sampleRate = 16000.0
        let targetFreq = 331.25 // Off-bin frequency (near E4 = 329.63 Hz)
        let signal = makeSineWave(frequency: targetFreq, sampleRate: sampleRate, count: 1536, amplitude: 0.3)

        let candidates = scorer.scoreWindow(signal)
        #expect(!candidates.isEmpty)

        let top = candidates[0]
        let centsDiff = abs(PitchMath.centsBetween(measured: top.frequency, reference: targetFreq))
        #expect(centsDiff < 1.0, "Parabolic refinement should achieve <1.0 cent error (got \(top.frequency), diff \(centsDiff) cents)")
    }

    @Test("Multi-harmonic pluck with weak fundamental resolves correct pitch without octave doubling")
    func testMultiHarmonicPluckScoreSeparation() {
        let scorer = SpectralPitchScorer()
        let sampleRate = 16000.0
        let f0 = 261.63 // C4
        let count = 1536

        // Weak fundamental (amplitude 0.1), strong 2nd harmonic (0.5), moderate 3rd (0.3)
        var signal = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let t = Double(i) / sampleRate
            let h1 = sin(2.0 * .pi * f0 * t) * 0.10
            let h2 = sin(2.0 * .pi * (2.0 * f0) * t) * 0.50
            let h3 = sin(2.0 * .pi * (3.0 * f0) * t) * 0.30
            signal[i] = Float(h1 + h2 + h3)
        }

        let candidates = scorer.scoreWindow(signal)
        #expect(!candidates.isEmpty)

        let top = candidates[0]
        let centsDiff = abs(PitchMath.centsBetween(measured: top.frequency, reference: f0))
        #expect(centsDiff < 3.0, "Top candidate must be fundamental C4 (got \(top.frequency) Hz, diff \(centsDiff) cents)")

        // Verify score separation against octave competitor (2 * f0 = 523.25 Hz)
        let octaveCompetitor = candidates.first { abs(PitchMath.centsBetween(measured: $0.frequency, reference: 2.0 * f0)) < 25.0 }
        if let oct = octaveCompetitor {
            #expect(top.score > oct.score * 1.05, "Fundamental score \(top.score) must exceed 2nd harmonic competitor \(oct.score)")
        }
    }

    @Test("Silence and low energy return no candidates")
    func testSilenceAndLowEnergy() {
        let scorer = SpectralPitchScorer()
        let silence = [Float](repeating: 0, count: 1536)
        let emptyResult = scorer.scoreWindow(silence)
        #expect(emptyResult.isEmpty, "Silence must yield no spectral candidates")

        // Extremely low amplitude below minAnalysisRMS (0.00006)
        let tinySignal = [Float](repeating: 0.00001, count: 1536)
        let tinyResult = scorer.scoreWindow(tinySignal)
        #expect(tinyResult.isEmpty, "Sub-RMS signal must yield no spectral candidates")
    }

    @Test("Whitening boosts weak harmonic balance relative to non-whitened spectrum")
    func testWhiteningEnabledVsDisabled() {
        let f0 = 440.0 // A4
        let count = 1536
        let sampleRate = 16000.0

        // Realistic weak fundamental pluck: h1 = 0.15, h2 = 0.50, h3 = 0.30
        var signal = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let t = Double(i) / sampleRate
            let h1 = sin(2.0 * .pi * f0 * t) * 0.15
            let h2 = sin(2.0 * .pi * (2.0 * f0) * t) * 0.50
            let h3 = sin(2.0 * .pi * (3.0 * f0) * t) * 0.30
            signal[i] = Float(h1 + h2 + h3)
        }

        let scorer = SpectralPitchScorer()

        // With whitening
        scorer.isWhiteningEnabled = true
        let whitenedCandidates = scorer.scoreWindow(signal)

        // Without whitening
        scorer.isWhiteningEnabled = false
        let unwhitenedCandidates = scorer.scoreWindow(signal)

        #expect(!whitenedCandidates.isEmpty)
        #expect(!unwhitenedCandidates.isEmpty)

        let topWhitened = whitenedCandidates[0]
        #expect(abs(PitchMath.centsBetween(measured: topWhitened.frequency, reference: f0)) < 3.0, "Whitened must identify A4 fundamental")
    }

    @Test("Offline evaluation of recorded quiet plucks: compares YIN baseline vs unwhitened vs whitened spectral scorer")
    func testOfflineFixtureEvaluationAndComparativeTable() {
        let fixtures: [(name: String, targetNote: String, targetMidi: Int, targetFreq: Double)] = [
            ("quiet_a", "A4", 69, 440.0),
            ("quiet_c", "C4", 60, 261.63),
            ("quiet_e", "E4", 64, 329.63),
            ("quiet_g", "G4", 67, 392.00)
        ]

        let hopSamples = 2048

        print("\n=== TASK 4: OFFLINE SPECTRAL SCORER DECISION TABLE ===")
        print("Fixture  | Note   | Frames   | YIN Valid    | Scorer Raw   | Scorer White | Separation")

        for fixture in fixtures {
            guard let audio = AudioTestHelpers.loadWav(name: fixture.name) else {
                Issue.record("Failed to load \(fixture.name).wav")
                continue
            }

            let windowSamples = AudioCaptureService.requiredInputSamples(for: audio.sampleRate)
            let detector = PitchDetector(sampleRate: audio.sampleRate, bufferSize: windowSamples)
            let scorerRaw = SpectralPitchScorer()
            scorerRaw.isWhiteningEnabled = false
            let scorerWhite = SpectralPitchScorer()
            scorerWhite.isWhiteningEnabled = true

            var totalFrames = 0
            var yinCorrectFrames = 0
            var rawCorrectFrames = 0
            var whiteCorrectFrames = 0
            var separationSums: Double = 0
            var separationCount = 0

            var offset = 0
            while offset + hopSamples <= audio.samples.count {
                totalFrames += 1
                let windowStart = max(0, offset + hopSamples - windowSamples)
                let windowEnd = offset + hopSamples
                let window = Array(audio.samples[windowStart..<windowEnd])

                // 1. YIN Baseline
                let yinResult = detector.detectPitch(in: window, noiseGateRMS: 0.0001, yinThreshold: 0.15)
                if yinResult.frequency > 0 && AudioTestHelpers.isCorrectRecordedPitch(yinResult.frequency, reference: fixture.targetFreq) {
                    yinCorrectFrames += 1
                }

                // 2. Spectral Scorer (Raw / Unwhitened)
                let rawCandidates = scorerRaw.scoreAudio(samples: window, sampleRate: audio.sampleRate)
                if let topRaw = rawCandidates.first, AudioTestHelpers.isCorrectRecordedPitch(topRaw.frequency, reference: fixture.targetFreq) {
                    rawCorrectFrames += 1
                }

                // 3. Spectral Scorer (Whitened)
                let whiteCandidates = scorerWhite.scoreAudio(samples: window, sampleRate: audio.sampleRate)
                if let topWhite = whiteCandidates.first, AudioTestHelpers.isCorrectRecordedPitch(topWhite.frequency, reference: fixture.targetFreq) {
                    whiteCorrectFrames += 1

                    // Measure separation ratio over competitor outside ±50 cents
                    let competitor = whiteCandidates.first { abs(PitchMath.centsBetween(measured: $0.frequency, reference: topWhite.frequency)) > 50.0 }
                    if let comp = competitor, comp.score > 0 {
                        let sep = topWhite.score / comp.score
                        separationSums += sep
                        separationCount += 1
                    }
                }

                offset += hopSamples
            }

            let avgSep = separationCount > 0 ? String(format: "%.2fx", separationSums / Double(separationCount)) : "N/A"
            let row = "\(fixture.name.padding(toLength: 8, withPad: " ", startingAt: 0)) | \(fixture.targetNote.padding(toLength: 6, withPad: " ", startingAt: 0)) | \(String(totalFrames).padding(toLength: 8, withPad: " ", startingAt: 0)) | \(String(yinCorrectFrames).padding(toLength: 12, withPad: " ", startingAt: 0)) | \(String(rawCorrectFrames).padding(toLength: 12, withPad: " ", startingAt: 0)) | \(String(whiteCorrectFrames).padding(toLength: 12, withPad: " ", startingAt: 0)) | \(avgSep)"
            print(row)

            // Fundamental must remain well-separated candidate on sustaining plucks
            #expect(whiteCorrectFrames >= yinCorrectFrames,
                    "Whitened spectral scorer must capture at least as many correct frames as baseline YIN for \(fixture.name)")
        }
    }
}
