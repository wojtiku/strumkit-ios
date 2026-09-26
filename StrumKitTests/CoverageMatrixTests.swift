// StrumKitTests/CoverageMatrixTests.swift
import Foundation
import Testing
@testable import StrumKit

@Suite("Coverage matrix signal model")
struct CoverageMatrixSignalModelTests {

    @Test("inharmonicity stretches partials away from exact multiples of the fundamental")
    func inharmonicityStretchesPartials() {
        // B = 0 must be exactly harmonic.
        let harmonic = CoverageMatrix.signal(
            CoverageMatrix.Case(name: "h", truthHz: 82.4069, h1: 1.0, h2: 0.3, h3: 0.15, h4: 0.1,
                                inharmonicity: 0, attackSeconds: 0.006, decayTau: 1.8,
                                snrDB: .infinity, amplitude: 0.2, seed: 1),
            rate: 44100, seconds: 0.25)
        // Find the dominant peak by brute-force DFT over the plausible harmonic range.
        let peakHz = CoverageMatrix.dominantPeakHz(harmonic, rate: 44100, from: 150, to: 180)
        #expect(abs(peakHz - 164.8138) < 12, "B=0 second partial should sit at 2*f0, got \(peakHz)")

        // B = 2e-3 pushes the 4th partial measurably sharp: 4*f0*sqrt(1+16*2e-3).
        let stretched = CoverageMatrix.signal(
            CoverageMatrix.Case(name: "s", truthHz: 82.4069, h1: 1.0, h2: 0.3, h3: 0.15, h4: 0.1,
                                inharmonicity: 2e-3, attackSeconds: 0.006, decayTau: 1.8,
                                snrDB: .infinity, amplitude: 0.2, seed: 1),
            rate: 44100, seconds: 0.25)
        let expected = 4 * 82.4069 * (1 + 16 * 2e-3).squareRoot()
        let peak4 = CoverageMatrix.dominantPeakHz(stretched, rate: 44100,
                                                  from: expected - 15, to: expected + 15)
        #expect(abs(peak4 - expected) < 10,
                "B=2e-3 4th partial expected ~\(expected) Hz, got \(peak4) Hz")
    }

    @Test("the same seed reproduces the same signal bit for bit")
    func determinism() {
        let c = CoverageMatrix.Case(name: "d", truthHz: 110, h1: 0.3, h2: 0.3, h3: 0.15, h4: 0.1,
                                    inharmonicity: 5e-4, attackSeconds: 0.006, decayTau: 1.8,
                                    snrDB: 12, amplitude: 0.05, seed: 99)
        let a = CoverageMatrix.signal(c, rate: 44100, seconds: 0.25)
        let b = CoverageMatrix.signal(c, rate: 44100, seconds: 0.25)
        #expect(a == b)
    }

    @Test("seed A and seed B generate different noise for the same case")
    func seedSplitDiffers() {
        var a = CoverageMatrix.Case(name: "x", truthHz: 110, h1: 1, h2: 0.3, h3: 0.15, h4: 0.1,
                                    inharmonicity: 0, attackSeconds: 0.006, decayTau: 1.8,
                                    snrDB: 6, amplitude: 0.05, seed: 0)
        var b = a
        a.seed = CoverageMatrix.SEED_A
        b.seed = CoverageMatrix.SEED_B
        #expect(CoverageMatrix.signal(a, rate: 44100, seconds: 0.25)
                != CoverageMatrix.signal(b, rate: 44100, seconds: 0.25))
    }

    @Test("amplitude is the requested peak level, not the RMS")
    func amplitudeIsPeakLevel() {
        let c = CoverageMatrix.Case(name: "a", truthHz: 220, h1: 1, h2: 0, h3: 0, h4: 0,
                                    inharmonicity: 0, attackSeconds: 0.006, decayTau: 100,
                                    snrDB: .infinity, amplitude: 0.25, seed: 1)
        let s = CoverageMatrix.signal(c, rate: 44100, seconds: 1.0)
        #expect(abs(s.map { abs($0) }.max()! - 0.25) < 0.02)
    }

    @Test("the matrix has exactly spec §6's per-axis distribution")
    func matrixCoverage() {
        let a = CoverageMatrix.matrix(seed: CoverageMatrix.SEED_A)
        let b = CoverageMatrix.matrix(seed: CoverageMatrix.SEED_B)
        #expect(a.count == 40, "spec §6 enumerates 40 cells across eight axes; got \(a.count)")

        // Pin the per-axis distribution, not just the total: a bare substring
        // check on "B" is satisfied by every `lvl-` label, which ends in "dB".
        let expected: [String: Int] = ["h1-": 6, "snr-": 5, "B-": 4, "atk-": 3,
                                      "tau-": 3, "lvl-": 5, "str-": 10, "poly-": 4]
        for (tag, count) in expected {
            let actual = a.filter { $0.label.hasPrefix(tag) }.count
            #expect(actual == count, "axis \(tag) has \(actual) cells, spec §6 says \(count)")
        }
        #expect(a.allSatisfy { !$0.label.isEmpty })

        // Every cell must carry the seed it was asked for, not merely differ
        // somewhere - an array inequality still passes if 39 of 40 ignore it.
        #expect(a.allSatisfy { $0.case.seed == CoverageMatrix.SEED_A })
        #expect(b.allSatisfy { $0.case.seed == CoverageMatrix.SEED_B })

        // And the two runs must actually differ in audio. A finite-SNR cell is
        // required: `signal` returns before adding noise when snrDB is infinite,
        // so a clean cell is seed-independent by construction.
        let noisyA = a.first { $0.case.snrDB.isFinite }!
        let noisyB = b.first { $0.case.snrDB.isFinite }!
        #expect(CoverageMatrix.signal(noisyA.case, rate: 44100, seconds: 0.25)
                != CoverageMatrix.signal(noisyB.case, rate: 44100, seconds: 0.25))
    }

    @Test("every cell's truth frequency is a real string of its own instrument")
    func cellsTargetRealStrings() {
        for cell in CoverageMatrix.matrix(seed: CoverageMatrix.SEED_A) {
            let preset = Presets.presets(for: cell.config.instrument)
                .first { $0.id == cell.config.tuningId }!
            let expected = preset.midi.map { PitchMath.midiFrequency($0, a4: cell.config.a4) }
            #expect(expected.contains { abs($0 - cell.noteHz) < 0.001 },
                    "\(cell.label): \(cell.noteHz) Hz is not a string of \(cell.config.tuningId) (\(expected))")
        }
    }

    @Test("a polyphony cell's audio actually contains the second voice")
    func polyCellsArePolyphonic() {
        let matrix = CoverageMatrix.matrix(seed: CoverageMatrix.SEED_A)
        let poly = matrix.filter { $0.label.hasPrefix("poly-") }
        #expect(poly.count == 4, "spec §6 has 4 polyphony cells; got \(poly.count)")

        for cell in poly {
            #expect(!cell.extraStrings.isEmpty, "\(cell.label) declares no second string")
            // Two assertions, because they prove different things and neither
            // implies the other.
            //
            // This is the assertion whose absence let a head-to-head report
            // WebTuna 40/40 on a matrix that included "E2+F#2, the pair that
            // defeats WebTuna" while every poly- cell was a lone note. Compare
            // against a signal built from the same case with the second voice
            // removed: the two differ in exactly one thing, so energy appearing
            // at the fundamental is evidence rather than a coincidence of the
            // primary's own partials.
            var solo = cell.case
            solo.extraFrequencies = []
            let full = CoverageMatrix.signal(cell.case, rate: 44100, seconds: 1.0)
            let primaryOnly = CoverageMatrix.signal(solo, rate: 44100, seconds: 1.0)

            for f in cell.extraStrings {
                // (1) Presence: the voice is in the audio at all. A +/−4 Hz band
                //     deliberately overlaps the primary's neighbourhood, so this
                //     says "energy here that is not there without the voice" and
                //     nothing about where in the band it sits.
                let withVoice = CoverageMatrix.bandEnergy(
                    full, rate: 44100, aroundHz: f, halfWidthHz: 4)
                let without = CoverageMatrix.bandEnergy(
                    primaryOnly, rate: 44100, aroundHz: f, halfWidthHz: 4)
                #expect(withVoice > without * 4,
                        "\(cell.label): no energy at the second voice \(f) Hz (with voice \(withVoice), primary only \(without))")

                // (2) Position: that energy is centred on f, not merely
                //     somewhere in the 8 Hz window (1) used. A 2 Hz-wide band
                //     (`halfWidthHz: 1` is +-1, so 1 Hz either side) at 1.02f
                //     costs one more bandEnergy call. The comparison probe sits
                //     2% above f, which is 1.85 Hz at the 92.5 Hz cell and
                //     6.6 Hz at the 329.6 Hz one - not "one bin", which is what
                //     an earlier version of this comment wrongly called it.
                //
                //     Measured margins against the 4x threshold, from the
                //     committed traces: 17.1x (poly-E2+Fs2), 25.5x
                //     (poly-E2+A2), 130x (poly-A2+E4), 138x (poly-E2+E4). The
                //     17.1x is the minimum and is the one to quote. The ratio
                //     is scale-invariant — both bands come from the same signal,
                //     so any common scaling cancels — which is why the threshold
                //     is a ratio and not an absolute level.
                //
                //     On its own this would be vacuous: with the voice absent both
                //     bands would be equal. It only means something alongside (1),
                //     and a 5% detuning of the voice fails it while passing
                //     (1) on the two E4 cells.
                let atVoice = CoverageMatrix.bandEnergy(
                    full, rate: 44100, aroundHz: f, halfWidthHz: 1)
                let offVoice = CoverageMatrix.bandEnergy(
                    full, rate: 44100, aroundHz: f * 1.02, halfWidthHz: 1)
                #expect(atVoice > offVoice * 4,
                        "\(cell.label): energy near the second voice is not centred on \(f) Hz (at \(atVoice), off \(offVoice))")
            }
        }

        // And the control: a cell with no declared second string must be
        // unaffected by the comparison, so the assertion above is measuring the
        // voice and not a general property of every signal.
        for cell in matrix where !cell.label.hasPrefix("poly-") {
            #expect(cell.case.extraFrequencies.isEmpty,
                    "\(cell.label) is not a polyphony cell but carries extra voices \(cell.case.extraFrequencies)")
        }
    }

    @Test("the hard-coded string tables match the presets they claim to mirror")
    func stringTablesMatchPresets() {
        for f in CoverageMatrix.ukuleleStrings {
            #expect(Presets.ukulele.first { $0.id == "high-g" }!.midi
                    .contains { abs(PitchMath.midiFrequency($0, a4: 440) - f) < 0.001 },
                    "ukulele string \(f) Hz is not in the high-g preset")
        }
        for f in CoverageMatrix.guitarStrings {
            #expect(Presets.guitar.first { $0.id == "standard" }!.midi
                    .contains { abs(PitchMath.midiFrequency($0, a4: 440) - f) < 0.001 },
                    "guitar string \(f) Hz is not in the standard preset")
        }
    }
}

