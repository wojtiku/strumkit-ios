# StrumKit Tuner Reliability Implementation Plan and Handoff

> **For agentic workers:** Use the `executing-plans` skill, if available, to implement this plan one task at a time. Each task has a testable completion gate. A failed experimental gate is a result to report, not permission to loosen tests. This document is a handoff; its creation did not implement the changes.

**Goal:** Make quiet guitar and ukulele plucks remain correctly measurable for longer, preserve honest and useful feedback as they fade, and make tuning adjustments feel responsive.

**Architecture:** Retain the current YIN detector as the baseline. First make replay tests faithful to production and separate fresh detection from display persistence. Then fix analysis ownership and prototype a spectral harmonic scorer behind an internal strategy switch; promote it only after measured improvement without false-note regressions.

**Tech stack:** Native iOS 17+, Swift 6, AVAudioEngine/AVAudioSession, Accelerate, SwiftUI, Swift Testing. No production dependency on GuitarTuna or a network service.

**Spec:** The requirements, evidence, and acceptance criteria are embedded in this document. Read sections 1–5 before implementing a task. Read section 8 when implementing spectral DSP.

**Date and scope:** September 25, 2026. The user identified **quiet plucks disappearing too quickly** as the main problem. GuitarTuna's online ukulele tuner is the experience reference. This is not a request for a UI redesign or a wholesale algorithm rewrite.

## 1. Execution contract

- Preserve the user's concurrent work. The investigated checkout was dirty; `HEAD` alone does not identify the analyzed implementation. Inspect the current diff and compare the fingerprints in section 11 before relying on a finding.
- This handoff authorizes no execution by itself. Once asked to implement it, begin with Task 0 and proceed in order. Ship the independently useful baseline, presentation, and scheduling improvements even if the experimental detector does not qualify.
- Work in an agreed checkout or isolated worktree containing the intended current changes. Starting from clean `HEAD` would omit the quiet-recording and sustain improvements inspected here.
- Keep microphone permissions, existing presets, custom tuning, A4 calibration, chromatic/manual/auto/guided modes, reference tones, and Swift 6 concurrency correctness working.
- Treat suggested numerical settings as initial experimental settings unless explicitly labeled a behavior requirement. Keep each experiment's parameters and results together.
- A held reading is historical evidence. Only accepted fresh audio can update the detector prior, complete a guided string, or trigger a new success event.
- Pitch confidence is algorithm-specific. YIN periodicity and spectral salience are not interchangeable numbers.
- Raw detection, accepted tracking, and displayed feedback are three different measurements. Report all three.
- Change one DSP mechanism per experiment. Keep a control run using identical PCM, timestamps, and mode.
- Run targeted tests for each task. Run the full suite at the integration checkpoints; avoid repeated full-suite runs without a new change or failure to investigate.

### Review focus

1. A fading A4 must not turn into a fresh A1-like reading: Tasks 1, 4, and 5.
2. A genuine new string must interrupt continuity with the old string: Tasks 3 and 5.
3. Silence must neither keep a prior alive indefinitely nor complete guided tuning: Tasks 1 and 2.
4. Stop, route changes, and preset changes must invalidate queued results: Tasks 3 and 7.
5. Guitar low notes, calibration changes, and detuned strings must survive ukulele-oriented improvements: Tasks 4–7.

## 2. Evidence and corrections to the other analysis

### 2.1 What is verified

**Local Swift replay:** The actual detector and tracker were run offline against the WAV fixtures, using 2,048-sample hops and capture-sized trailing windows. This simulates the requested capture cadence; it is not a measurement of actual iPhone callback timing.

- At 48 kHz, `quiet_a.wav` yielded raw estimates of approximately 440.9, 440.5, and 440.0 Hz at file times 0.256, 0.299, and 0.341 seconds. Auto mode acquired on the third estimate.
- Later raw estimates included approximately 54.9 Hz, 55.0 Hz, and 62.9 Hz. Auto mode appropriately rejected these as incompatible with the high-G ukulele targets.
- The recording produced one fresh auto-mode reading and 19 held readings at that replay cadence.
- Reducing the replay noise gate to 0.00006 did not increase the fresh auto-mode count. Gate reduction alone is not a supported fix for this fixture.
- `quiet_c.wav` also developed low-frequency estimates around 52–65 Hz during decay. This is a pitch-candidate problem as well as a presentation problem.

**GuitarTuna source inspection:** Its wrapper retains the previous UI state for roughly one second after the first no-note result. The AudioWorklet transfers 4,096 nonoverlapping samples. The wrapper uses a 110 ms needle transition.

**GuitarTuna WebAssembly inspection and execution:** The binary was disassembled into WebAssembly text, not reconstructed into original C++ source. Runtime memory inspection and offline execution supported these observations:

- C++ type names include `Yousician::Ooura_FFT`.
- At 48 kHz, the internal analysis window is 4,096 samples and the internal hop is 2,048 samples. Its FFT size is 8,192; zero padding does not mean it waits for 8,192 audio samples.
- A Hamming window, band-energy processing across 56 bands, compression-derived spectral gains, and weighted summation over up to 19 harmonics appear in the pitch-analysis path.
- Candidate generation includes 15 points per semitone, approximately 6.67 cents apart, followed by additional processing. This grid spacing is not a claim about final accuracy.
- The core maintains state across calls. It must receive sequential, newly captured samples, not duplicated overlapping input chunks, when reproducing the website's behavior.

