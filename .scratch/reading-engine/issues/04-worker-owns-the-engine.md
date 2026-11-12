# 04: The worker owns the engine

**What to build:** The session becomes a bounded queue of raw captured audio, one worker that is the Reading engine's only owner, generation, and publication. Configuration reaches the engine as a message on the worker. Overload is an explicit discontinuity. See ADR 0002.

**Blocked by:** 03

**Status:** ready-for-agent

- [x] The session assembles nothing: no framer, detector, tracker or adapter of its own.
- [x] No engine state is touched off the worker.
- [x] A capture callback carrying several hops delivers every hop to the detector, proven by a test.
- [x] Exceeding the queue bound flushes, resets the engine and counts a discontinuity, proven by a test.
- [x] A configuration change still invalidates results in flight.
- [x] The synchronous replay path and the live path run the same code.
- [x] The suite is green.
