# 05: Parity through the engine

**What to build:** The parity suite drives the Reading engine module the app runs. `FaithfulParityReplayEngine`'s separate assembly is deleted; the mid-stream reset vector uses the engine's interface.

**Blocked by:** 03

**Status:** ready-for-agent

- [x] No test assembles framer, detector, tracker, confirmation and throttle by hand for a full-stream replay.
- [x] Every full-stream parity vector passes through the engine, with the tolerances unchanged.
- [x] The suite is green.
