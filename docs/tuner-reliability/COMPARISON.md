# StrumKit vs. WebTuna — algorithm comparison

Two guitar tuners, compared stage by stage. WebTuna is GuitarTuna's production web engine,
fully reverse-engineered in [`WEBTUNA.md`](WEBTUNA.md) with the harness in
[`webtuna/`](webtuna/). This document is about the *algorithms*.

Every StrumKit number is read from the code or from the test suite; every WebTuna number is
measured by running the real wasm. Sources are labelled. Nothing here is estimated.

---

## 1. The one-sentence difference

**StrumKit asks "is this waveform periodic, and at what lag?" WebTuna asks "which f0 best
explains the energy at f0, 2·f0, 3·f0 … ?"**

That single choice explains almost every behavioural difference below — including the two
places where WebTuna is better and the one place StrumKit is much better.

---

## 2. Pipeline, side by side

| Stage | **StrumKit** | **WebTuna** |
|---|---|---|
| Capture | `AVAudioEngine` tap, requested 1024 frames, `setPreferredIOBufferDuration(0.020)`, session mode **`.measurement`** (disables AGC and the voice high-pass), cardioid polar pattern when the hardware offers it | `AudioWorkletProcessor`, hard-coded 4096-sample buffer, no DSP in the worklet |
| Framing | ring buffer → trailing `requiredInputSamples` = 4328 @ 44.1 kHz = **98.1 ms**; short windows on start-up | 4096 non-overlapping per call, **2048 hop** → 2 FFT frames/call |
| Rate | polyphase-sinc resample 44.1 k → **16 kHz** (97 taps, 256 phases, cutoff `min(0.45, 6400/rate)`), 1536 samples = 96 ms | native rate, no resampling |
| DC | explicit mean subtraction | implicit — the filterbank discards bins 0–6 |
| Window | `0.54 − 0.46·cos(2πn/1535)` | `0.54 − 0.46·cos(2πn/4095)` (verified to 3·10⁻⁸ in the live heap) |
| **Primary estimator** | **YIN** — difference function + CMNDF, 14…320 lags, threshold 0.15 attack / 0.25 sustain | **Salience** over a 56-band log filterbank |
| Band structure | 56 **ERB** bands, 50–6400 Hz, used for *whitening* only | 56 **log** bands, 65–5465 Hz centres, ratio 1.055377 = **91.4 ¢/band**, ±1-band triangles — this *is* the analysis resolution |
| Secondary | Klapuri-2006 harmonic summation over the whitened bands — **recovery only** | none |
| Candidate grid | 15 pts/semitone = **6.67 ¢**, 50–1100 Hz, 1245 points | 15 pts/semitone = **6.67 ¢**, bounded by the tuning |
| String prior | in the **tracker**, post-hoc: nearest string within 200 ¢, 20 ¢ hysteresis, else `.ambiguous` | in the **search**: the candidate grid is bounded by the tuning, so a string is always chosen |
| Octave handling | explicit arbitration over f0/2, /3, /4 using CMNDF residual + Hann-projection energy | implicit in the harmonic sum; harmonic-support ratio test per peak |
| Confidence | YIN periodicity `1 − CMNDF`, plus an elapsed-evidence-span confirmation | `InTuneRatio` = agreeing-frame counter / 15 |
| In-tune | hysteresis **5 ¢** enter / **7 ¢** exit (2/3 in precision mode) | **±12 ¢** fixed, 10 ¢ chromatic |
| Verdict latency | **one confirmed frame** | **14 further calls ≈ 1.15 s** |
| A4 | **415–466 Hz, user-calibratable**, threaded through every path | 440 Hz hard-coded in three places |
| Range | 50–1100 Hz | 37.7–6115 Hz |
| Cost | YIN 0.38 ms median, spectral scorer 2.32 ms median and only on recovery frames (RESULTS.md §6) | 2 wasm FFT frames per 4096 samples |

They share three things, which is not coincidence — both descend from one DSP lineage: the
0.54/0.46 window, the 15-points-per-semitone grid, and the 56-band count. But the 56 bands do
completely different jobs: **whitening** in StrumKit, **resolution** in WebTuna.

---

## 3. Where StrumKit is better, and why

### 3.1 Frequency resolution — the biggest gap

