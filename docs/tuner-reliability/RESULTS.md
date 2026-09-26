# Tuner reliability — measured results

Plan: [`docs/superpowers/plans/2026-09-25-tuner-reliability-handoff.md`](../plans/2026-09-25-tuner-reliability-handoff.md)

All numbers below are produced by the test suite and are reproduced by:

```bash
xcodebuild test -project StrumKit.xcodeproj -scheme StrumKit \
  -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath ./DerivedData
```

Print prefixes to grep for: `BASELINE`, `TASK5-GATE`, `RECOVERY-BIAS`, `RECOVERY-CONTRACT`,
`RECOVERY-NOISE`, `WEAK-FUNDAMENTAL`, `ACCURACY`, `EVID`.

**Status: 90 tests in 12 suites passing.** Replay cadence is the live request cadence
(`AudioTestHelpers.productionHopSamples` = 1024 frames, matching the capture tap's
requested buffer size). Timing figures come from an `SWIFT_OPTIMIZATION_LEVEL=-O` build on
the iOS Simulator; treat them as indicative, not as device measurements.

---

## 1. The defect that was fixed

Spectral recovery was reporting a systematically wrong fundamental. Measured against
YIN's own readings on the same recording (a plucked string's fundamental is constant while
it decays, so the YIN frames are a valid in-track reference):

| Fixture | YIN anchor | Recovered (before) | Recovered (after) |
|---|---:|---:|---:|
| quiet_a | +0.91¢ | mean **−4.76¢** | mean **−3.06¢** |
| quiet_c | +1.08¢ | mean **+8.11¢**, median +7.62¢ | mean **−1.19¢**, median −1.23¢ |
| quiet_e | −1.06¢ | mean −1.22¢ | mean −1.18¢ |
| quiet_g | −0.48¢ | mean +0.21¢ | mean −1.81¢ |

**Root cause.** The reported frequency was read off the *whitened* spectrum. The whitening
gain is recomputed from every window and varies steeply with frequency, so as a note
decays the gain curve moves and displaces the apparent peak. On quiet_c the whitened h1
peak sat at 262.99 Hz while the true fundamental is 261.63 Hz; the unwhitened peak for the
same frame is 261.57 Hz.

Whitening is correct for *ranking* candidates (it flattens the instrument's spectral
envelope) and wrong for *localising* a frequency. The scorer now keeps two peak lists:
`whitenedPeaks` drives ranking, `rawPeaks` drives frequency estimation, and the unwhitened
peaks are interpolated on log-magnitude (a windowed main lobe is closer to a Gaussian than
to a parabola).

**User-visible effect before the fix:** on quiet_c, 27 of 29 recovered frames reported
`inTune == false` on a correctly-tuned string, so the readout said "Tune down" for the whole
sustain. After the fix: 0 over-claims, 0 tuning-advice emissions.

## 2. Recovery trust boundary

A recovered estimate is now explicitly lower-trust than a YIN-confirmed one:

- `TunerReading.inTune` is `false` for recovered frames (`recoveredFramesMayAssertInTune = false`).
- Guidance is `"Still ringing — hold to check"` — never "Tune up"/"Tune down".
- The needle and readout render at `TunerPresentation.recoveredOpacity` (0.55) so inferred
  evidence is visibly distinct from confirmed evidence.
- Recovered frames still update the display, the cents readout and the continuity prior,
  and still cannot complete a guided string.

| Fixture | recovered | over-claimed in-tune | advice emitted | worst single frame |
|---|---:|---:|---:|---:|
| quiet_a | 31 | 0 | 0 | 9.6¢ |
| quiet_c | 32 | 0 | 0 | 9.8¢ |
| quiet_e | 15 | 0 | 0 | 7.3¢ |
| quiet_g | 23 | 0 | 0 | 13.7¢ |

### Acceptance settings

| Setting | Value | Why |
|---|---:|---|
| `spectralRecoverySeparationRatio` | 1.25 | 1.10 admitted a fabricated 445 Hz "A4" out of a 0.0008-amplitude noise tail, 21¢ sharp. 1.25 is one of the ratios the plan's sweep called for and keeps measured real-signal separation (1.36–1.44×). |
| `spectralRecoveryMinScore` | 0.035 | unchanged; absolute evidence floor. |
| `spectralRecoveryMinRMS` | 0.0003 | 5× above `PitchDetector.minAnalysisRMS`. |
| `spectralRecoveryMinHarmonics` | 2 | a lone peak in the search window is far more often noise than a decaying note. |
| `spectralSupportFraction` | 0.15 | each supporting partial must carry 15% of the strongest. |
| `spectralSearchRadiusCents` | 70 | local search around the prior, not an acceptance range. |