With fresh engine state for each WAV and 4,096-sample nonoverlapping input blocks, the unmodified WebTuna core reported:

| Fixture | Expected MIDI | Correct-note output count | First / last correct output, seconds from file start |
|---|---:|---:|---:|
| quiet_a | 69 / A4 | 10 | 0.427 / 1.195 |
| quiet_c | 60 / C4 | 23 | 0.427 / 2.304 |
| quiet_e | 64 / E4 | 14 | 0.427 / 1.536 |
| quiet_g | 67 / G4 | 11 | 0.597 / 1.451 |

These are accepted core outputs at the expected MIDI note, not precision-tuning accuracy claims. They exclude the JavaScript UI hold. File time includes any leading silence and is not onset-to-acquisition latency.

An in-memory experimental variant replaced the whitening gains with unity, leaving other processing unchanged:

| Fixture | Correct-note outputs with original gains | With unity gains |
|---|---:|---:|
| quiet_a | 10 | 0 |
| quiet_c | 23 | 31 |
| quiet_e | 14 | 8 |
| quiet_g | 11 | 12 |

This supports investigating whitening, especially for A and E. It does not establish universal benefit: C and G did not improve with whitening, and the modification changed the scale presented to downstream thresholds. When the quiet A tail was replaced with zero samples starting at 0.512 seconds, the core stopped reporting a note on the next block. The extended detection on the original fixture is therefore not solely an internal hold timer.

### 2.2 How to use Gemini's analysis

| Claim or recommendation | Handoff decision |
|---|---|
| GuitarTuna holds the display for about one second | Verified and useful. Implement explicit held presentation. |
| Both engines detect all four quiet notes accurately | Not established by counts or first detected notes. Check every accepted result, octave, and cents error. |
| The difference is primarily a UI illusion | Too strong. Core replay and whitening ablation demonstrate a real detection difference on quiet A. |
| Quiet plucks physically remain measurable only 0.8–1.2 seconds | Not a general bound. Instrument, pluck, distance, room noise, and microphone all matter. |
| Increase `readingHoldDuration` to 1.2 seconds | The inspected hold branch actually uses `priorGraceDuration`; changing the named display constant alone has no effect. Separate those mechanisms first. Start with a 1.0-second display hold. |
| Apply a 65–1,200 Hz bandpass globally | Experimental only. It can attenuate supported low notes and remove useful upper harmonics. It is not spectral whitening. |
| Ooura FFT and SIMD explain the advantage | FFT use is verified. A SIMD explanation of quality is unverified; optimization instructions do not establish detection robustness. |
| `InTuneRatio` is a continuous confidence measure | It behaves like accumulated tuning evidence, with discrete steps in replay. Its value is not YIN confidence, cents error, or permission to count held frames. |
| Passing current recording tests proves sustain quality | False assurance: current tests use chromatic mode, a permissive gate, and counts without verifying correct pitch. |

Do not compare Gemini's frame counts directly with the table above: hop size, mode, input conversion, fresh/held semantics, and state handling were not normalized. Some existing local WebTuna scripts feed overlapping chunks into the stateful core; inspect their input loop before reusing them.

## 3. Current code map and concrete hazards

Paths are relative to the repository root, `/Users/wojtiku/src/strumkit-ios`.

| File | Responsibility and relevant finding |
|---|---|
| `StrumKit/Audio/AudioCaptureService.swift` | Microphone/session setup, tap, ring buffer. Requests 2,048-frame buffers; discards tap timestamps; allocates/copies and locks in tap path. Startup errors are printed rather than propagated. |
| `StrumKit/Audio/Resampler.swift` | 16 kHz, 1,536-sample trailing analysis window; approximately 96 ms. Coefficients are cached per instance. |
| `StrumKit/Audio/PitchDetector.swift` | DC removal, RMS/clipping gates, YIN, fallback trough, harmonic arbitration. Broad range is 50–1,100 Hz. |
| `StrumKit/Audio/HannProjection.swift` | Existing frequency-specific projections; not a complete FFT pitch estimator. |
| `StrumKit/Audio/PitchTracker.swift` | Acquisition, target selection, ambient floor, continuity prior, hold, EMA, in-tune and guided state. Holds set `inTune` false; candidate count resets on loss. |
| `StrumKit/ViewModels/TunerViewModel.swift` | Creates a detector per buffer and launches detached work through MainActor. Results can become stale or complete out of order; detector caches are discarded. |
| `StrumKit/Models/TunerTypes.swift` | `TunerReading`, freshness, config, diagnostics. `at` is currently also used for held display updates. |
| `StrumKit/Models/MusicalNote.swift` | Pitch math, calibration, `PitchResult`, supported frequency range. |
| `StrumKit/Views/Components/HardwareReadoutView.swift` | Guidance uses `inTune` and cents without respecting freshness. A faded in-tune note can become “Tune up/down” without new evidence. |
| `StrumKit/Views/Components/HardwareGaugeView.swift` | Adds a 220 ms spring on top of tracker EMA. |
| `StrumKitTests/AudioTestHelpers.swift` | Replay currently uses 20 ms hops, constant 0.00006 gate, and can refresh a prior from held readings. |
| `StrumKitTests/RecordedAudioTests.swift` | Quiet tests count any fresh chromatic reading; do not establish correct-note sustain. |

**Important additional finding:** `StrumKit/Audio/SpectralNoiseFilter.swift` is not currently a frequency-domain noise filter despite its name and comments. It groups samples by their time index into “bins,” with no Fourier transform, then applies sample-wise attenuation. A symbol search found no production caller in the inspected snapshot. Leave it disconnected. Implement whitening in a separate, tested component; do not wire this class into the pipeline as a shortcut.

