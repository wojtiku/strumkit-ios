# 04 — Port candidate estimation and spectral support

Status: resolved
Blocked by: 03 (completed)

## Outcome
The stateless detector matches the source's candidate decisions on identical windows.

## Work and test boundary
- [x] Port `detectPitch` and spectral candidate scoring, lag bounds, CMNDF valley and
  fallback thresholds, fractional lag and original-rate refinement, in source order.
- [x] Preserve 110–1100 Hz strict profile, silence/physical-power thresholds,
  harmonic/odd-only requirements, waveform validation and confidence construction.
- [x] Keep optional `oddOnly`/`foregroundAgrees` presence distinct from false.
- [x] Carry detector RMS separately from raw full-window RMS; do not substitute
  StrumKit's ambient gate, periodicity thresholds or sustain-only spectral recovery.
- [x] Port quiet, noisy, harmonic, weak/missing-fundamental, odd-only and alias
  vectors; include threshold-adjacent and invalid/arbitrary-length buffers.

## Acceptance
Stateless golden traces have identical accepted/null masks and candidate flags, and
all numeric fields meet budgets. Persistent behavior remains the next ticket.

## Comments
- Implemented `FaithfulPitchCandidate`, `SpectralRanking`, `SpectralPitchResult`, and `FaithfulFrameAnalysis` in `StrumKit/Algorithm/FaithfulStatelessDetector.swift`.
- Implemented `FaithfulStatelessDetector.detectSpectralPitch` matching `spectrum.ts` lines 85–157.
- Implemented `FaithfulStatelessDetector.detectPitch` matching `pitch.ts` lines 407–562, including 110–1100 Hz strict profile, decimation, bandpass filtering, physical power checks, out-of-band detection, Butterworth anti-aliasing with Float32 intermediate casting, CMNDF calculation, valley picking (0.16) and minimum fallback (0.25), original-rate lag refinement, and harmonic octave correction.
- Implemented `FaithfulStatelessDetector.refineOnsetPitch` and `filteredPeriodResidual`.
- Added unit tests in `StrumKitTests/Parity/StatelessDetectorTests.swift` covering pure tones (A4 440 Hz, C4, E4, G4 at 44.1/48/96 kHz), harmonic tones, silence, sub-threshold noise, threshold-adjacent boundaries (0.0000149 vs 0.0000151 RMS, CMNDF thresholds), missing fundamental and odd-partials series (`oddOnly == true`), out-of-band 5 kHz rejection, anti-aliased loud interferer recovery, quiet tones, clipped signals, DC offset removal, degenerate inputs, `FaithfulFrameAnalysis` cache invalidation and reset semantics, and direct verification against golden traces.
- All unit tests and `make verify-parity` pass with 0 divergences.