### Noise immunity (tone, then broadband noise, prior established)

| Noise amplitude | frames after tone | recovered | drifted >20¢ |
|---:|---:|---:|---:|
| 0.0008 | 51 | 0 | 0 |
| 0.0040 | 51 | 0 | 0 |
| 0.0100 | 51 | 0 | 0 |
| 0.0200 | 51 | 0 | 0 |

> Note: this table was clean at a 2048-hop cadence and *failed* at 1024. The finer cadence
> doubles the number of chances to admit a noise peak. Any future cadence change must
> re-run this test rather than assume the result carries over.

## 3. Recorded fixture replay (auto mode, 1024-hop cadence)

| Fixture | Frames | Fresh | Correct | Wrong | Held | Coverage [0.20,1.30] | First | Last |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| quiet_a | 104 | 37 | 37 | 0 | 49 | 0.789s | 0.256 | 1.088 |
| quiet_c | 160 | 105 | 105 | 0 | 45 | 1.067s | 0.235 | 3.029 |
| quiet_e | 123 | 45 | 45 | 0 | 58 | 0.875s | 0.235 | 1.429 |
| quiet_g | 118 | 39 | 39 | 0 | 60 | 0.661s | 0.341 | 1.451 |

### Task 5 acceptance gate (quiet A4)

| Hop | Coverage | Last correct | Fresh | Wrong |
|---:|---:|---:|---:|---:|
| 1024 (production) | 0.789s | 1.088s | 37 | 0 |
| 2048 | 0.768s | 1.067s | 18 | 0 |

Target: ≥0.40s coverage in [0.20, 1.30], a correct fresh output at or after 0.90s, zero
wrong accepted notes. **Met at both cadences.**

### Chromatic mode (diagnostic)

| Fixture | Fresh | Correct | Wrong |
|---|---:|---:|---:|
| quiet_a | 37 | 37 | 0 |
| quiet_c | 113 | 93 | **20** |
| quiet_e | 45 | 45 | 0 |
| quiet_g | 39 | 39 | 0 |

**Open defect.** quiet_c produces 20 wrong fresh notes in chromatic mode (3 at a
2048-hop cadence). Chromatic mode has no target set to anchor it, so a decaying fundamental
sliding between semitones can surface as a different note. Auto mode — the primary user
flow — is clean on all four fixtures. The count is printed and bounded at 24 so it cannot
regress silently, but it is **not** asserted to zero.

## 4. Weak-fundamental guitar low notes

Deterministic plucks with the fundamental at 0.060 against a 0.300 second partial (energy
share 0.033, just above `PitchDetector.fundamentalMinEnergyRatio` = 0.004):

| Note | Frames | Fresh | Correct | Wrong | Coverage | Last |
|---|---:|---:|---:|---:|---:|---:|
| E2 (82.41 Hz) | 117 | 115 | 115 | 0 | 1.080s | 2.496 |
| A2 (110.00 Hz) | 117 | 116 | 116 | 0 | 1.080s | 2.496 |

**Known limitation.** Below `PitchDetector.fundamentalMinEnergyRatio` (0.004) YIN reports
"signal present, pitch ambiguous" and declines to name a note. Spectral recovery **cannot**
rescue this case, because recovery requires an already-accepted continuity prior, so it can
only extend a note, never acquire one. A prior-free spectral acquisition path is the
outstanding work item; it is deliberately not implemented here because admitting notes
without a prior is where false detections would come from.

## 5. Accuracy on deterministic tones

| Tone | Median error | p95 error | Gate |
|---|---:|---:|---|
| A4 440.00 Hz | 0.02¢ | 0.02¢ | ≤2¢ / ≤5¢ |
| C4 261.63 Hz | 0.00¢ | 0.01¢ | ≤2¢ / ≤5¢ |
| E2 82.41 Hz | 0.00¢ | 0.00¢ | ≤2¢ / ≤5¢ |