## 4. Measurement contract

### Definitions

- **Raw estimate:** a detector output before target matching or confirmation.
- **Accepted fresh reading:** current audio supplied adequate evidence and the tracker accepted it.
- **Held reading:** presentation of a previous accepted estimate; contributes zero new detection evidence.
- **Correct-note output:** positive finite frequency within 50 cents of the fixture's annotated reference, with the intended octave. Use this coarse criterion only for recorded-note coverage.
- **Precision accuracy:** cents error against a known instantaneous frequency, measured on deterministic synthetic inputs or independently annotated real audio. The nominal tuning preset is not a ground-truth pitch trajectory for a real pluck.
- **Fresh coverage:** sum of time represented by correct fresh outputs, clipped to the evaluation interval. For output at `t[i]`, use `max(0, t[i] - max(intervalStart, t[i-1]))`, clipped at interval end. Use interval start for the missing previous timestamp. A wrong or held output contributes zero.
- **Acquisition latency:** first accepted correct output minus annotated onset. Until onset is annotated, label the metric “first correct output from file start.”
- **Analysis age:** monotonic publication time minus the source window's capture-end time. This differs from CPU analysis duration.

### Replay trace

Add a test/debug trace with one record per attempted analysis. Its fields must include:

```swift
struct ReplayFrame {
    let captureEndSeconds: Double
    let rawFrequency: Double
    let rawRMS: Double
    let confidence: Double
    let rejection: String?  // gate, clipping, noPeriodicity, ambiguity, targetMismatch, acquiring
    let reading: TunerReading?
}
```

Make rejection reasons structured enums in production if they cross component boundaries. The string above is sufficient for a test/report adapter. Preserve the existing `PitchResult` behavior until a task explicitly changes its contract.

Metrics must first check `frequency.isFinite && frequency > 0`. `PitchMath.centsBetween` currently returns zero for invalid input, which would otherwise make invalid estimates appear perfect.

```swift
func isCorrectRecordedPitch(_ frequency: Double, reference: Double) -> Bool {
    guard frequency.isFinite, frequency > 0, reference > 0 else { return false }
    return abs(1200 * log2(frequency / reference)) <= 50
}
```

### Required input matrix

- All four quiet WAVs and existing `uke_*` sustains; use expected MIDI 69, 60, 64, 67 for A, C, E, G.
- Existing strummed-guitar chord: never complete a guided string.
- Synthetic guitar E2/A2 and all standard ukulele notes, plus low-G ukulele and supported low guitar/custom notes.
- A4 calibration at 415, 440, and 466 Hz; generate the input with the same selected calibration.
- Known detuning of −40, −10, +10, and +40 cents; verify the result is not snapped to a tuning target.
- Deterministic decays with weak fundamental/strong second and third harmonics; seeded white noise; 50/60 Hz interference mixed with a pluck; silence; clipped inputs.
- A→C, G→A, and guitar E2→A2 transitions, including a new pluck during display hold.
- Sample rates 44.1 and 48 kHz, plus the actual rate of any supported external route. Resample with a proper converter when creating variants; relabeling sample rate changes pitch.

Use synthetic signals for exact-frequency assertions. For real recordings, annotate onset and a stable reference region before claiming cents accuracy. Count wrong-note rate separately from fresh coverage.

## 5. Delivery order and gates

| Task | Deliverable | Ship decision |
|---|---|---|
| 0 | Reconciled snapshot and reproducible baseline | Required before edits |
| 1 | Honest production-equivalent replay and metrics | Required for all later claims |
| 2 | Correct held feedback and independent prior expiry | Useful independently |
| 3 | Serialized, bounded analysis with capture timestamps | Useful independently |
| 4 | Offline spectral scorer experiment | Remains experimental until gates pass |
| 5 | Evidence-based sustain integration | Ship only if correctness and coverage gates pass |
| 6 | Measured confirmation/needle responsiveness | Ship only without stability regression |
| 7 | Audio lifecycle and physical-device validation | Required for a release claim |

Create a result table after each task: strategy/settings, fixture/rate/mode, first correct time, correct fresh coverage, last correct fresh time, wrong-note count, held duration, and CPU/age metrics where available. Store results with the implementation, not only in a chat transcript.

## 6. Tasks 0–3: baseline, presentation, and execution

### Task 0 — Reconcile the active checkout

**Files:** Read all files in section 3, `Makefile`, `project.yml`, and any current repository instructions. No implementation changes in this task.

- [ ] Run `git status --short` and `git diff --stat`; inspect active changes in the audio, tracker, and test files.
- [ ] Compare section 11 fingerprints. If code differs, state which findings still apply after reading the new implementation.
- [ ] Verify all WAV fixtures exist and preserve their bytes. Determine which changes belong to another worker before editing overlapping files.
- [ ] Discover the runnable scheme and simulator; use the commands in section 10.
- [ ] Run the existing relevant suites once and capture failures. Record preexisting failures separately; a failed build is not a pitch-quality result.

**Done:** The implementation baseline and test command are identified, and no other worker's changes have been overwritten.

### Task 1 — Make replay expose the real failure

**Modify:** `StrumKitTests/AudioTestHelpers.swift`, `StrumKitTests/RecordedAudioTests.swift`.

**Create:** `StrumKitTests/ReplayMetricsTests.swift` for metric correctness and trace utilities if the existing helper becomes unwieldy.

