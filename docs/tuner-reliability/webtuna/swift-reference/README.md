# WebTuna — a Swift reference port of GuitarTuna's `WebTuna.wasm`

## What this is

A standalone Swift implementation of the pitch engine behind
`guitartuna.com/online-guitar-tuner`, written from the reverse engineering in
[`../WEBTUNA.md`](../WEBTUNA.md) and from `wasm-decompile` output.

## What this is **not**

**This is not a proposed change to StrumKit, and nothing here should become
one.** It is a *reference*: a readable, instrumented, independently buildable
copy of somebody else's algorithm, kept for two reasons.

1. To check the reverse engineering. A report that says "the filterbank is
   56 bands with ±1-band support" is a claim; a port that can be run against the
   original is a test of that claim. This port has already falsified three
   separate statements in `WEBTUNA.md` (§Fidelity below, and `NOTES.md`).
2. To run experiments. "Swap a constant, see what breaks, understand *why* it
   works" needs a place to do that which is not our production detector.

Nothing in `StrumKit/` imports this package, this package does not import
`StrumKit`, and it builds with SwiftPM rather than through `project.yml` or
`StrumKit.xcodeproj` so that it keeps compiling while those are being edited.

## Layout

| Path | What |
|---|---|
| `Package.swift` | Standalone SwiftPM manifest, macOS 12+, links Accelerate |
| `Sources/WebTunaReference/Tuning.swift` | The compiled-in guitar tuning, tolerances, `stringIdx` modes |
| `Sources/WebTunaReference/EngineTables.swift` | §3.3 filterbank tables, §3.5 candidate grid |
| `Sources/WebTunaReference/FrameGeometry` (in `SpectrumAnalyser.swift`) | §3.1 geometry, §3.1 window |
| `Sources/WebTunaReference/SpectrumAnalyser.swift` | §3.3 windowed FFT → magnitude spectrum |
| `Sources/WebTunaReference/Filterbank.swift` | §3.3 56-band filterbank, §3.4 salience |
| `Sources/WebTunaReference/CandidateAnalysis.swift` | §3.5 resample onto the grid, §3.6 harmonic score |
| `Sources/WebTunaReference/WebTunaReferenceEngine.swift` | §3.2 framing, §3.6 peak pick, §3.6–3.8 state machine, §1.4 output |
| `Sources/WebTunaReference/DetectorState.swift` | The state fields, each tagged with the engine field it corresponds to |
| `Sources/WebTunaReference/CoverageMatrix.swift` | Bit-exact port of `xeng.mjs`'s `buildSignal` + FNV-1a |
| `Sources/WebTunaReference/Conformance.swift` | Field-by-field comparison against the recorded oracle |
| `Tools`/`tools/*.mjs` | Read-only probes and the oracle-trace recorder |
| `Fixtures/` | Recorded oracle output, signal manifest |
| `DIVERGENCES.md` | Every place the port does not match, and why |
| `NOTES.md` | The three places `WEBTUNA.md` surprised me |

## Building and testing

```bash
cd docs/tuner-reliability/webtuna/swift-reference
swift build
swift test
```

`swift test` needs **neither node nor the wasm**. Everything it compares against
is a committed fixture of recorded output numbers.

## Fetching the wasm (only needed to *regenerate* the fixtures)

`WebTuna.wasm` is Yousician's intellectual property and is **not committed**,
here or one directory up. It lives at `docs/tuner-reliability/webtuna/WebTuna.wasm`
and is gitignored there.

```bash
cd docs/tuner-reliability/webtuna
curl -o WebTuna.wasm https://guitartuna.com/webtuna/WebTuna.wasm
shasum -a 256 WebTuna.wasm
# 14ec8582a5cd1becfc8597fbc8bec75d2361f57522046ffdb0fbafc9394508bd
```

`tools/oracle-trace.mjs` refuses to run against a binary with a different
SHA-256, and records the one it used in the trace, so a fixture can never
silently drift onto a different build.

### Regenerating

Run from the `webtuna/` directory — `iso.mjs` reads `./WebTuna.wasm` relative to
the process cwd.

```bash
cd docs/tuner-reliability/webtuna

# Fixtures/oracle-trace.json — 40 cells x 32 calls of the real engine's output.
node swift-reference/tools/oracle-trace.mjs > swift-reference/Fixtures/oracle-trace.json

# Fixtures/intermediates.json — the engine's own spectrum and 56-float arrays.
node swift-reference/tools/probe-intermediates.mjs > swift-reference/Fixtures/intermediates.json
```

Read-only probes, useful when investigating a divergence:

| Tool | What it answers |
|---|---|
| `tools/probe-fields.mjs` | Which engine field is which, by watching it change against the JSON |
| `tools/probe-fft.mjs` | The spectrum's normalisation and whether it is a magnitude or a power |
| `tools/probe-intermediates.mjs` | The engine's internal 1136-float spectrum and 56-float arrays |

None of them writes to the engine's memory; they only read.

## Conformance: how the comparison is made trustworthy

Two independent gates, in this order.

**1. The signals are provably identical.** `CoverageMatrix.signal(for:)` is a
line-by-line port of `xeng.mjs`'s `buildSignal`, including the three separate
float32 rounding points (envelope write, noise add, final scale) and the noise
LCG. `SignalParityTests` asserts that the FNV-1a checksum of the Swift samples
equals the `sig` the *oracle run* recorded, for all 40 cells. There is no
tolerance: either the bytes match or the two generators have drifted, and if
they have, every other number in the suite is meaningless.

This gate caught a real bug. The four noisy cells initially disagreed because
`out[i] *= Float(scale)` rounds `scale` to float32 and then multiplies in
float32, whereas JavaScript promotes both to double and rounds once. The other 36
cells matched bit-for-bit, which is also the evidence that Swift's `sin`/`exp`
agree with V8's on these arguments.