| Path | Resolution floor | Measured |
|---|---|---|
| StrumKit YIN | continuous lag interpolation | **0.00 – 0.02 ¢** median, ≤0.01 ¢ p95 on clean tones |
| StrumKit spectral | 6.67 ¢ grid | worst single recovered frame **7.3 – 13.7 ¢** |
| WebTuna | 6.67 ¢ grid, on a 91.4 ¢ filterbank | **0 – +5 ¢** steady state, biased positive on every string |

StrumKit has *two* resolutions and uses the good one for the number that matters. WebTuna has
one, and its ±3.3 ¢ quantisation floor is present by construction — the positive bias on
E2/A2/G3 is that floor showing through.

A direct comparison on identical signals: E2 82.4069 Hz gives StrumKit **−0.005 ¢** and
WebTuna **+5.0 ¢**; A2 110.0 Hz gives **+0.009 ¢** and **+3.0 ¢**. That is a factor of
500–1000 on the primary path.

### 3.2 The confidence value means something

`PitchTracker` uses `confidence` (= `1 − CMNDF`, a genuine periodicity quality measure) for
two real decisions: the ambient-floor foreground test (`≥ 0.75`) and guided-string completion
(`≥ 0.85` and not recovered).

WebTuna's `InTuneRatio` cannot be used that way. `counter/15` says "we have agreed for N
frames" — it carries **no evidence about quality**. A confidently-wrong lock and a clean lock
ramp it identically. That is why WebTuna needs the separate `MicRms` and `CanHearANote` flags,
and why its chromatic mode has no way to express doubt.

### 3.3 Latency, and the shape of the latency budget

| | StrumKit | WebTuna |
|---|---|---|
| Update rate | **43.1 Hz** | 10.8 Hz decisions / 21.5 FFT frames per second |
| First reading | **~46 ms** (the start-up path analyses a short window natively before the 98 ms window is available) | **279 ms** — the first two calls always return `CanHearANote == false` |
| In-tune verdict | **~46 ms** — a threshold on the confirmed frame | **1.30 s** |
| String completed (guided) | 1.0 s *continuous* hold | 1.30 s ratio ramp |

WebTuna computes 21.5 FFT frames per second and then makes one decision per 92.9 ms, and
gates that decision on a 15-step counter. **~1.15 s of its latency is structural waste.**
StrumKit's ratio is 28× better on the verdict and its cadence is 4× finer, which is what makes
a 50 ms display EMA (`displayEmaTimeConstant`) the right smoothing constant — at WebTuna's
10.8 Hz it would be useless.

### 3.4 A real trust boundary

`recoveredMayAssertInTune = false` is a genuinely good product decision, and it is
evidenced rather than asserted: 101 recovered frames across four fixtures, **0 over-claimed
in-tune, 0 advice emissions**, and the recovered value is rendered at 0.55 opacity so the
user can see it is inferred. WebTuna cannot make this distinction at all — a decaying pluck
and a fresh one are indistinguishable in its output, and it will say "Tune down" at the 15 ¢
of decay-induced bias it measured on a realistic pluck.

### 3.5 Calibration, and everything downstream of it

A4 ∈ [415, 466], persisted, and threaded through `midiFrequency`, `nearestMidi`, the target
table *and* `applySpectralRecovery`. WebTuna hard-codes 440 with no hook. At A4 = 432 Hz
StrumKit is correct and WebTuna is 7.85 ¢ wrong everywhere.

### 3.6 Explicit DC removal

