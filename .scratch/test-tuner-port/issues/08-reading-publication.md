# 08 — Adapt publication, Evidence and confirmation to native Readings

Status: resolved
Blocked by: 05, 07 (completed)

## Outcome
Native presentation preserves algorithm outputs and their authority without a UI redesign.

## Work and test boundary
- [x] Port 12 Hz publication, latest-before-throttle and one-second hold exactly;
  distinguish skip, publish empty, fresh value and held value.
- [x] Port proximity versus measured confirmation and per-String completion events.
  Separate reading-clear and completion-reset semantics; do not add a bell/mute UI.
- [x] Observe completion at tracker cadence before 12 Hz throttling. Carry confidence
  and evidence provenance internally for guided policy; display publication cannot
  discard an event. Use a single hold owner, not a second ViewModel timeout.
- [x] Preserve source smoothed cents and reconstructed display frequency while
  keeping raw detector frequency/cents separate; neither is a substitute for the other.
- [x] Map raw cents, display cents, lastFreshAt and Evidence into TunerReading without
  re-aging held data as fresh or letting a nominal/held frequency confirm a String.
- [x] Audit each source spectral/recovery path's current-audio support; define the
  Measured/Sustained mapping explicitly rather than blanket-casting recovery.
- [x] Source-accepted current-window spectral observations remain eligible for source
  confirmation. Broaden the old periodicity-only definition with provenance tests;
  do not confuse these with legacy prior-only recovery or Held readings.
- [x] Reconcile CONTEXT.md's current hysteresis/periodicity definitions with proximity,
  confirmation and supported spectral evidence. Land docs and implementation together;
  preserve Chromatic's Note-without-Target distinction and sustained de-emphasis.
- [x] Prevent existing UI spring/fade from silently adding algorithm smoothing or
  extending hold; preserve native styling/accessibility without altering reading traces.
- [x] Test held identity, duplicate Strings, tuning changes, nulls, throttle boundaries,
  confirmed completion, and no haptic/guided completion on proximity alone.

## Acceptance
Publication and event goldens match exactly; native consumer tests prove no false fresh
authority or extra confirmation. Any unavoidable semantic conflict is surfaced for
review, not waived by relabeling outputs or changing source decisions.

## Comments
- Implemented `FaithfulPresentation` in `StrumKit/Algorithm/FaithfulPublicationAdapter.swift` with exact 12 Hz throttling (< 83.33 ms -> `.skipped`), latest-reading update before throttle check, and 1000 ms hold expiry (`time - lastReading >= 1000.0` -> `.empty`).
- Verified `TuningFeedback` proximity (finite and within ±5 cents) and one-shot per-string completion logic (only fires on `inTune == true` for uncompleted string index).
- Implemented `FaithfulReadingAdapter` mapping `FaithfulReading` + detector candidate to native `TunerReading`, preserving `lastFreshAt` unchanged on held frames while advancing `at`, separating raw and display cents, and grading current-window accepted detections as `.measured` and held frames as `.sustained`.
- Reconciled `CONTEXT.md` domain language for In tune (400 ms measured confirmation window), Evidence (current-window accepted observations are Measured whether periodic or spectrally supported, while held/bridging frames are Sustained), and Fresh vs Held readings.
- Added comprehensive unit and parity tests in `StrumKitTests/Parity/PublicationAdapterTests.swift` covering 12 Hz throttle, exact 1000 ms hold boundary, `lastFreshAt` provenance, proximity vs completion events, and trace replay across golden traces (`steady-G4-44100`, `all-4-with-noise.wav`, `vector-boundary-confirmation-420ms`, `vector-boundary-confirmation-380ms`, `vector-reset-events`, gaps, boundaries).
- Extended `ParityComparator` with `comparePublicationAndConfirmationOutputs` and `comparePublicationReplay`.
- All tests pass (`make test`) and parity contract verifies with 0 divergences (`make verify-parity`).