**Interface:** Add `replayTrace(samples:sampleRate:config:hopSamples:) -> [ReplayFrame]` to `AudioTestHelpers`. Keep the existing `replay` helper as an adapter if existing suites need it. Derive detector gates and priors from the actual tracker on each step.

- [ ] Add a metric test proving 55 Hz is wrong for A4 and zero/nonfinite frequencies are invalid:

```swift
#expect(isCorrectRecordedPitch(440, reference: 440))
#expect(!isCorrectRecordedPitch(55, reference: 440))
#expect(!isCorrectRecordedPitch(0, reference: 440))
#expect(!isCorrectRecordedPitch(.nan, reference: 440))
```

- [ ] Implement baseline replay with 2,048-sample hops, `AudioCaptureService.requiredInputSamples(for:)` trailing windows, actual sample rate, and sample-count timestamps. Match current startup partial-window behavior for the baseline; any later change to that behavior must be explicit and separately measured.
- [ ] At each step use `tracker.recommendedNoiseGate`, `recommendedYinThreshold`, and `tracker.continuityPrior`. Read the prior from the tracker again on the next step. Never derive it from a held reading's timestamp.
- [ ] Preserve the full trace, including invalid detector outputs and periods with no tracker reading. This is how raw 55 Hz errors remain visible even when auto mode rejects them.
- [ ] Add auto and chromatic recording checks with expected-note classification. Chromatic is diagnostic; auto is the primary user-flow test.
- [ ] Add a failing improvement test for quiet A using the unchanged fixture: zero wrong fresh A4-classification outputs, at least **0.40 seconds of correct fresh coverage** within file time 0.20–1.30 seconds, and at least one correct fresh output at or after 0.90 seconds. These are proposed product targets, not measured baseline performance. Run this expected-failing test explicitly; keep it labeled as the Task 5 acceptance test until implemented, rather than weakening it to pass Task 1.
- [ ] Add regression measurements for other recordings. For valid behavior already present, assert no new wrong-note outputs and no loss of correct fresh coverage greater than one evaluation hop in later comparisons.
- [ ] Record a baseline trace/table. A known expected failure may be isolated from the normal passing suite while the experiment is incomplete, with an explicit tracked test name and reason.

**Done:** The baseline exposes the quiet A sustain failure, correct-pitch metrics reject subharmonic errors, and replay's gates/prior/cadence match production semantics. This task need not make the DSP acceptance test pass.

### Task 2 — Separate display hold from active evidence

**Modify:** `PitchTracker.swift`, `TunerTypes.swift`, `TunerViewModel.swift`, `HardwareReadoutView.swift`, `HardwareGaugeView.swift`, and the containing `TunerView.swift` as needed to pass presentation state.

**Tests:** Extend `TrackerTests.swift`; add `StrumKitTests/TunerPresentationTests.swift` for a small pure presentation helper if guidance is otherwise embedded in SwiftUI.

**Interface:** Add `lastFreshAt: TimeInterval` to `TunerReading`; preserve it on held copies. Keep `at` as the current update timestamp. Update construction sites explicitly. Set `readingHoldDuration = 1.0`; initially retain `priorGraceDuration = 0.85` as a separate DSP setting.

- [ ] Write a tracker test: acquire an in-tune manual A4 reading at `t=10.0`, then process lost-signal frames at 10.10, 10.90, and 11.01. At 10.10 retain the display and prior; at 10.90 retain the display but expire the prior; at 11.01 return no active reading. The last-fresh timestamp must remain 10.0 throughout.
- [ ] Split the lost-signal branch into independent prior-expiry and display-expiry decisions. It must evaluate prior expiry even when returning a held display.
- [ ] Preserve the last confirmed in-tune visual state in held output. All evidence-consuming code must require `.fresh`; a held `inTune` value denotes the last result only.
- [ ] Make guidance freshness-aware: fresh results say “In tune” or “Tune up/down”; held results say “Last reading — pluck again.” Keep the needle at its last position. Fade opacity using `lastFreshAt` from 1.0 toward 0.4 over the display-hold interval, clamped to that range. Use a presentation timer while held so fading/expiry is not dependent on audio callbacks continuing.
- [ ] Keep guided completion based on uninterrupted fresh in-tune evidence. Test 0.8 seconds fresh + 0.3 seconds held: it must not complete the current one-second requirement. Reset the guided hold on loss, as the current implementation does.
- [ ] Test a new valid pluck during hold: it must replace the historical display without waiting for the one-second timer. A timeout callback from the old hold must not clear the new reading.
- [ ] On display expiration, the existing neutral “Last note” memory may remain; it must not show active pitch guidance or update fresh evidence.

**Done:** Signal loss no longer turns an in-tune result into contradictory adjustment advice. Display hold and prior expiry are independent, and held frames never complete tuning.

### Task 3 — Give analysis one owner and bounded pending work

**Modify:** `AudioCaptureService.swift`, `TunerViewModel.swift`, `TunerTypes.swift` diagnostics.

**Create:** `StrumKit/Audio/TunerAnalysisSession.swift`, `StrumKitTests/AnalysisSessionTests.swift`.

**Boundary:** `TunerAnalysisSession` owns reusable detector/resampler state and `PitchTracker`. Its processing method is synchronous on one private serial worker. The UI receives an immutable result snapshot. Reuse the detector until sample rate or analysis configuration changes.

**Input contract:** A frame carries PCM, actual sample rate, capture-end time, sequence number, and session generation. Capture timestamps and prior timestamps share the same monotonic timeline. Replay uses a deterministic equivalent beginning at zero.

