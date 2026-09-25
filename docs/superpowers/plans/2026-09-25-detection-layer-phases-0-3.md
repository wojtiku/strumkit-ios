# Detection-Layer Redesign, Phases 0–3 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the measurement rig that can prove the decay flapping is fixed, then fix it — by filtering the estimate continuously upstream of the state machine, gating recovery behind continuation hysteresis, and stopping a weaker estimate from displacing a live confirmed one.

**Architecture:** Phases 0–3 of `docs/superpowers/specs/2026-09-25-tuner-detection-layer-design.md`, which is the authority. Phase 0 builds a deterministic coverage matrix and a transition counter so every later phase is gated on a measurement rather than a judgement. Phase 1 sweeps the fundamental-energy gate. Phase 2 moves filtering upstream of the state machine. Phase 3 adds continuation hysteresis and a one-way ratchet between the two estimators. Phases 4–7 of the spec are a separate plan.

**Tech Stack:** Swift 6 (iOS 17+, `SWIFT_STRICT_CONCURRENCY: complete`), Accelerate (`vDSP`), AVFoundation, Swift Testing (`import Testing`), XcodeGen. Node 20+ for the WebTuna oracle harness.

**Spec:** `docs/superpowers/specs/2026-09-25-tuner-detection-layer-design.md` — read it before starting; this plan argues from it and the two travel together.

## Global Constraints

- iOS 17.0 deployment target. Swift 6. `SWIFT_STRICT_CONCURRENCY: complete`.
- **No new dependencies.** Accelerate and AVFoundation only. No SPM packages, no CocoaPods.
- Every acceptance constant is a `public static let` on the type that owns it, with the seed-A number that chose it recorded in `docs/tuner-reliability/RESULTS.md`.
- **Seed A tunes. Seed B validates, exactly once, at the end. No threshold may ever be chosen by looking at seed B.** Task 6 installs the test that enforces this.
- Replay cadence is always `AudioTestHelpers.productionHopSamples` (1024). Do not introduce a second cadence.
- Analysis rate is 16 000 Hz, window 1536 samples, lags 14…320. Do not change these in this plan.
- **Do not widen the public API of `TunerReading`** for test concerns. Harness-only additions go on `AudioTestHelpers.ReplayFrame`, which is test-target code.
- `WebTuna.wasm` is Yousician's IP and must not be committed. Fetch it to the harness directory untracked.
- Accuracy gates that must not regress: clean-tone median ≤ 2 ¢ and p95 ≤ 5 ¢; the tighter E2 0.00 ¢/0.00 ¢ and C4 0.00 ¢/0.01 ¢ figures.
- `xcodebuild test` targets `'platform=iOS Simulator,name=iPhone 17'` with `-derivedDataPath ./DerivedData`. **Never run two `xcodebuild test` invocations against the same simulator concurrently** — the second test host is `SIGKILL`ed and it looks like a crash in the code under test.
- After adding a file under `StrumKitTests/`, run `make project` (xcodegen globs the directory) before building.

## Review Focus

Five input classes the spec implies that no existing test exercises. Each is pinned to the task that owns the code.

1. **A real string change while the previous string is still ringing** (pluck A2, then D3 before A2 decays). The continuation hysteresis in Task 10 must not delay the switch — a sticky failure counter that ignores a *new, stronger* estimate is worse than the flapping it fixes.
2. **A true dropout in a noisy room.** Task 10's hold-through-dropout path must not hold indefinitely: `maxCandidateGap` (250 ms) must still fire and return `nil`.
3. **A recovered frame arriving while a fresh reading is live.** Task 11's ratchet must still extend liveness — the note must not expire just because the ratchet refused the frequency.
4. **Inharmonicity B = 2e-3 on the low E.** The axis no current fixture touches, and the one where YIN is most likely to degrade. Task 1 generates it; Task 2 measures it; the matrix result is the first honest read on whether YIN survives real strings.
5. **A threshold re-tuned against seed B.** Task 6 installs a test that fails if a constant changes after seed B has been read, so the validation set cannot silently become a training set.

---

## File Structure

| File | Responsibility |
|---|---|
| `StrumKit/Audio/PitchDetector.swift` | YIN. Gains `fundamentalEnergyScale` (Task 5). Task 5 is its only change in this plan. |
| `StrumKit/Audio/PitchTracker.swift` | Owns all display filtering and continuation state. Tasks 7, 8, 9, 10, 11. |
| `StrumKit/Audio/TunerAnalysisSession.swift` | Orchestration. Gains the ratchet (Task 11) and recovery gating on continuation state (Task 12). |
| `StrumKit/Models/TunerTypes.swift` | Unchanged in this plan. |
| `StrumKitTests/CoverageMatrix.swift` | **New.** Deterministic signal model + matrix enumeration. Tasks 1, 2. |
| `StrumKitTests/AudioTestHelpers.swift` | Gains `displayState` on `ReplayFrame`, `countDisplayTransitions`, and a `fundamentalEnergyScale` passthrough. Tasks 3, 5, 6. |
| `StrumKitTests/CoverageMatrixTests.swift` | **New.** Phase 0 and 1 gates. Tasks 2, 6. |
| `StrumKitTests/DisplayStabilityTests.swift` | **New.** Phase 2 and 3 gates, including all five Review Focus items. Tasks 7–12. |
| `StrumKitTests/CrossEngineComparisonTests.swift` | **New.** Head-to-head trace emitter. Task 4. |
| `docs/tuner-reliability/webtuna/xeng.mjs` | **New.** WebTuna side of the head-to-head. Task 4. |
| `docs/tuner-reliability/RESULTS.md` | Records every tuned constant and its seed-A number. Tasks 6, 8, 10, 11. |

---

## Phase 0 — Measurement infrastructure

### Task 1: Deterministic plucked-string model with an inharmonicity axis

The current fixtures are recorded sustains. No current fixture stretches partials, and stretched partials are the condition classically known to degrade autocorrelation on strings. This task creates the signal model; Task 2 measures across it.

**Files:**
- Create: `StrumKitTests/CoverageMatrix.swift`
- Test: `StrumKitTests/CoverageMatrixTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `CoverageMatrix.Case`, `CoverageMatrix.signal(_:rate:seconds:) -> [Float]`, `CoverageMatrix.cases(seed:) -> [CoverageMatrix.Case]`, `CoverageMatrix.SEED_A`, `CoverageMatrix.SEED_B`, `CoverageMatrix.truthHz(_:) -> Double`. Tasks 2, 4, 6 depend on all of these by name.

- [ ] **Step 1: Write the failing test**

```swift
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
            rate: 44100, seconds: 0.5)
        // Find the dominant peak by brute-force DFT over the plausible harmonic range.
        let peakHz = CoverageMatrix.dominantPeakHz(harmonic, rate: 44100, from: 200, to: 240)
        #expect(abs(peakHz - 164.8138) < 12, "B=0 second partial should sit at 2*f0, got \(peakHz)")

        // B = 2e-3 pushes the 4th partial measurably sharp: 4*f0*sqrt(1+16*2e-3).
        let stretched = CoverageMatrix.signal(
            CoverageMatrix.Case(name: "s", truthHz: 82.4069, h1: 1.0, h2: 0.3, h3: 0.15, h4: 0.1,
                                inharmonicity: 2e-3, attackSeconds: 0.006, decayTau: 1.8,
                                snrDB: .infinity, amplitude: 0.2, seed: 1),
            rate: 44100, seconds: 0.5)
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
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
make project
xcodebuild test -project StrumKit.xcodeproj -scheme StrumKit \
  -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath ./DerivedData \
  -only-testing:StrumKitTests/CoverageMatrixSignalModelTests
```
Expected: compile failure — `CoverageMatrix` is undefined.

- [ ] **Step 3: Implement the signal model**

```swift
// StrumKitTests/CoverageMatrix.swift
import Foundation

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
        /// Peak amplitude of the harmonic sum before the envelope.
        let amplitude: Double
        let seed: UInt64
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
}
```

- [ ] **Step 4: Add the single-string case factory and the base case list**

Append to `CoverageMatrix`:

```swift
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
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
xcodebuild test -project StrumKit.xcodeproj -scheme StrumKit \
  -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath ./DerivedData \
  -only-testing:StrumKitTests/CoverageMatrixSignalModelTests
```
Expected: 4 tests pass.

- [ ] **Step 6: Commit**

```bash
git add StrumKitTests/CoverageMatrix.swift StrumKitTests/CoverageMatrixTests.swift
git commit -m "test(tuner): add deterministic plucked-string model with an inharmonicity axis

Partials are stretched by f_n = n*f0*sqrt(1+B*n^2). No recorded fixture in
the repo exercises this, and it is the axis classically known to degrade
autocorrelation on real strings - so the coverage matrix needs it before any
threshold is changed.

Noise is a Park-Miller LCG keyed on a seed, with SEED_A for tuning and
SEED_B reserved for validation. Peak amplitude and SNR are independent axes:
noise power is set relative to signal power, then the requested peak is
restored."
```

---

### Task 2: Coverage matrix enumeration and a runnable scoreboard

**Files:**
- Modify: `StrumKitTests/CoverageMatrix.swift`
- Modify: `StrumKitTests/AudioTestHelpers.swift`
- Test: `StrumKitTests/CoverageMatrixTests.swift`

**Interfaces:**
- Consumes: `CoverageMatrix.Case`, `.signal(_:rate:seconds:)`, `.baseCase(...)`, `.SEED_A`, `.SEED_B` from Task 1.
- Produces: `CoverageMatrix.matrix(seed:) -> [CoverageMatrix.Cell]`, `CoverageMatrix.Cell` (with `.case`, `.config`, `.noteHz`, `.label`), and `AudioTestHelpers.replayTrace(_:fundamentalEnergyScale:)` overload used by Task 6. Tasks 4 and 6 consume `Cell` and `matrix(seed:)`.

- [ ] **Step 1: Write the failing test**

Append to `CoverageMatrixSignalModelTests`:

```swift
    @Test("the matrix covers every axis in the spec and both seed sets are disjoint")
    func matrixCoverage() {
        let a = CoverageMatrix.matrix(seed: CoverageMatrix.SEED_A)
        let b = CoverageMatrix.matrix(seed: CoverageMatrix.SEED_B)
        #expect(a.count == 40, "spec §6 enumerates 40 cells across eight axes; got \(a.count)")
        // Compare the seeds, not the labels: a label carries no seed, so the
        // label sets are identical by construction and comparing them is
        // unsatisfiable.
        #expect(a.allSatisfy { $0.case.seed == CoverageMatrix.SEED_A })
        #expect(b.allSatisfy { $0.case.seed == CoverageMatrix.SEED_B })
        // Select a finite-SNR cell: a clean cell is seed-independent by
        // construction, because `signal` returns before the noise loop.
        if let noisyA = a.first(where: { $0.case.snrDB.isFinite }),
           let noisyB = b.first(where: { $0.case.snrDB.isFinite }) {
            #expect(CoverageMatrix.signal(noisyA.case, rate: 44100, seconds: 0.25)
                    != CoverageMatrix.signal(noisyB.case, rate: 44100, seconds: 0.25),
                    "seed A and seed B must generate different audio, not just differ in seed")
        }

        // Pin the per-axis distribution, not just the total: a bare substring
        // check on "B" is satisfied by every `lvl-` label, which ends in "dB".
        let expected: [String: Int] = ["h1-": 6, "snr-": 5, "B-": 4, "atk-": 3,
                                      "tau-": 3, "lvl-": 5, "str-": 10, "poly-": 4]
        for (tag, count) in expected {
            let actual = a.filter { $0.label.hasPrefix(tag) }.count
            #expect(actual == count, "axis \(tag) has \(actual) cells, spec §6 says \(count)")
        }
    }

    @Test("every cell's truth frequency is a real string of its own instrument")
    func cellsTargetRealStrings() {
        for cell in CoverageMatrix.matrix(seed: CoverageMatrix.SEED_A) {
            let preset = Presets.presets(for: cell.config.instrument)
                .first { $0.id == cell.config.tuningId }!
            let expected = preset.midi.map { PitchMath.midiFrequency($0, a4: cell.config.a4) }
            #expect(expected.contains { abs($0 - cell.noteHz) < 0.001 },
                    "\(cell.label): \(cell.noteHz) Hz is not a string of "
                    + "\(cell.config.tuningId) (\(expected))")
        }
    }
