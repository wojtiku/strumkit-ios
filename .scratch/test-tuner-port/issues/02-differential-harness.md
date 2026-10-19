# 02 — Build the Swift differential harness before porting

Status: resolved
Blocked by: 01 (completed)

## Outcome
A failing same-input test identifies the first divergent observation or state transition.

## Work and test boundary
- [x] Add Swift Testing loaders and pure replay seams; explicit PCM/time/config in,
  canonical trace out. Tests do not require a microphone, browser, Node or network.
- [x] Compare every frame: exact masks, flags, indices, events and publication slots;
  numeric fields use the frozen field-specific budgets, never aggregate-only scores.
- [x] Preserve optional-field absence and three publication outcomes: skip/empty/value.
- [x] Report first divergence with sample/time/config, raw and displayed fields, plus
  total differences; reject nonfinite serialization and missing/reordered frames.
- [x] Prove red with altered frequency, null mask, identity, confirmation, timestamp,
  hop, threshold and omitted-frame negative controls. Prove green with unchanged traces.
- [x] Keep test-target resources isolated; use project.yml/XcodeGen conventions rather
  than hand-maintained divergent project membership.

## Acceptance
Harness catches each seeded defect and accepts unchanged golden traces; a stub Swift
engine cannot pass. Report machine-readable failures and reproducible run commands.

## Comments
- Test boundary is the deterministic replay API, not private member inspection.
- Implemented pure Swift models (`ParityTrace`, `ParityFrame`, `ParityDetectorOutput`, `ParityTrackerOutput`, `ParityPublicationOutput`, `ParityBudgets`, `ParityManifest`) in `StrumKitTests/Parity/ParityModels.swift`.
- Implemented `ParityLoader` utilizing compile-time `#filePath` anchor to load `manifest.json` and golden traces directly without app-bundle resource bundling.
- Implemented `ParityReplayEngine` protocol and pure `StubReplayEngine` in `StrumKitTests/Parity/ParityReplayEngine.swift`.
- Implemented `ParityComparator` enforcing frozen field-specific budgets (1e-6 Hz freq, 1e-6 cents raw/smoothed, 1e-9 confidence, 1e-10+1e-7 RMS, exact sample indices, 1e-6 ms timestamp conversion), exact discrete transitions, non-finite (NaN/Inf) rejection, and detailed first-divergence contextual reporting.
- Added comprehensive test suite in `StrumKitTests/Parity/DifferentialHarnessTests.swift` proving positive acceptance against golden traces, sub-budget tolerance, and negative controls for altered frequency, raw cents, smoothed cents, confidence, RMS, flipped null masks, altered target note/index, inTune flag, confirmation state, publication action, shifted timestamps/sample index, missing/extra frames, non-finite values, and stub engine failure.
- Regenerated project with `make project` and verified full test suite passes with `make test`. Verified contract integrity with `make verify-parity`.

