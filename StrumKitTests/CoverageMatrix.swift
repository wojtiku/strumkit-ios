// StrumKitTests/CoverageMatrix.swift
import Foundation
@testable import StrumKit

/// Deterministic plucked-string signal model for the detection-layer coverage matrix.
///
/// The partials are stretched by the standard inharmonicity relation
/// `f_n = n * f0 * sqrt(1 + B * n^2)`. `B = 0` is perfectly harmonic. Real steel
/// strings sit around `B = 1e-4` (low E) to `1e-3` (high E), and that stretch —
/// not a weak fundamental — is what classically degrades autocorrelation on
/// strings. No recorded fixture in the repo exercises it, which is why this
/// model exists rather than another WAV file.
///
/// Noise is a Lehmer/Park-Miller LCG so a `seed` fully determines the output.
enum CoverageMatrix {

    /// Tuning set. Thresholds are chosen against this and only this.
    static let SEED_A: UInt64 = 0x5EED_A
    /// Validation set. Read exactly once per tuned constant, at the end.
    /// Never used to choose a value. Enforced by a test in Task 6.
    static let SEED_B: UInt64 = 0x5EED_B

    struct Case: Sendable {
        let name: String
        let truthHz: Double
        let h1: Double
        let h2: Double
        let h3: Double
        let h4: Double
        let inharmonicity: Double
        let attackSeconds: Double
        let decayTau: Double
        let snrDB: Double
        /// Output peak amplitude. The requested value is the peak of the returned
        /// samples, restored after noise is added so that peak level and SNR
        /// remain independent axes.
        let amplitude: Double
        var seed: UInt64
    }

    static func signal(
        _ c: Case,
        rate: Double = 44100,
        seconds: Double = 3.0
    ) -> [Float] {
        let count = Int((rate * seconds).rounded())
        var out = [Float](repeating: 0, count: count)
        var peak: Double = 0

        for i in 0..<count {
            let t = Double(i) / rate
            var sum: Double = 0
            for (n, w) in [c.h1, c.h2, c.h3, c.h4].enumerated() where w != 0 {
                let nD = Double(n + 1)
                let fn = nD * c.truthHz * (1 + c.inharmonicity * nD * nD).squareRoot()
                guard fn < rate / 2 else { continue }
                // Deterministic per-partial phase offsets; no RNG in the tone itself.
                sum += w * sin(2 * .pi * fn * t + 0.4 * Double(n))
            }
            let attack = min(1.0, t / max(c.attackSeconds, 1e-6))
            let envelope = attack * exp(-t / c.decayTau)
            let v = c.amplitude * envelope * sum
            out[i] = Float(v)
            peak = max(peak, abs(v))
        }

        guard c.snrDB.isFinite, peak > 0 else { return out }
        // Scale so total noise power is `snrDB` below total signal power, then
        // restore the requested peak so SNR and level stay independent axes.
        let scale = c.amplitude / peak
        var sumSq: Double = 0
        for v in out { let d = Double(v); sumSq += d * d }
        let signalPower = sumSq / Double(out.count)
        let noiseAmplitude = (signalPower.squareRoot())
            * pow(10.0, -c.snrDB / 20.0) * 3.0.squareRoot()

        var lcg = c.seed == 0 ? 1 : c.seed
        for i in 0..<out.count {
            lcg = (lcg &* 48271) % 2147483647
            let uniform = Double(lcg) / 2147483647.0
            out[i] = Float(Double(out[i]) + noiseAmplitude * (uniform * 2 - 1))
        }
        for i in 0..<out.count { out[i] = Float(Double(out[i]) * scale) }
        return out
    }

    /// Brute-force DFT magnitude, used only by the model's own tests to locate a
    /// partial without depending on the code under test.
    static func dominantPeakHz(
        _ samples: [Float],
        rate: Double,
        from lowHz: Double,
        to highHz: Double,
        stepHz: Double = 0.5
    ) -> Double {
        var bestHz = lowHz
        var bestPower = -Double.infinity
        var hz = lowHz
        while hz <= highHz {
            let omega = 2 * .pi * hz / rate
            var re = 0.0, im = 0.0
            for (n, s) in samples.enumerated() {
                let a = omega * Double(n)
                let v = Double(s)
                re += v * cos(a)
                im += v * sin(a)
            }
            let power = re * re + im * im
            if power > bestPower { bestPower = power; bestHz = hz }
            hz += stepHz
        }
        return bestHz
    }

    /// Ground-truth frequency for a case, in the sense the matrix is scored
    /// against: the fundamental, whatever its amplitude.
    static func truthHz(_ c: Case) -> Double { c.truthHz }

    /// One plucked string, sweeping one axis at a time over the base case.
    static func baseCase(
        truthHz: Double,
        seed: UInt64,
        h1: Double = 1.0, h2: Double = 0.30, h3: Double = 0.15, h4: Double = 0.10,
        inharmonicity: Double = 0, snrDB: Double = .infinity,
        attackSeconds: Double = 0.006, decayTau: Double = 1.8, amplitude: Double = 0.2
    ) -> Case {
        Case(name: "f\(Int(truthHz))", truthHz: truthHz, h1: h1, h2: h2, h3: h3, h4: h4,
             inharmonicity: inharmonicity, attackSeconds: attackSeconds, decayTau: decayTau,
             snrDB: snrDB, amplitude: amplitude, seed: seed)
    }