```

- [ ] **Step 2: Run and verify it fails**

```bash
xcodebuild test -project StrumKit.xcodeproj -scheme StrumKit \
  -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath ./DerivedData \
  -only-testing:StrumKitTests/CoverageMatrixSignalModelTests
```
Expected: compile failure — `matrix(seed:)` and `Cell` are undefined.

- [ ] **Step 3: Implement `Cell` and the matrix**

Append to `CoverageMatrix`:

```swift
    /// One scored run: a signal, the tuning it must be read against, and the
    /// frequency a correct reading must land on.
    struct Cell: Sendable {
        let label: String
        // Backticked: `case` is a Swift keyword. Member *access* (cell.case) is
        // fine, so Tasks 4, 6, 10 and 12 read `.case` unchanged.
        let `case`: Case
        let config: TunerConfig
        let noteHz: Double
        let extraStrings: [Double]
    }

    /// Guitar standard open strings, low to high.
    static let guitarStrings: [Double] = [82.4069, 110.0, 146.8324, 195.9977, 246.9417, 329.6276]
    /// Ukulele high-G.
    static let ukuleleStrings: [Double] = [195.9977, 261.6256, 329.6276, 440.0]

    private static func guitarConfig() -> TunerConfig {
        TunerConfig(instrument: .guitar, tuningId: "standard", mode: .auto)
    }
    private static func ukuleleConfig() -> TunerConfig {
        TunerConfig(instrument: .ukulele, tuningId: "high-g", mode: .auto)
    }

    /// Every cell in the matrix, sweeping one axis at a time over a base pluck
    /// of the low E, plus a per-string sweep and a polyphony sweep.
    ///
    /// Axis tags in `label` are stable and greppable: h1, snr, B, atk, lvl,
    /// tau, poly, str.
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
```

- [ ] **Step 4: Run and verify it passes**

```bash
xcodebuild test -project StrumKit.xcodeproj -scheme StrumKit \
  -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath ./DerivedData \
  -only-testing:StrumKitTests/CoverageMatrixSignalModelTests
```
Expected: 6 tests pass.

- [ ] **Step 5: Commit**

```bash
git add StrumKitTests/CoverageMatrix.swift StrumKitTests/CoverageMatrixTests.swift
git commit -m "test(tuner): enumerate the coverage matrix across all eight axes

Sweeps fundamental strength, SNR, inharmonicity, attack, decay, level,
per-string, and polyphony - one axis at a time over a base pluck of the low E
- so any threshold change can be scored on detect rate, wrong-note rate and
octave errors rather than argued about.

Includes E2+F#2, the semitone pair WebTuna fails on completely, so the two
engines are compared on a case neither is known to handle."
```

---

### Task 3: Display-state transition counter

Without this, "no jitter" is a judgement. `ReplayFrame` already carries the reading; it just does not expose *which display state* produced it, so transitions cannot be counted.

**Files:**
- Modify: `StrumKitTests/AudioTestHelpers.swift:150-175` (`ReplayFrame`), `:294-303` (the append site in `replayTrace`)
- Test: `StrumKitTests/CoverageMatrixTests.swift`

**Interfaces:**
- Consumes: `TunerReading.Freshness` (`StrumKit/Models/TunerTypes.swift:145`).
- Produces: `AudioTestHelpers.ReplayFrame.displayState: String` (one of `"none"`, `"fresh"`, `"held"`, `"recovered"`), `AudioTestHelpers.displayState(for reading: TunerReading?) -> String`, `AudioTestHelpers.countDisplayTransitions(_ frames: [ReplayFrame]) -> Int`. Tasks 6, 7, 8, 9, 10, 11, 12 assert on these.

- [ ] **Step 1: Write the failing test**

Append to `CoverageMatrixTests` (a new suite in the same file):

```swift
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

    @Test("a clean sustained pluck produces at most one transition after acquisition")
    func cleanPluckIsStable() {
        let c = CoverageMatrix.baseCase(truthHz: 110, seed: CoverageMatrix.SEED_A)
        let (frames, _) = AudioTestHelpers.replayTrace(
            samples: CoverageMatrix.signal(c), sampleRate: 44100,
            config: CoverageMatrix.matrix(seed: CoverageMatrix.SEED_A)
                .first { $0.noteHz == 110 }!.config)
        let transitions = AudioTestHelpers.countDisplayTransitions(frames)
        print("MATRIX-TRANSITIONS [\(c.name)] = \(transitions)")
        // This is the pre-fix baseline. Task 10 drives it to <= 1.
        #expect(transitions <= 6, "baseline should not already be perfect; got \(transitions)")
    }
}
```

- [ ] **Step 2: Run and verify it fails**

```bash
xcodebuild test -project StrumKit.xcodeproj -scheme StrumKit \
  -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath ./DerivedData \
  -only-testing:StrumKitTests/DisplayTransitionTests
