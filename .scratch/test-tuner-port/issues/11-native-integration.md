# 11 — Wire the faithful engine into the native analysis session

Status: resolved
Blocked by: 08, 09, 10 (completed)

## Outcome
The app uses the new engine while retaining safe native permissions and lifecycle.

## Work and test boundary
- [x] Connect capture → engine → Reading/publication using TunerAnalysisSession's
  single-owner/generation seams; remove bypassed native resampling, recovery, ambient
  gates and smoothing from this path, without deleting unrelated investigation work.
- [x] Test same trace through direct replay and the actual session adapter; capture
  and main-actor delivery latency do not become evidence timestamps.
- [x] Preserve automatic native appearance/scene behavior, permission denial, route
  changes, interruptions and listening intent. Reset engine on new stream/generation;
  no stale async result after Stop/background/config adoption.
- [x] Stop/pause measurement while a reference tone plays; resume using listening
  intent and current permission/route. Test rapid repeated taps and scene interruptions
  so app-generated sound cannot earn confirmation. No new Start/Stop screen or bell.
- [x] Add an explicit tone-ended/cancelled seam to ReferenceTonePlayer, flush buffered
  capture and reset engine state. Resume callbacks are generation/intent guarded;
  duration guesses and already-queued speaker input cannot restart/confirm accidentally.
- [x] Preserve preset/settings persistence, target mapping, haptics and guided behavior
  according to tickets 08/10; isolate audio callback work from UI operations.
- [x] Regenerate project membership from project.yml as required, build app and tests,
  and audit production bundle for fixtures, reference engines and debug/oracle assets.

## Acceptance
Session/lifecycle seam tests pass and replay matches the standalone engine. No silent
legacy policy overlay, dual measurement route or microphone-monitor feedback path.

## Comments
- Native lifecycle adaptation is explicit; it does not weaken same-input parity.
- `TunerAnalysisSession` wires `FaithfulCaptureFraming` → `FaithfulStreamingDetector` → `FaithfulReadingAdapter` (`FaithfulTargetTracker`, `TuningFeedback`, `FaithfulPresentation`).
- Capture buffering is framed into 4096-sample windows on 1024-sample hops and enqueued into a bounded mailbox (capacity 1).
- Direct frame replay through `TunerAnalysisSession` verified against standalone faithful engine with bit-for-bit parity and sample-clock timestamp accuracy in `NativeIntegrationTests.swift`.
- Reference tone lifecycle coordinates thread-safe start and stop callbacks, pauses audio capture, flushes capture framing, and guards resume callbacks with `toneGeneration` and listening intent.
- `TunerViewModel` hold timer neutralized in favor of single-owner 1000 ms hold in `FaithfulPresentation`.
- Production bundle audited: zero test fixtures, audio WAV files, or reference oracles in `StrumKit` target bundle.
