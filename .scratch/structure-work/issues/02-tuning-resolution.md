# 02: One place for tuning resolution

**What to build:** Resolving what the player has chosen into what the tuner will actually do happens
in one place. The rule that decides whether a custom tuning is valid — the string count and the note
range — is written once instead of four times across two modules. The config and the target list are
derived from the same resolution, so "the config says one thing and the targets another" stops being
possible rather than merely unlikely. Each of the three setters performs that resolution once
instead of by hand.

**Blocked by:** None (can start immediately)

**Status:** ready-for-agent

- [ ] The custom-tuning validity rule appears exactly once in the app.
- [ ] A single resolution returns both the config and the target list; no separate target-derivation path survives.
- [ ] Instrument change, preset change and custom-note edit each perform the resolution once, not by hand.
- [ ] The three existing ViewModel preference tests pass **unmodified** — they are the gate for this collapse.
- [ ] New tests pin the three previously unpinned fallbacks: a custom array of the wrong length, an out-of-range note, and an unknown preset id. Each resolves to the instrument's default rather than trapping.
- [ ] The suite is green.
