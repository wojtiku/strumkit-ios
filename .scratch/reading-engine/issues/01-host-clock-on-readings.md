# 01: Host clock on every Reading

**What to build:** A **Reading**'s `at` and `lastFreshAt` are host-clock times again, while the tracker keeps running on the stream clock. The thinnest fix for the hold fade, made in the session as it stands; ticket 03 moves it inside the engine. See ADR 0001.

**Blocked by:** none

**Status:** ready-for-agent

- [x] A frame carries both its stream time and its host time, as two named fields.
- [x] The detector, tracker and throttle are given stream time; the published **Reading** carries host time.
- [x] A test proves a **Held reading**'s `lastFreshAt` is on the host clock and that `holdOpacity` fades it across the hold window.
- [x] The suite is green.