```
Expected: compile failure — `displayState` and `countDisplayTransitions` are undefined.

- [ ] **Step 3: Add `displayState` to `ReplayFrame`**

In `StrumKitTests/AudioTestHelpers.swift`, add the stored property and initialiser parameter:

```swift
    public struct ReplayFrame: Sendable {
        public let captureEndSeconds: TimeInterval
        public let rawFrequency: Double
        public let rawRMS: Double
        public let confidence: Double
        public let rejection: String?
        public let reading: TunerReading?
        /// Which display state produced this frame: "none", "fresh", "held", or
        /// "recovered". Derived from the reading, not stored on it, so the public
        /// `TunerReading` API is not widened for a test concern.
        public let displayState: String
```

and in its `init`, after `self.rejection = rejection`:

```swift
            self.displayState = AudioTestHelpers.displayState(for: reading)
```

- [ ] **Step 4: Add the two helpers**

In `StrumKitTests/AudioTestHelpers.swift`, next to `classifyRejection`:

```swift
    /// The display state a reading represents. "recovered" wins over "held"
    /// because a recovered reading is the more specific fact about the frame.
    public static func displayState(for reading: TunerReading?) -> String {
        guard let reading else { return "none" }
        if reading.recovered { return "recovered" }
        return reading.freshness == .fresh ? "fresh" : "held"
    }

    /// Number of times the display state changed, ignoring consecutive repeats.
    ///
    /// This is the primary gate for goal G1: a note that is read continuously
    /// should acquire once and then hold, not oscillate between fresh, held and
    /// recovered while it decays.
    public static func countDisplayTransitions(_ frames: [ReplayFrame]) -> Int {
        var transitions = 0
        var previous: String?
        for frame in frames {
            if frame.displayState != previous { transitions += 1 }
            previous = frame.displayState
        }
        return max(0, transitions - 1)   // the first frame is acquisition, not a transition
    }
```

- [ ] **Step 5: Update the one `ReplayFrame` construction site**

In `replayTrace`, the append becomes:

```swift
            frames.append(ReplayFrame(
                captureEndSeconds: atSeconds,
                rawFrequency: snapshot.pitchResult.frequency,
                rawRMS: snapshot.pitchResult.amplitudeRMS,
                confidence: snapshot.pitchResult.confidence,
                rejection: rejection,
                reading: snapshot.reading,
                displayState: displayState(for: snapshot.reading)
            ))
```

- [ ] **Step 6: Run and verify it passes**

```bash
xcodebuild test -project StrumKit.xcodeproj -scheme StrumKit \
  -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath ./DerivedData \
  -only-testing:StrumKitTests/DisplayTransitionTests
```
Expected: 2 tests pass, and `MATRIX-TRANSITIONS` prints the pre-fix baseline. **Record that number in `RESULTS.md` as the G1 starting point** — it is the number Tasks 10–12 must beat.

- [ ] **Step 7: Commit**

```bash
git add StrumKitTests/AudioTestHelpers.swift StrumKitTests/CoverageMatrixTests.swift
git commit -m "test(tuner): count display-state transitions so jitter is measurable

A note that is read continuously should acquire once and then hold. Counting
fresh/held/recovered changes makes that a number instead of a judgement, and
it is the primary gate for G1.

displayState is derived from the reading on the harness frame record rather
than stored on TunerReading, so the public model API is not widened for a test
concern. The first frame is acquisition, not a transition."
```

---

### Task 3b: the decay-with-dropout family (spec §6's primary G1 gate)

Spec §6 names a family this plan originally omitted: *"a 4 s decay with per-frame YIN
dropout injected at 0 %, 10 %, 30 % and 50 % of frames. This is the fixture that reproduces
the reported symptom and it is the primary gate for G1."* It is a **replay-time** construct,
not a signal — you cannot inject frame-level dropout into a generated waveform — so it does
not belong in `CoverageMatrix.matrix(seed:)` and is not a `Case`. It is part of Task 3.

- **3b.1** `AudioTestHelpers.replayTrace` gains `yinDropoutRate: Double = 0.0`. For a
  deterministic subset of frames selected by a Park-Miller walk seeded from the case's seed,
  the frame is analysed as if the signal had been lost: feed a window of the same length and
  sample rate but replace the samples with a low-level noise-only buffer scaled to the
  configured `lvl-` amplitude, which is what a real dropout looks like to YIN. Deterministic
  for a given seed; seed A and seed B must drop different frames.
- **3b.2** Add `CoverageMatrix.decayWithDropout(rate:seed:) -> Case` — a 4 s decay
  (`decayTau: 4.0`) at the low E, one per dropout rate in {0.0, 0.1, 0.3, 0.5}. The 0.0
  member is the control: it must produce zero transitions, which proves the injection itself
  is what the G1 gate is measuring.
- **3b.3** Test: for `yinDropoutRate: 0.0` the control asserts **0** display transitions. For
  0.1, 0.3, 0.5 assert the count is **finite and less than the number of dropped frames** —
  pre-fix it is roughly one transition per dropped frame, so this is the assertion that fails
  first and proves the fixture reproduces the reported symptom.

**Gate:** the 0.0 control is 0 transitions, and the pre-fix numbers for 0.1/0.3/0.5 are recorded
in `RESULTS.md` as the G1 baseline.

### Task 4: Head-to-head trace emitter against the WebTuna oracle

**Files:**
- Create: `StrumKitTests/CrossEngineComparisonTests.swift`
- Create: `docs/tuner-reliability/webtuna/xeng.mjs`
- Modify: `docs/tuner-reliability/webtuna/README.md`

**Interfaces:**
- Consumes: `CoverageMatrix.Cell`, `CoverageMatrix.matrix(seed:)`, `AudioTestHelpers.replayTrace` from Tasks 2–3.
- Produces: `XENG|<label>|...` and `XWEB|<label>|...` line formats, and a truth table `docs/tuner-reliability/webtuna/xtruth.txt` that `xcompare.py` scores against. Task 6 uses the same truth table for its head-to-head column.

- [ ] **Step 1: Write the Swift emitter**

```swift
// StrumKitTests/CrossEngineComparisonTests.swift
import Foundation
import Testing
@testable import StrumKit

/// Emits machine-readable traces for the coverage matrix so the same signals can
/// be pushed through the WebTuna oracle and compared cell by cell. See
/// docs/tuner-reliability/webtuna/xeng.mjs for the other side and
/// docs/tuner-reliability/COMPARISON.md for what the comparison is for.
@Suite("Cross-engine comparison trace emitter")
struct CrossEngineComparisonTests {

    @Test("Emit StrumKit traces for every coverage-matrix cell")
    func emitTraces() {
        for cell in CoverageMatrix.matrix(seed: CoverageMatrix.SEED_A) {
            let audio = CoverageMatrix.signal(cell.case, rate: 44100, seconds: 3.0)
            let (frames, _) = AudioTestHelpers.replayTrace(
                samples: audio, sampleRate: 44100, config: cell.config)
            var firstCorrect: Double?
            var lastCorrect: Double?
            for f in frames {
                let hz = f.rawFrequency
                let cents = hz > 0 ? 1200 * log2(hz / cell.noteHz) : Double.nan
                if hz > 0, abs(cents) <= 50 {
                    if firstCorrect == nil { firstCorrect = f.captureEndSeconds }
                    lastCorrect = f.captureEndSeconds
                }
                let centsText = cents.isNaN ? "nan" : String(format: "%.3f", cents)
                print("XENG|\(cell.label)|t=\(String(format: "%.5f", f.captureEndSeconds))"
                      + "|hz=\(hz)|cents=\(centsText)"
                      + "|state=\(f.displayState)"
                      + "|conf=\(String(format: "%.3f", f.confidence))")
            }
            print("XENG-SUMMARY|\(cell.label)|truth=\(cell.noteHz)"
                  + "|first=\(firstCorrect ?? -1)|last=\(lastCorrect ?? -1)"
                  + "|transitions=\(AudioTestHelpers.countDisplayTransitions(frames))")
        }
    }
}
```

- [ ] **Step 2: Write the WebTuna side**

```javascript
// docs/tuner-reliability/webtuna/xeng.mjs
// Runs the coverage-matrix cells through the WebTuna oracle and emits
// XWEB|... lines for the same cell labels the Swift emitter prints.
// The wasm is Yousician's IP and is NOT committed; fetch it untracked.
//
//   curl -o WebTuna.wasm https://guitartuna.com/webtuna/WebTuna.wasm
//   node xeng.mjs > xweb-trace.txt
import { mk } from "./iso.mjs";
import { readFileSync } from "node:fs";

const RATE = 44100;
const CHUNK = 4096;            // WebTuna's hard-coded input size
const GUITAR = [329.6276, 246.9417, 195.9977, 146.8324, 110.0, 82.4069]; // idx 0 = highest

// Mirrors CoverageMatrix.Case / CoverageMatrix.matrix in the Swift test target.
// Kept in sync by hand; the truth table below is what xcompare.py scores against.
const cells = JSON.parse(readFileSync(new URL("./xcells.json", import.meta.url), "utf8"));

for (const cell of cells) {
  const { run } = mk();          // fresh instance: the engine is a stateful singleton
  const audio = buildSignal(cell);
  let firstHeard = null, lastHeard = null, call = 0;
  for (let s = 0; s + CHUNK <= audio.length; s += CHUNK) {
    const o = run(audio.subarray(s, s + CHUNK), cell.idx, RATE);
    call++;
    const t = (s + CHUNK) / RATE;
    if (o.CanHearANote && o.MeasuredPitchHz > 0) {
      const cents = 1200 * Math.log2(o.MeasuredPitchHz / cell.noteHz);
      if (Math.abs(cents) <= 50) {
        if (firstHeard === null) firstHeard = t;
        lastHeard = t;
      }
    }
    console.log(`XWEB|${cell.label}|t=${t.toFixed(5)}|hz=${o.MeasuredPitchHz}`
      + `|ratio=${o.InTuneRatio.toFixed(3)}|str=${o.CurrentString}`
      + `|rms=${o.MicRms.toFixed(6)}|pw=${o.PossibleWrongStringId}|calls=${call}`);
  }
  console.log(`XWEB-SUMMARY|${cell.label}|truth=${cell.noteHz}`
    + `|first=${firstHeard ?? -1}|last=${lastHeard ?? -1}`);
}
```

Append to `xeng.mjs`. `buildSignal` mirrors `CoverageMatrix.signal` line for line — same
inharmonicity relation, same envelope, same LCG. **If the two generators drift, the comparison
is meaningless**, which is why `xcells.json` is emitted from the Swift side rather than
hand-maintained: a label that only one side knows about shows up as a missing row in the
comparison instead of silently disappearing.

```javascript
function buildSignal(cell, rate = RATE, seconds = 3.0) {
  const n = Math.round(rate * seconds);
  const out = new Float32Array(n);
  const weights = [cell.h1, cell.h2, cell.h3, cell.h4];
  let peak = 0;
  for (let i = 0; i < n; i++) {
    const t = i / rate;
    let sum = 0;
    for (let k = 0; k < 4; k++) {
      const w = weights[k];
      if (w === 0) continue;
      const nd = k + 1;
      const fn = nd * cell.truthHz * Math.sqrt(1 + cell.inharmonicity * nd * nd);
      if (fn >= rate / 2) continue;
      sum += w * Math.sin(2 * Math.PI * fn * t + 0.4 * k);
    }
    const attack = Math.min(1, t / Math.max(cell.attackSeconds, 1e-6));
    const envelope = attack * Math.exp(-t / cell.decayTau);
    const v = cell.amplitude * envelope * sum;
    out[i] = v;
    peak = Math.max(peak, Math.abs(v));
  }
  if (cell.snrDB === "clean" || peak === 0) return out;

  const scale = cell.amplitude / peak;
  let sumSq = 0;
  for (const v of out) sumSq += v * v;
  const signalPower = sumSq / out.length;
  const noiseAmplitude = Math.sqrt(signalPower) * Math.pow(10, -cell.snrDB / 20) * Math.sqrt(3);
  let lcg = cell.seed === 0 ? 1 : cell.seed;
  for (let i = 0; i < n; i++) {
    lcg = (lcg * 48271) % 2147483647;
    out[i] += noiseAmplitude * ((lcg / 2147483647) * 2 - 1);
  }
  for (let i = 0; i < n; i++) out[i] *= scale;
  return out;
}
```

`cell.seed` must be in `xcells.json` for this to reproduce. Add it to the JSON object below,
alongside `idx`.

Also write the scorer, which is new (the archived harness has no cross-engine comparator):

```python
#!/usr/bin/env python3
"""Diff StrumKit and WebTuna traces produced from identical coverage-matrix cells.

Usage: xcompare.py <xeng-trace.txt> <xweb-trace.txt> <xtruth.txt>
"""
import re, sys
from collections import defaultdict


def parse(path, tag):
    cells = defaultdict(list)
    pattern = re.compile(r"^" + tag + r"-SUMMARY\|([^|]+)\|(.*)$")
    for line in open(path, encoding="utf8", errors="replace"):
        m = pattern.match(line.strip())
        if not m:
            continue
        kv = dict(p.split("=", 1) for p in m.group(2).split("|") if "=" in p)
        cells[m.group(1)] = kv
    return cells


def main(eng_path, web_path, truth_path):
    truth = {}
    for line in open(truth_path):
        if "=" in line:
            k, v = line.strip().split("=", 1)
            truth[k] = float(v)
    eng = parse(eng_path, "XENG")
    web = parse(web_path, "XWEB")

    missing = sorted(set(truth) - (set(eng) & set(web)))
    if missing:
        print(f"WARNING: {len(missing)} cells missing from a trace: {missing[:5]}")

    hdr = (f"{'cell':<16}{'truth':>9} | {'SK first':>9}{'SK last':>9}"
           f" | {'WT first':>9}{'WT last':>9} | {'winner':>8}")
    print(hdr); print("-" * len(hdr))
    eng_wins = web_wins = 0
    for label in sorted(set(eng) | set(web)):
        e, w = eng.get(label, {}), web.get(label, {})
        ef, el = float(e.get("first", -1)), float(e.get("last", -1))
        wf, wl = float(w.get("first", -1)), float(w.get("last", -1))
        heard_e, heard_w = el > 0, wl > 0
        if heard_e and not heard_w: winner, eng_wins = "StrumKit", eng_wins + 1
        elif heard_w and not heard_e: winner, web_wins = "WebTuna", web_wins + 1
        else: winner = "tie" if heard_e else "neither"
        fmt = lambda v: f"{v:9.3f}" if v > 0 else f"{'-':>9}"
        print(f"{label:<16}{truth.get(label, 0):9.2f} | {fmt(ef)}{fmt(el)}"
              f" | {fmt(wf)}{fmt(wl)} | {winner:>8}")
    print(f"\nStrumKit heard {eng_wins} cells WebTuna missed; "
          f"WebTuna heard {web_wins} cells StrumKit missed.")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2], sys.argv[3])
```

And generate the truth table from the same `xcells.json`, one `label=noteHz` per line, so
`xtruth.txt` cannot drift from the matrix either:

```bash
python3 -c "import json;[print(f\"{c['label']}={c['noteHz']}\") for c in json.load(open('docs/tuner-reliability/webtuna/xcells.json'))]" \
  > docs/tuner-reliability/webtuna/xtruth.txt
```

Emit `xcells.json` from the Swift side so the label set cannot diverge:

```swift
        // Append to emitTraces(), before the loop:
        let cells = CoverageMatrix.matrix(seed: CoverageMatrix.SEED_A)
        if let data = try? JSONSerialization.data(
            withJSONObject: cells.map {
                ["label": $0.label, "noteHz": $0.noteHz,
                 "truthHz": $0.case.truthHz, "h1": $0.case.h1, "h2": $0.case.h2,
                 "h3": $0.case.h3, "h4": $0.case.h4,
                 "inharmonicity": $0.case.inharmonicity,
                 "attackSeconds": $0.case.attackSeconds, "decayTau": $0.case.decayTau,
                 "snrDB": $0.case.snrDB.isFinite ? $0.case.snrDB : "clean",
                 "amplitude": $0.case.amplitude,
                 "idx": $0.config.instrument == .guitar ? -1 : -2]
            }, options: [.prettyPrinted, .sortedKeys]),
            let url = URL(fileURLWithPath: "docs/tuner-reliability/webtuna/xcells.json") {
            try? data.write(to: url)
        }
```

- [ ] **Step 3: Run both and diff**

```bash
xcodebuild test -project StrumKit.xcodeproj -scheme StrumKit \
  -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath ./DerivedData \
  -only-testing:StrumKitTests/CrossEngineComparisonTests 2>&1 \
  | grep -E '^(XENG|XENG-SUMMARY)' > /tmp/xeng-trace.txt

