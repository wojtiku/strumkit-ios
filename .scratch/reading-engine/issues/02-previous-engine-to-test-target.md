# 02: Previous engine out of the app target

**What to build:** `PitchDetector`, `PitchTracker`, `SpectralPitchScorer`, `Resampler`, `HannProjection` and `PitchResult` live in the test target as a comparison oracle. The session loses its legacy branch, and `replayTrace` assembles the previous engine itself, spectral recovery included. The suites that use it are unchanged.

**Blocked by:** 01

**Status:** ready-for-agent

- [ ] The app target contains none of the previous engine's sources.
- [ ] The session has no `tracker:`, `fundamentalEnergyScale:`, `isSpectralRecoveryEnabled` or `continuityPrior`.
- [ ] `AnalysisSnapshot` no longer carries a `PitchResult`.
- [ ] `SignalFeedbackState` in the app names only ready, inactive, checking and tracking; the previous engine keeps its own wider state in the test target.
- [ ] Every suite that drove the previous engine through the session still runs, through the test-target replay helper.
- [ ] The suite is green.
