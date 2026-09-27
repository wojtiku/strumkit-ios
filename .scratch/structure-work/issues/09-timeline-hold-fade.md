# 09: Timeline-driven hold fade

**What to build:** The display's own lifetime belongs to the display. A 30 Hz poll currently wakes
to recompute one opacity number, and the ViewModel has to know it. Deriving the fade from the
timeline deletes the poll, the published value and the bookkeeping with it.

**Blocked by:** 8 — Split Target from Note

**Status:** ready-for-agent

- [ ] The hold fade derives from the timeline in the view, from the Reading's last-fresh time.
- [ ] The 30 Hz poll, the published opacity property, and the associated bookkeeping are deleted.
- [ ] Clearing the Reading when the hold expires stays in the ViewModel, because it changes observed state — as a one-shot scheduled task, not a poll.
- [ ] The ViewModel takes no clock parameter.
- [ ] The existing hold-presentation and display-hold-duration tests still pass, and still pass unmodified.
