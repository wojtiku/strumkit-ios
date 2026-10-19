# 09 — Adapt native capture to the exact frame and sample-clock contract

Status: resolved
Blocked by: 02 (completed)

## Outcome
Identical captured PCM reaches the engine in identical windows regardless of tap size.

## Work and test boundary
- [x] Average channels samplewise as the source does; test mono and multichannel
  inputs, not channel-zero-only native capture. Add 4096/1024 reblocking at capture sample
  rate, with an initial full-window wait. Preserve Float32 sample bytes; no hidden
  16 kHz resampling, normalization, noise gate or gain compensation.
- [x] Reproduce 128-sample worklet quantum timestamp convention from sample indices;
  expose window-end and host-monotonic times separately for replay/latency diagnostics.
- [x] Test identical PCM split into 128/256/512/1024/irregular callbacks at 44.1/48/96 kHz;
  compare every window's samples, timestamps and raw message RMS to worklet goldens.
- [x] Specify and test missing input, suspension, route/rate change and new-generation
  resets. Exact-worklet replay preserves its missing-input behavior; native hardware
  discontinuities are explicitly signaled/reset, never silently glued or zero-filled.
- [x] Audit mailbox semantics: no pre-engine replacement that skips required stateful
  detector/tracker hops. Keep real-time capture bounded, processing single-owner and
  overload detectable; UI publication may coalesce after algorithm processing.
- [x] Define a bounded PCM transport sized by rate and processing budget; retained
  samples are consumed in order and no hop is silently skipped. Exhaustion marks an
  overload/discontinuity, invalidates/resets the generation, and is reported as a
  failure in normal-workload acceptance, not silently presented as continuous evidence.
- [x] Add overload/restart tests proving no old-generation PCM/results are published.

## Acceptance
Block partitioning changes no strict replay outputs. Distinguish capture loss from
algorithm rejection; dropped hops cannot masquerade as ordinary null observations.

## Comments
- Hardware processing differences are recorded, not assumed to improve accuracy.
- Implemented `FaithfulCaptureFraming` in `StrumKit/Algorithm/FaithfulCaptureFraming.swift`:
  - Sample-wise channel averaging across all available channels (`sum / channels.count`).
  - Strict 4096-sample window with 1024-sample hop reblocking.
  - Strict 4096-sample initial wait: zero windows emitted before sample 4096, 1st window at sample 4096, 2nd window at sample 5120, etc.
  - Arbitrary chunk processing: accepts input buffers of any size (128, 256, 512, 1024, or irregular sizes like 441, 705) and emits bit-identical 4096-sample windows every 1024 samples.
  - Sample clock timestamps:
    - Tracks `sampleIndex` at window trailing edge.
    - Window-end timestamp: `timeMs = Double(sampleIndex) / sampleRate * 1000.0`.
    - Worklet quantum timestamp: `workletTimeMs = Double(sampleIndex - 128) / sampleRate * 1000.0`.
    - Exact worklet offset: `(128.0 / sampleRate) * 1000.0` ms delta.
    - Monotonic host time carried separately and linearly interpolated to window trailing edge for latency/diagnostics.
    - Raw frame RMS computed as `sqrt(sum(x^2) / 4096.0)`.
  - Discontinuity and overload handling:
    - Bounded transport capacity (`bufferCapacity`, default 16384).
    - Overload marks discontinuity (`lastDiscontinuityReason = .overload`), increments `generation`, flushes buffer, and resets state rather than silently dropping hops.
    - Route change (`routeChanged()`), rate change (`setSampleRate()`), and explicit `reset()` increment generation, record discontinuity, and flush buffered samples to guarantee no old-generation leakage.
- Unit tests implemented in `StrumKitTests/Parity/CaptureFramingTests.swift`:
  - Verified mono, stereo, and 4-channel sample-wise averaging with cancellation.
  - Verified bit-identical window samples, sample indices, timestamps, and raw frame RMS across 128, 256, 512, 1024, irregular, and random chunkings.
  - Verified strict 4096-sample initial wait: 0 windows before sample 4096, 1st window at sample 4096, 2nd at sample 5120.
  - Verified sample clock vs worklet clock conventions across 44.1, 48, and 96 kHz.
  - Verified route change, rate change, explicit reset, and generation isolation.
  - Verified bounded transport capacity exhaustion and overload detection.
  - Verified agreement with golden worklet traces.
