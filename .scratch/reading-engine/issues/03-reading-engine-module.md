# 03: The Reading engine module

**What to build:** One synchronous module, no threads and no locks: raw captured audio of any chunk size and a resolved **Tuning** in, one outcome per hop out (nothing to show, clear the display, or a **Reading** to publish, with guided progress and **Level**). It owns framing, detection, tracking, confirmation, throttle and hold, translation to domain types, and the guided sequence. Not yet wired into the session.

**Blocked by:** 02

**Status:** ready-for-agent

- [x] The engine is configured once per change, not once per frame.
- [x] **String** completion is decided at tracker cadence, before the throttle, and credited only to the **String** currently being guided.
- [x] There is one guided-sequence implementation.
- [x] **Reading** times are host-clock; the stream clock does not appear in the engine's output.
- [x] The engine can be told of a discontinuity and starts a fresh stream.
- [x] Tests at the engine's interface cover: chunk-size independence, completion before the throttle, sequential guided credit, hold fade times, discontinuity reset.
- [x] The suite is green.
