# 05: The five remaining seam tests

**What to build:** The bugs the comments describe become tests. An interruption currently stops the
analysis and leaves the capture tap installed, which makes the stop cosmetic; a route change
restarts unconditionally whenever listening; and reference tones — the documented fallback when the
microphone is blocked — are never asserted to be offered.

**Blocked by:** 4 — Microphone seam, thin slice

**Status:** ready-for-agent

- [ ] An interruption leaves the source stopped, not merely the analysis.
- [ ] A resumable interruption restarts only when listening was intentional, and does not when the user deliberately stopped.
- [ ] A route change restarts capture.
- [ ] A reference tone is requested even when the microphone is denied.
- [ ] Changing instrument replaces the target list and clears the Reading. This extends the existing test, which stops at the config and never checks the reading.
- [ ] **Four of these five fail before ticket 4's wiring lands.** Where one passes beforehand, the seam was not the problem — delete the test rather than keep it.
- [ ] The suite is green, with the existing tests unchanged.
- [ ] The production adapter is not unit-tested; its correctness stays with the fixture-replay suite.
