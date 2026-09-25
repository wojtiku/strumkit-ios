# Tuner reliability — measured results

Plan: [`docs/superpowers/plans/2026-09-25-tuner-reliability-handoff.md`](../plans/2026-09-25-tuner-reliability-handoff.md)

All numbers below are produced by the test suite and are reproduced by:

```bash
xcodebuild test -project StrumKit.xcodeproj -scheme StrumKit \
  -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath ./DerivedData
```

Print prefixes to grep for: `BASELINE`, `TASK5-GATE`, `RECOVERY-BIAS`, `RECOVERY-CONTRACT`,
`RECOVERY-NOISE`, `WEAK-FUNDAMENTAL`, `ACCURACY`, `EVID`, `DROPOUT-BASELINE`,
`XENG` / `XENG-SUMMARY` (head-to-head emitter, §11).

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

## 11. Head-to-head against WebTuna — the G2 baseline (Phase 0, pre-change)

**This is the number G2 is measured against.** It was produced before any Phase 1-3
change landed and must not be regenerated without recording why.

The same 40 cells of the coverage matrix (`CoverageMatrix.matrix(seed: SEED_A)`, spec §6)
were pushed through both engines. StrumKit via `StrumKitTests/CrossEngineComparisonTests.swift`
(3.0 s of audio, 1024-sample hop, 129 frames per cell); WebTuna via
`docs/tuner-reliability/webtuna/xeng.mjs` (32 calls of 4096 samples, covering 2.97 s).

`first`/`last` are the first and last moment at which the engine's **own reported
frequency** was within ±50 cents of the cell's truth frequency, or `–` for never.
"Own reported frequency" is deliberately not the same as what the user would see: the
StrumKit column is `PitchDetector`'s YIN output, so it excludes the spectral-recovery
path. The emitter also prints `firstReading`/`lastReading` (the reading the display would
have shown, recovery included) on the same line; on this run the two are identical for
every cell that was heard at all, so the recovery path added nothing here.