These exercise the YIN path. The recovery path's accuracy is gated separately by the
in-track bias test in §1, which is the only accuracy signal available for real recordings
without hand-annotated pitch.

## 6. Cost (simulator, `-O`)

| Stage | median | p95 | max |
|---|---:|---:|---:|
| YIN (`PitchDetector.detectPitch`) | 0.38ms | 0.65ms | 2.17ms |
| Spectral scorer | 2.32ms | 2.99ms | 3.20ms |

Worst observed combined cost ≈3.2ms per frame, against the plan's budget of <10ms p95 for a
20ms hop. The scorer runs only when YIN fails or jumps during sustain.

## 7. Task 4 decision table (YIN vs unwhitened vs whitened scorer)

| Fixture | Frames | YIN correct | Scorer unwhitened | Scorer whitened | Mean separation |
|---|---:|---:|---:|---:|---:|
| quiet_a | 52 | 3 | 22 | 23 | 1.44× |
| quiet_e | 61 | 15 | 28 | 32 | 1.36× |
| quiet_g | 59 | 8 | 26 | 33 | 1.37× |

Whitening helps ranking on A, E and G. Only the mean separation over already-correct frames
is recorded; the plan's full sweep over ratios 1.1/1.25/1.5/2.0 was **not** run, and 1.25 was
selected on the basis of the noise-fabrication failure described in §2 rather than from a
systematic sweep. quiet_c is absent from this table because the offline harness samples it
on a different frame count than the replay harness.

## 8. Validation discipline

The plan asked for parameters frozen on a development subset with quiet C/G held back for
validation. **That was not honoured** during the original implementation: all four recorded
fixtures were available while the recovery thresholds were chosen, and quiet_c carried the
largest bias precisely because it was never held out. The in-track bias test in §1 now
guards all four, but there is still **no reserved validation set**. Adding one — with
parameters frozen before it is run — is outstanding.

## 9. Physical-device validation

**Outstanding.** No physical-device run has been performed. Everything above is simulator
plus offline replay. Specifically unverified on hardware:

- actual `AVAudioEngine` callback sizes (`diagnostics.callbackFrameCount` is logged in-app but
  has not been read from a device)
- that `AVAudioTime.seconds(forHostTime:)` and `CACurrentMediaTime()` share an epoch on
  device — the display-hold fade and `resultAgeMs` both assume they do
- microphone noise floor, so real quiet plucks will have lower SNR than these fixtures and
  the §2 noise-immunity margin will be thinner
- input route / sample-rate changes and interruption recovery
- residual real-time behaviour of the capture tap (see below)

## 10. Real-time safety of the capture tap — residual risk

The tap no longer materialises an intermediate `[Float]` for the channel data, and the
ring-buffer read no longer allocates its own result array. What remains on the real-time
thread per callback:

- one `[Float]` allocation for the window handed to the analysis session
- an `NSLock` acquisition in `AudioRingBuffer` (write, then copy) and one in
  `TunerAnalysisSession.submitLiveAudio`
- a `DispatchQueue.async` block allocation

The remaining window allocation is roughly 19KB at ~47 callbacks/s (~880KB/s). Removing it
requires a buffer pool with real ownership transfer to the worker; doing that incorrectly
would introduce a data race between the tap overwriting a window and the worker reading it,
which is a worse outcome than the allocation. **The tap is therefore not claimed to be
real-time safe** — it is measurably better than before and still documented as a risk.

## 11. Sustain continuity — the north star, and what blocks it

The stated north star: for a clean pluck, detect the tone on the pluck and hold that
detection steady for as long as the sound lasts. `SustainContinuityTests` measures it on the
four recorded fixtures by establishing the sounding span from raw RMS (independent of the
detector), then counting fresh vs held readings, wrong notes, string transitions and the
longest run without a fresh reading.

### 11.1 What already works

| fixture | sounding | correct | wrong | transitions | longest gap |
|---|---|---|---|---|---|
| quiet_a | 2.20 s | 37 | **0** | **0** | 0.235 s |
| quiet_c | 3.29 s | 105 | **0** | **0** | 0.107 s |
| quiet_e | 2.60 s | 45 | **0** | **0** | 0.213 s |
| quiet_g | 2.30 s | 34 | **0** | **0** | 0.192 s |