StrumKit subtracts the mean. WebTuna gets it free by discarding bins below 37.7 Hz. Both work
— but StrumKit's is deliberate and also protects the path that has no high-pass at all
(YIN's difference function happens to be DC-immune, which is luck, not design). StrumKit
tolerates a DC offset to ±2.0; WebTuna fails at 5.0.

---

## 4. Where WebTuna is better, and why

### 4.1 It can acquire a fundamental autocorrelation cannot see

This is the one real algorithmic gap, and it is physical rather than parametric.

YIN needs the waveform to repeat at the fundamental period. Salience sums energy across the
harmonic series, so a candidate whose 1st harmonic is nearly absent still scores on its 2nd,
3rd and 4th. Measured on a tone with h1 at **0.014 % energy** (285× below StrumKit's
`fundamentalMinEnergyRatio` floor of 0.004): **WebTuna detects it, at +13 ¢.**

`RESULTS.md` §4 already states the consequence honestly: below 0.004 YIN abstains, and
**spectral recovery cannot rescue it, because recovery requires an already-accepted
continuity prior.** So StrumKit's spectral path contributes *nothing* to acquisition — it can
only extend a note YIN already found.

The scope matters, though. StrumKit's *tested* weak-fundamental case (`weakf0_E2`, h1 = 0.06)
has a fundamental energy share of 2.9 %, which is **7× above** its own 0.4 % floor. The suite
has not actually probed the region where the two architectures diverge most. Closing that
measurement gap is cheap and should come before any engine change.

### 4.2 A positive "wrong string" hint

`PossibleWrongStringId` reports the string you probably meant, while still keeping
`CurrentString` on your selection and showing the true (large) cents error:

| played | selected | `CurrentString` | `TuningErrorCents` | suggestion |
|---|---|---|---|---|
| E2 | B3 | 1 | −1897 ¢ | **5** (E2) |
| E2 | E4 | 0 | −2397 ¢ | **5** |
| C4 | E2 | 5 | +1999 ¢ | **1** (B3, nearest) |
| C4 | B3 | 1 | +99 ¢ | −1 (already nearest) |

StrumKit has only the negative form — `.ambiguous` and the 200 ¢ gate. This is the single
best UX idea in the WebTuna engine and it is cheap: nearest string to the measured pitch,
reported alongside the selection.

### 4.3 Scale invariance without a gate

WebTuna has **no absolute level gate at all**. `CanHearANote` held down to `MicRms = 0.0042`
(≈ −48 dBFS); level is used only to *normalise* the salience, so loud input cannot saturate
the decision. StrumKit is more sensitive at the bottom (floor 6·10⁻⁵ ≈ −84 dBFS) but has an
adaptive gate on top, which is the right idea for a real room and introduces a failure mode
WebTuna does not have (§5.7).

---

## 5. Defects in StrumKit's algorithm

Ordered by how much they could hurt a player.

### 5.1 The spectral path cannot acquire

`applySpectralRecovery` requires `prior != nil`, `!isOnset`, and
`captureEndSeconds − prior.at ≤ 0.85 s`. Every one of those is defensible on its own — and
together they mean the 56-band machinery never sees a note for the first time. Given WebTuna
demonstrates the spectral approach *can* acquire down to 0.014 % energy, this is the gap worth
closing, and the two honest options are:

- **(a) Do nothing, and say so in the UI copy.** Zero risk, and it makes an existing
  limitation legible instead of mysterious.
- **(b) Add a prior-free spectral acquisition path** with its own, much stricter gate than
  the recovery path has — a higher score floor, a larger `spectralRecoveryMinHarmonics`, and
  mandatory agreement across two consecutive frames. This is the version that can get the
  weak-fundamental coverage WebTuna has.

If (b), freeze the thresholds first and hold out a validation set before running it.
`RESULTS.md` §8 already records that this discipline was not honoured for the recovery
thresholds.

### 5.2 The recovery path cannot resolve better than ~7 ¢

Inherent to a 6.67 ¢ grid — YIN avoids it by interpolating on a continuous axis. Two
improvements that stay within the architecture:

- The grid score is never re-evaluated at the refined frequency. `refinedScore` comes from
  parabolic interpolation of the *neighbouring grid scores*, but by then the individual
  harmonic positions have already been snapped to a grid step. Re-scoring the candidate at
  `gridFreq` using `estimateFundamental`'s peak positions would tighten this.
- `gridPointsPerSemitone` could go to 30 or 60 **for the recovery path only**, at 2×/4× the
  grid loop. Recovery runs on a minority of frames (2.32 ms median, and only when YIN fails or
  jumps during sustain), so this is far cheaper here than it would be as a primary estimator.

### 5.3 Recovery bias is written into the continuity prior

`RESULTS.md` §1 measures it: on `quiet_a` the YIN anchor is +0.91 ¢ and the recovered
estimate averages **−3.06 ¢**. `applySpectralRecovery` replaces `pitchResult.frequency`
outright, and `PitchTracker.process` then writes that into `continuityPrior` — which feeds
`PitchDetector`'s subharmonic arbitration (`priorSubharmonicMaxDistanceCents` 35 ¢) *and*
halves the ambiguity threshold. So a ~4 ¢ bias propagates into the next 0.85 s of YIN
refinement. The bias is bounded and tested, but the mechanism is a slow random walk rather
than a convergence, and **no test asserts the prior does not drift over a long sustain.**

### 5.4 Whitening still moves under the ranking, even though localisation was fixed

`RESULTS.md` §1 fixed the real bug (localising off the whitened spectrum). But the *gain
curve itself* is still recomputed from every window and normalised by the median of the
"active" bands, so the quantity `spectralRecoverySeparationRatio = 1.25` is measured against a
moving reference — and the measured margin is only 1.36–1.44×. A note that decays changes
which bands count as active, which changes `normRefGain`, which changes every candidate's
score. The 1.25 threshold was picked from that moving distribution rather than from a
sweep (`RESULTS.md` §7 says the sweep was not run), which is the weakest link in the
acceptance chain.

Fixing this properly means making the rank signal stationary: normalise by a slowly-adapting
reference rather than a per-window median, or rank on the unwhitened spectrum and use
whitening only for the harmonic-support test.

### 5.5 Subharmonic arbitration only ever divides

`candidateMultipliers = [2, 3, 4]`, all divisors of the YIN answer. That correctly repairs
the common "h1 missing, YIN locks 2·f0" case. There is no protection in the other direction:
if YIN's first trough is *below* the true f0 (a strong sub-subharmonic from a neighbouring
string bleeding in), nothing raises it. The `+1` octave candidate is absent by design and the
comment does not say why, so this reads as an omission rather than a decision.