cd docs/tuner-reliability/webtuna
curl -o WebTuna.wasm https://guitartuna.com/webtuna/WebTuna.wasm
node xeng.mjs > xweb-trace.txt
```

Expected: both traces have the same number of `*-SUMMARY` lines and identical label sets. If not, the generators have drifted — fix before going further.

- [ ] **Step 4: Record the head-to-head baseline**

```bash
python3 xcompare.py /tmp/xeng-trace.txt xweb-trace.txt xtruth.txt
```

Paste the resulting table into `RESULTS.md` as the pre-change head-to-head. **This is the number G2 is measured against.** Do not proceed to Phase 1 without it.

- [ ] **Step 5: Commit**

```bash
git add StrumKitTests/CrossEngineComparisonTests.swift \
        docs/tuner-reliability/webtuna/xeng.mjs \
        docs/tuner-reliability/webtuna/xcompare.py \
        docs/tuner-reliability/webtuna/xcells.json \
        docs/tuner-reliability/webtuna/README.md \
        docs/tuner-reliability/RESULTS.md
git commit -m "test(tuner): add head-to-head traces against the WebTuna oracle

Same signals, same cell labels, both engines. WebTuna's compiled-in tuning is
a six-string guitar, so ukulele cells go through its chromatic mode.

xcells.json is emitted from the Swift matrix so the two signal generators
cannot drift apart silently - if they do, the comparison is meaningless and
says so. WebTuna.wasm stays untracked; it is Yousician's IP.

Records the pre-change head-to-head in RESULTS.md as the baseline for G2."
```

---

### Task 5: Make the fundamental-energy gate one tunable

The sweep needs a single knob. The three thresholds have different roles, so they keep their ratio to each other and scale together.

**Files:**
- Modify: `StrumKit/Audio/PitchDetector.swift:23-24` (constants), `:37-46` (`init`), `:229`, `:259`, `:340`
- Modify: `StrumKit/Audio/TunerAnalysisSession.swift` (detector construction, ~line 459)
- Modify: `StrumKitTests/AudioTestHelpers.swift` (`replayTrace` passthrough)

**Interfaces:**
- Consumes: nothing.
- Produces: `PitchDetector.fundamentalEnergyScale: Double` (initialiser parameter, default 1.0), and computed `fundamentalMinEnergyRatio` / `standardAmbiguityMinEnergyRatio` / `highNoteAmbiguityMinEnergyRatio` instance properties. `TunerAnalysisSession.init(...,fundamentalEnergyScale:)` and `AudioTestHelpers.replayTrace(...,fundamentalEnergyScale:)` passthroughs. Task 6 sweeps them.

- [ ] **Step 1: Write the failing test**

Append to `CoverageMatrixTests`:

```swift
@Suite("Fundamental energy gate is one tunable")
struct FundamentalEnergyScaleTests {

    @Test("scale 1.0 reproduces today's three thresholds exactly")
    func scaleOneIsIdentity() {
        let d = PitchDetector(sampleRate: 44100, bufferSize: 4328, fundamentalEnergyScale: 1.0)
        #expect(abs(d.fundamentalMinEnergyRatio - 0.004) < 1e-12)
        #expect(abs(d.standardAmbiguityMinEnergyRatio - 0.004) < 1e-12)
        #expect(abs(d.highNoteAmbiguityMinEnergyRatio - 0.002) < 1e-12)
    }

    @Test("scale 0.25 lowers all three and preserves their ratio")
    func scaleIsProportional() {
        let d = PitchDetector(sampleRate: 44100, bufferSize: 4328, fundamentalEnergyScale: 0.25)
        #expect(abs(d.fundamentalMinEnergyRatio - 0.001) < 1e-12)
        #expect(abs(d.highNoteAmbiguityMinEnergyRatio - 0.0005) < 1e-12)
        #expect(abs(d.highNoteAmbiguityMinEnergyRatio / d.fundamentalMinEnergyRatio - 0.5) < 1e-9)
    }

    @Test("a scale of zero disables the gate without dividing by zero")
    func zeroIsSafe() {
        let d = PitchDetector(sampleRate: 44100, bufferSize: 4328, fundamentalEnergyScale: 0)
        #expect(d.fundamentalMinEnergyRatio == 0)
        let c = CoverageMatrix.baseCase(truthHz: 110, seed: CoverageMatrix.SEED_A)
        let r = d.detectPitch(in: CoverageMatrix.signal(c, rate: 44100, seconds: 1.0),
                              noiseGateRMS: 0, yinThreshold: 0.15, referenceA4: 440)
        #expect(r.frequency > 0, "detection must not crash or abstain when the gate is off")
    }
}
```

- [ ] **Step 2: Run and verify it fails**

```bash
xcodebuild test -project StrumKit.xcodeproj -scheme StrumKit \
  -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath ./DerivedData \
  -only-testing:StrumKitTests/FundamentalEnergyScaleTests
```
Expected: compile failure — `fundamentalEnergyScale` is undefined.

- [ ] **Step 3: Replace the three constants with a scaled pair**

In `StrumKit/Audio/PitchDetector.swift`, replace lines 23-24:

```swift
    /// Multiplies every fundamental-energy gate. `1.0` is the pre-2026-09-25
    /// behaviour. Swept on coverage-matrix seed A; see RESULTS.md §Phase 1.
    ///
    /// These three gates sit *on top of* YIN and were found rejecting correct
    /// detections: at 0.18 % fundamental energy YIN still reports the right f0
    /// with zero octave errors, and this gate discards the answer. See
    /// docs/superpowers/specs/2026-09-25-tuner-detection-layer-design.md §2.2.
    public static let fundamentalEnergyBase: Double = 0.004
    public static let highNoteEnergyBase: Double = 0.002

    /// The shipped value. `1.0` is the pre-2026-09-25 behaviour; Task 6 changes
    /// it from a measured sweep and records the decision table in RESULTS.md.
    public static let defaultFundamentalEnergyScale: Double = 1.0
```

and add, next to the other stored properties:

```swift
    /// See `fundamentalEnergyBase`. Instance state rather than a `static var` so
    /// the Task 6 sweep needs no global mutable state.
    public let fundamentalEnergyScale: Double

    public var fundamentalMinEnergyRatio: Double { Self.fundamentalEnergyBase * fundamentalEnergyScale }
    public var standardAmbiguityMinEnergyRatio: Double { Self.fundamentalEnergyBase * fundamentalEnergyScale }
    public var highNoteAmbiguityMinEnergyRatio: Double { Self.highNoteEnergyBase * fundamentalEnergyScale }
```

- [ ] **Step 4: Extend the initialiser**

```swift
    public init(
        sampleRate: Double = 44100.0,
        bufferSize: Int = 2048,
        minFrequency: Double = TunerConstants.detectorMinHz,
        maxFrequency: Double = TunerConstants.detectorMaxHz,
        fundamentalEnergyScale: Double = PitchDetector.defaultFundamentalEnergyScale
    ) {
        self.sampleRate = sampleRate
        self.bufferSize = bufferSize
        self.minFrequency = minFrequency
        self.maxFrequency = maxFrequency
        self.fundamentalEnergyScale = fundamentalEnergyScale
    }
```

- [ ] **Step 5: Update the three call sites**

`PitchDetector.swift:229` — inside the subharmonic loop, `Self.fundamentalMinEnergyRatio` becomes `fundamentalMinEnergyRatio`.

`PitchDetector.swift:259`:
```swift
        var ambiguousThresh = frequency > 300.0 ? highNoteAmbiguityMinEnergyRatio : standardAmbiguityMinEnergyRatio
        if hasPrior {
            ambiguousThresh *= 0.5
        }
```

`PitchDetector.swift:340`, inside `shouldPreferSubharmonic` — this is a method on the same type, so it can read the instance property directly:
```swift
        if evidence.candidateEnergy / power < fundamentalMinEnergyRatio {
            return false
        }
```

- [ ] **Step 6: Thread it through the session and the harness**

`TunerAnalysisSession`: add a stored `private let fundamentalEnergyScale: Double`, an initialiser parameter defaulting to `1.0`, and pass it at both detector construction sites (`:459` and the start-up path):

```swift
        let newlyCreated = PitchDetector(
            sampleRate: frame.sampleRate,
            bufferSize: frame.samples.count,
            fundamentalEnergyScale: fundamentalEnergyScale)
```

`AudioTestHelpers.replayTrace`: add `fundamentalEnergyScale: Double = 1.0` after `enableSpectralRecovery`, and pass it into the session:

```swift
        let session = TunerAnalysisSession(
            config: config, targets: targets, tracker: tracker,
            fundamentalEnergyScale: fundamentalEnergyScale)
```

- [ ] **Step 7: Run and verify it passes, plus the whole suite**

```bash
xcodebuild test -project StrumKit.xcodeproj -scheme StrumKit \
  -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath ./DerivedData \
  -only-testing:StrumKitTests/FundamentalEnergyScaleTests
xcodebuild test -project StrumKit.xcodeproj -scheme StrumKit \
  -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath ./DerivedData \
  -only-testing:StrumKitTests/RecordedAudioTests
```
Expected: 3 new tests pass; `RecordedAudioTests` still passes 10/10 — this change must be behaviour-preserving at scale 1.0.

- [ ] **Step 8: Commit**

```bash
git add StrumKit/Audio/PitchDetector.swift StrumKit/Audio/TunerAnalysisSession.swift \
        StrumKitTests/AudioTestHelpers.swift StrumKitTests/CoverageMatrixTests.swift
git commit -m "refactor(audio): make the fundamental-energy gate a single tunable

The three gates at PitchDetector:229, :259 and :340 reject correct YIN
detections - at 0.18% fundamental energy YIN reports the right f0 with zero
octave errors and the gate discards the answer. Sweeping them needs one knob.

They keep their 2:1 ratio to each other and scale together, so the high-note
threshold stays deliberately half the standard one. Instance state rather than
a static var, so the sweep needs no global mutable state. Scale 1.0 reproduces
today's behaviour exactly and RecordedAudioTests is unchanged."
```

---

### Task 6: Sweep the gate, select on measurement, validate once on seed B

**Files:**
- Modify: `StrumKitTests/CoverageMatrixTests.swift`
- Modify: `docs/tuner-reliability/RESULTS.md`
- Modify: `StrumKit/Audio/PitchDetector.swift` (the selected default, if it is not 1.0)

**Interfaces:**
- Consumes: `PitchDetector.fundamentalEnergyScale`, `CoverageMatrix.matrix(seed:)`, `AudioTestHelpers.replayTrace(_:fundamentalEnergyScale:)`, `countDisplayTransitions` from Tasks 2, 3, 5.
- Produces: `FundamentalEnergySweep.Result` (per-scale detect / octave / wrong-note rates), the selected `defaultScale`, and `FundamentalEnergySweep.VALIDATED` — a recorded fact that seed B has been consumed, which the guard test checks so it cannot be consumed twice.

- [ ] **Step 1: Write the sweep test**

```swift
/// Where the Phase 1 selection is recorded so the validation set cannot be
/// consumed twice. Lives with the tests because it is test provenance, not
/// shipped configuration.
enum FundamentalEnergySweep {
    /// The scale that was validated against seed B, or `nil` if that has not
    /// happened yet. `ContinuationHysteresisTests`-style guard tests compare this
    /// against `PitchDetector.defaultFundamentalEnergyScale`: if they ever
    /// diverge, a threshold was chosen by looking at the validation set.
    public static let VALIDATED_SCALE: Double? = nil
}

@Suite("Fundamental energy gate sweep")
struct FundamentalEnergySweepTests {