@Suite("Display state transitions")
struct DisplayTransitionTests {

    @Test("transitions counts state changes and ignores repeats")
    func countsOnlyChanges() {
        func frame(_ s: String) -> AudioTestHelpers.ReplayFrame {
            AudioTestHelpers.ReplayFrame(
                captureEndSeconds: 0, rawFrequency: 110, rawRMS: 0.1,
                confidence: 1, rejection: nil, reading: nil, displayState: s)
        }
        let frames = [frame("none"), frame("none"), frame("fresh"), frame("fresh"),
                      frame("recovered"), frame("recovered"), frame("held"), frame("fresh")]
        #expect(AudioTestHelpers.countDisplayTransitions(frames) == 4,
                "none->fresh, fresh->recovered, recovered->held, held->fresh = 4")
    }

    @Test("a clean sustained pluck produces a trace and its transition count is recorded")
    func cleanPluckIsStable() {
        let c = CoverageMatrix.baseCase(truthHz: 110, seed: CoverageMatrix.SEED_A)
        let config = CoverageMatrix.matrix(seed: CoverageMatrix.SEED_A)
            .first { $0.noteHz == 110 }!.config
        let (frames, _) = AudioTestHelpers.replayTrace(
            samples: CoverageMatrix.signal(c), sampleRate: 44100, config: config)
        #expect(!frames.isEmpty, "the trace must contain frames")
        let first = frames.first?.displayState
        #expect(first == "none" || first == "fresh",
                "the first frame is acquisition, not a transition; got \(first ?? "no frames")")
        print("BASELINE-TRANSITIONS [\(c.name)] = \(AudioTestHelpers.countDisplayTransitions(frames))")
    }
}

