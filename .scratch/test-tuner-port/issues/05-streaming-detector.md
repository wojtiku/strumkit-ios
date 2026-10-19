# 05 — Port every detector repair stage and state lifetime

Status: resolved
Blocked by: 04 (completed)

## Outcome
Default `createPitchDetector()` behavior matches across complete streams, not isolated tones.

## Work and test boundary
- [x] Translate core → recovered → canonical → foreground, including all enabled
  product repair flags. Preserve distinct anchors/counters and downstream-only repair
  effects; do not let final corrected results rewrite earlier-stage history.
- [x] Cover onset refinement, waveform/octave repair, weak precision, fresh-null and
  paired-partial recovery, spectral octave competition and foreground agreement/vetoes.
- [x] Preserve 32/64/200/300/1000 ms evidence lifetimes and exact inequalities from
  source; test strong/weak acquisition after silence and cross-note transitions.
- [x] Port FrameAnalysis per-frame invalidation and storage reuse; transformed alias
  input cannot use the original cache. Test reused PCM object, rate/length changes,
  independent streams, restart and nonfinite samples.
- [x] Run streaming goldens plus prior-expiry, frame-analysis, coherent-foreground,
  null-recovery and spectral/waveform octave regression vectors.

## Acceptance
All detector frame decisions and metadata match; first differing frame is a failure.
No target- or nominal-frequency substitution, stale cache reuse or legacy fallback.

## Comments
- Implemented the 4-layer composition in `StrumKit/Algorithm/FaithfulStreamingDetector.swift`:
  1. `PitchDetectorCore` (`createPitchDetectorCore`):
     - Tracks `accepted`, `frames`, `anchor`, `waveformAnchor`, and `precisionEvidence`.
     - 300 ms expiry on `anchor` and `waveformAnchor`.
     - First 5 accepted frames eligible for onset refinement (`refineOnsetPitch`).
     - Harmonic fallback repair: 64 ms window, `supported-power` alternative with higher spectral power.
     - Waveform octave repair: 64 ms window, octave doubling check against `waveformAnchor` with unexplained harmonic check and period residual <= 0.35.
     - Weak precision refinement: 32 ms cadence check, 64 ms persistence duration.
  2. `RecoveredPitchDetector` (`createRecoveredPitchDetector`):
     - Tracks `frames`, `stableAnchor`, `pairedAnchor`, and pruned `evidence` array.
     - 300 ms expiry on `stableAnchor` (clears evidence history), 200 ms expiry on `pairedAnchor`, evidence pruned to 200 ms.
     - Fresh-null recovery for stable single tones: >= 3 frames in evidence, duration >= 64 ms, agreement <= 5 cents, RMS >= 0.000015, spectral peak prominence >= 500, filtered residual <= 0.5. Emits recovered pitch at confidence 0.8 with DC-removed window RMS.
     - Null recovery for paired partials: fundamental + second harmonic within 30 and 40 cents, residual <= 0.7, weighted frequency combination.
  3. `CanonicalPitchDetector` (`createCanonicalPitchDetector`):
     - Tracks `frames` and 1000 ms `anchor`.
     - Spectral octave repair (`repairSpectralOctave`): evaluates candidate multiples [2] or [2, 3] against anchor within 20 cents, verifies no lower visible fundamental, checks candidate power against voiced maximum, filters incidental upper odd matches, and repairs fundamental frequency.
  4. `FaithfulStreamingDetector` (`createPitchDetector`):
     - Owns per-stream `FaithfulFrameAnalysis`, explicitly resetting it on every frame via `analysis.begin(input, rate)`.
     - 1000 ms foreground identity lifetime (`FOREGROUND_IDENTITY_MS`).
     - Third-harmonic waveform repair: 64 ms lifetime, 3x lower fundamental check with period residual <= 0.35.
     - Stale `oddOnly` veto: vetoes candidate to nil when > 300 ms without anchor agreement and filtered residual > 0.7.
     - Persistent foreground agreement: 32 ms cadence check, 64 ms persistence duration.
     - Foreground agreement flag (`foregroundAgrees: true`): attaches only when confidence in [0.95, 0.98), peak prominence >= 50, peak agreement <= 5 cents, and residual <= 0.5 (absent/nil otherwise, never false).
- Added `compareDetectorOutputs` to `ParityComparator` to strictly compare detector frame outputs against frozen numeric budgets and discrete rules.
- Added comprehensive unit and golden parity tests in `StrumKitTests/Parity/StreamingDetectorTests.swift`:
  - Verified state lifetimes and expiry boundaries (32ms, 64ms, 200ms, 300ms, 1000ms).
  - Verified scratch cache invalidation and in-place buffer reuse.
  - Verified stale oddOnly vetoes and degenerate input handling (empty, short, NaN, Inf).
  - Replayed golden traces frame-by-frame (`steady-A4-48000`, `quiet-A4-44100`, `vector-gap-short-100ms`, `vector-gap-medium-500ms`, `vector-gap-long-1200ms`, `vector-reset-events`, `vector-alias-electronic-44100`, `vector-quiet-onset-bootstrap`, and real fixture `uke_e.wav`) with 0 divergences across all frames.
- Verified test suite passes: `make project`, `make test`, and `make verify-parity`.
