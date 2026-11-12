# 06: One Target translation

**What to build:** The engine accepts **Targets** from `Tuning.resolve` and returns **Readings** aimed at them; the reference-shaped target type and index are translated in exactly one place. The ported tracker is not edited.

**Blocked by:** 04, 05

**Status:** ready-for-agent

- [x] The translation between the domain's **Target** and the port's exists once.
- [x] No path invents a **Target** (no fallback MIDI 60).
- [x] `FaithfulTargetResolver` and `FaithfulPrecisionPreference` and their tests are deleted.
- [x] The live path never looks a **Tuning** up by id in `TUNINGS`.
- [x] The suite is green.