```swift
struct AnalysisFrame: Sendable {
    let samples: [Float]
    let sampleRate: Double
    let captureEndSeconds: TimeInterval
    let sequence: UInt64
    let generation: UInt64
}
```

- [ ] Write scheduler tests with an injected slow analysis closure: only one job executes at a time; there is at most one pending frame; submitting newer frames replaces the pending frame rather than growing a queue. A test seam must exercise the same scheduler used in production.
- [ ] Use a bounded mailbox/worker, not one detached task per callback and not an unbounded sequence of actor tasks. Start one worker loop, process the newest pending frame, then check for another.
- [ ] Move tracker processing onto that worker so each analysis sees the prior produced by the previous accepted result. Publish only presentation/configuration snapshots through MainActor.
- [ ] Increment generation and reset analysis state for stop/start, preset/instrument/calibration changes, and route/sample-rate changes. Mode/target changes must invalidate results computed under the old target policy. Use a generation check again immediately before UI publication.
- [ ] Use `AVAudioTime` plus sample count/sample rate to preserve capture timing. Document whether the timestamp denotes buffer start or end and convert once at the boundary. Do not substitute `Date()` at task execution time.
- [ ] Track pure DSP duration, queue delay, result age, replaced-frame count, and actual callback sizes separately. The current `analysisMs` includes scheduling and is not a pure CPU measure.
- [ ] Keep expensive DSP, coefficient construction, and UI dispatch outside the audio tap. Reuse storage where practical. Audit existing lock/copy costs; do not claim the callback is real-time safe just because analysis moved elsewhere.
- [ ] Test stop followed by delayed completion, preset switch during a delayed job, and sample-rate restart. None may publish an old reading. Test a new string after restart to ensure prior/floor/window state was reset.
- [ ] Rerun Task 1 replay through the session's sequential processing seam. Preserve baseline decisions unless a separately documented behavior change explains them.

**Done:** One owner advances DSP/tracker state in order; pending work is bounded; stale sessions cannot update the display; detector caches survive consecutive frames.

## 7. Tasks 4–7: detection experiment, integration, and validation

### Task 4 — Prototype spectral evidence offline

**Create:** `StrumKit/Audio/SpectralPitchScorer.swift`, `StrumKitTests/SpectralPitchScorerTests.swift`.

**Modify:** Replay helpers to select a detector strategy for experiments. Leave the app's default strategy as the baseline.

**Interface:** The scorer returns ranked `SpectralCandidate` values containing `frequency: Double` and `score: Double`. These are evidence values, not `PitchResult.confidence`. Reuse FFT setup, window coefficients, whitening-band maps, and candidate/harmonic maps.

- [ ] Start with a known off-bin sine, a two/three-harmonic pluck, and silence. Verify FFT scaling, real/imaginary packing, window normalization, and peak locations against a direct DFT on a short test vector. A finite output alone is not sufficient.
- [ ] Implement the independent prototype recipe in section 8. Use the existing 16 kHz/1,536-sample analysis input initially so the experiment does not simultaneously change sample rate and window length.
- [ ] Expose internal experiment switches for whitening enabled/disabled and spectral scoring enabled/disabled. Add no settings UI.
- [ ] Run all four quiet recordings plus the required synthetic/chord/noise cases. Log the top three candidates, the score of the correct candidate, harmonic competitors, RMS, and rejection reason.
- [ ] For identical input, compare baseline YIN, spectral scorer without whitening, and spectral scorer with whitening. Scorer-only results are candidates and must not yet be counted as accepted fresh detections.
- [ ] Freeze a parameter set before evaluation. Choose it on quiet A/E plus a synthetic development subset; reserve quiet C/G and a separate seeded synthetic subset for validation. If parameters are changed after inspecting validation, mark that subset as development and add a new validation set.
- [ ] Produce a decision table identifying whether the correct fundamental remains a well-separated candidate after YIN fails. If not, report failure and retain baseline production behavior.

**Done:** A tested, bounded-cost scorer and comparative evidence exist. This is not yet a production-quality detector. A favorable quiet A result alone does not pass the integration gate.

### Task 5 — Use spectral support to extend trustworthy sustain

**Modify:** `TunerAnalysisSession.swift`, `PitchDetector.swift`, `PitchTracker.swift`, recording and transition tests.

**Initial integration choice:** Use spectral evidence as a sustain fallback for a recently accepted note. Keep YIN acquisition behavior initially. Avoid changing first acquisition, target confirmation, and spectral recovery at the same time.

