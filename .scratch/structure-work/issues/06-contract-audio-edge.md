# 06: Contract the audio edge

**What to build:** The seam becomes permanent rather than provisional. Device-specific session
configuration and the real-time ring buffer move behind the interface into files of their own, the
old capture service and its discarding convenience overload are deleted, and tap size and the
callback-frame count stop being the caller's business.

**Blocked by:** 5 — The five remaining seam tests

**Status:** ready-for-agent

- [ ] Device-specific session configuration and the ring buffer live behind the seam, in their own files.
- [ ] The old capture service type and its convenience overload that silently discards parameters are deleted.
- [ ] Tap size and the callback-frame count are no longer part of the caller's interface.
- [ ] Nothing outside the audio-input group references the ring buffer or the session configuration.
- [ ] The suite is green.
