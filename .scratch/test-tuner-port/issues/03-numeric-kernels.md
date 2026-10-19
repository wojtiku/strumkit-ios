# 03 — Port the source-order numeric, filter and spectrum kernels

Status: resolved
Blocked by: 02 (completed)

## Outcome
Native primitives reproduce the pinned arithmetic before any detector policy is added.

## Work and test boundary
- [x] Start red at pure buffer/rate → filtered signal/power/peaks boundaries.
- [x] Float32 PCM to Double math; mirror intentional Float32 anti-alias intermediate.
- [x] Port source biquad equations, section order and zero-per-window filter state,
  mean removal, box decimation, conditional anti-alias path and support/energy checks.
- [x] Port radix-2 FFT ordering, symmetric Hann, zero padding and unnormalized power;
  4096 input produces an 8192 FFT and 4096 returned power bins.
- [x] Preserve interpolation, prominence, peak ordering/ties and truncation exactly.
- [x] Cover empty/one/short/nonfinite input, DC, silence, rates, off-bin tones,
  supported weak mixtures and out-of-band interference, including the 5 kHz regression.
- [x] Use source detector/spectrum/out-of-band test vectors, not native legacy constants.

## Acceptance
Kernel goldens pass numeric budgets and exact peak/support decisions. No Accelerate
substitution, streaming filter memory, new normalization or “better” resampling.

## Comments
- Implemented pure faithful spectral kernels in `StrumKit/Algorithm/FaithfulSpectralKernels.swift`:
  - Radix-2 FFT with symmetric Hann denominator (N - 1), zero-padding to next power of two of input.count * 2 (4096 -> 8192 FFT -> 4096 half-spectrum power bins), mean removal, unnormalized power (`real^2 + imag^2`).
  - Spectral peaks extraction matching `spectrum.ts`: local maxima, prominence over ±18 bins excluding ±5 bins, log-parabolic peak offset clamped to [-0.5, 0.5], stable descending sort by power (preserving insertion order for ties), truncated to top 40 peaks.
  - `hasUnfoldedPitchSupport` verifying audible peaks (prominence >= 15, power >= minimumPower), in-range tones [110, 1100], and harmonic series with GCD == 1; rejects out-of-band 5 kHz interference while accepting genuine coprime harmonic series.
- Implemented pure faithful numeric and filter kernels in `StrumKit/Algorithm/FaithfulNumericKernels.swift`:
  - Direct form biquad filter with zero initial state per invocation (no streaming filter memory across windows).
  - 3-section bandpass filter (100 Hz HP Q = 1/sqrt(2), 1200 Hz LP Q = 0.541196, 1200 Hz LP Q = 1.306563).
  - 8th-order Butterworth anti-alias filter (4 biquad sections at decimatedRate / 4 with Qs: 0.50979558, 0.60134489, 0.89997622, 2.56291545).
  - Mirroring intentional Float32 intermediate rounding (`Float32Array.from(antiAliased)` -> double -> float -> double) matching reference `pitch.ts` lines 465-466.
  - Box decimation: stride = max(1, floor(sampleRate / 12000)), box average, mean removal.
  - Lag difference and parabolic refinement (`refineLag`).
  - Normalized fractional-delay `filteredPeriodResidual`.
- Added unit tests in `StrumKitTests/Parity/NumericKernelsTests.swift` verifying all kernels against exact reference test vectors generated from `Tools/parity-contract/reference-source/` via tsx.
- All 28+ test suites and 282 parity cases verified clean (`make test` and `make verify-parity` passing).
