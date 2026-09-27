# 01: Remove the detector's dependencies on the modules above it

**What to build:** The estimator and the state machine stop reaching upward. The trust rule — a
Sustained Reading may never assert a String is in tune — lives on the type whose Evidence it
constrains, not on the coordinator that happens to schedule frames. And the estimator's entry
point states only what it cannot infer: it no longer recomputes whether a Sustain is still live,
because its caller already decided that, with the correct clock, before branching on recovery.

Together: the detector layer depends on nothing above it, and can be read top to bottom.

**Blocked by:** None (can start immediately)

**Status:** ready-for-agent

- [ ] The trust rule no longer lives on the coordinator, and the state machine no longer references the coordinator.
- [ ] The estimator's entry point takes four parameters; the two carrying a timestamp pair are gone.
- [ ] A sustained Note crosses that interface only when already known to be live, so "no prior" and "expired prior" cannot be confused.
- [ ] The estimator references no module above it in the detection layer.
- [ ] The suite is green with no assertion added, removed, or loosened.
- [ ] No constant changes value. This is a move, not a retune.
