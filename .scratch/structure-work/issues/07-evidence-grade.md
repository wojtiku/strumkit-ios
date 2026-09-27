# 07: Grade Evidence as a type

**What to build:** How much a Reading can be trusted becomes a type rather than a flag, so that a
path added later has to choose a level explicitly instead of silently inheriting one. The trust
levels already exist, half-built, fused to display states inside an ordering used for display
precedence — this promotes the trust half out and leaves the display ordering alone.

Only Measured Evidence asserts a String is in tune, and only Measured Evidence completes a Tuning
sequence. That is the policy in force today, so no assertion changes.

**Blocked by:** 6 — Contract the audio edge

**Status:** ready-for-agent

- [ ] Evidence is a type with Measured and Sustained levels, promoted from the trust half of the existing display-ordered type.
- [ ] The display ordering keeps its own cases and its own precedence; it is not merged with Evidence.
- [ ] Only Measured Evidence may assert a String is in tune, and may complete a Tuning sequence.
- [ ] The boolean is gone from both the pitch result and the Reading.
- [ ] De-emphasis of weaker Evidence is unchanged.
- [ ] No assertion is added, removed, or loosened.
- [ ] The withdrawn third grade stays documented in the glossary with its failure mode, so the next person does not rebuild it without the measurement that stopped it.