- [ ] Add a failing test for the quiet A target from Task 1, and seeded decay tests with a weak fundamental. Add A→C and guitar E2→A2 transition tests before adding continuity bias.
- [ ] When YIN rejects or jumps implausibly during sustain, score spectral candidates around the last fresh fundamental and competing fundamentals/harmonics. Use ±70 cents as an initial local-search setting, not a guarantee or an instrument-wide acceptance range.
- [ ] Accept recovery only when the candidate has current spectral evidence and passes the frozen noise/competitor checks. Prior proximity alone is insufficient. Preserve the measured frequency; do not substitute the preset frequency or the prior.
- [ ] Use a robust fresh-audio onset/energy-change signal and competing-candidate evidence to release continuity on a new pluck. Existing `lastRms` only advances on certain valid paths, so audit it before treating it as an onset detector.
- [ ] Keep candidate evidence explicit. `TunerReading.recovered` already exists and can identify accepted spectral recovery. Do not set YIN confidence to 1.0 or reuse a salience score as periodicity. Until recovery confidence is separately validated for guided mode, recovered frames may update tuning display/prior but must not complete a guided string.
- [ ] On auto mode, use target context as a preference with the current detuning policy, not pitch snapping. Chromatic mode retains broad frequency coverage. Manual mode still requires actual audio evidence for its selected target. Low-G and custom tunings derive ranges from their actual targets.
- [ ] Pass the quiet A target: ≥0.40 seconds correct fresh coverage in 0.20–1.30 seconds, a correct fresh output ≥0.90 seconds, and zero wrong accepted notes. For other existing real fixtures, lose no more than one evaluation hop of correct fresh coverage versus the Task 1 baseline and introduce no new wrong accepted notes.
- [ ] On deterministic clean tones, require ≤2 cents median and ≤5 cents 95th-percentile absolute error after the first 150 ms; preserve the stricter existing assertions where applicable. On seeded noisy/weak-fundamental signals, report coverage and reject untrustworthy frames instead of allowing octave errors.
- [ ] On synthetic silence and seeded broadband noise with no instrument, require zero accepted fresh tuner readings. For hum mixed with an instrument, require no switch from the instrument to the hum. A pure 55 Hz tone in chromatic mode is a legitimate pitch; do not write a test that treats all low-frequency tones as noise.
- [ ] Require correct acquisition of the next synthetic string within 200 ms of its onset, with no continued fresh labeling as the previous string after acquisition. Treat failure as a reason to revise continuity handling, not to increase hold duration.
- [ ] Re-run the original guided-chord rejection test. Compare CPU cost and result age to Task 3. Retain the baseline strategy if any acceptance gate fails.

**Done:** Longer correct fresh tracking is demonstrated independently of display hold, with no measured octave/string-switch regression. A failed experiment remains off by default and is reported with its traces.

### Task 6 — Tune responsiveness after correctness is stable

**Modify:** `AudioCaptureService.swift`, `TunerAnalysisSession.swift`, `PitchTracker.swift`, `HardwareGaugeView.swift`.

**Tests:** Extend `TrackerTests.swift`, `AnalysisSessionTests.swift`, and deterministic replay tests.

- [ ] Measure actual device callback sizes and analysis age before choosing a new preferred I/O duration. Requested frame counts are preferences, not guaranteed callback cadence.
- [ ] Evaluate 20 ms analysis hops while retaining the existing approximately 96 ms window. If input arrives in larger chunks, extracting intermediate windows after the chunk arrives does not reduce real capture latency; report that limitation.
- [ ] Replace frame-count confirmation with elapsed fresh evidence. Initial policy: two or more consistent observations spanning at least 40 ms; an onset may use two consistent observations spanning at least 20 ms. Same-target fresh continuation may update immediately. Confirmation must not accumulate across arbitrarily long invalid gaps; reset after a gap greater than two nominal analysis hops.
- [ ] Reset display smoothing and in-tune hysteresis when the target changes. In chromatic mode, key identity by MIDI note rather than `targetIndex == -1` for every note.
- [ ] Use a time-based EMA with an initial time constant of 50 ms:

```swift
let alpha = 1 - exp(-max(0, deltaSeconds) / 0.050)
displayCents += alpha * (clampedCents - displayCents)
```

- [ ] Initialize a newly acquired target's display to its first accepted cents value. Remove the spring initially and rely on time-based smoothing; add only a short visual interpolation if device observation demonstrates a need.
- [ ] Test a +40 to −40 cent step on the same note: display error should be ≤5 cents within 150 ms of the first accepted changed estimate. Run at 20 ms and approximately 43/46 ms update cadences. This excludes the microphone/window delay, which must be measured separately.
- [ ] Test a stationary signal: measure display jitter and in-tune state transitions; improve step response without increasing false target changes or repeated success feedback.
- [ ] Run full replay and device validation. Keep the prior timing settings if faster hops overload the target device or worsen tracking.

**Done:** Measured response improves with explicit latency/jitter results; the app does not merely animate faster while processing stale audio.

### Task 7 — Make lifecycle failures visible and validate on device

**Modify:** `AudioCaptureService.swift`, `AudioProtocols.swift`, `TunerViewModel.swift`, `TunerAnalysisSession.swift` as required.

**Tests:** `AnalysisSessionTests.swift` plus focused lifecycle tests using an injected capture/session boundary. Check current Apple documentation for API details before implementing route/session changes.

- [ ] Propagate session-activation and engine-start failures to the view model. Set `.listening` only after successful capture startup. A zero-channel input must produce a meaningful unavailable-input result, not a success state.
- [ ] Handle interruptions and route/sample-rate changes by invalidating the generation, rebuilding dependent analysis state, and resuming only under the app's existing listening intent.
- [ ] Avoid forcing maximum hardware gain as a generic quiet-signal fix. Log the active input route, actual sample rate, buffer duration, channel count, and clipping frequency during device evaluation.
- [ ] Use the built-in microphone for the initial comparison. Evaluate Bluetooth/external inputs separately; do not combine their results with the built-in-microphone baseline.
- [ ] On the same iPhone, compare the app and GuitarTuna sequentially with similar placement, distance, instrument, and room conditions. Record first useful response, duration of changing pitch estimates, held-display behavior, string changes, false locks, and pitch-adjustment response. Browser microphone preprocessing may differ; record this as an uncontrolled variable.
- [ ] Run a sustained session with repeated plucks, silence, navigation/backgrounding, and a route interruption. Report device/OS/build configuration and whether CPU/age metrics remain stable.
- [ ] Initial performance budget: on the chosen test iPhone's Release build, 95th-percentile DSP duration below 10 ms for a 20 ms hop, bounded pending work, and no monotonically growing result age. These are proposed engineering targets, not measured current performance.

