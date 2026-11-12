# 08: Listening lifecycle

**What to build:** A module that owns everything deciding whether the tuner is listening — permission, the player's intent, interruptions, route changes, the handoff between a reference tone and capture — drives the session, and reports one status. The view model keeps the **Tuning** choice, preferences and what is displayed.

**Blocked by:** 04

**Status:** ready-for-agent

- [ ] The view model holds no microphone, permission or tone sequencing, and no hold-expiry machinery.
- [ ] The teardown that pauses listening is written once.
- [ ] The existing microphone and reference-tone doubles drive the lifecycle's tests without a view model.
- [ ] Existing view-model lifecycle tests pass, moved or unchanged.
- [ ] The suite is green.