**2. The oracle output is recorded, not recomputed.** `Fixtures/oracle-trace.json`
is the real module's output for the same 40 cells, 32 calls each, 1280 calls
total, plus the SHA-256 of the binary that produced it.

## Fidelity, stage by stage

"exact" = verified against the running module or the live heap. "within
tolerance" = the stated tolerance, with the reason. "divergent" = does not match;
see `DIVERGENCES.md`.

| # | Stage | Status | Evidence |
|---|---|---|---|
| 1 | Framing — 4096/call, 2048 hop, 2 frames, ring shift | **exact** | Warm-up boundary identical on 40/40 cells; `StageTests.testFrameGeometry` |
| 2 | Window — `0.54 − 0.46·cos(2πn/4095)`, symmetric | **within tolerance** | 1 float32 ulp (1.19e-7) of the closed form, exactly symmetric. WEBTUNA.md's 3e-8 is against the *live* vector, which is not committed |
| 3 | FFT — 4096 real → 8192 complex, magnitude/8192 | **exact** | Spectrum matches the engine's 1136 floats to 1e-5 relative; `MicRms` then matches on **1280/1280** calls within 1e-4 |
| 4 | 56-band log filterbank | **divergent** | Cannot be verified: the engine's internal 56-float array could not be identified. D6 |
| 5 | Salience — cube-root and residual | **within tolerance** | The `a[k]`/`i[k]` relation is confirmed against the engine's own arrays to 1.3e-7; the *input* to it is D6 |
| 6 | Candidate grid, resample, harmonic score | **divergent** | Grid and its base-MIDI transform are exact; the resample and the harmonic index mapping are not. D6 |
| 7 | State — EMA, ring, stability, `InTuneRatio`, `MicRms`, `PossibleWrongStringId` | **divergent** | `MicRms` and `PossibleWrongStringId` exact; `CanHearANote` 85.5 %, `CurrentString` 3.3 %, `InTuneRatio` 45.5 %. D7 |
| 8 | Output — the nine fields, both quantisations | **within tolerance** | Field mapping and both quantisations implemented as the code does them, including the `rint` that WEBTUNA.md calls a `floor` (D1). `TuningErrorCents` 18 % exact because its target string is wrong, not its quantisation |

### The measured conformance numbers

40 cells × 32 calls = **1280 calls**, `swift test --filter ConformanceTests`:

```
CanHearANote   exact        1095/1280  85.5%
CurrentString  exact          42/1280   3.3%
InTuneRatio    exact         582/1280  45.5%
MeasuredPitchMidi exact      792/1280  61.9%
PossibleWrongStringId exact 1262/1280  98.6%
TuningErrorCents exact       231/1280  18.0%
MicRms         within 1e-4  1280/1280 100.0%
warm-up boundary (first-heard call) identical  40/40
max |ΔHz| where the oracle reported a pitch: 441.000   (criterion 1 Hz — NOT MET)
```

### Tolerances, and why each one

| Comparison | Tolerance | Why |
|---|---|---|
| Signal checksums | **none** | float32 samples and the same operation order; either the bytes match or the generators drifted |
| Window | 1.19e-7 abs | one float32 ulp. WEBTUNA.md's 3e-8 is against the engine's own sin/cos polyfill, which is not committed; asserting tighter would be asserting libm and that polyfill round identically |
| Spectrum | 1e-5 rel **or** 2e-8 abs | vDSP vs Ooura compute the same DFT in a different order, so they differ in the last couple of float32 ulps. The absolute arm exists because the high bins are pure float32 round-off in *both* — a flat ~1.3e-6 noise floor with a ~1e-9 between-implementation spread. A relative-only test there would be asserting that two FFTs agree on their own rounding error |
| `MicRms` | 1e-4 rel | inherited from the spectrum sum; two orders above the measured 1.9e-5 |
| `MeasuredPitchHz` | **1 Hz, not met** | the field's own quantisation is ±0.5 Hz, so 1 Hz is the floor; the port's worst case is 441 Hz. Not relaxed |
| `CanHearANote`, `CurrentString`, `InTuneRatio` | **none, not met** | these are integers or `k/15`; there is no defensible tolerance. Asserted only as regression floors at the measured values, each labelled |

The regression floors in `ConformanceTests.testConformanceSummaryAndRegressionFloors`
are the numbers this port achieves today, rounded down. They exist so that an
improvement is visible and a regression is caught. They are not claims of
fidelity, and raising them to make the suite green would defeat the purpose of
the exercise.

## Using it

```swift
import WebTunaReference

let engine = WebTunaReferenceEngine(sampleRate: 44_100)   // one per case: it is stateful
var result = WebTunaResult.stub
var s = 0
while s + 4096 <= audio.count {
    result = engine.analyse(Array(audio[s..<s + 4096]), stringIndex: -1)  // -1 auto, -2 chromatic
    s += 4096
}
```

The ABI is a hard 4096-sample call (§1.1) and the engine is a stateful singleton
with no reset (§5.10), so construct a fresh engine per case.

## The YIN measurement

`docs/tuner-reliability/webtuna/yinvsalience.mjs` measures that YIN finds the
correct f0 down to a fundamental carrying 0.00 % of the energy. **This port does
not reproduce that measurement in Swift** — it was left out rather than half-done,
because it is a measurement of *our* detector rather than part of the WebTuna
port, and getting it right would have meant reverse-engineering a second engine
with the budget already spent on the first. The existing measurement stands on
its own; what is missing is an independent re-derivation of it, which is a
reasonable follow-up and is *not* evidence for or against anything in this
directory.