| Cell | Truth Hz | SK first | SK last | SK trans | WT first | WT last | Winner |
|---|---:|---:|---:|---:|---:|---:|---|
| `B-0` | 82.41 | 0.046 s | 2.995 s | 1 | 0.279 s | 2.972 s | tie |
| `B-1e-4` | 82.41 | 0.046 s | 2.995 s | 1 | 0.279 s | 2.972 s | tie |
| `B-2e-3` | 82.41 | 0.046 s | 2.995 s | 1 | 0.279 s | 2.972 s | tie |
| `B-5e-4` | 82.41 | 0.046 s | 2.995 s | 1 | 0.279 s | 2.972 s | tie |
| `atk-0.6ms` | 82.41 | 0.046 s | 2.995 s | 1 | 0.279 s | 2.972 s | tie |
| `atk-30ms` | 82.41 | 0.046 s | 2.995 s | 1 | 0.279 s | 2.972 s | tie |
| `atk-6ms` | 82.41 | 0.046 s | 2.995 s | 1 | 0.279 s | 2.972 s | tie |
| `h1-0.004` | 82.41 | **–** | **–** | 0 | 0.279 s | 2.972 s | **WebTuna** |
| `h1-0.01` | 82.41 | **–** | **–** | 0 | 0.279 s | 2.972 s | **WebTuna** |
| `h1-0.03` | 82.41 | 0.046 s | 2.995 s | 1 | 0.279 s | 2.972 s | tie |
| `h1-0.1` | 82.41 | 0.046 s | 2.995 s | 1 | 0.279 s | 2.972 s | tie |
| `h1-0.3` | 82.41 | 0.046 s | 2.995 s | 1 | 0.279 s | 2.972 s | tie |
| `h1-1.0` | 82.41 | 0.046 s | 2.995 s | 1 | 0.279 s | 2.972 s | tie |
| `lvl--24dB` | 82.41 | 0.046 s | 2.995 s | 1 | 0.279 s | 2.972 s | tie |
| `lvl--36dB` | 82.41 | 0.046 s | 2.995 s | 1 | 0.279 s | 2.972 s | tie |
| `lvl--48dB` | 82.41 | 0.046 s | 2.995 s | 1 | 0.279 s | 2.972 s | tie |
| `lvl--60dB` | 82.41 | 0.046 s | 2.159 s | 2 | 0.279 s | 2.972 s | tie |
| `lvl--6dB` | 82.41 | 0.046 s | 2.995 s | 1 | 0.279 s | 2.972 s | tie |
| `poly-A2+E4` | 110.00 | 0.023 s | 2.995 s | 1 | 0.279 s | 2.972 s | tie |
| `poly-E2+A2` | 82.41 | 0.046 s | 2.995 s | 1 | 0.279 s | 2.972 s | tie |
| `poly-E2+E4` | 82.41 | 0.046 s | 2.995 s | 1 | 0.279 s | 2.972 s | tie |
| `poly-E2+Fs2` | 82.41 | 0.046 s | 2.995 s | 1 | 0.279 s | 2.972 s | tie |
| `snr-0` | 82.41 | 0.046 s | 1.927 s | **8** | 0.279 s | 2.972 s | tie |
| `snr-12` | 82.41 | 0.046 s | 2.995 s | 1 | 0.279 s | 2.972 s | tie |
| `snr-20` | 82.41 | 0.046 s | 2.995 s | 1 | 0.279 s | 2.972 s | tie |
| `snr-6` | 82.41 | 0.070 s | 2.995 s | 1 | 0.279 s | 2.972 s | tie |
| `snr-clean` | 82.41 | 0.046 s | 2.995 s | 1 | 0.279 s | 2.972 s | tie |
| `str-g0` | 82.41 | 0.046 s | 2.995 s | 1 | 0.279 s | 2.972 s | tie |
| `str-g1` | 110.00 | 0.023 s | 2.995 s | 1 | 0.279 s | 2.972 s | tie |
| `str-g2` | 146.83 | 0.023 s | 2.995 s | 1 | 0.279 s | 2.972 s | tie |
| `str-g3` | 196.00 | 0.023 s | 2.995 s | 1 | 0.279 s | 2.972 s | tie |
| `str-g4` | 246.94 | 0.023 s | 2.995 s | 1 | 0.279 s | 2.972 s | tie |
| `str-g5` | 329.63 | 0.023 s | 2.995 s | 1 | 0.279 s | 2.972 s | tie |
| `str-u0` | 392.00 | 0.023 s | 2.995 s | 1 | 0.279 s | 2.972 s | tie |
| `str-u1` | 261.63 | 0.023 s | 2.995 s | 1 | 0.279 s | 2.972 s | tie |
| `str-u2` | 329.63 | 0.023 s | 2.995 s | 1 | 0.279 s | 2.972 s | tie |
| `str-u3` | 440.00 | 0.023 s | 2.995 s | 1 | 0.279 s | 2.972 s | tie |
| `tau-0.4s` | 82.41 | 0.046 s | 2.624 s | 2 | 0.279 s | 2.601 s | tie |
| `tau-1.8s` | 82.41 | 0.046 s | 2.995 s | 1 | 0.279 s | 2.972 s | tie |
| `tau-6s` | 82.41 | 0.046 s | 2.995 s | 1 | 0.279 s | 2.972 s | tie |

**Detect rate: StrumKit 38/40, WebTuna 40/40. G2 does not hold today.** StrumKit misses
`h1-0.01` and `h1-0.004` — fundamental at 1% and 0.4% of the second partial. This is the
`fundamentalMinEnergyRatio = 0.004` gate of §4 above, and it is the gap Phase 1 exists to
close (`FundamentalEnergyScale`, Task 5-6). WebTuna's only measured advantage in
[`webtuna/yinvsalience.mjs`](webtuna/yinvsalience.mjs) was at 0 dB SNR, but here it also
covers the two weak-fundamental cells, so the advantage is larger than that reference
measurement suggested.