**Done:** All automated gates pass; device behavior is documented. If no physical device is available, report “offline validation complete; physical-device validation outstanding,” not “matches GuitarTuna.”

## 8. Spectral prototype recipe and its limits

This is an independent implementation recipe inspired by the observed algorithm family and published research. It is not a reconstruction of every WebTuna operation. Its settings are a starting point for Task 4, not instructions to ship unmeasured constants.

### Input and transform

1. Use the existing resampled 16 kHz, 1,536-sample trailing window. Remove DC. Measure raw RMS and clipping before whitening.
2. Apply `w[n] = 0.54 - 0.46*cos(2*pi*n/(N-1))`.
3. Zero-pad to 4,096 samples and compute a real FFT using Accelerate. Preserve the actual input duration in timestamps. Zero padding interpolates the spectrum; it does not create extra signal information.
4. Compute magnitude `A[k] = sqrt(re[k]^2 + im[k]^2)` with consistent normalization. Explicitly handle packed DC/Nyquist bins if using `vDSP_fft_zrip`; exclude them from pitch scoring.

### Whitening

Use 56 overlapping triangular bands from 50 Hz through 6,400 Hz. Place 58 edges uniformly in `E(f) = 21.4*log10(1+0.00437*f)`; each three consecutive edges defines one band. This is a chosen prototype layout, not a recovered exact WebTuna band map.

For each band `b`, compute:

```text
sigma[b] = sqrt(sum_k H[b,k] * A[k]^2 / max(sum_k H[b,k], tiny))
epsilon = max(1e-12, 1e-4 * max_b sigma[b])
gain[b] = max(sigma[b], epsilon)^(-2/3)
```

Interpolate gains between band centers; use the nearest gain at the scoring-range edges. Normalize gains by their median and clamp them to `[0.1, 10]` for this initial independent prototype. Apply `Aw[k] = A[k] * gain[k]`. Preserve pre-whitening RMS for signal gating. Gain normalization/clamping are explicit prototype safeguards, not claims about the reference engine.

Test both unity gains and whitening. Whitening can amplify noise; a stronger normalized spectral peak is not automatically a valid note.

### Candidate scoring

Use a logarithmic candidate grid over the supported 50–1,100 Hz range, initially 15 points per semitone. For candidate `f0`, inspect harmonics `h=1...19` while `h*f0 <= 6400`.

```text
radiusHz = max(sampleRate / fftSize, h*f0*(2^(1/360)-1))
peak[h] = maximum Aw[k] within radiusHz of h*f0
weight[h] = (f0 + 52) / (h*f0 + 320)
score[f0] = sum_h weight[h] * peak[h]
```

The neighborhood permits off-bin harmonics. The ±1/360-octave term is an initial half-grid tolerance. Keep the raw sum for the first comparison; add normalized alternatives only as separate named experiments. Competing fundamentals must be compared because a lower subharmonic can explain a subset of the same spectral peaks.

Retain local score maxima and refine a peak with three-point parabolic interpolation on log-frequency grid coordinates. Clamp the offset to ±0.5 grid cells; retain the grid estimate if the curvature is flat or has the wrong sign. Test off-grid detuning explicitly.

### Acceptance calibration

A scorer always has a largest peak, even for noise. Build acceptance from evidence rather than declaring the winner correct:

- Evaluate score separation from competitors outside ±50 cents, harmonic competitors `f0/2`, `2*f0`, and `f0/3` where in range, and actual pre-whitening level.
- During sustain compare evidence near the previous pitch against the global winner. The local prior changes preference, not whether there is signal.
- On the fixed development set, sweep candidate/competitor ratios `1.1, 1.25, 1.5, 2.0` and the existing acquisition/sustain RMS gates. Preserve raw score distributions in the report. These ratios are experimental settings, not calibrated probabilities.
- Select a setting only if it rejects the seeded no-instrument controls while improving correct sustain. If none qualifies, do not promote recovery. Investigate score normalization, instrument spectral envelope, and competing subharmonics separately.
- Validate on the reserved input set and then Task 5's complete matrix. Do not retune constants independently for each recording or hardcode expected fixture notes.

### Why not just add the suggested bandpass?

A 65 Hz high-pass can attenuate A1 at 55 Hz, which lies within the app's custom-note support. A 1.2 kHz low-pass removes higher partials that a harmonic scorer could use, particularly for ukulele. Existing resampling already provides anti-alias filtering but does not solve all room-noise problems.

If filtering is later tested, use a separate named experiment, derive cutoff choices from the actual tuning/range, and check guitar/low-G/custom notes. A causal filter processes each newly captured sample once before overlapping windows are extracted; feeding overlapping windows repeatedly through one persistent filter state corrupts the time history. Spectral subtraction, whitening, and bandpass filtering are distinct mechanisms.

## 9. Completion report required from the implementation agent

Return a compact report containing:

1. Tasks completed and any experimental strategy left disabled.
2. Baseline versus final per-fixture metrics from section 4, including wrong-note outputs and held time separately.
3. The exact strategy and parameter set selected, with failed alternatives summarized only when they explain the choice.
4. Tests run, failures remaining, and whether original quiet A acceptance criteria passed.
5. Physical-device results or an explicit statement that they are outstanding.
6. Changed files and material behavior changes, including confidence/guided-mode treatment of recovered estimates.

