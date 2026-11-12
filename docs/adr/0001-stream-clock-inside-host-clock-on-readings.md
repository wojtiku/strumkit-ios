# Stream clock inside the engine, host clock on a Reading

The tracker's timing (smoothing, the 400 ms in-tune confirmation, the 12 Hz throttle, the
1000 ms hold) has to run on the stream clock — hop count divided by sample rate — because
that is what the reference does and what the parity contract compares; host timestamps
jitter and would make cadence depend on the scheduler. The display's hold fade, however,
compares a **Reading**'s last-fresh time with `CACurrentMediaTime()`, which is the host
clock. One timestamp field used to carry whichever of the two the last fix needed, and each
fix broke the other consumer (`af913a6` moved it to the stream clock and the fade stopped
fading).

So: the stream clock never leaves the Reading engine, and every time on a **Reading** (`at`,
`lastFreshAt`) is a host-clock time taken from the capture callback's timestamp for that
hop. A replay has no host clock and supplies its own start time, which makes the "now" a
hold-fade test compares against explicit.

## Consequences

A **Reading**'s times are not comparable with stream positions, and nothing outside the
engine should try. Anything that needs elapsed audio time (rather than elapsed wall time)
belongs inside the engine.
