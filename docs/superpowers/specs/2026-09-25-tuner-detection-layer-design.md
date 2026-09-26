# Tuner detection layer — redesign spec

**Date:** 2026-09-25
**Status:** draft for review
**Supersedes:** nothing. Extends `docs/tuner-reliability/RESULTS.md` (StrumKit measurements)
and `docs/tuner-reliability/COMPARISON.md` + `WEBTUNA.md` (GuitarTuna's engine).

---

## 1. Summary

StrumKit's pitch algorithm is sound. Two measurements taken while preparing this spec
reframed the work:

1. **YIN is not weak on weak fundamentals.** At StrumKit's own parameters it reports the
   correct f0 with zero octave errors down to a fundamental carrying 0.00 % of the energy.
2. **A gate in `PitchDetector` is discarding those correct answers.** `fundamentalMinEnergyRatio`
   rejects 6/6 of them, and prevents zero octave errors in doing so.

So the primary estimator stays. Every fix in this spec is in the layer above it: the gates,
the filtering, and the state transitions. The only real algorithmic change is replacing
YIN's `O(maxLag × span)` difference-function loop with an FFT-based autocorrelation, which
is the same computation done faster.

The flapping symptom — *"when the note is decaying it loses and acquires it quickly"* — is
not a detector problem. It is one un-hysteretic binary decision per frame driving three
state flips at once, on a signal whose SNR is falling monotonically.

**This spec does not copy GuitarTuna.** It adopts one idea (filter the estimate continuously,
upstream of any decision) and rejects the rest. §9 lists what we are deliberately not doing.

**Decomposition.** Phases 0–3 are one coherent unit: you cannot measure the flapping without
Phase 0, and Phases 2 and 3 are two halves of the same fix. Phases 4–5 are threshold changes
that depend on Phase 0's sweep. Phases 6–7 are independent performance and cleanup work that
can be dropped without affecting G1–G3. If this needs to ship in more than one cycle, cut
after Phase 3.

---

## 2. Evidence

### 2.1 YIN vs. salience on fundamental strength and SNR

Reference YIN at StrumKit's parameters (16 kHz, 1536-sample window, lags 14–320, CMNDF
threshold 0.15, StrumKit's own energy gate applied), low E 82.4069 Hz, 12 trials per cell.
Reproduce with `webtuna/yinvsalience.mjs`.

| h1 weight | fundamental energy | YIN lag found | YIN f0 correct | octave errors | YIN **accepted** | WebTuna heard |
|---:|---:|:---:|:---:|:---:|:---:|:---:|
| 1.0 | 22.14 % | 12/12 | 12/12 | 0 | 12/12 | 12/12 |
| 0.3 | 10.57 % | 12/12 | 12/12 | 0 | 12/12 | 12/12 |
| 0.1 | 1.89 % | 12/12 | 12/12 | 0 | 12/12 | 12/12 |
| 0.03 | 0.18 % | 12/12 | 12/12 | 0 | **0/12** | 12/12 |
| 0.01 | 0.02 % | 12/12 | 12/12 | 0 | **0/12** | 12/12 |
| 0.004 | 0.00 % | 12/12 | 12/12 | 0 | **0/12** | 12/12 |

YIN fails only at 0 dB SNR, where it finds no trough at any fundamental strength. WebTuna
survives 0 dB at 10–12/12. That single cell is GuitarTuna's only measured advantage on this
axis, and it is a signal-to-noise result, not a weak-fundamental one.

**Caveat, and it matters:** these signals are perfectly harmonic. Real strings are not —
partials are stretched by `fₙ = n·f₀·√(1 + B·n²)`, and that, not a weak fundamental, is what
classically degrades autocorrelation on strings. Phase 0 measures that axis (§6) before any
threshold is changed.

### 2.2 The acceptance gate rejects valid detections

`fundamentalMinEnergyRatio = 0.004` and its two siblings are applied at three call sites in
`PitchDetector`. **Corrected after implementation review:** this section originally claimed all
three reject the §2.1 detections, and that was wrong. The three sites are not equivalent, and
the direction of each threshold is not the same.

| Site (post-Task-5 line numbers) | Role | Polarity when the scale falls |
|---|---|---|
| `shouldPreferSubharmonic` (`:402`) | accepts a lower candidate | **more permissive** — relaxes an acceptance test |
| ambiguity threshold (`:321`) | flags a note as ambiguous | **more permissive** — relaxes an acceptance test |
| `candidateEvidence` bit (`:291`) | **suppresses a veto**, not a preference: the bit sets `isAmbiguous` unless the selected multiplier divides the candidate's | **less permissive** — arms the veto |

So lowering the scale moves two acceptance thresholds and one veto in opposite directions, and
the optimum is interior. Neither endpoint is "the permissive one". This is why the sweep must
read the whole table rather than pick an endpoint, and why `net = detected - 4*octave - wrong`
is a better summary than raw detect count.

**Which site actually causes the §2.1 rejections:** only the ambiguity threshold (`:321`). The
subharmonic search probes `f0/2`, `f0/3` and `f0/4` — the *sub-octave*, not the second
harmonic, which is `2*f0` and above. The whole `h1-` axis is built on 82.4069 Hz, so all three
candidates fall below `TunerConstants.detectorMinHz = 50` and the loop is skipped entirely. The
§2.1 cells therefore never execute the subharmonic gate at all, and their accept/reject split
(1.89 % accepted, 0.18 % rejected, straddling the 0.004 floor) is the ambiguity threshold's
signature. The rejections are real and the thresholds are the cause; the mechanism is not the
one originally claimed.

Per §2.1 the gates reject 6/6 correct detections below 1.89 % fundamental energy and prevent
no octave errors at any strength tested.

### 2.3 The flapping mechanism

`TunerAnalysisSession.performAnalysis` computes `yinFailed` from a single frame
(`!pitchResult.isSignalPresent || frequency <= 0`) and, on that basis alone, engages recovery.
`applySpectralRecovery` then **replaces `pitchResult` wholesale**. One flip drives three
things at once:

| Flip | Observable |
|---|---|
| `fresh` ↔ `held` | `holdOpacity` animates 1.0 ↔ 0.4; the needle dims and brightens |
| YIN value ↔ recovery value | needle steps up to 14 ¢ and back (measured worst recovered frame: 9.6 ¢ quiet_a, 13.7 ¢ quiet_g) |
| foreground ↔ non-foreground | recovery caps `confidence` at 0.70, below the 0.75 foreground threshold, so the ambient-floor learner stutters |

`RESULTS.md` §1 establishes the premise that makes the third fix possible: *"a plucked
string's fundamental is constant while it decays."*

### 2.4 WebTuna filters the estimate, StrumKit filters the state

`WEBTUNA.md` §3: a 0.75/0.25 pitch EMA feeding a **7-entry median/mode vote ring**, both
upstream of any state decision, and a continuous score rather than a boolean. StrumKit's
`displayEmaTimeConstant` sits *after* the fresh/held/recovered transitions, so every state
change bypasses it. This is the one structural idea worth taking.

---

## 2.5 The dominant defect, found on a real recording (added 2026-09-26)

The user supplied a real recording — four strings strummed **in sequence**, with room noise,
21.95 s at 48 kHz. Measured on both engines. This reorders everything below.

| config | heard | display transitions | strums detected |
|---|---:|---:|---|
| ukulele auto + recovery (**production**) | 90 % | **75** | **4/4, right string** |
| chromatic + recovery | 91 % | 112 | 4/4 |
| **GuitarTuna, chromatic** | — | **0 string switches** | 4/4 |

**Detection was never the problem.** StrumKit finds every strum and names the right string.
The defect is display stability: 75 transitions against 0.

**The mechanism.** The first strum's segment is an exact tie — **72 frames reported as G4, 72
frames as E4.** G4 is correct (390.8–395.1 Hz at confidence 0.98–0.999). Then YIN returns
302.6–356.5 Hz, which is **136 ¢ from E4 and comfortably inside the 200 ¢ `maxDetuningCents`
acquisition gate**, so `PitchTracker`'s auto-mode search reassigns the display to E4 and holds it
for 0.98 s. A reverb tail is being displayed as a valid string match. The existing 20 ¢
hysteresis bonus cannot help: it is 116 ¢ short of the error it would have to absorb.

Supporting: **25 of 73 non-`none` runs last ≤ 2 frames** (median 107 ms), stable at ~34 % across
every vocabulary and 47 % in chromatic. Recovery accounts for only 5 of the 75. And StrumKit is
**3.6× better than GuitarTuna on the loud attack** (sd 0.139 vs 0.500 Hz) and 5–10× worse on
sustains, discarding the good answer.

**What this adds to the design.** Two *continuation* tolerances, which the original phases did
not contain. A plucked fundamental does not move during its own decay — `RESULTS.md` §1 already
asserts this and the YIN anchor validates it at +0.91 ¢ — so:

- **Assignment stickiness.** While a target is live, a reading more than
  `continuationMaxDetuningCents` from *that* target may not be reassigned to a different string.
  The wide 200 ¢ window stays for **acquisition**, where a genuinely flat string needs it.
- **Frequency continuity.** While a target is live, a measured frequency more than
  `continuationMaxFrequencyCents` from the continuity prior is held at the prior rather than
  followed.
- **A breach counter.** Both produce a *hold*, not a rejection, so tuning a string while holding
  it still works: once the disagreement persists for `continuationBreachFrames`, the new value
  wins. This is the same shape as the phase-3 continuation counters, applied to the value rather
  than only to the estimator's success.

Thresholds start at 50 ¢, chosen because a real drift during one decay is single-digit cents
and 50 ¢ is an order of magnitude beyond that. They are a **chosen value, not a derived one**,
and the sweep is deferred — the same honesty Task 4's `extraVoiceWeight` now carries.

**Consequence for the phases.** The median ring is demoted: it bypasses itself when entries
disagree by > 15 ¢, and a 50/50 G4/E4 split is maximal disagreement, which is exactly when it
stands aside. The ratchet is demoted: recovery is 5 of 75 transitions. Continuation hysteresis
is promoted. And chromatic mode being *worst* (112 transitions, 47 % short runs) is the
confirmation — it is the only mode with no string prior, so the prior is the stabiliser and the
gate is the weakness.

**The real recording becomes a permanent gate.** Synthetic cells cannot reproduce a strum
sequence with decay tails and room noise, so this file is the acceptance test for stability, and
it is the one the user actually cares about.

## 3. Goals

- **G1** No `fresh ↔ held ↔ recovered` flapping during a decay. Target: ≤ 1 transition per
  note on the fixture suite and the coverage matrix.
- **G2** Detection at least as good as WebTuna across the coverage matrix, on detect rate
  and time-to-first-reading.
- **G3** No regression in frequency accuracy. The existing 0.00 ¢ median / ≤0.01 ¢ p95 gates
  on clean tones must still pass.
- **G4** Every acceptance constant in the pipeline cites a number from a held-out validation
  set that was not used to choose it.
- **G5** The Debug test build completes the whole suite. **This is a hypothesis, not a
  confirmed diagnosis.** Observed: the unfiltered `xcodebuild test` kills the test host with
  `SIGKILL` partway through and reports the unfinished tests as failures; it reproduces both
  with and without `-parallel-testing-enabled NO`, so it is not a Swift Testing concurrency
  artefact; and both fixture suites pass in isolation with every `RESULTS.md` number
  reproducing. `SWIFT_OPTIMIZATION_LEVEL` is unset in `project.yml`, so `make test` builds
  `-Onone`, where Phase 6's inner loop is an order of magnitude slower. Phase 6 will confirm
  or refute this. It is listed here because it is a real gate on trusting the other numbers,
  not because the cause is established.

## 4. Non-goals

- Replacing YIN.
- Supporting bass, 12-string, or mandolin. `detectorMinHz`/`MaxHz` and the 16 kHz analysis
  rate stay as they are.
- Changing the UI, modes, presets, or guided-mode semantics.
- Porting any of GuitarTuna's fixed constants. Where a number is adopted, it is adopted
  because it was measured on StrumKit's own signals, not because WebTuna uses it.

---

## 5. Changes

Ordered. Each phase is independently shippable and independently gated. Phases 0–3 are the
core; 4–7 are cleanup and can be dropped without affecting G1–G3.

### Phase 0 — Measurement infrastructure (blocks everything)

Nothing below can be gated without this, and `RESULTS.md` §7/§8 record that thresholds were
previously chosen without a sweep.

- **0.1 Coverage matrix generator.** A deterministic synthetic generator in
  `AudioTestHelpers` covering: fundamental strength (h1 = 1.0 … 0.004), SNR (∞, 20, 12, 6,
  0 dB), **inharmonicity coefficient B (0, 1e-4, 5e-4, 2e-3)**, attack sharpness, level
  (−60 … −6 dBFS), decay rate, and polyphony (1–3 strings, including the E2+F♯2 semitone
  pair that defeats WebTuna).
- **0.2 Transition counter.** `replayTrace` already returns per-frame records. Add a
  `transitions` count — the number of `freshness`/`recovered` state changes — to the *harness*
  frame record, not to the public `TunerReading` model, and emit it in every `BASELINE` line.
- **0.3 Head-to-head harness.** Restore the cross-engine trace emitter
  (`webtuna/xeng.mjs` + a `CrossEngineComparisonTests` counterpart) so both engines consume
  the same signals. WebTuna's compiled-in tuning is a 6-string guitar, so ukulele and
  chromatic cases run through `stringIdx = -2`.
- **0.4 Held-out validation set.** Generate the matrix twice from two fixed seeds. Seed A is
  the tuning set; **seed B is the validation set and no threshold may be chosen from it.**
  A test asserts that every constant in §5.2–§5.5 has a recorded seed-A number next to it.

**Gate:** all four exist and the matrix runs end to end in both engines.

### Phase 1 — Sweep the energy gate

- **1.1** Make `fundamentalMinEnergyRatio`, `standardAmbiguityMinEnergyRatio` and
  `highNoteAmbiguityMinEnergyRatio` one tunable, swept over {0.004 (current), 1e-3, 3e-4,
  1e-4, 0} on seed A across the matrix.
- **1.2** Select on: detect rate (max), octave-error rate (must stay 0), wrong-string rate
  (max). The current value is the baseline to beat.
- **1.3** Record the selected value and its seed-A numbers in `RESULTS.md`. Validate on
  seed B once, at the end, and record that result — not per-candidate.

**Risk:** lowering the gate may admit noise-frame detections in a quiet room. The octave-error
and wrong-string columns are the guard; if a candidate raises either, it is rejected
regardless of detect rate.

**Gate:** detect rate improves or holds, octave errors stay 0, and no existing fixture
regresses.

### Phase 2 — Estimate-level filtering (the core anti-jitter change)

- **2.1 Median ring.** In `PitchTracker`, keep a 7-entry ring of accepted frequencies (the
  entry pushed *before* display smoothing, not after). The reading reports the ring median
  when ≥ 3 entries agree within 15 ¢ of each other, otherwise the newest value. This is the
  one idea taken from WebTuna.
- **2.2 Asymmetric display EMA.** `displayEmaTimeConstant` becomes two constants: 50 ms when
  moving toward a fresh YIN-confirmed estimate, 120 ms when moving toward a recovered or
  held one. Rationale: a better estimate deserves a faster response than a worse one.
- **2.3 The EMA must sit above the state machine.** Feed the smoothed value to
  `TunerReading.cents`, not downstream of `handleLostSignal`. A held reading must report the
  *smoothed* last value, not freeze the last raw one.

**Gate:** G1 (transitions) and G3 (accuracy) both hold; needle position is monotonic on a
step-response fixture.

### Phase 3 — Continuation hysteresis and the one-way ratchet

- **3.1** Two counters in `PitchTracker`, alongside the existing `candidateCount`:
  `consecutiveYinFailures` — recovery or `handleLostSignal` engages only after **3**
  consecutive failures (≈ 70 ms at 43.1 Hz); `consecutiveYinSuccesses` — return to fresh after
  **2** consecutive successes (≈ 46 ms). Asymmetric on purpose: falling back to a weaker
  estimator is sticky, returning to a stronger one is prompt.
- **3.2 Ratchet.** While a fresh reading is younger than `readingHoldDuration`, a recovered
  reading may update `isSignalPresent` and extend the hold but **must not** replace
  `frequency` or `cents`. It is accepted only once the fresh reading has expired — which is
  the case recovery exists for.
- **3.3** Gate recovery in `performAnalysis` on the tracker's continuation state instead of
  the bare per-frame `yinFailed` flag.

**Gate:** G1. The synthetic decay fixture with injected per-frame YIN dropout must produce
≤ 1 transition.

### Phase 4 — Anchor recovery to the prior

- **4.1** When a prior exists and the winning candidate is within
  `spectralPriorAnchorCents` (15 ¢) of it, report the **prior's** frequency. The premise
  from `RESULTS.md` §1 is that the fundamental does not move during a decay, so the prior is
  the better estimate. Accept the candidate's own frequency only beyond that radius.
- **4.2** This replaces the alternative of bias-correcting recovery with a constant measured
  off four fixtures. A correction constant fitted to the same data it is validated on is the
  defect `RESULTS.md` §7 already documents once.

**Gate:** the `RECOVERY-BIAS` mean moves toward 0 and the worst single recovered frame drops
below 5 ¢.

### Phase 5 — String assignment gate

`TunerConstants.maxDetuningCents = 200` is used at exactly one site
(`PitchTracker.swift:203`). It leaves a 100 ¢-wide dead zone at every string midpoint, which
strands F♯2 and G2 in standard tuning — notes a player passes through while tuning *down* from
A2.

| between | dead zone (200 ¢) | stranded |
|---|---|---|
| E2 82.41 – A2 110.00 | 92.50 – 98.00 Hz | F♯2, G2 |
| A2 110.00 – D3 146.83 | 123.47 – 130.81 Hz | C♯3 |
| D3 146.83 – G3 195.998 | 164.81 – 174.61 Hz | F3, F♯3 |
| G3 195.998 – B3 246.94 | none (4 semitones apart) | — |
| B3 246.94 – E4 329.628 | 277.18 – 293.66 Hz | D4 |

Raise to **300 ¢**, which closes every hole, and keep the constant so the choice is visible.
Test both values: at 300 ¢ the wrong-string rate must not rise by more than 1 point on the
matrix.

**Gate:** no stranded notes; wrong-string rate within tolerance.

### Phase 6 — YIN difference function via FFT autocorrelation

`d(τ) = P(0) + P(τ) − 2·r(τ)`, so the whole difference function is derivable from one
autocorrelation. Replace the `320 × 1216 ≈ 389 000`-iteration scalar `Double` loop — the only
non-vDSP hot path in an otherwise Accelerate-based pipeline — with `vDSP_fft_zrip` over a
4096-point transform. Linear autocorrelation via a circular transform needs `N_fft ≥ 2N`;
`2 × 1536 = 3072`, so 4096 is the next power of two and gives headroom for the 320-lag span.

**On the expected speedup, stated honestly:** in raw flop count this is close to a wash —
the direct sum is ~1.5 M flops, two 4096-point transforms are ~1 M. The win is not arithmetic,
it is that the direct loop is scalar Swift with bounds checking while `vDSP_fft_zrip` is
hand-vectorised. So the realistic expectation is a large *wall-clock* win (order 10×) rather
than a large flop win, and the specific beneficiary is the `-Onone` Debug test build (`G5`).
This must be measured, not assumed — Phase 6 records the before/after on both Debug and `-O`.

**Risk:** FFT autocorrelation rounds differently from direct summation, and
`curvatureEpsilon = 1e-15` guards the parabolic refinement against exactly that. Re-validate
the 0.00 ¢ median gate; if it cannot be held, raise the epsilon and record why.

**Gate:** G3 holds; suite runtime in Debug drops enough to complete.

### Phase 7 — Cleanup

- **7.1 Window follows expected pitch.** The window is sized by `maxLag`, i.e. by the lowest
  supported frequency, so a 330 Hz note is analysed through 96 ms of its own decay. Choose
  window length from the current prior/expectation: ~128 ms below 200 Hz, ~48 ms above. One
  window per frame, chosen from state — not two windows per frame.
- **7.2** `Resampler.resampleWindow` returns `nil` for `inputRate < 16 000` and recovery
  silently disables. Surface a `recoveryAvailable` capability so §2.4's trust boundary can be
  reflected in the UI instead of failing invisibly. The resampler's `nil` stays as-is; it is
  the correct guard.
- **7.3 Delete `SpectralNoiseFilter`.** 99 lines, never instantiated, and not a working
  filter — `observeFrame` bins time-domain samples by index as though they were frequency
  bins. `PitchTracker`'s ambient floor already covers the function.

---

## 6. Coverage matrix

Deterministic, generated from a seed. Each axis is swept independently unless stated.

| Axis | Values |
|---|---|
| Fundamental strength h1 | 1.0, 0.3, 0.1, 0.03, 0.01, 0.004 (h2 0.30, h3 0.15, h4 0.10) |
| SNR | ∞, 20, 12, 6, 0 dB |
| **Inharmonicity B** | **0, 1e-4, 5e-4, 2e-3** — `fₙ = n·f₀·√(1+Bn²)` |
| Attack | 0.6 ms, 6 ms, 30 ms |
| Level | −60, −48, −36, −24, −6 dBFS |
| Decay τ | 0.4 s, 1.8 s, 6 s |
| Polyphony | 1 string; E2+A2; E2+E4; A2+E4; **E2+F♯2** (the pair that defeats WebTuna) |
| String | all 6 guitar, all 4 ukulele |

Plus a **decay-with-dropout** family: a 4 s decay with per-frame YIN dropout injected at
0 %, 10 %, 30 % and 50 % of frames. This is the fixture that reproduces the reported symptom
and it is the primary gate for G1.

## 7. Gates

Held by every phase, from `docs/tuner-reliability/RESULTS.md`:

1. **G1** ≤ 1 `fresh ↔ held ↔ recovered` transition per note across the whole matrix, and on
   the four recorded fixtures.
2. **G2** Detect rate and time-to-first-reading ≥ WebTuna, per cell, in the head-to-head.
3. **G3** Existing accuracy gates: clean-tone median ≤ 2 ¢, p95 ≤ 5 ¢; the tighter 0.00 ¢ /
   0.01 ¢ E2 and C4 figures must not regress.
4. **G4** Every tuned constant has a seed-A number recorded and a seed-B confirmation.
5. **Frozen regression set.** A copy of the current `RESULTS.md` numbers, asserted, so "no
   regression" is measured rather than assumed. `quiet_c` chromatic `WrongFresh = 20` is
   expected to *improve*; it is recorded as a known-open baseline, not a gate to preserve.

## 8. Risks and rollback

| Risk | Mitigation |
|---|---|
| Lowering the energy gate admits noise in a quiet room | Octave-error and wrong-string columns veto it; matrix includes −60 dBFS and 0 dB SNR cells |
| Median ring adds latency on a genuine string change | Ring only engages when ≥ 3 entries agree within 15 ¢; a real change breaks agreement and bypasses it |
| Hysteresis delays a real string switch | `consecutiveYinSuccesses = 2` (46 ms); the existing `TrackerTests` step-response fixture covers this |
| FFT autocorrelation changes accuracy | `curvatureEpsilon` is already a tunable guard; G3 is a hard gate |
| Phases land together and something regresses | Each phase is separately flagged and separately revertible; phases 4–7 are droppable without affecting G1–G3 |

**Rollback:** every constant introduced here is a named `static let` with its previous value
recorded in `RESULTS.md`. Reverting a phase is a one-line change per constant.

## 9. What we are deliberately not doing

- **Not replacing YIN.** §2.1 is the evidence.
- **Not porting WebTuna's filterbank as the primary estimator.** It ties YIN on detection
  (§2.1) and loses 100–1000× on frequency precision.
- **Not copying WebTuna's confidence.** `InTuneRatio` is a frame counter carrying no
  evidence about quality. StrumKit's `confidence` (periodicity) is strictly better and stays.
- **Not copying WebTuna's 440 Hz A4, ±12 ¢ window, ±200 ¢ needle, 1.30 s verdict latency, or
  its 1.55 s in-tune counter.** Every one of those is a measured regression against
  StrumKit's current behaviour.
- **Not using the two estimators to out-vote each other.** One idea from WebTuna: filter the
  estimate continuously. The arbitration stays one-directional (recovery never displaces a
  live fresh reading), rather than becoming a two-way contest.