    /// Candidate scales, spec §5.1: {0.004-equivalent 1.0, then 1e-3, 3e-4, 1e-4, 0}.
    static let candidates: [Double] = [1.0, 0.25, 0.075, 0.025, 0.0]

    struct CellScore {
        let detected: Bool        // a fresh reading within 50 cents of truth
        let octaveError: Bool     // within 50 cents of truth +/- 1200
        let wrongNote: Bool       // fresh, but not within 50 cents and not an octave
    }

    static func score(_ cell: CoverageMatrix.Cell, scale: Double) -> CellScore {
        let audio = CoverageMatrix.signal(cell.case, rate: 44100, seconds: 3.0)
        let (frames, _) = AudioTestHelpers.replayTrace(
            samples: audio, sampleRate: 44100, config: cell.config,
            fundamentalEnergyScale: scale)
        var detected = false, octave = false, wrong = false
        for f in frames where f.displayState == "fresh" {
            guard f.rawFrequency > 0 else { continue }
            let cents = 1200 * log2(f.rawFrequency / cell.noteHz)
            if abs(cents) <= 50 { detected = true }
            else if abs(abs(cents) - 1200) <= 50 { octave = true }
            else { wrong = true }
        }
        return CellScore(detected: detected, octaveError: octave, wrongNote: wrong)
    }

    @Test("sweep every candidate on seed A and print the decision table")
    func sweepOnSeedA() {
        let cells = CoverageMatrix.matrix(seed: CoverageMatrix.SEED_A)
        var lines: [String] = []
        lines.append("ENERGY-SWEEP (seed A, \(cells.count) cells)")
        lines.append(String(repeating: "-", count: 64))
        lines.append("  scale  detected  octave  wrong   net")
        for scale in Self.candidates {
            let scores = cells.map { Self.score($0, scale: scale) }
            let det = scores.filter(\.detected).count
            let oct = scores.filter(\.octaveError).count
            let wrong = scores.filter(\.wrongNote).count
            // Octave errors are disqualifying; wrong notes are expensive.
            let net = det - 4 * oct - wrong
            lines.append(String(format: "  %5.3f  %8d  %6d  %5d  %4d",
                                scale, det, oct, wrong, net))
        }
        print(lines.joined(separator: "\n"))
    }

    @Test("the selected scale introduces no octave error relative to scale 1.0")
    func selectedScaleIsSafe() {
        let cells = CoverageMatrix.matrix(seed: CoverageMatrix.SEED_A)
        let selected = PitchDetector.defaultFundamentalEnergyScale
        guard selected != 1.0 else { return }
        let baselineOct = cells.filter { Self.score($0, scale: 1.0).octaveError }.count
        let chosenOct = cells.filter { Self.score($0, scale: selected).octaveError }.count
        #expect(chosenOct <= baselineOct,
                "scale \(selected) introduced \(chosenOct - baselineOct) octave errors")
    }

    @Test("seed B has been consumed exactly once and never re-tuned against")
    func seedBIsSingleUse() {
        // Recorded in RESULTS.md when the selection was validated. Once this is
        // non-nil, any later change to defaultFundamentalEnergyScale is a bug:
        // it would mean a threshold was chosen by looking at the validation set.
        let validated = FundamentalEnergySweep.VALIDATED_SCALE
        #expect(validated == nil || validated == PitchDetector.defaultFundamentalEnergyScale,
                "defaultFundamentalEnergyScale changed after seed B was validated "
                + "(validated \(String(describing: validated)), now "
                + "\(PitchDetector.defaultFundamentalEnergyScale))")
    }
}
```

- [ ] **Step 2: Run the sweep and read the table**

```bash
xcodebuild test -project StrumKit.xcodeproj -scheme StrumKit \
  -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath ./DerivedData \
  -only-testing:StrumKitTests/FundamentalEnergySweepTests 2>&1 | grep -A 10 "ENERGY-SWEEP"
```

Expected: a table with one row per candidate. **Read it. Do not pick the value now.**

- [ ] **Step 3: Choose the value, and only then**

Selection rule, in order:
1. Any candidate that raises the octave count above scale 1.0 is **disqualified**, regardless of detect rate.
2. Among survivors, take the highest detect count.
3. Among those, take the lowest wrong-note count.
4. If a lower scale ties on detect with a higher one, **prefer the higher one** — the gate exists for a reason and the smallest change that achieves the goal is the defensible one.

- [ ] **Step 4: Set the default and re-run**

```swift
// StrumKit/Audio/PitchDetector.swift — change the one line added in Task 5
    /// Selected on coverage-matrix seed A, validated once on seed B.
    /// See RESULTS.md §Phase 1 for the decision table.
    public static let defaultFundamentalEnergyScale: Double = <value chosen in Step 3>
```

The initialiser already defaults to this constant, so nothing else changes.

```bash
xcodebuild test -project StrumKit.xcodeproj -scheme StrumKit \
  -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath ./DerivedData \
  -only-testing:StrumKitTests/FundamentalEnergySweepTests \
  -only-testing:StrumKitTests/RecordedAudioTests \
  -only-testing:StrumKitTests/SpectralPitchScorerTests
```
Expected: sweep passes, and **both fixture suites still pass in isolation** with the numbers in `RESULTS.md` reproducing.

- [ ] **Step 5: Validate on seed B, once**

```swift
@Suite("Seed B validation")
struct SeedBValidationTests {
    @Test("the selected scale holds on the held-out validation set")
    func validateOnSeedB() {
        let cells = CoverageMatrix.matrix(seed: CoverageMatrix.SEED_B)
        let scale = PitchDetector.defaultFundamentalEnergyScale
        let det = cells.filter {
            FundamentalEnergySweepTests.score($0, scale: scale).detected
        }.count
        let base = cells.filter {
            FundamentalEnergySweepTests.score($0, scale: 1.0).detected
        }.count
        print("SEED-B detect scale=\(scale): \(det)/\(cells.count)  baseline scale=1.0: \(base)/\(cells.count)")
        #expect(det >= base, "the selected scale must not be worse than the baseline on seed B")
    }
}
```

Run it, record the number, then set:

```swift
    /// Set once, when the seed-B run in Step 5 was made. Consumed by the
    /// guard test so the validation set cannot silently become a training set.
    public static let VALIDATED_SCALE: Double? = <the scale whose Step 5 run you just recorded>
```

This is the one place in the plan where a value is filled in from a measurement
rather than written out in advance. It is deliberately so: the alternative is
picking the number before running the sweep, which is the failure this whole
phase exists to correct.

- [ ] **Step 6: Record the decision in RESULTS.md**

Append a `## Phase 1 — fundamental energy gate` section containing: the decision table from Step 2, the chosen value and the rule from Step 3 that chose it, the seed-B result from Step 5, and the `RESULTS.md` fixture numbers before and after.

- [ ] **Step 7: Commit**

```bash
git add StrumKit/Audio/PitchDetector.swift StrumKitTests/CoverageMatrixTests.swift \
        docs/tuner-reliability/RESULTS.md
git commit -m "perf(audio): retune the fundamental-energy gate from a measured sweep

The gate was rejecting correct YIN detections: at 0.18% fundamental energy YIN
reports the right f0 with zero octave errors and the gate discards it. Swept
five candidate scales across the coverage matrix on seed A, selected on
detect count with octave errors disqualifying and wrong notes penalised, then
validated once on the held-out seed B.

A guard test now fails if the default changes after seed B was read, so the
validation set cannot quietly become a training set."
```

---

## Phase 2 — Filter the estimate, upstream of the state machine

The one idea taken from WebTuna (`WEBTUNA.md` §3: a 0.75/0.25 EMA into a 7-entry median ring, both before any state decision). StrumKit's `displayCentsEma` sits *after* the fresh/held/recovered transitions, so every state change bypasses it.

### Task 7: Median ring on accepted frequencies

**Files:**
- Modify: `StrumKit/Audio/PitchTracker.swift:33-38` (constants), `:40-60` (state)
- Test: `StrumKitTests/DisplayStabilityTests.swift` (create)

**Interfaces:**
- Consumes: `PitchMath.centsBetween(measured:reference:)` (`StrumKit/Models/MusicalNote.swift`).
- Produces: `PitchTracker.medianRingSize`, `.medianRingAgreementCents`, `.medianRingMinAgreement`; private `filteredFrequency(_:) -> Double`. Tasks 8 and 9 call into the smoothed result; Task 10 resets the ring.

- [ ] **Step 1: Write the failing tests**

```swift
// StrumKitTests/DisplayStabilityTests.swift
import Foundation
import Testing
@testable import StrumKit

@Suite("Estimate-level filtering")
struct EstimateFilteringTests {

    private func steadyChain(
        frequencies: [Double], target: Double, hop: Double = 1024.0 / 44100.0
    ) -> [TunerReading] {
        let tracker = PitchTracker()
        let s = StringTarget(note: "A2", midi: 45, frequency: target, number: 2)
        tracker.reset(targetCount: 1)
        var out: [TunerReading] = []
        for (i, f) in frequencies.enumerated() {
            let at = Double(i + 1) * hop
            let r = PitchResult(frequency: f, closestNote: MusicalNote(midiNoteNumber: 45),
                                centsDeviation: 1200 * log2(f / target), confidence: 1.0,
                                amplitudeRMS: 0.05, isSignalPresent: true)
            if let reading = tracker.process(pitchResult: r, at: at,
                                            config: TunerConfig(mode: .manual, selectedString: 0),
                                            targets: [s]) {
                out.append(reading)
            }
        }
        return out
    }

    @Test("a single wild outlier does not move the displayed frequency")
    func outlierIsRejected() {
        let t = 110.0
        var seq = [Double](repeating: t, count: 8)
        seq[5] = t * 1.06          // 100 cents out, one frame
        let readings = steadyChain(frequencies: seq, target: t)
        let atOutlier = readings[4]
        #expect(abs(atOutlier.frequency - t) / t < 0.002,
                "median ring should hold the frequency through a one-frame outlier, "
                + "got \(atOutlier.frequency) Hz")
    }

    @Test("a sustained real change is followed immediately, not filtered out")
    func realChangePassesThrough() {
        let t = 110.0
        var seq = [Double](repeating: t, count: 6) + [Double](repeating: t * 1.06, count: 6)
        let readings = steadyChain(frequencies: seq, target: t)
        let last = readings.last!
        #expect(abs(1200 * log2(last.frequency / t) - 100) < 25,
                "a real 100-cent change must be followed, got "
                + "\(1200 * log2(last.frequency / t)) cents")
    }

    @Test("the ring is exactly the WebTuna size, for parity")
    func ringSizeMatchesWebTuna() {
        #expect(PitchTracker.medianRingSize == 7)
    }
}
```

- [ ] **Step 2: Run and verify it fails**

```bash
make project
xcodebuild test -project StrumKit.xcodeproj -scheme StrumKit \
  -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath ./DerivedData \
  -only-testing:StrumKitTests/EstimateFilteringTests
```
Expected: compile failure — `medianRingSize` is undefined.

- [ ] **Step 3: Add the constants and the ring**

In `StrumKit/Audio/PitchTracker.swift`, after `displayEmaTimeConstant`:

```swift
    /// Rolling window of recently accepted frequencies, filtered *before* the
    /// display EMA and before any fresh/held/recovered decision. Size and
    /// intent match WebTuna's 7-entry vote ring (docs/tuner-reliability/WEBTUNA.md
    /// §3) — the one idea adopted from that engine.
    public static let medianRingSize: Int = 7
    /// Entries must agree this closely for the median to be trusted.
    public static let medianRingAgreementCents: Double = 15.0
    /// Below this many agreeing entries the ring is bypassed, so a genuine
    /// string change is not smoothed away.
    public static let medianRingMinAgreement: Int = 3
```

and in the state block:

```swift
    private var frequencyRing: [Double] = []
```

- [ ] **Step 4: Add the filter**

```swift
    /// Records an accepted frequency and returns the value that should be
    /// displayed.
    ///
    /// Returns the ring median once `medianRingMinAgreement` entries agree
    /// within `medianRingAgreementCents`; otherwise returns `incoming`
    /// unchanged, so a real change to pitch breaks agreement and passes
    /// straight through rather than being filtered.
    private func filteredFrequency(_ incoming: Double) -> Double {
        guard incoming > 0 else { return incoming }
        frequencyRing.append(incoming)
        if frequencyRing.count > Self.medianRingSize { frequencyRing.removeFirst() }
        guard frequencyRing.count >= Self.medianRingMinAgreement else { return incoming }

        let sorted = frequencyRing.sorted()
        let median = sorted[sorted.count / 2]
        let agreeing = frequencyRing.filter {
            abs(PitchMath.centsBetween(measured: $0, reference: median))
                <= Self.medianRingAgreementCents
        }
        return agreeing.count >= Self.medianRingMinAgreement ? median : incoming
    }
```

- [ ] **Step 5: Apply it in `process`**

In `PitchTracker.process`, after the presence guard, replace

```swift
        let frequency = pitchResult.frequency
```
with
```swift
        // Filter the estimate before anything decides on it, so a single bad
        // frame cannot move the readout. See the class doc for why this is
        // upstream of the state machine rather than inside it.
        let frequency = filteredFrequency(pitchResult.frequency)
```

- [ ] **Step 6: Run and verify it passes, plus the tracker suite**

```bash
xcodebuild test -project StrumKit.xcodeproj -scheme StrumKit \
  -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath ./DerivedData \
  -only-testing:StrumKitTests/EstimateFilteringTests \
  -only-testing:StrumKitTests/PitchTrackerStateMachineTests
```
Expected: 3 new tests pass; all 17 existing tracker tests pass unchanged. The step-response and guided tests are the ones most likely to catch a regression here.

- [ ] **Step 7: Commit**

```bash
git add StrumKit/Audio/PitchTracker.swift StrumKitTests/DisplayStabilityTests.swift
git commit -m "feat(audio): filter the frequency estimate before any decision

A 7-entry median ring over accepted frequencies, applied upstream of the
display EMA and of the fresh/held/recovered decision. Size and intent match
WebTuna's vote ring - the single idea adopted from that engine.

The ring bypasses itself when fewer than three entries agree within 15 cents,
so a genuine string change passes straight through instead of being smoothed
away. That is the difference between a filter and a lag."
```

---

### Task 8: Asymmetric display EMA

**Files:**
- Modify: `StrumKit/Audio/PitchTracker.swift:38` (constant), and the EMA update site
- Test: `StrumKitTests/DisplayStabilityTests.swift`

**Interfaces:**
- Consumes: `medianRing*` from Task 7.
- Produces: `PitchTracker.displayEmaTimeConstantLowConfidence: TimeInterval = 0.120`. Task 9 uses it on the held path.

- [ ] **Step 1: Write the failing test**

Append to `EstimateFilteringTests`:

```swift
    @Test("a better estimate is adopted faster than a worse one")
    func asymmetricEma() {
        #expect(PitchTracker.displayEmaTimeConstantLowConfidence
                > PitchTracker.displayEmaTimeConstant,
                "the low-confidence constant must be the slower of the two")
        #expect(PitchTracker.displayEmaTimeConstant == 0.050)
        #expect(PitchTracker.displayEmaTimeConstantLowConfidence == 0.120)
    }
```

- [ ] **Step 2: Run and verify it fails**

```bash
xcodebuild test -project StrumKit.xcodeproj -scheme StrumKit \
  -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath ./DerivedData \
  -only-testing:StrumKitTests/EstimateFilteringTests
```
Expected: compile failure — the constant is undefined.

- [ ] **Step 3: Add the constant and use it**

```swift
    public static let displayEmaTimeConstant: TimeInterval = 0.050
    /// Slower on purpose. A recovered or held reading is 1-2 orders of
    /// magnitude less accurate than a YIN-confirmed one, so it should not move
    /// the needle as quickly. Asymmetric by intent: a better estimate deserves
    /// a faster response than a worse one.
    public static let displayEmaTimeConstantLowConfidence: TimeInterval = 0.120
```

At the EMA update site, replace the single `dt`-based alpha with:

```swift
        let tau = pitchResult.recovered
            ? Self.displayEmaTimeConstantLowConfidence
            : Self.displayEmaTimeConstant
        let alpha = 1.0 - exp(-dt / tau)
        displayCentsEma += alpha * (rawCents - displayCentsEma)
```

- [ ] **Step 4: Run and verify it passes**

```bash
xcodebuild test -project StrumKit.xcodeproj -scheme StrumKit \
  -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath ./DerivedData \
  -only-testing:StrumKitTests/EstimateFilteringTests \
  -only-testing:StrumKitTests/PitchTrackerStateMachineTests \
  -only-testing:StrumKitTests/TunerPresentationTests
```
Expected: all pass. The presentation tests assert on hold opacity and guidance text, so they are the check that the asymmetry did not leak into the wrong place.

- [ ] **Step 5: Commit**

```bash
git add StrumKit/Audio/PitchTracker.swift StrumKitTests/DisplayStabilityTests.swift
git commit -m "perf(audio): slow the display EMA for low-confidence estimates

A recovered reading carries 1-2 orders of magnitude more error than a
YIN-confirmed one, so it moves the needle at 120 ms instead of 50 ms. The
asymmetry is the point: a better estimate should be adopted faster than a
worse one."
```

---

### Task 9: The held reading reports the smoothed value, not a frozen raw one

`handleLostSignal` currently returns `cents: last.cents` with `displayCents: displayCentsEma`. The displayed value therefore jumps to whatever the EMA last held, which after a one-frame outlier is the outlier's tail. The held reading should carry the same smoothed number as the live path.

**Files:**
- Modify: `StrumKit/Audio/PitchTracker.swift:369-381` (`handleLostSignal`)
- Test: `StrumKitTests/DisplayStabilityTests.swift`

**Interfaces:**
- Consumes: `filteredFrequency(_:)` and `displayEmaTimeConstantLowConfidence` from Tasks 7, 8.
- Produces: nothing new. Changes what `handleLostSignal` returns.

- [ ] **Step 1: Write the failing test**

```swift
@Suite("Held readings carry the smoothed value")
struct HeldReadingSmoothingTests {

    @Test("a held reading's cents equal the EMA, not the last raw reading")
    func heldUsesSmoothed() {
        let tracker = PitchTracker()
        let t = 110.0
        let s = StringTarget(note: "A2", midi: 45, frequency: t, number: 2)
        tracker.reset(targetCount: 1)
        let config = TunerConfig(mode: .manual, selectedString: 0)
        let hop = 1024.0 / 44100.0

        var last: TunerReading?
        for i in 0..<8 {
            let at = Double(i + 1) * hop
            let f = t * (1 + 0.004)          // consistently ~7 cents sharp
            let r = PitchResult(frequency: f, closestNote: MusicalNote(midiNoteNumber: 45),
                                centsDeviation: 1200 * log2(f / t), confidence: 1.0,
                                amplitudeRMS: 0.05, isSignalPresent: true)
            last = tracker.process(pitchResult: r, at: at, config: config, targets: [s])
        }
        let fresh = last!
        #expect(abs(fresh.cents - fresh.displayCents) > 1.0,
                "precondition: the EMA should still be converging")

        // Signal lost. The held reading must keep showing the smoothed value.
        let heldAt = 9.0 * hop
        let lost = PitchResult.idle
        let held = tracker.process(pitchResult: lost, at: heldAt, config: config, targets: [s])
        let heldReading = held!
        #expect(heldReading.freshness == .held)
        #expect(abs(heldReading.cents - fresh.displayCents) < 1.0,
                "held cents \(heldReading.cents) should stay at the smoothed "
                + "\(fresh.displayCents), not snap to the raw \(fresh.cents)")
    }
}
```

- [ ] **Step 2: Run and verify it fails**

```bash
xcodebuild test -project StrumKit.xcodeproj -scheme StrumKit \
  -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath ./DerivedData \
  -only-testing:StrumKitTests/HeldReadingSmoothingTests
```
Expected: FAIL — the held reading reports `last.cents`, which is ~7 cents off the EMA.

- [ ] **Step 3: Fix `handleLostSignal`**

At `PitchTracker.swift:369-381`, change the constructed reading so `cents` and `frequency` are the *filtered* pair, not the raw one. Because the raw pair no longer matches the ring, recompute from the target:

```swift
        // 2. Evaluate display hold independently (readingHoldDuration = 1.0s)
        if elapsed <= Self.readingHoldDuration, let last = lastReading {
            feedbackState = .tracking
            // Hold the *filtered* value. Reporting `last.cents` here would snap
            // the display back to a pre-filter number the moment the signal is
            // lost, which is exactly the twitch this whole phase removes.
            let heldCents = displayCentsEma
            return TunerReading(
                at: now,
                lastFreshAt: last.lastFreshAt,
                frequency: last.target.frequency * pow(2.0, heldCents / 1200.0),
                note: last.note,
                target: last.target,
                targetIndex: last.targetIndex,
                cents: heldCents,
                displayCents: heldCents,
                freshness: .held,
                inTune: last.inTune,
                recovered: last.recovered
            )
        }
```

- [ ] **Step 4: Run and verify it passes, plus the presentation suite**

```bash
xcodebuild test -project StrumKit.xcodeproj -scheme StrumKit \
  -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath ./DerivedData \
  -only-testing:StrumKitTests/HeldReadingSmoothingTests \
  -only-testing:StrumKitTests/PitchTrackerStateMachineTests \
  -only-testing:StrumKitTests/TunerPresentationTests \
  -only-testing:StrumKitTests/RecordedAudioTests
```
Expected: all pass. `RecordedAudioTests` is the real check here — it asserts `Held` counts on the fixtures, and this change alters what held readings contain.

- [ ] **Step 5: Commit**

```bash
git add StrumKit/Audio/PitchTracker.swift StrumKitTests/DisplayStabilityTests.swift
git commit -m "fix(audio): hold the filtered cents value, not the last raw one

handleLostSignal reported last.cents alongside displayCentsEma, so the
moment the signal was lost the display snapped from the smoothed value back to
a pre-filter number - the twitch phases 2 and 3 exist to remove.

The held reading now derives frequency from the target and the smoothed cents,
so the two fields can never disagree."
```

---

## Phase 3 — Hysteresis and the one-way ratchet

### Task 10: Continuation hysteresis

Acquisition already has confirmation (`candidateCount`, `standardEvidenceSpan`). Continuation has none: one YIN failure engages recovery, and one success cancels it. On a monotonically decaying signal that oscillates every frame.

**Files:**
- Modify: `StrumKit/Audio/PitchTracker.swift:33-38` (constants), `:40-60` (state), the presence guard in `process`, and `handleLostSignal`
- Test: `StrumKitTests/DisplayStabilityTests.swift`

