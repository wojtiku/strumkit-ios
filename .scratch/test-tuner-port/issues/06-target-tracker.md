# 06 — Port target identity and base tracker transitions

Status: resolved
Blocked by: 02 (completed)

## Outcome
The pure tracker chooses the same Target and handles evidence gaps identically.

## Work and test boundary
- [x] Port default target tables/order, manual selection and automatic nearest-target
  selection, duplicate tie ordering, 250-cent rejection and 25-cent hysteresis.
- [x] Port pending-target votes/timing (two frames; auto-switch delay) and exact
  update order for last accepted reading versus last pitch observation.
- [x] Preserve reset subsets: selected/tuning/auto survive tracker reset; null or
  low-confidence input clears only the source-defined evidence, not all configuration.
- [x] Test exact 150/160/300/1000 ms boundaries, rejected pitches, null runs,
  low confidence, arbitrary cadence, target switching and fresh acquisition.
- [x] Map source index to native String identity explicitly (ukulele 4→1); never
  use MIDI alone as identity when two Strings share a pitch.

## Acceptance
Tracker-only scripted observations match source target/null/reset behavior with no
dependency on detector output. Tests expose the old midpoint dead-band difference.

## Comments
- Use domain terms from CONTEXT.md; target frequency is not the observed Note.
- Implemented `FaithfulTargetTracker.swift` (`FaithfulTracker`, `Target`, `TUNINGS`, `centsBetween`, `FaithfulReading`).
- Pre-calculated standard, low-g, d, and slack tunings match reference `tuning.ts` definitions and exact frequencies.
- Preserved duplicate tie ordering (Slack tuning index 0 vs 3) using lowest index tie breaker.
- Implemented 250-cent rejection gate (> 250 cents returns nil and clears pending candidate).
- Implemented 25-cent hysteresis (`distances[current] < distances[index] + 25` retains current target).
- Implemented 2-frame pending acquisition vote and 160 ms auto-switch delay.
- Implemented 150 ms pending expiry (frame gap > 150 ms resets pending vote count).
- Implemented distinct 300 ms pitch history expiry vs 1000 ms display hold / identity expiry.
- Implemented explicit reset subsets: user configuration (`tuning`, `auto`, `selected`) survives tracker reset; dropouts clear pending candidate and non-confirmed settled timer without dropping current target.
- Mapped source index to native String identity: ukulele string index 0..3 maps to strings 4..1, preserving distinct identity in Slack tuning where two strings share G4 (MIDI 67).
- Verified with comprehensive test suite in `TargetTrackerTests.swift` (12 test groups covering all boundary conditions).