Progress is meaningful even if the spectral experiment fails: faithful tests, honest held feedback, and bounded ordered analysis are independently valuable. A failed experiment is not evidence that longer UI hold fixed pitch detection.

## 10. Commands and reproducibility

Run from the repository root. Inspect current instructions first.

```bash
git status --short
git diff --stat
xcodebuild -list -project StrumKit.xcodeproj
xcodebuild -showdestinations -project StrumKit.xcodeproj -scheme StrumKit
```

The current Makefile selects the `StrumKit` scheme and an `iPhone 17` simulator. Use an available destination from the preceding command if that name is unavailable:

```bash
xcodebuild test -project StrumKit.xcodeproj -scheme StrumKit \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath ./DerivedData \
  -only-testing:StrumKitTests/RecordedAudioTests \
  -only-testing:StrumKitTests/TrackerTests
```

After adding suites, select their actual test identifiers or run the full suite with `make test`. `make test`'s printed test count is stale; trust test results rather than that message. Preserve any existing failures before changing code.

Fixture parsing must honor WAV chunks, channel count, sample rate, PCM format, and data length. Use the existing validated loader or AVAudioFile rather than assuming a 44-byte header or locating the first arbitrary occurrence of the bytes `data`. Missing fixtures must fail the test; remove user-machine absolute-path dependence when making tests portable.

Historical analysis helpers and public assets were present under `/tmp`, including `/tmp/strumkit-tuner-research/` and `/tmp/WebTuna.wasm`. They are disposable research artifacts, not required build inputs or durable test infrastructure. Implement a repository-owned replay harness as part of Task 1. The comparative evidence above remains available if these temporary files disappear.

## 11. Snapshot and sources

The analyzed checkout's base commit was `7a19a4dc91c2f45c62bf2619706f5ce5da4c9191`, with uncommitted app/test changes. Fingerprints captured while preparing this handoff:

| File | SHA-256 |
|---|---|
| `StrumKit/Audio/PitchDetector.swift` | `e7016a0409ab502d699dd3d9be61a84d2450c0bdcf1d7c4e7690c656b6200b61` |
| `StrumKit/Audio/PitchTracker.swift` | `2f5462240f8fb9e85ea5f3723d90b80a02e6aa81f93b9889a61f6635eb5464d4` |
| `StrumKit/ViewModels/TunerViewModel.swift` | `6fb64a6f5b2f3d2f8e005601b7672c9527cd7cce219f6e1a731b3f70036c6c3a` |
| `StrumKitTests/Fixtures/quiet_a.wav` | `ac8f4f87876623a02b1312041c1c2ea1a184e9f8e44b9fd09be295a890240665` |
| `StrumKitTests/Fixtures/quiet_c.wav` | `0bcfa81c47fd0723d4e0dc1d78518758c5cb07e06efd0f8457e84b8268f5266d` |
| `StrumKitTests/Fixtures/quiet_e.wav` | `0b40db1ec3bddb5aa1bd37e27c0401b48485321f27b118fdc0252cedec0cd15e` |
| `StrumKitTests/Fixtures/quiet_g.wav` | `95179003285329da1bb835ce7f03342999fdf6043d1c0efb8f0b3460af2dcaf3` |
| Inspected `WebTuna.wasm` | `14ec8582a5cd1becfc8597fbc8bec75d2361f57522046ffdb0fbafc9394508bd` |

Primary reference sources inspected during the investigation:

- [GuitarTuna online ukulele tuner](https://guitartuna.com/online-ukulele-tuner).
- [AudioWorklet processor](https://guitartuna.com/tuner-processor.js): browser input batching.
- [Shipped tuner wrapper](https://guitartuna.com/_next/static/chunks/1ptmawfbhl_cx.js): no-note UI hold, target mapping, presentation. Hashed asset URLs may change between deployments.
- [WebTuna JavaScript loader](https://guitartuna.com/webtuna/WebTuna.js) and [compiled binary](https://guitartuna.com/webtuna/WebTuna.wasm): entry point and inspected DSP operations.
- [Klapuri, ISMIR 2006](https://archives.ismir.net/ismir2006/paper/000125.pdf): whitening and weighted harmonic-summation context. The observed formulas resemble this family; exact implementation identity has not been established.
- [Essentia MultiPitchKlapuri documentation](https://essentia.upf.edu/reference/std_MultiPitchKlapuri.html): an independent reference for the algorithm family, not evidence that GuitarTuna uses Essentia.

Gemini's pasted analysis was reviewed as secondary evidence. Its numerical results were not substituted for normalized replay measurements. No physical same-iPhone comparison was performed during the research, and no change in this handoff has yet been validated as an app improvement.

## 12. Ready-to-use implementation prompt

> Read `docs/superpowers/plans/2026-09-25-tuner-reliability-handoff.md`. Implement the plan one task at a time, starting by reconciling the dirty checkout and preserving other workers' changes. The primary goal is longer correct fresh tracking of quiet plucks; display hold is a separate improvement. Use the measured gates and record baseline/final traces. Keep the existing detector as the control and leave experimental spectral recovery disabled unless it passes the stated correctness, sustain, transition, and noise tests. Do not count held frames as detections or replace measured pitch with target pitch. Complete the independently useful tasks even if the experiment fails, and explicitly report any physical-device validation still outstanding.