### 5.6 The YIN inner loop is the only non-vectorised hot path

`PitchDetector.detectPitch` runs `maxLag × span` = 320 × 1216 ≈ **389 000 scalar `Double`
iterations per frame** in a hand-written nested loop with bounds checking. Every other stage
in the codebase uses Accelerate — `vDSP_rmsqv`, `vDSP_meanv`, `vDSP_vsadd`, `vDSP_vmul`,
`vDSP_fft_zrip`, `vDSP_zvmags`, `vDSP_vsmul` — and `HannProjection` is called 5× per frame
with its own `cos`/`sin` loop.

This is a correctness-of-construction issue, not a style one: it is why the Debug test build
is roughly an order of magnitude slower than the optimised one, and the DSP budget is
dominated by a loop that vDSP could do in a fraction of the time. `vDSP_conv` /
`vDSP_vsq`-style primitives, or a `withUnsafeBufferPointer` loop over contiguous memory, would
recover most of it.

### 5.7 The ambient-floor tracker can learn from a decay

`ambientFloor` is updated with α = 0.05 on any frame that is not foreground
(`isSignalPresent && frequency ≥ 50 && confidence ≥ 0.75`) once 0.35 s has passed without a
foreground frame. During a deep decay YIN stops being foreground, so **the decay's own RMS
starts raising the noise floor**, which raises `recommendedNoiseGate`, which cuts the decay
further. The `maxAmbientFloor` cap of 0.015 (−36 dBFS) bounds the damage and the 0.85 s prior
grace usually expires first, but the loop is real and there is no fixture that exercises a
*very* quiet sustain late in a recording. WebTuna has no equivalent because it has no gate.

### 5.8 Auto mode has a ±50 ¢ dead zone at every string midpoint

`maxDetuningCents = 200` rejects any pitch further than 200 ¢ from every string. Between two
strings 5 semitones apart that leaves a 100 ¢-wide hole centred on the geometric midpoint:

| between | dead zone | notes stranded |
|---|---|---|
| E2 82.41 – A2 110.00 | 92.50 – 98.00 Hz | **F♯2, G2** |
| A2 110.00 – D3 146.83 | 123.47 – 130.81 Hz | C♯3, D3 |
| D3 – G3 | 164.81 – 174.61 Hz | F3, F♯3 |
| G3 196.00 – B3 246.94 | *(none — 4 semitones apart)* | — |
| B3 246.94 – E4 329.63 | 277.18 – 293.66 Hz | D4, D♯4 |

A player tuning *down* from A2 passes through G2 and F♯2 and gets "ambiguous" rather than
"Tune down to E2". Arguably correct — those pitches genuinely are between two strings — but
it is a 100 ¢ band per gap and it should be a conscious choice rather than a side effect of
one constant. 300 ¢ closes every hole at the cost of a looser assignment.

