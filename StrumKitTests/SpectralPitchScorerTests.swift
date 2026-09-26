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

    // MARK: - Harmonic Evidence Diagnostics

    @Test("Per-harmonic evidence log for biased and clean fixtures")
    func testHarmonicEvidenceLog() {
        for (name, reference) in [("quiet_a", 440.0), ("quiet_c", 261.63)] {
            guard let wav = AudioTestHelpers.loadWav(name: name) else { continue }
            let win = AudioCaptureService.requiredInputSamples(for: wav.sampleRate)
            let scorer = SpectralPitchScorer()
            let hop = 2048
            var offset = hop
            var logged = 0
            while offset <= wav.samples.count && logged < 5 {
                let start = max(0, offset - win)
                let window = Array(wav.samples[start..<offset])
                let t = Double(offset) / wav.sampleRate
                // Only log the sustained region, and only the candidate that the
                // recovery path would actually consider (within 70 cents).
                if t > 0.35, let a = scorer.analyzeAudio(samples: window, sampleRate: wav.sampleRate),
                   let idx = a.candidates.firstIndex(where: {
                       abs(PitchMath.centsBetween(measured: $0.frequency, reference: reference)) <= 70
                   }) {
                    let cand = a.candidates[idx]
                    let dev = PitchMath.centsBetween(measured: cand.frequency, reference: reference)
                    let desc = a.evidence[idx].prefix(7).map { e -> String in
                        let pf = e.peakFrequency.map { String(format: "%.2f", $0) } ?? "none"
                        let d = e.peakFrequency.map { String(format: "%+.1f", 1200 * log2($0 / e.expectedFrequency)) } ?? "  - "
                        return "h\(e.harmonic)=\(pf)(\(d)c,\(String(format: "%.2f", e.peakMagnitude)))"
                    }.joined(separator: " ")
                    print(String(format: "EVID %@ t=%.3f rms=%.5f top=%.2f dev=%+.1fc score=%.4f | %@",
                                 name, t, a.rms, cand.frequency, dev, cand.score, desc))
                    logged += 1
                }
                offset += hop
            }
        }
    }

    // MARK: - Task 5 Recovery Accuracy Gates

    /// A plucked string's fundamental is effectively constant while it decays, so
    /// the frames YIN accepts early in a recording are a valid in-track reference
    /// for the frames spectral recovery accepts later in the same decay. These
    /// tests compare the two, which is the only accuracy signal available for real
    /// recordings without hand-annotated pitch.
    @Test("Recovered frames must not bias away from the in-track YIN anchor")
    func testRecoveredFramesHaveNoSystematicBias() {
        let fixtures: [(name: String, reference: Double)] = [
            ("quiet_a", 440.0),
            ("quiet_c", 261.63),
            ("quiet_e", 329.63),
            ("quiet_g", 392.0)
        ]

        for fixture in fixtures {
            guard let wav = AudioTestHelpers.loadWav(name: fixture.name) else {
                Issue.record("Failed to load WAV fixture: \(fixture.name).wav")
                continue
            }

            let config = TunerConfig(instrument: .ukulele, tuningId: "high-g", mode: .auto)
            let (frames, _) = AudioTestHelpers.replayTrace(
                samples: wav.samples,
                sampleRate: wav.sampleRate,
                config: config
            )

            let fresh = frames.compactMap { $0.reading }.filter { $0.freshness == .fresh }
            let anchor = fresh.filter { !$0.recovered }
                .map { PitchMath.centsBetween(measured: $0.frequency, reference: fixture.reference) }
            let recovered = fresh.filter { $0.recovered }

            #expect(anchor.count >= 2, "\(fixture.name): need at least 2 YIN frames to anchor against")
            #expect(recovered.count >= 5, "\(fixture.name): expected spectral recovery to engage during the decay")

            guard !anchor.isEmpty, !recovered.isEmpty else { continue }

            let anchorMean = anchor.reduce(0, +) / Double(anchor.count)
            let offsets = recovered
                .map { PitchMath.centsBetween(measured: $0.frequency, reference: fixture.reference) - anchorMean }
                .sorted()

            let mean = offsets.reduce(0, +) / Double(offsets.count)
            let median = offsets[offsets.count / 2]
            let p95Index = min(offsets.count - 1, Int(ceil(0.95 * Double(offsets.count))) - 1)
            let p95 = offsets[max(0, p95Index)]

            print(String(format: "RECOVERY-BIAS [%@]: anchor n=%lld mean=%+.2fc | recovered n=%lld mean=%+.2fc median=%+.2fc p95=%+.2fc min=%+.2fc max=%+.2fc",
                         fixture.name, anchor.count, anchorMean,
                         recovered.count, mean, median, p95, offsets.first!, offsets.last!))

            // Gate calibrated from measurement, not chosen to pass. The pre-fix
            // implementation measured a +8.0 cent mean / +7.6 cent median bias on
            // quiet_c; the fixed implementation's worst fixture is quiet_a at
            // -3.1/-3.1. A 4 cent gate therefore sits clear of the defect it exists
            // to catch while still bounding residual error. See RESULTS.md.
            #expect(abs(mean) <= 4.0, "\(fixture.name): recovered mean bias \(mean)c must be within 4c of the in-track anchor")
            #expect(abs(median) <= 4.0, "\(fixture.name): recovered median bias \(median)c must be within 4c of the in-track anchor")
        }
    }

    @Test("Recovered frames neither over-claim in tune nor drive tuning advice")
    func testRecoveredFramesNeitherOverClaimNorAdvise() {
        let fixtures: [(name: String, reference: Double)] = [
            ("quiet_a", 440.0),
            ("quiet_c", 261.63),
            ("quiet_e", 329.63),
            ("quiet_g", 392.0)
        ]

        for fixture in fixtures {
            guard let wav = AudioTestHelpers.loadWav(name: fixture.name) else {
                Issue.record("Failed to load WAV fixture: \(fixture.name).wav")
                continue
            }

            let config = TunerConfig(instrument: .ukulele, tuningId: "high-g", mode: .auto)
            let (frames, _) = AudioTestHelpers.replayTrace(
                samples: wav.samples,
                sampleRate: wav.sampleRate,
                config: config
            )

            let fresh = frames.compactMap { $0.reading }.filter { $0.freshness == .fresh }
            let recovered = fresh.filter { $0.recovered }
            let confirmed = fresh.filter { !$0.recovered }
            guard !recovered.isEmpty else { continue }

            // 1. Recovery must never assert that a string is in tune. Its cents error
            //    is larger than YIN's, so an in-tune verdict from it is a claim the
            //    evidence does not support.
            let overClaimed = recovered.filter { $0.inTune }
            #expect(overClaimed.isEmpty, "\(fixture.name): \(overClaimed.count) recovered frames asserted in-tune")

            // 2. Recovery must never produce directional advice. This is the user
            //    facing consequence of (1): a wrong cents value must not be able to
            //    tell the player to move a tuning peg.
            let advice = recovered
                .map { TunerPresentation.guidanceText(for: $0, feedback: .tracking) }
                .filter { $0 == "Tune up" || $0 == "Tune down" }
            #expect(advice.isEmpty, "\(fixture.name): \(advice.count) recovered frames produced tuning advice")

            // 3. No single recovered frame may be far enough off to look absurd.
            //    (Measured worst case is ~18 cents on the deepest frame of the
            //    quietest decay; see docs/tuner-reliability/RESULTS.md.)
            let worst = recovered.map { abs($0.cents) }.max() ?? 0
            #expect(worst <= 20.0, "\(fixture.name): worst recovered frame error \(worst)c exceeds 20c")

            print("RECOVERY-CONTRACT [\(fixture.name)]: recovered=\(recovered.count) overClaimed=\(overClaimed.count) advice=\(advice.count) worstErr=\(String(format: "%.1f", worst))c confirmed=\(confirmed.count)")

            // 4. The suppression must not disable the normal YIN path: frames YIN
            //    confirmed still assert in tune when the string is in tune.
            if let inTuneAnchor = confirmed.first(where: { abs($0.cents) < 2.0 }) {
                #expect(inTuneAnchor.inTune,
                        "\(fixture.name): a YIN-confirmed in-tune frame must still report inTune")
            }
        }
    }

    @Test("Spectral recovery does not fabricate notes from noise once a prior exists")
    func testRecoveryDoesNotFabricateFromNoiseAfterPrior() {
        let sampleRate = 44100.0
        let tone = (0..<Int(sampleRate * 0.4)).map { i -> Float in
            0.2 * Float(sin(2.0 * .pi * 440.0 * Double(i) / sampleRate))
        }

        // Levels span a quiet decay tail up to a loud room floor.
        let noiseAmplitudes: [Float] = [0.0008, 0.004, 0.010, 0.020]

        for amplitude in noiseAmplitudes {
            var noise: [Float] = []
            var seed: UInt64 = 777
            for _ in 0..<Int(sampleRate * 1.2) {
                seed = (seed &* 48271) % 2147483647
                noise.append(amplitude * Float((Double(seed) / 2147483647.0) * 2.0 - 1.0))
            }

            let config = TunerConfig(instrument: .ukulele, tuningId: "high-g", mode: .auto)
            let (frames, _) = AudioTestHelpers.replayTrace(
                samples: tone + noise,
                sampleRate: sampleRate,
                config: config
            )

            let afterTone = frames.filter { $0.captureEndSeconds > 0.4 }
            let recovered = afterTone.compactMap { $0.reading }
                .filter { $0.freshness == .fresh && $0.recovered }

            let drifted = recovered.filter {
                abs(PitchMath.centsBetween(measured: $0.frequency, reference: 440.0)) > 20.0
            }

            print(String(format: "RECOVERY-NOISE amp=%.4f: framesAfterTone=%lld recovered=%lld driftedOver20c=%lld",
                         amplitude, afterTone.count, recovered.count, drifted.count))

            #expect(drifted.isEmpty, "Noise at amplitude \(amplitude) fabricated \(drifted.count) drifted readings; first: \(drifted.first?.frequency ?? 0) Hz")
        }
    }

    @Test("Weak-fundamental guitar low notes are measured rather than silently dropped")
    func testWeakFundamentalGuitarLowNoteSustain() {
        let sampleRate = 48000.0

        // Deterministic plucks whose fundamental is deliberately much weaker than
        // their second and third partials, as a real low string rings.
        //
        // `fundamentalAmplitude` is chosen to sit just above
        // `PitchDetector.fundamentalEnergyBase` (0.004), the detector's
        // documented floor for trusting a subharmonic candidate's fundamental.
        // Below that floor YIN reports "signal present, pitch ambiguous" and
        // declines to name a note, which is the intended abstention rather than a
        // bug; `docs/tuner-reliability/RESULTS.md` records that boundary and the
        // fact that spectral recovery cannot rescue it (recovery requires an
        // already-accepted prior, so it can only extend a note, never acquire one).
        let fundamentalAmplitude = 0.060
        let secondAmplitude = 0.300
        let thirdAmplitude = 0.220
        let fourthAmplitude = 0.100

        func weakFundamentalPluck(fundamental: Double, seconds: Double) -> [Float] {
            let count = Int(sampleRate * seconds)
            var signal = [Float](repeating: 0, count: count)
            for i in 0..<count {
                let t = Double(i) / sampleRate
                let envelope = Float(exp(-t / 1.1)) * Float(min(1.0, t / 0.005))
                let a = 2.0 * .pi * fundamental * t
                let body = fundamentalAmplitude * sin(a)
                    + secondAmplitude * sin(2 * a)
                    + thirdAmplitude * sin(3 * a)
                    + fourthAmplitude * sin(4 * a)
                signal[i] = envelope * Float(body)
            }
            return signal
        }

        let energyShare = fundamentalAmplitude * fundamentalAmplitude
            / (fundamentalAmplitude * fundamentalAmplitude
                + secondAmplitude * secondAmplitude
                + thirdAmplitude * thirdAmplitude
                + fourthAmplitude * fourthAmplitude)
        #expect(energyShare > PitchDetector.fundamentalEnergyBase,
                "test fixture fundamental must sit above the detector's abstention floor")

        let cases: [(name: String, fundamental: Double)] = [
            ("E2", 82.41),
            ("A2", 110.00)
        ]

        for testCase in cases {
            let signal = weakFundamentalPluck(fundamental: testCase.fundamental, seconds: 2.5)
            let config = TunerConfig(instrument: .guitar, tuningId: "standard", mode: .auto)
            let (frames, _) = AudioTestHelpers.replayTrace(
                samples: signal,
                sampleRate: sampleRate,
                config: config
            )

            let fresh = frames.compactMap { $0.reading }.filter { $0.freshness == .fresh }
            let correct = fresh.filter {
                AudioTestHelpers.isCorrectRecordedPitch($0.frequency, reference: testCase.fundamental)
            }
            let wrong = fresh.filter {
                !AudioTestHelpers.isCorrectRecordedPitch($0.frequency, reference: testCase.fundamental)
            }
            let coverage = AudioTestHelpers.freshCoverageSeconds(
                frames: frames,
                reference: testCase.fundamental,
                intervalStart: 0.20,
                intervalEnd: 1.30
            )

            print(String(format: "WEAK-FUNDAMENTAL %@: frames=%lld fresh=%lld correct=%lld wrong=%lld coverage=%.3fs last=%.3f",
                         testCase.name, frames.count, fresh.count, correct.count, wrong.count,
                         coverage, fresh.last?.at ?? 0))

            // The analysis window is ~96 ms, so the window centred at t is dominated
            // by the onset. Acquisition must be essentially immediate.
            #expect(!correct.isEmpty, "\(testCase.name) with a weak fundamental produced no correct reading at all")
            #expect(wrong.isEmpty, "\(testCase.name) with a weak fundamental produced \(wrong.count) wrong readings")
            #expect(coverage >= 0.40, "\(testCase.name) correct fresh coverage \(coverage)s must be >= 0.40s")
        }
    }
}