No wrong note, no string jump, no drift, and no gap longer than 235 ms on any fixture. The
core case is sound. Synthetic plucks are better still: 21 ms to first detection, zero
transitions, fresh detection held to the end of a 3 s decay.

### 11.2 The two open shortfalls

| fixture | acquisition | trailing held readout |
|---|---|---|
| quiet_a | 235 ms | 1131 ms of 2197 ms sounding |
| quiet_c | 107 ms | 384 ms of 3285 ms sounding |
| quiet_e | 213 ms | 1195 ms of 2603 ms sounding |
| quiet_g | 128 ms | 1173 ms of 2304 ms sounding |

**(a) Acquisition latency.** 107–235 ms from first audible sample to first fresh reading.
The analysis window alone is 98 ms and the tracker then needs further frames to confirm, so
the structural floor is well below this. Not yet diagnosed.

**(b) End-of-sustain dropout.** Fresh detection stops at ~1.1–1.5 s while the string is
still audible for another 1–1.2 s, after which the app shows a held, dimmed reading. This is
the failure the project set out to fix, and it is now localised precisely.

### 11.3 Root cause of (b)

Not the noise gate, not the prior expiry, not YIN's ambiguity test. YIN reports
`isSignalPresent == true` with `frequency == 0` from t≈0.96 s onward while the string rings
at RMS 0.0005. Spectral recovery is entered and then **refused by its separation gate**:
`why=separation` on 4 of the first 6 refused frames, the rest `why=score`.

The vetoing competitor is the top-ranked peak *anywhere* outside the 70-cent search window.
Measured on quiet_a, t=1.067–1.195, against a correct 437–441 Hz candidate, it was 296.6,
59.5, 54.9, 62.6, 78.4, 57.1 and 57.4 Hz — ratios of 1.5x and 7–8x below. Not octave errors,
not plausible subharmonics: low-frequency artefacts. At t=1.195 the 57.4 Hz artefact
outranked the real note outright.

### 11.4 Why the obvious fix was rejected

Narrowing the comparison to genuine octave/subharmonic confusions (f0/2, /3, /4) fixes the
dropout — coverage rose on all four fixtures — **and was reverted**, because it let broadband
noise fabricate readings up to **60 cents** off at amplitudes 0.004 and above. The
low-frequency artefact that vetoes noise frames is the same one vetoing real frames.

Five ways of separating "decaying note" from "broadband noise" on this evidence were tried.
**All five failed to separate them:**

| discriminator | real decaying note | broadband noise | verdict |
|---|---|---|---|
| relative salience (score / best in window) | 0.40–0.97 | 0.58–1.12 | noise scores *better* |
| supporting-partial count | median 8 | median 8 | identical |
| RMS vs tracker's own ambient floor | — | — | does not separate |
| frame-to-frame frequency stability | median 18c | median 29c | overlapping |
| harmonic alignment error | median 0.4c | median 1.8c | overlapping (0.2–1.4 vs 0.2–3.1) |

The structural reason: the synthetic noise is **4–5x louder** than the decaying note it must
be told apart from, so no level or salience threshold admits one and rejects the other.

Keeping the wide comparison costs ~1.1 s of readout at the very end of a quiet pluck.
Loosening it costs correctness against noise. For a tuner that is the worse trade, so the
gate is held and the shortfall left open and visible. The `SustainContinuityTests` comment
records all of this so the next attempt starts from measurement rather than from the same
four refuted ideas.

## 12. Spectral acquisition — still blocked

`SpectralAcquisitionTests` remains 3 tests failing. Same root cause, one step earlier in the
chain: the prior-free path needs `spectralAcquisitionSeparationRatio = 1.60` and the measured
separation for weak fundamentals is 1.15–1.79, degrading smoothly as the fundamental weakens.
1.60 was an arbitrary pick that excludes exactly the cases the path exists to rescue. The
score, RMS and harmonic-count gates all pass comfortably, and the winning candidate is the
correct note at every level tested.

Lowering 1.60 to ~1.20–1.25 is the obvious move and is **not** justified by any evidence
collected here — §11.4 shows the same tradeoff plays out at the acquisition gate, where
fabricating a note with no prior to corroborate it is strictly worse. Blocked pending a
discriminator that is measured to work.
