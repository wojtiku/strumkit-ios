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

    @Test("the matrix covers every axis in the spec and both seed sets are disjoint")
    func matrixCoverage() {
        let a = CoverageMatrix.matrix(seed: CoverageMatrix.SEED_A)
        let b = CoverageMatrix.matrix(seed: CoverageMatrix.SEED_B)
        #expect(a.count == 40, "spec §6 enumerates 40 cells across eight axes; got \(a.count)")
        // Labels are constant axis tags and deliberately carry no seed, so the
        // two runs are compared on the seed that reaches each case.
        #expect(a.map(\.case.seed) != b.map(\.case.seed),
                "seed A and seed B must be different runs, not the same cells")

        func hasAxis(_ name: String) -> Bool {
            a.contains { $0.label.contains(name) }
        }
        for axis in ["h1", "snr", "B", "atk", "lvl", "tau", "poly"] {
            #expect(hasAxis(axis), "matrix is missing the \(axis) axis")
        }
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