    /// One scored run: a signal, the tuning it must be read against, and the
    /// frequency a correct reading must land on.
    struct Cell: Sendable {
        let label: String
        /// Backticked because `case` is a keyword; callers still write `cell.case`.
        let `case`: Case
        let config: TunerConfig
        let noteHz: Double
        let extraStrings: [Double]
    }

    /// Guitar standard open strings, low to high, matching Presets.guitar
    /// `standard` = midi [40, 45, 50, 55, 59, 64].
    static let guitarStrings: [Double] = [82.4069, 110.0, 146.8324, 195.9977, 246.9417, 329.6276]
    /// Ukulele high-G, matching Presets.ukulele `high-g` = midi [67, 60, 64, 69].
    static let ukuleleStrings: [Double] = [391.9954, 261.6256, 329.6276, 440.0]

    private static func guitarConfig() -> TunerConfig {
        TunerConfig(instrument: .guitar, tuningId: "standard", mode: .auto)
    }
    private static func ukuleleConfig() -> TunerConfig {
        TunerConfig(instrument: .ukulele, tuningId: "high-g", mode: .auto)
    }

    /// Every cell in the matrix, sweeping one axis at a time over a base pluck
    /// of the low E, plus a per-string sweep and a polyphony sweep. This is
    /// exactly the axis table in spec §6, and it is 40 cells.
    ///
    /// Axis tags in `label` are stable and greppable: h1, snr, B, atk, lvl,
    /// tau, poly, str.
    ///
    /// Spec §6's decay-with-dropout family is deliberately *not* here: it
    /// injects per-frame YIN dropout at replay time rather than at
    /// signal-generation time, so it cannot be a `Case`. It lives in the replay
    /// harness, `AudioTestHelpers.replayTrace(..., yinDropoutRate:)`.
    static func matrix(seed: UInt64) -> [Cell] {
        var cells: [Cell] = []
        let f0 = guitarStrings[0]
        let g = guitarConfig()

        func add(_ label: String, _ c: Case, _ config: TunerConfig,
                 _ noteHz: Double, _ extra: [Double] = []) {
            cells.append(Cell(label: label, case: c, config: config,
                              noteHz: noteHz, extraStrings: extra))
        }

        // Fundamental strength: 6 levels.
        for (tag, h1) in [("1.0", 1.0), ("0.3", 0.3), ("0.1", 0.1),
                          ("0.03", 0.03), ("0.01", 0.01), ("0.004", 0.004)] {
            add("h1-\(tag)", baseCase(truthHz: f0, seed: seed, h1: h1), g, f0)
        }

        // SNR: 5 levels.
        for (tag, snr) in [("clean", Double.infinity), ("20", 20.0),
                           ("12", 12.0), ("6", 6.0), ("0", 0.0)] {
            add("snr-\(tag)", baseCase(truthHz: f0, seed: seed, snrDB: snr), g, f0)
        }

        // Inharmonicity: 4 levels. The axis under test.
        for (tag, b) in [("0", 0.0), ("1e-4", 1e-4), ("5e-4", 5e-4), ("2e-3", 2e-3)] {
            add("B-\(tag)", baseCase(truthHz: f0, seed: seed, inharmonicity: b), g, f0)
        }

        // Attack, decay, level.
        for (tag, atk) in [("0.6ms", 0.0006), ("6ms", 0.006), ("30ms", 0.030)] {
            add("atk-\(tag)", baseCase(truthHz: f0, seed: seed, attackSeconds: atk), g, f0)
        }
        for (tag, tau) in [("0.4s", 0.4), ("1.8s", 1.8), ("6s", 6.0)] {
            add("tau-\(tag)", baseCase(truthHz: f0, seed: seed, decayTau: tau), g, f0)
        }
        for (tag, amp) in [("-60dB", 0.001), ("-48dB", 0.004),
                           ("-36dB", 0.015), ("-24dB", 0.063), ("-6dB", 0.5)] {
            add("lvl-\(tag)", baseCase(truthHz: f0, seed: seed, amplitude: amp), g, f0)
        }

        // Every guitar and ukulele string, at a realistic pluck and light B.
        for (i, f) in guitarStrings.enumerated() {
            add("str-g\(i)", baseCase(truthHz: f, seed: seed, inharmonicity: 1e-4), g, f)
        }
        for (i, f) in ukuleleStrings.enumerated() {
            add("str-u\(i)", baseCase(truthHz: f, seed: seed, inharmonicity: 5e-4),
                ukuleleConfig(), f)
        }

        // Polyphony. E2 + F#2 is the semitone pair that defeats WebTuna outright.
        let poly: [(String, [Double])] = [
            ("E2+A2", [guitarStrings[0], guitarStrings[1]]),
            ("E2+E4", [guitarStrings[0], guitarStrings[5]]),
            ("A2+E4", [guitarStrings[1], guitarStrings[5]]),
            ("E2+Fs2", [guitarStrings[0], 92.4986]),
        ]
        for (tag, freqs) in poly {
            add("poly-\(tag)",
                baseCase(truthHz: freqs[0], seed: seed, h1: 0.7, h2: 0.3, h3: 0.15, h4: 0.1),
                g, freqs[0], Array(freqs.dropFirst()))
        }

        return cells
    }
}
