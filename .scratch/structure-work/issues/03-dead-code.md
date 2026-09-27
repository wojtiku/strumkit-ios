# 03: Dead code and stale comments

**What to build:** The next reader is not sent to a file that no longer describes the code. Four
things go: a filter that is never instantiated and does not work, an unused enumeration, a feature
flag that is never switched off, and a field that fed a consumer this codebase no longer has. Two
comments that have outlived their subjects get corrected.

This is deliberately first among the removals: the audio seam in ticket 4 replaces the tap callback
wholesale, so the vestigial field should already be gone before that happens.

**Blocked by:** None (can start immediately)

**Status:** ready-for-agent

- [ ] The spectral noise filter is deleted and nothing references it.
- [ ] The unused signal-condition enumeration and the unused scorer feature flag are deleted.
- [ ] The resampling coefficient method is no longer part of any interface.
- [ ] The "new samples in this window" field, its tap parameter, and every call site are deleted. Nothing reads it — it existed to feed a stateful consumer of the WebTuna engine, which now lives in a separate package driven by tests, not by the live capture path.
- [ ] Two stale documentation comments are corrected, including one describing a type deleted several commits earlier.
- [ ] The suite is green and no test loses coverage.
