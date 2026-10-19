# 07 — Port smoothing, peg response, decay and measured confirmation

Status: resolved
Blocked by: 06 (completed)

## Outcome
Native responsiveness and stability arise from the identical tracker, not retuned EMA.

## Work and test boundary
- [x] Port upper median history and strong-onset running-mean bootstrap, confidence
  and optional-flag eligibility, first-acquisition rules and rearm behavior.
- [x] Translate the default `fast-persistence64-away-rearm-bootstrap` path only;
  preserve 2–12-cent corroborated release and overlapping >8-cent innovation.
- [x] Port physical-time decay support/decline checks, 50/220/500/1000 ms constants,
  elapsed clamp and 0.75 cents/ms slew limit in the same statement order.
- [x] Port raw/smoothed ±5-cent sustained confirmation and exact 400 ms boundary;
  held, rejected or missing observations cannot accumulate fresh confirmation.
- [x] Port early/medium peg, strong bootstrap, tracker-evidence, jitter, decay-rate,
  transient-motion, target-stability and green-stability vectors.
- [x] Cover 3–15-cent up/down steps, nine/ten/twelve-cent overlap, weak attacks,
  quiet tails, fluctuating near-boundary input and 44.1/48/96 kHz cadences.

## Acceptance
Every smoothed value and confirmation transition matches its golden trace; response
metrics supplement, never replace, framewise parity. No new dead band or frozen reading.

## Comments
- Do not keep native 50 ms EMA or 5/7-cent in-tune latch around the new tracker.
- Ported full motion path and constructor defaults (`maxSlewCentsPerMs: 0.75`, `greenPolicy: .raw`, `motionTrial: .fastPersistence64AwayRearmBootstrap`, `bootstrapConfidence: 0.98`, `bootstrapSeed: .mean`, `decayDamping: true`).
- Ported `TuningFeedback` faithfully from `Tools/parity-contract/reference-source/feedback.ts` to model the 1-per-string confirmation event and proximity rules.
- Added `compareTrackerOutputs`, `compareTrackerAndConfirmationOutputs`, and `compareTrackerReplay` to `ParityComparator`.
- Added unit and golden trace parity test suite `TrackerMotionTests.swift`, verifying step responses (+40c/-40c slew limit, 3c, 8c, 12c, 15c), peg adjustment innovations and rearms, physical decay damping on plucks vs sustained tones, exact 400 ms confirmation boundary (380 ms vs 420 ms), and frame-by-frame parity across golden traces: `vector-boundary-confirmation-380ms`, `vector-boundary-confirmation-420ms`, `vector-boundary-intune-5cents-within`, `vector-boundary-intune-5cents-sharp`, `vector-step-3cents`, `vector-step-8cents`, `vector-step-12cents`, `vector-step-15cents`, `vector-peg-adjustment-48000`, `vector-quiet-onset-bootstrap`, `vector-continuous-sweep-40cents`, `steady-G4-44100`, and `all-4-with-noise.wav`.
- Full test suite passes clean with 0 failures (`make test`); parity contract verification passes clean (`make verify-parity`).
