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
}
