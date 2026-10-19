# 10 — Preserve guitar, Calibration and native modes without weakening parity

Status: resolved
Blocked by: 05, 07, 08 (completed)

## Outcome
StrumKit keeps its feature set, with strict parity separated from unsupported-by-source behavior.

## Work and test boundary
- [x] Before extension code, produce and obtain review of a focused contract: exact
  low/high range, filter corners, lag/spectral bounds, precision and guided policies,
  and fixture acceptance limits. Do not guess source-absent constants. If unresolved,
  mark needs-info and block rollout; strict-engine work remains independently testable.
- [x] Define explicit strict ukulele versus extended-range configurations; the source
  110 Hz minimum/100 Hz HP cannot cover guitar low E unchanged. Use the same translated
  engine structure with deliberate range/filter extensions, not a silent old-engine fork.
- [x] Test all shipped guitar/ukulele Presets and Custom tuning range (native MIDI
  bounds), including guitar low notes, ukulele Baritone and duplicate target pitches.
- [x] Preserve Calibration range/persistence; resolve target frequencies atomically.
  At 440/common source targets, strict traces remain identical. Other Calibration
  settings receive separate raw-accuracy and target-conversion tests.
- [x] Keep Chromatic Note-only semantics; adapt guided sequencing to fresh measured
  confirmation plus existing sequence requirements, never held/proximity completion.
- [x] Specify precision-preference effects as native extension behavior without
  modifying strict confirmation; validate every mode/config transition and reset.
- [x] Record native fixture accuracy, quiet coverage, wrong-note rejection and response
  expectations before changing them; source parity does not certify guitar performance.

## Acceptance
Strict corpus remains unchanged. Every existing feature has explicit tested behavior;
an unsupported/failed extension blocks rollout rather than removing settings or hiding
old policies in the strict engine. Profile choices and limitations are documented.

## Comments
- Extensions are not permission to “improve” the reference ukulele algorithm.
- Implemented `FaithfulEngineProfile`:
  - `.strictUkulele`: [110, 1100] Hz, 100 Hz HP / 1200 Hz LP filter corners, bit-identical reference parity across 282 cases / 31495 frames.
  - `.extendedRange`: [50, 1200] Hz, 40 Hz HP / 1200 Hz LP filter corners, lag bounds `max(2, floor(rate/1200))` and `min(floor(rate/50), length/2 - 1)`. Accurately detects Low E (82.41 Hz), Drop D (73.42 Hz), and Drop A (55.0 Hz) within < 1 cent.
- Dynamic Calibration (`FaithfulTargetResolver`):
  - Target frequencies resolve atomically via `calibrationA4 * 2^((midi - 69)/12)`.
  - At 440 Hz, matches reference target frequencies bit-identically.
  - Engine DSP pitch detection remains completely unaltered by target calibration.
- Native Modes:
  - Shipped Presets: All 10 guitar presets and 4 ukulele presets (including Baritone) and custom MIDI 33..83 validated with proper target mapping and string numbering.
  - Chromatic mode: Note-only semantics (`ReadingAim.note`), with `target` and `inTune` strictly nil.
  - Guided mode (`FaithfulGuidedSequence`): String advancement requires fresh measured confirmation (`inTune == true && evidence == .measured && freshness == .fresh`). Proximity alone, held readings, sustained frames, or out-of-order strings never advance the sequence.
  - Precision preferences (`FaithfulPrecisionPreference`): Presentation overlay (±2 cents formatting/indication) that leaves canonical 400 ms ±5c confirmation completely intact.
- Verified with `make project`, `make test`, and `make verify-parity` — all suites passing.
