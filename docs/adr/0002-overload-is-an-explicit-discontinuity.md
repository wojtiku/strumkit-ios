# Overload is an explicit discontinuity, never a dropped hop

The analysis session used to hold at most one pending window and let a newer one replace it.
That was right for the previous detector, which looked at each window on its own. The
streaming detector and tracker that replaced it are stateful across hops: their filters,
repair stages and confirmation timers assume every 1024-sample hop arrives, in order. A
replaced window is a silent gap in that stream, and the engine keeps running as though
nothing was lost.

So: the session queues raw captured audio up to a fixed bound (the framer's capacity,
16,384 samples, about 370 ms), and when the worker falls far enough behind to exceed it the
engine is told so explicitly — buffered audio is flushed, tracker state is reset, and a
fresh stream begins. The player sees confirmation restart after a stall instead of a
**Reading** computed across a gap.

## Considered Options

- **Latest-wins mailbox (the previous behaviour).** Lowest latency after a stall, but feeds
  the engine a stream it was not designed for, and ticket 09 of the test-tuner port recorded
  the mailbox as audited while it still replaced.
- **Unbounded queue.** Never loses a hop, but a sustained stall turns into unbounded display
  latency, which for a tuner is worse than a restart.