**Interfaces:**
- Consumes: `displayState(for:)` and `countDisplayTransitions(_:)` from Task 3.
- Produces: `PitchTracker.continuationFailureFrames: Int = 3`, `.continuationRecoveryFrames: Int = 2`, `consecutiveYinFailures: Int`, `consecutiveYinSuccesses: Int` (both `public private(set)`), and `shouldHoldThroughDropout: Bool`. Task 12 reads these from the session.

- [ ] **Step 1: Write the failing tests**

```swift
@Suite("Continuation hysteresis")
struct ContinuationHysteresisTests {

    /// Review Focus #1: a real string change while the previous one still rings.
    @Test("a genuine pitch change is followed promptly despite the failure counter")
    func realChangeNotDelayed() {
        let tracker = PitchTracker()
        let lowE = StringTarget(note: "E2", midi: 40, frequency: 82.4069, number: 6)
        let d3 = StringTarget(note: "D3", midi: 50, frequency: 146.8324, number: 3)
        tracker.reset(targetCount: 2)
        let config = TunerConfig(mode: .manual, selectedString: 0)
        let hop = 1024.0 / 44100.0
        var readings: [TunerReading] = []
        for i in 0..<24 {
            // Frames 0-11: low E present. Frame 12: two dropped frames (a
            // transient), then D3 from frame 15 on.
            let f: Double
            if i < 12 { f = 82.4069 }
            else if i < 14 { f = 0 }
            else { f = 146.8324 }
            let r: PitchResult = f > 0
                ? PitchResult(frequency: f, closestNote: MusicalNote(midiNoteNumber: f < 100 ? 40 : 50),
                              centsDeviation: 0, confidence: 0.95, amplitudeRMS: 0.05,
                              isSignalPresent: true)
                : .idle
            if let reading = tracker.process(pitchResult: r, at: Double(i + 1) * hop,
                                            config: config, targets: [lowE, d3]) {
                readings.append(reading)
            }
        }
        let after = readings.filter { $0.at >= 16.0 * hop }
        #expect(!after.isEmpty, "a real new note must be read")
        #expect(abs(after.last!.frequency - 146.8324) / 146.8324 < 0.01,
                "D3 must be followed, got \(after.last!.frequency) Hz")
    }

    /// Review Focus #2: a true dropout must still expire.
    @Test("a long dropout still expires past maxCandidateGap")
    func longDropoutExpires() {
        let tracker = PitchTracker()
        let s = StringTarget(note: "A2", midi: 45, frequency: 110, number: 2)
        tracker.reset(targetCount: 1)
        let config = TunerConfig(mode: .manual, selectedString: 0)
        let hop = 1024.0 / 44100.0
        for i in 0..<6 {
            let r = PitchResult(frequency: 110, closestNote: MusicalNote(midiNoteNumber: 45),
                                centsDeviation: 0, confidence: 0.95, amplitudeRMS: 0.05,
                                isSignalPresent: true)
            _ = tracker.process(pitchResult: r, at: Double(i + 1) * hop,
                                config: config, targets: [s])
        }
        // 0.5 s of silence: past the 250 ms candidate gap and the 1.0 s hold.
        let late = tracker.process(pitchResult: .idle, at: 6 * hop + 0.5,
                                   config: config, targets: [s])
        #expect(late == nil, "holding through a transient must not hold forever")
    }

    @Test("an alternating dropout pattern costs at most one transition")
    func alternatingDropoutIsHeld() {
        let tracker = PitchTracker()
        let s = StringTarget(note: "A2", midi: 45, frequency: 110, number: 2)
        tracker.reset(targetCount: 1)
        let config = TunerConfig(mode: .manual, selectedString: 0)
        let hop = 1024.0 / 44100.0
        var states: [String] = []
        for i in 0..<40 {
            // Every third frame drops. Pre-fix this is fresh/held/fresh/held/...
            let present = (i % 3) != 2
            let r: PitchResult = present
                ? PitchResult(frequency: 110, closestNote: MusicalNote(midiNoteNumber: 45),
                              centsDeviation: 0, confidence: 0.95, amplitudeRMS: 0.05,
                              isSignalPresent: true)
                : .idle
            if let reading = tracker.process(pitchResult: r, at: Double(i + 1) * hop,
                                            config: config, targets: [s]) {
                states.append(AudioTestHelpers.displayState(for: reading))
            }
        }
        let transitions = zip(states, states.dropFirst()).filter { $0 != $1 }.count
        print("HYSTERESIS alternating-dropout transitions = \(transitions)")
        #expect(transitions <= 1, "expected the dropout to be held, got \(transitions) transitions")
    }
}
```

- [ ] **Step 2: Run and verify it fails**

```bash
xcodebuild test -project StrumKit.xcodeproj -scheme StrumKit \
  -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath ./DerivedData \
  -only-testing:StrumKitTests/ContinuationHysteresisTests
```
Expected: at least `alternatingDropoutIsHeld` FAILs, printing a transition count well above 1.

- [ ] **Step 3: Add the constants and state**

```swift
    /// Continuation hysteresis. Acquisition already requires `candidateCount`
    /// and an evidence span; continuation required nothing, so a single YIN
    /// failure engaged recovery and a single success cancelled it. On a
    /// monotonically decaying signal that oscillates every frame.
    ///
    /// Asymmetric on purpose: falling back to a weaker estimator is sticky,
    /// returning to a stronger one is prompt. At 43.1 Hz, 3 frames is ~70 ms and
    /// 2 frames is ~46 ms.
    public static let continuationFailureFrames: Int = 3
    public static let continuationRecoveryFrames: Int = 2
```

```swift
    public private(set) var consecutiveYinFailures: Int = 0
    public private(set) var consecutiveYinSuccesses: Int = 0

    /// `true` while the current failure streak is too short to conclude the note
    /// is gone. Read by `TunerAnalysisSession` to decide whether a weaker
    /// estimate may take over.
    public var shouldHoldThroughDropout: Bool {
        consecutiveYinFailures < Self.continuationFailureFrames
    }
```

- [ ] **Step 4: Update the counters and the guard in `process`**

In `PitchTracker.process`, immediately before the presence guard:

```swift
        // Continuation hysteresis, counted on the *estimator* rather than on the
        // pitch: a recovery-sourced reading is a success for the pipeline but a
        // failure for YIN, and conflating them is what makes the state flap.
        if pitchResult.isSignalPresent && !pitchResult.recovered {
            consecutiveYinSuccesses += 1
            consecutiveYinFailures = 0
        } else {
            consecutiveYinFailures += 1
            consecutiveYinSuccesses = 0
        }
```

and replace the presence guard:

```swift
        guard pitchResult.isSignalPresent && frequency >= TunerConstants.detectorMinHz else {
            // Hold through a short dropout: one or two bad frames in a decaying
            // signal are not a lost note. `maxCandidateGap` still bounds how
            // long this can last, so a genuine loss expires.
            return handleLostSignal(at: now, rms: pitchResult.amplitudeRMS,
                                    isTransient: shouldHoldThroughDropout)
        }
```

- [ ] **Step 5: Make `handleLostSignal` transient-aware**

```swift
    private func handleLostSignal(
        at now: TimeInterval,
        rms: Double = 0,
        isTransient: Bool = false
    ) -> TunerReading? {
        if !isTransient {
            // A real loss ends any guided hold and invalidates the candidate.
            guidedHoldStartTime = nil
            if (now - candidateLastSeenAt) > Self.maxCandidateGap {
                candidateKey = nil
                candidateCount = 0
                candidateFirstSeenAt = 0
                candidateLastSeenAt = 0
                candidateIsOnset = false
            }
        }
        lastRms = rms
        // ... the prior-expiry and display-hold blocks below are unchanged ...
```

- [ ] **Step 6: Run and verify it passes**

```bash
xcodebuild test -project StrumKit.xcodeproj -scheme StrumKit \
  -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath ./DerivedData \
  -only-testing:StrumKitTests/ContinuationHysteresisTests \
  -only-testing:StrumKitTests/PitchTrackerStateMachineTests \
  -only-testing:StrumKitTests/RecordedAudioTests
```
Expected: 3 new tests pass, including `HYSTERESIS ... transitions = 1` or 0. All 17 tracker tests and 10 recorded-audio tests still pass. **If `PitchTrackerStateMachineTests` regresses, the hysteresis is too sticky — raise `continuationRecoveryFrames` before doing anything else.**

- [ ] **Step 7: Commit**

```bash
git add StrumKit/Audio/PitchTracker.swift StrumKitTests/DisplayStabilityTests.swift
git commit -m "fix(audio): add continuation hysteresis so a decay does not flap

Acquisition required three frames and a 40 ms evidence span. Continuation
required nothing: one YIN failure engaged recovery, one success cancelled it.
On a monotonically decaying signal that oscillates every frame, which is the
reported symptom.

Asymmetric by intent - three frames (70 ms) to fall back to a weaker
estimator, two (46 ms) to return to a stronger one. Counted on the estimator,
not the pitch: a recovery-sourced reading succeeds for the pipeline but fails
for YIN, and conflating them is what makes the state flap.

maxCandidateGap still bounds the hold, so a genuine loss expires."
```

---

### Task 11: One-way ratchet — recovery may not displace a live fresh reading

`RESULTS.md` §1 establishes the premise: *a plucked string's fundamental is constant while it decays*. So while a YIN-confirmed reading is younger than the hold window, a recovered reading may extend the note's life but must not replace its frequency.

**Files:**
- Modify: `StrumKit/Audio/PitchTracker.swift` (new public query)
- Modify: `StrumKit/Audio/TunerAnalysisSession.swift:512-540` (`applySpectralRecovery`)
- Test: `StrumKitTests/DisplayStabilityTests.swift`

**Interfaces:**
- Consumes: `PitchTracker.readingHoldDuration`, `continuityPrior` from Task 10's file.
- Produces: `PitchTracker.hasLiveFreshReading(at now: TimeInterval) -> Bool`. Task 12 depends on this existing.

- [ ] **Step 1: Write the failing test**

```swift
@Suite("Recovery cannot displace a live fresh reading")
struct RecoveryRatchetTests {

    /// Review Focus #3: the ratchet must still extend liveness.
    @Test("a ratcheted recovery still reports a reading rather than going silent")
    func ratchetStillExtendsLiveness() {
        let tracker = PitchTracker()
        let t = 110.0
        let s = StringTarget(note: "A2", midi: 45, frequency: t, number: 2)
        tracker.reset(targetCount: 1)
        let config = TunerConfig(mode: .manual, selectedString: 0)
        let hop = 1024.0 / 44100.0
        var freshAt: TimeInterval?
        for i in 0..<6 {
            let r = PitchResult(frequency: t, closestNote: MusicalNote(midiNoteNumber: 45),
                                centsDeviation: 0, confidence: 0.95, amplitudeRMS: 0.05,
                                isSignalPresent: true)
            if let reading = tracker.process(pitchResult: r, at: Double(i + 1) * hop,
                                            config: config, targets: [s]),
               reading.freshness == .fresh {
                freshAt = reading.at
            }
        }
        let now = 6.5 * hop
        #expect(tracker.hasLiveFreshReading(at: now), "precondition: fresh reading is live")

        // Past the hold window it must stop protecting the frequency.
        #expect(!tracker.hasLiveFreshReading(at: now + 2.0))
        #expect(freshAt != nil)
    }

    @Test("held readings do not count as a live fresh reading")
    func heldIsNotLive() {
        let tracker = PitchTracker()
        let s = StringTarget(note: "A2", midi: 45, frequency: 110, number: 2)
        tracker.reset(targetCount: 1)
        let config = TunerConfig(mode: .manual, selectedString: 0)
        let hop = 1024.0 / 44100.0
        for i in 0..<6 {
            let r = PitchResult(frequency: 110, closestNote: MusicalNote(midiNoteNumber: 45),
                                centsDeviation: 0, confidence: 0.95, amplitudeRMS: 0.05,
                                isSignalPresent: true)
            _ = tracker.process(pitchResult: r, at: Double(i + 1) * hop,
                                config: config, targets: [s])
        }
        // Four consecutive failures: past continuationFailureFrames, so this
        // produces a held reading rather than a transient hold.
        var last: TunerReading?
        for i in 0..<4 {
            last = tracker.process(pitchResult: .idle, at: 7 * hop + Double(i) * hop,
                                   config: config, targets: [s])
        }
        if let last, last.freshness == .held {
            #expect(!tracker.hasLiveFreshReading(at: last.at),
                    "a held reading must not protect the frequency from recovery")
        }
    }
}
```

