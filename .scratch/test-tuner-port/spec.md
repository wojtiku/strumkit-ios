# Faithful test-tuner algorithm port

Status: proposed implementation plan — awaiting review; no implementation authorized by this document

## Approved intent

Port the complete working test-tuner algorithm to native Swift, not an approximation,
hybrid with the old engine, or opportunity to retune thresholds. The user approved
framing, filtering, detection, identity expiry, target tracking, smoothing, physical-time
decay handling and measured confirmation. Preserve StrumKit's native interface,
lifecycle, guitar, Calibration, Custom tuning, Chromatic and guided modes as explicitly
tested extensions. Bell sound and UI redesign are out of scope. Work in the existing
`main` checkout (the user's “master”); all prior work was committed.

This delivery is planning only: separate tickets, not Swift changes or changed gates.

## Authority and provenance

- Algorithm authority: test-tuner `6a5a4f30304f392ff9dec9997633f83c295e1e1b`.
- Native starting point: StrumKit `b5075fd94bcb7d9df8161c98536fe08d09bcdd27`.
- The authoritative path is the default `createPitchDetector()`, `new TunerTracker()`,
  `new TunerPresentation()` and `TuningFeedback`. The tracker earns 400 ms confirmation;
  feedback maintains proximity and per-String one-shot completion state.
- `src/main.ts` supplies wiring/reset rules; `src/audio-worklet.ts` supplies framing.
- Experimental flags, historical WebTuna engines, reference adapters, UI replays and
  oracle WASM are not algorithm dependencies. Do not port them or bundle test data.
- Existing reports are supporting evidence only after revision and source-hash checks.
  Generate fresh expected outputs from the pinned own-code engine; never bless Swift
  output as its own oracle. The user reported a successful live iPhone Safari smoke
  test, not full hardware, blind, or unseen-session acceptance.

SHA-256 of pinned source bytes:

| Source | SHA-256 |
| --- | --- |
| src/pitch.ts | `009c7b4c357fe729012da21394c69e433264a525b6c0e38216e3fb7bd7ca4fe1` |
| src/spectrum.ts | `90c67aec8cf7769380da5dfb93d95a1b61725feb9fcfc814b0a7b022e57b1b81` |
| src/tuning.ts | `a744f4cc7033e885b2d48608b1e9327e4fb22606a781be1de2870f3de9aa83ff` |
| src/audio-worklet.ts | `99e5390bee0d655ee2a30c02b9dbf0594bb1202843e7573421f7e04a6a340f9c` |
| src/presentation.ts | `f16d7bc502a6350e6a4db29b542621174acd652ad7db75fe0eca6767ba0bcc0f` |
| src/feedback.ts | `5b90171a9e113c12cdcbaa0243dd4a5260036e52c550476d6ae28c714cab5ab1` |
| src/main.ts | `dd31f09b268ac673abef9cba337a032caaec0799975c4fa3fe372f307ec322b7` |

## Meaning of 1:1

**Algorithm parity:** feed the same Float32 PCM, sample rate, frame boundaries,
timestamps, configuration and event sequence; get the same accepted/rejected
observations, target choices, state transitions, confirmation events and publication
decisions. Frequency/cents/RMS differences may only reflect bounded numeric rounding.
Matching average accuracy or a pleasant needle is insufficient.

**Capture compatibility:** AVFoundation may deliver different PCM, routes, rates or
processing from Safari. Native capture is not assumed better. Assess real input
separately; it cannot excuse a same-input parity failure or justify hidden gain,
denoising, resampling, smoothing or changed thresholds.

**Native extension:** behavior absent from the source (guitar low notes, Calibration,
Chromatic, guided completion, precision preferences) is tested and labelled separately.
Never weaken strict ukulele parity to accommodate an extension. No universal-accuracy
claim: known source failures remain visible and future improvements are separate work.

Strict reference configurations use the source's target order and A4=440: high-G,
Low-G and D. Slack/duplicate targets are mandatory engine tests even if not added to
the UI. Baritone, guitar, custom targets and other Calibration values are extensions.

## Intended architecture

Preserve native permission, scene, interruption, route and generation ownership.
Replace measurement policy behind `TunerAnalysisSession`, not its entire application
architecture. A deterministic, single-owner Swift engine accepts explicit audio/time
and returns observations/readings; it must also run without AVFoundation in tests.
Suggested internal names are provisional, not a mandate for parallel abstractions.

1. Capture adapter: channel policy, lossless reblocking, sample-clock timestamps.
2. Numeric kernels: source-order Double filtering, decimation, FFT, YIN and spectrum.
3. Stateful detector: independent stage anchors and per-frame cached analysis.
4. Tracker: target choice, motion, smoothing, decay and confirmation.
5. Publication/feedback adapter: fresh versus held, proximity versus confirmation,
   native Reading mapping and existing haptic/guided consumers.

No old ambient gate, 16 kHz resampler, spectral recovery, EMA, in-tune latch or UI
spring may silently sit before/after the new strict path and alter its behavior.
Test visibility need not expose a production test API. Oracle generation, PCM,
traces and diagnostics belong only to tooling/test targets.

## Non-negotiable translation details

- Stream geometry: 4096 capture-rate samples, 1024-sample hop, initial full-window
  wait. Reblock arbitrary AVAudioEngine callback sizes; do not analyze once per tap.
- Worklet parity clock is the start of the final 128-sample render quantum. Offline
  reports often use window end instead. Store the convention and normalize the
  explicit 128/sampleRate offset; do not compare unlike clocks. Carry host time
  separately for latency, never use processing completion time as audio evidence.
- Float32 input; Double internal math and caches. Preserve deliberate Float32
  rounding in the transformed anti-alias path, stable peak tie ordering and JS rounding
  semantics (including negative half ties); do not assume Swift defaults match.
- Biquads start at zero for each analyzed window, not a streaming filter history.
  Preserve section order, box-decimation semantics, support/energy checks, conditional
  anti-aliasing and original-rate refinement.
- FFT zero-pads to next power of two of twice input length (8192 for 4096 input),
  returns half-spectrum power, symmetric Hann denominator N-1, no normalization.
  Start with the source radix-2 Double implementation, not an unproved vDSP substitute.
- Detector composition is core → recovered → canonical → foreground. Preserve
  independent anchors, counters, update order and optional-field presence semantics.
  FrameAnalysis invalidates on every public frame, including reused PCM storage;
  transformed anti-alias input has separate analysis, streams share no state.
- Preserve all raw/message/detector RMS meanings; never replace them with nominal
  note frequencies, a held value, normalization, or a display estimate.
- Target acquisition, 25-cent hysteresis, 250-cent rejection, five-value upper median,
  strong-onset mean bootstrap and reset subsets must follow source statements exactly.
- Preserve 300 ms history, 1000 ms identity, 400 ms confirmation; nulls do not update
  every clock. Source inequality boundaries and update order are part of the contract.
- Port the product's default motion path `fast-persistence64-away-rearm-bootstrap`,
  including 2–12-cent corroborated release, >8-cent innovation, physical-time decay,
  50/220/500/1000 ms smoothing and 0.75 cents/ms slew cap. No threshold redesign.
- Pin remaining constructor defaults: max slew 0.75, green policy `raw`, bootstrap
  confidence 0.98, bootstrap seed `mean`, decay damping enabled by the default trial.
- Source `Reading.cents` is smoothed; `Reading.frequency` is Target frequency times
  `2^(smoothedCents/1200)`. Preserve those display values, while separately carrying
  accepted detector frequency, raw cents, confidence and provenance. Never use the
  reconstructed display frequency as raw evidence in tests, confirmation or metrics.
- Publication is 12 Hz with latest-reading updates before throttling and a one-second
  hold. “Skip publication”, “publish empty” and “publish held” are distinct outcomes.
- Immediate ±5-cent proximity is not 400 ms measured confirmation. Preserve the
  confirmation event and per-string identity without adding a bell. Held/sustained
  evidence must not silently acquire fresh authority or complete guided tuning.
- Observe confirmation/completion on every tracker output, before the publication
  throttle. Publication is the single algorithm hold owner; remove/neutralize the
  native ViewModel's competing hold timer rather than extending the reading twice.

## Native-only behavior and explicit conflicts

`CONTEXT.md` currently defines In tune using enter/exit hysteresis and Measured as
periodicity evidence. The new source distinguishes proximity/confirmation and can
accept supported spectral observations. Ticket 08 must reconcile those definitions
with actual source evidence, with provenance tests. A current-window observation
accepted by the pinned detector is eligible for the same source confirmation even
when supported spectrally rather than by periodicity alone; do not demote it and
break parity. A held value is not a new accepted observation. Document these distinctions
instead of relabeling every native legacy recovery Measured or retaining its latch.
Keep existing definitions until implementation and documentation land together.

The 2026-09-25 detection design's “do not replace YIN” restriction is superseded for
this effort by the user's explicit whole-algorithm port approval. Preserve that record
as history and link the superseding decision; do not claim a WebTuna port.

The strict source range is 110–1100 Hz with a 100 Hz high-pass. It cannot promise
guitar low-E or other low tuning support unchanged. Ticket 10 implements a separately
identified extended-range profile with measured coverage, not the old engine as a
hidden ukulele fallback. Its low-frequency filter/lag/support contract requires a
written, reviewed extension design before implementation; the current approval does
not establish unmeasured new constants. Calibration changes targets, not strict-profile constants.
Unsupported extension behavior blocks rollout rather than silently removing features.

Guided mode consumes fresh measured confirmation and retains its additional sequence
requirements; Chromatic reports Note without Target. Existing haptics consume earned
confirmation rather than raw proximity. Precision settings cannot change strict
400 ms confirmation; keep any stricter precision indication separate from the canonical
confirmation and require an explicit native-extension contract before implementation.
Existing native appearance/background/interrupt handling remains. New capture streams
reset algorithm state. Reference tones must not contaminate confirmation: pause/stop
analysis while they play, flush/reset capture state, and resume according to native
listening intent only after an explicit tone-ended event. Add that seam to
ReferenceTonePlayer; cancellation, repeated taps and backgrounding invalidate pending
resume callbacks. Do not introduce a new Start/Stop UI. Test separately from DSP parity.

## Parity acceptance contract

Ticket 01 freezes a machine-readable manifest and comparison schema before porting.
Every trace carries corpus hashes, source hashes, generator/runtime versions, rate,
channel conversion, Float32 encoding, timestamps/configuration and event sequence.
Export decoded PCM once; codec decoding differences are not algorithm differences.
Include 44.1/48/96 kHz and variable-callback/block-partition cases. Existing 55-case
product comparisons and both 96-case stress matrices are mandatory coverage, but the
exporter must run own-code only, without depending on external reference engines.

The existing comparison scripts may require external engines, old revisions or
gitignored reports. Reuse their deterministic input definitions, not those runtime
dependencies or mixed reference payloads. Record source ownership/licensing explicitly;
the absence of a LICENSE is not evidence of permission to redistribute third-party code.

Initial maximum numeric budgets to verify and freeze in ticket 01:

| Field | Budget |
| --- | --- |
| Frequency | 0.000001 Hz absolute |
| Raw/smoothed cents | 0.000001 cents absolute |
| Confidence | 0.000000001 absolute |
| RMS | 0.0000000001 absolute + 0.0000001 relative |
| Algorithm timestamp | same sample index; at most 0.000001 ms conversion error |

These are proposed rounding budgets, not measured Swift results. Calibration of a
budget requires a documented numerical explanation and review before acceptance;
no widening to hide wrong notes or threshold crossings. Exact equality is required
for frame counts, null/accepted mask, optional flag presence, targets, modes, event
sequence, publication slots and confirmation transitions. Numerical closeness never
excuses a changed discrete decision, including at boundary test vectors.

Budgets apply together: a frequency that passes its Hz budget must also pass the
cents budget. For threshold-adjacent vectors, record the Double inputs, exact source
decision and distance to the boundary; include exact representable ties separately.
If platform math causes a discrete difference, resolve arithmetic compatibility or
escalate the contract for review—do not dismiss the frame as “within tolerance”.

Use deliberately altered hop, stage order, threshold, stale cache and held-evidence
negative controls to prove the checker catches regressions. Keep all existing native
fixture/regression gates: explain changed expectations individually as intentional
source-policy differences; do not delete failing suites or bless a new baseline en masse.
The newly committed responsiveness tests contain defect demonstrations; inspect their
intent before converting them to positive acceptance tests, not bug-preserving gates.

TDD is per ticket: red behavioral tests at the named public boundary, smallest faithful
translation, full parity/regression run and review. Exporting expected traces is not
proof that Swift matches. Physical tests and performance numbers remain unperformed
until recorded with device/build/route/rate and measured capture provenance.

## Tickets and dependencies

| # | Deliverable | Blocked by |
| --- | --- | --- |
| 01 | Freeze source, corpus, trace schema and numeric contract | — |
| 02 | Differential Swift harness and negative controls | 01 |
| 03 | Numeric/filter/spectrum kernels | 02 |
| 04 | Stateless candidate detector | 03 |
| 05 | Full stateful detector and per-frame cache | 04 |
| 06 | Target identity and base tracker state | 02 |
| 07 | Product motion, bootstrap, decay and confirmation | 06 |
| 08 | Publication, Evidence and confirmation adapter | 05, 07 |
| 09 | Capture-rate framing and sample clock | 02 |
| 10 | Guitar, Calibration and mode extensions | 05, 07, 08 |
| 11 | Native integration and lifecycle | 08, 09, 10 |
| 12 | Full parity and native regression acceptance | 11 |
| 13 | Device/performance/release acceptance | 12 |

Order by dependency; ticket numbers do not authorize early cutover. All tickets await
review of this spec. No new product implementation is part of this planning delivery.
