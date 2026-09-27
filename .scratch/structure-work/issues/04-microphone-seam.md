# 04: Microphone seam, thin slice

**What to build:** The tuner takes its microphone as a dependency instead of building one, and a
single test proves something that is not a microphone can stand in: when microphone permission is
denied, the source is never started at all.

This is the thinnest path that makes the seam real — interface, production adapter, coordinator
wiring, ViewModel injection, one test. Everything else about the seam is breadth, in ticket 5.

**Blocked by:** 3 — Dead code

**Status:** ready-for-agent

- [ ] A microphone-source interface exists, with a typed captured-window value and an event type for interruption and route change.
- [ ] The production capture path satisfies it. The interface does not expose tap size, ring-buffer sizing, or device-specific session configuration.
- [ ] The captured window is one typed value, not a five-parameter positional closure.
- [ ] The coordinator owns starting the source, translating interruption and route change into invalidation, and stopping the source on teardown. Callers no longer have to remember to stop capture, stop analysis and re-arm both.
- [ ] A reference-tone seam exists so a test can assert which tone was requested. The synthesiser keeps its existing integration test.
- [ ] The ViewModel accepts its microphone and reference-tone dependencies, and they are **required** rather than defaulted, so a test cannot be handed a real microphone by omission.
- [ ] A recording test double stands in, and a test asserts that denied permission never starts the source.
- [ ] The suite is green.