@Suite("Decay with injected YIN dropout")
struct DecayWithDropoutTests {

    @Test("injected dropout raises the transition count above the uninjected control")
    func dropoutReproducesTheSymptom() throws {
        var counts: [Double: Int] = [:]
        for rate in CoverageMatrix.dropoutRates {
            let c = CoverageMatrix.decayWithDropout(rate: rate, seed: CoverageMatrix.SEED_A)
            let config = TunerConfig(instrument: .guitar, tuningId: "standard", mode: .auto)
            let (frames, _) = AudioTestHelpers.replayTrace(
                samples: CoverageMatrix.signal(c, rate: 44100, seconds: 4.0),
                sampleRate: 44100, config: config,
                yinDropoutRate: rate, dropoutSeed: CoverageMatrix.SEED_A)
            let t = AudioTestHelpers.countDisplayTransitions(frames)
            counts[rate] = t
            print("DROPOUT-BASELINE rate=\(rate) transitions=\(t) frames=\(frames.count) states=\(AudioTestHelpers.stateHistogram(frames))")
        }
        let control = try #require(counts[0.0], "dropoutRates must contain the 0.0 control")
        #expect(control <= 3, "uninjected control made \(control) transitions; expected the natural decay tail only")
        for rate in CoverageMatrix.dropoutRates where rate > 0 {
            let injected = try #require(counts[rate])
            #expect(injected > control,
                    "rate \(rate) made \(injected) transitions, control made \(control) — the injection is not reproducing the symptom")
        }
        let atThirty = try #require(counts[0.3], "dropoutRates must contain 0.3")
        #expect(atThirty >= control + 5,
                "rate 0.3 should reproduce the symptom substantially; got \(atThirty)")
    }

    @Test("dropout frame selection is deterministic per seed and differs between seeds")
    func dropoutSelectionIsDeterministic() {
        // Assert that the same seed drops the same frames on two runs, and that
        // SEED_A and SEED_B do not drop the same ones. Use a small injected
        // helper on AudioTestHelpers that returns the dropped frame indices, so
        // this is testable without running the whole pipeline.
        let a1 = AudioTestHelpers.droppedFrameIndices(
            frameCount: 40, rate: 0.3, seed: CoverageMatrix.SEED_A)
        let a2 = AudioTestHelpers.droppedFrameIndices(
            frameCount: 40, rate: 0.3, seed: CoverageMatrix.SEED_A)
        let b = AudioTestHelpers.droppedFrameIndices(
            frameCount: 40, rate: 0.3, seed: CoverageMatrix.SEED_B)
        #expect(a1 == a2, "same seed must drop the same frames")
        #expect(a1 != b, "seed A and seed B must drop different frames")
        #expect(a1.allSatisfy { $0 >= 0 && $0 < 40 })
    }

    @Test("the walk's drop rate tracks the requested rate, not just its determinism")
    func dropoutRateTracksRequest() {
        // A biased walk (e.g. `index % 3 == 0`) is deterministic per seed and
        // differs between seeds, so the two assertions above would pass while
        // the fixture silently measured 1/3 for every requested rate.
        let frameCount = 400
        for rate in CoverageMatrix.dropoutRates {
            let counts = (0..<200).map { s in
                Double(AudioTestHelpers.droppedFrameIndices(
                    frameCount: frameCount, rate: rate,
                    seed: CoverageMatrix.SEED_A &+ UInt64(s)).count)
            }
            let mean = counts.reduce(0, +) / Double(counts.count)
            let requested = rate * Double(frameCount)
            #expect(abs(mean - requested) < 0.06 * Double(frameCount),
                    "rate \(rate): mean drop count \(mean) over 200 seeds is more than 6% of \(frameCount) away from the requested \(requested)")
        }
    }
}