**Time to first reading: StrumKit is faster on 38 of 40 cells.** Median first correct
reading 0.046 s (StrumKit) vs 0.279 s (WebTuna). But WebTuna's 0.279 s is a **floor imposed
by its own ABI**, not a tuning result: its first two 4096-sample calls always return
`CanHearANote == false` (it needs three frames before it will name a note — see
`webtuna/README.md`), so 2 × 4096 / 44100 = 0.186 s plus one call is the earliest it is
arithmetically capable of. Read this as "WebTuna is not slower", not "StrumKit is better".
The comparison is also not like-for-like in frame rate: StrumKit analyses every 1024 samples
(129 frames per cell), WebTuna every 4096 (32 chunks), so StrumKit's column has ~4× the
temporal resolution to find an early reading with.

**`trans` is the G1 number, shown here because it came for free.** Only two cells flap:
`snr-0` at 8 transitions and `lvl--60dB` at 2. Every other cell is 1 — acquire once, hold
to the end. This is consistent with the `DROPOUT-BASELINE` numbers Task 3 recorded, and it
says the reported flapping symptom is **not** reproduced by these synthetic cells: it needs
the injected-dropout family, which is not a generated `Case` and so is not in this matrix.
The `-60 dBFS` cell losing its reading at 2.159 s is the level gate adapting, not flapping.

### What this table does not measure

- **Polyphony.** All four `poly-` cells generate a single plucked string. `Cell.extraStrings`
  is carried through the manifest and counted on every SUMMARY line as `extraStrings=N`, but
  neither `CoverageMatrix.signal` nor `buildSignal` synthesises the extra strings, so
  `poly-E2+Fs2` is a lone E2 on both sides. The head-to-head is still sound — both engines
  received byte-identical audio, which the `sig=` checksum proves — but the `poly-` rows
  measure single-note detection, **not** polyphony. Spec §6's "the pair that defeats
  WebTuna" is therefore untested here. Synthesising `extraStrings` is outstanding work.
- **The four recorded fixtures.** These are synthetic cells; §3's quiet_a/c/e/g numbers come
  from a different path and are not comparable to this table.
- **Anything below −60 dBFS or above 0 dB SNR.** Both are outside spec §6's axis ranges.

### Reproducing this table

```bash
make project    # required: StrumKit.xcodeproj globs StrumKitTests/

xcodebuild test -project StrumKit.xcodeproj -scheme StrumKit \
  -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath ./DerivedData \
  -only-testing:StrumKitTests/CrossEngineComparisonTests 2>&1 \
  | grep -E '^(XENG|XENG-SUMMARY)' > /tmp/xeng-trace.txt

cd docs/tuner-reliability/webtuna
curl -o WebTuna.wasm https://guitartuna.com/webtuna/WebTuna.wasm
node xeng.mjs > xweb-trace.txt
python3 xcompare.py /tmp/xeng-trace.txt xweb-trace.txt xtruth.txt
```

The run above took **277 s** for the 40 cells in a Debug (`-Onone`) build. The whole test
takes minutes; do not run a second `xcodebuild` against the same simulator concurrently —
the second test host is SIGKILLed and it looks like a crash in the code under test.

Output prefixes: `XENG` / `XENG-SUMMARY` (StrumKit) and `XWEB` / `XWEB-SUMMARY` (WebTuna).
Summary lines carry `first` / `last` / `transitions` / `frames` / `firstReading` /
`lastReading` / `extraStrings` / `sig`; the WebTuna side carries `first` / `last` /
`chunks` / `extraStrings` / `sig`.

`xcompare.py` refuses to score (exit 2) unless the two traces carry the same 40 labels
**and** the per-cell FNV-1a checksums of the generated audio agree. On this run: 40/40
labels on all three sides, 40/40 checksums identical. `WebTuna.wasm` is Yousician's IP and
is not committed.