- [ ] **Step 2: Run and verify it fails**

```bash
xcodebuild test -project StrumKit.xcodeproj -scheme StrumKit \
  -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath ./DerivedData \
  -only-testing:StrumKitTests/RecoveryRatchetTests
```
Expected: compile failure — `hasLiveFreshReading(at:)` is undefined.

- [ ] **Step 3: Add the query to `PitchTracker`**

```swift
    /// `true` while a YIN-confirmed reading is younger than `readingHoldDuration`.
    ///
    /// While this holds, a weaker estimate may extend the note's life but must
    /// not replace its frequency: `RESULTS.md` §1 establishes that a plucked
    /// string's fundamental is constant while it decays, so the last confirmed
    /// value is the better estimate and the recovery value is the noisier one.
    public func hasLiveFreshReading(at now: TimeInterval) -> Bool {
        guard let last = lastReading, last.freshness == .fresh, !last.recovered else {
            return false
        }
        return (now - last.lastFreshAt) <= Self.readingHoldDuration
    }
```

- [ ] **Step 4: Apply the ratchet in `applySpectralRecovery`**

In `TunerAnalysisSession.applySpectralRecovery`, after the separation guard and before `nearestMidi`:

```swift
        // One-way ratchet. A YIN-confirmed reading that is still live owns the
        // frequency; this estimate may only keep the note alive. See
        // PitchTracker.hasLiveFreshReading.
        let now = frame.captureEndSeconds
        if tracker.hasLiveFreshReading(at: now), let anchored = PitchMath.nearestMidi(
            for: prior.frequency, a4: config.a4) {
            pitchResult = PitchResult(
                frequency: prior.frequency,
                closestNote: MusicalNote(midiNoteNumber: anchored.midi, referenceA4: config.a4),
                centsDeviation: anchored.cents,
                // Still capped below the 0.75 foreground threshold: the *evidence*
                // is recovered even though the number is the confirmed one, and the
                // ambient-floor learner must not treat this as a fresh foreground.
                confidence: min(0.70, candidate.score / 2.0),
                amplitudeRMS: currentRms,
                isSignalPresent: true,
                recovered: true
            )
            return
        }
```

`applySpectralRecovery` needs the frame's timestamp. Add a `captureEnd: TimeInterval` parameter, passed from the call site at `TunerAnalysisSession.swift:512`:

```swift
    private func applySpectralRecovery(
        analysis: SpectralPitchScorer.WindowAnalysis,
        prior: (frequency: Double, at: TimeInterval),
        config: TunerConfig,
        currentRms: Double,
        captureEnd: TimeInterval,
        to pitchResult: inout PitchResult
    ) {
```

and at the call site add `captureEnd: frame.captureEndSeconds,`.

- [ ] **Step 5: Run and verify it passes**

```bash
xcodebuild test -project StrumKit.xcodeproj -scheme StrumKit \
  -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath ./DerivedData \
  -only-testing:StrumKitTests/RecoveryRatchetTests \
  -only-testing:StrumKitTests/SpectralPitchScorerTests \
  -only-testing:StrumKitTests/RecordedAudioTests
```
Expected: 2 new tests pass. `SpectralPitchScorerTests` is the sensitive one — `RECOVERY-BIAS` will move, and the tests assert a bound, so read the printed bias before and after. It should move *toward* 0, which is the point of the change.

- [ ] **Step 6: Commit**

```bash
git add StrumKit/Audio/PitchTracker.swift StrumKit/Audio/TunerAnalysisSession.swift \
        StrumKitTests/DisplayStabilityTests.swift
git commit -m "fix(audio): stop recovery from displacing a live fresh reading

A plucked string's fundamental is constant while it decays - RESULTS.md §1
established that, and the YIN anchor validates it. So while a YIN-confirmed
reading is younger than the hold window, the recovery estimate may keep the
note alive but must not replace its frequency. It was replacing it, by up to
13.7 cents on quiet_g, every time it fired.

Confidence stays capped below the 0.75 foreground threshold: the evidence is
recovered even when the number is the confirmed one, and the ambient-floor
learner must not read this as fresh foreground."
```

---

### Task 12: Gate recovery on continuation state, then measure G1

The session currently decides on a bare per-frame `yinFailed`. It should ask the tracker, which now knows the streak.

**Files:**
- Modify: `StrumKit/Audio/TunerAnalysisSession.swift:497-540`
- Test: `StrumKitTests/DisplayStabilityTests.swift`

**Interfaces:**
- Consumes: `PitchTracker.consecutiveYinFailures`, `.continuationFailureFrames`, `hasLiveFreshReading(at:)` from Tasks 10, 11.
- Produces: the G1 measurement. No new public API.

- [ ] **Step 1: Write the failing test**

```swift
@Suite("Goal G1: decay stability")
struct DecayStabilityTests {

    /// Review Focus #4: inharmonicity, the axis no recorded fixture touches.
    @Test("every coverage-matrix cell stays within one transition after acquisition")
    func matrixStability() {
        // The controller ruling on this plan: assert on one representative cell per axis
        // tag and print the full matrix, because a 40-cell pass in Debug is minutes long
        // and a gate that cannot finish is not a gate. The full print is pasted into
        // RESULTS.md for human review.
        let byTag = Dictionary(grouping: CoverageMatrix.matrix(seed: CoverageMatrix.SEED_A),
                               by: { $0.label.split(separator: "-").first.map(String.init) ?? $0.label })
        for (tag, cells) in byTag.sorted(by: { $0.key < $1.key }) {
            let cell = cells[0]
            let audio = CoverageMatrix.signal(cell.case, rate: 44100, seconds: 3.0)
            let (frames, _) = AudioTestHelpers.replayTrace(
                samples: audio, sampleRate: 44100, config: cell.config)
            let t = AudioTestHelpers.countDisplayTransitions(frames)
            print("G1 [\(tag)/\(cell.label)] transitions=\(t) of \(cells.count) cells")
            #expect(t <= 1, "\(cell.label) made \(t) display transitions; G1 allows 1")
        }
        // The dropout family is the primary G1 gate (spec §6) and lives in the
        // replay harness, not in CoverageMatrix.matrix. See Task 3b.
    }
}
```

- [ ] **Step 2: Run it and record the pre-gate number**

```bash
xcodebuild test -project StrumKit.xcodeproj -scheme StrumKit \
  -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath ./DerivedData \
  -only-testing:StrumKitTests/DecayStabilityTests 2>&1 | grep "^G1 "
```
Expected: several cells above 1. **Paste this table into `RESULTS.md` as the pre-change G1 baseline.**

- [ ] **Step 3: Gate recovery on the streak**

In `TunerAnalysisSession.performAnalysis`, replace:

```swift
            let yinFailed = !pitchResult.isSignalPresent || pitchResult.frequency <= 0
```
with:
```swift
            // Ask the tracker, which counts the streak, rather than deciding from
            // a single frame. `yinFailed` alone made the whole pipeline flip on
            // and off every frame through a decay.
            let yinFailed = tracker.shouldHoldThroughDropout
```
and leave `yinJumped` as it is — a jump is a different signal and is not the
symptom.

- [ ] **Step 4: Run and verify it passes**

```bash
xcodebuild test -project StrumKit.xcodeproj -scheme StrumKit \
  -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath ./DerivedData \
  -only-testing:StrumKitTests/DecayStabilityTests \
  -only-testing:StrumKitTests/ContinuationHysteresisTests \
  -only-testing:StrumKitTests/RecoveryRatchetTests \
  -only-testing:StrumKitTests/EstimateFilteringTests \
  -only-testing:StrumKitTests/HeldReadingSmoothingTests
```
Expected: all pass. Every `G1 [...]` line reads `transitions=0` or `1`.

If cells still exceed 1, do **not** loosen the assertion. Find which state is oscillating from the `displayState` sequence and fix the cause — most likely the recovery gate is still engaging between the 3-frame streak and the hold expiry.

- [ ] **Step 5: Run the whole gate set and paste the results into RESULTS.md**

```bash
xcodebuild test -project StrumKit.xcodeproj -scheme StrumKit \
  -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath ./DerivedData \
  -only-testing:StrumKitTests/RecordedAudioTests \
  -only-testing:StrumKitTests/SpectralPitchScorerTests \
  -only-testing:StrumKitTests/DecayStabilityTests \
  -only-testing:StrumKitTests/SeedBValidationTests
```

Then re-run the head-to-head from Task 4 Step 3 and record whether G2 (detect rate and time-to-first-reading ≥ WebTuna) held.

- [ ] **Step 6: Commit**

```bash
git add StrumKit/Audio/TunerAnalysisSession.swift \
        StrumKitTests/DisplayStabilityTests.swift docs/tuner-reliability/RESULTS.md
git commit -m "fix(audio): gate spectral recovery on the continuation streak

The session decided whether to invoke recovery from a single frame's
yinFailed flag. It now asks the tracker, which counts the streak, so recovery
engages once per decay phase instead of once per frame.

Records the G1 result: every coverage-matrix cell within one display
transition, with the pre-change table kept for comparison."
```

---

## Definition of done for this plan

- [ ] `G1` — every coverage-matrix cell ≤ 1 display transition; recorded before and after.
- [ ] `G2` — head-to-head detect rate and time-to-first-reading ≥ WebTuna, re-run and recorded.
- [ ] `G3` — `RecordedAudioTests` and `SpectralPitchScorerTests` pass in isolation with `RESULTS.md` numbers reproducing or improving.
- [ ] `G4` — every constant introduced here has a seed-A number and a one-time seed-B confirmation in `RESULTS.md`; the seed-B guard test passes.
- [ ] Review Focus 1–5 each have a test that fails if the behaviour regresses.
- [ ] The `SWIFT_OPTIMIZATION_LEVEL=-O` full-suite run completes, or the `SIGKILL` is recorded as still-open (G5 belongs to the Phase 6 plan, not this one).

## Not in this plan

Spec Phases 4–7, to be planned separately: recovery prior-anchoring at 15 ¢ (Phase 4), the `maxDetuningCents` 200 → 300 change and its stranded-note table (Phase 5), the FFT-based autocorrelation for YIN's difference function (Phase 6), and window-follows-pitch plus the sub-16 kHz capability signal and the `SpectralNoiseFilter` deletion (Phase 7).