### 5.9 Smaller items

- **`estimateFundamental` mixes two frequency bases.** `SpectralPitchScorer.swift:411`
  iterates `candidateGrid[m].queries` (built from the *unrefined* `f0`) while line 412
  computes `hFreq = query.h * gridFreq` from the *refined* frequency. Inert in practice
  (`delta` is clamped to ±3.33 ¢, and the only harmonic-count boundary is at 1066.7 Hz where
  the gained harmonic is above the 6115 Hz ceiling anyway), but the two should come from the
  same point.
- **Below 16 kHz input silently disables recovery.** `Resampler.resampleWindow` returns
  `nil` for `inputRate < 16 000`, and `analyzeAudio` then returns `nil`. Not a corruption —
  the hard-coded `binResolutionHz = 16000/4096` is never applied to mis-scaled audio — but on
  an 8 kHz Bluetooth HFP input the recovery path is simply off, and `PitchDetector` falls
  back to a 192 ms window at the raw rate. `AudioCaptureService` passes `.allowBluetoothHFP`,
  so this is reachable, and it fails silently rather than reporting reduced capability.
- **`SpectralNoiseFilter` is dead code.** 99 lines, never instantiated anywhere in the app or
  the tests. It is also not a working spectral filter — `observeFrame` bins *time-domain
  samples* by index as if they were frequency bins, and `denoise` applies a per-sample gain
  using that same time index. `PitchTracker` already does adaptive gating, so there is no
  functional gap, only wrong code that looks load-bearing. Delete it.
- **A fixed 96 ms window is 10× too long for the high E.** The window length is set by
  `maxLag` (the *lowest* supported frequency), so a 330 Hz note is analysed through 96 ms of
  audio that is almost entirely its own decay. WebTuna shares this limitation (93 ms for
  everything). A short second window for high notes, or an adaptive one, would improve
  high-string decay tracking on both.

---

## 6. What I would change, in order

1. **Measure the gap before closing it** (§4.1). Extend `weakf0_*` down through 1 %, 0.4 %,
   0.1 % and 0.014 % fundamental energy. Today the suite stops 7× above the floor, so the
   claim "we cannot acquire a missing fundamental" is untested at the boundary that matters.
2. **Decide on prior-free spectral acquisition** (§5.1) — build it with a much stricter gate
   than recovery has, or document the limitation in the UI copy. Either is defensible;
   leaving it implicit is not.
3. **Vectorise the YIN difference function** (§5.6). It is the only un-vectorised hot path in
   an otherwise Accelerate-based pipeline, and it is why the Debug test build is ~10× slower
   than the optimised one.
4. **Add the wrong-string hint** (§4.2). Nearest string to the measured pitch, reported
   alongside the selection. Cheap, and it is the best idea in the WebTuna engine.
5. **Make the whitening reference stationary** (§5.4) and then run the ratio sweep
   `RESULTS.md` §7 says was skipped, with the validation set held out (§8).
6. **Add the two missing tests**: no prior drift across a long sustain (§5.3), and a very
   quiet late decay (§5.7).
7. **Reconsider `maxDetuningCents`** (§5.8) as a deliberate product decision, with the
   stranded-note table above as the input.
8. Delete `SpectralNoiseFilter` (§5.9). Uncontroversial.

---

## 7. Note on the evidence base

`RESULTS.md`'s numbers all reproduce exactly when the fixture suites are run on their own
(verified: `RecordedAudioTests` 10/10 in 222 s, `SpectralPitchScorerTests` 11/11 in 134 s,
every `BASELINE`, `TASK5-GATE`, `RECOVERY-BIAS`, `RECOVERY-CONTRACT`, `WEAK-FUNDAMENTAL` and
`ACCURACY` line matching). The **unfiltered** `xcodebuild test` does not complete: the test
host is killed with `SIGKILL` partway through, and reports the unfinished tests as failures.
It reproduces both with and without `-parallel-testing-enabled NO`, so it is not a Swift
Testing concurrency artefact. `SWIFT_OPTIMIZATION_LEVEL` is not set in `project.yml`, so
`make test` builds Debug at `-Onone` — where §5.6's 389 000-iteration scalar loop runs roughly
an order of magnitude slower, which is the most likely cause and the easiest thing to test
next. Until that is resolved the numbers above are reproducible but not continuously verified.
