# 08: Split Target from Note

**What to build:** A Reading says what it is measured against, and in chromatic mode nothing is being
aimed at. Today one field carries both meanings — the String a player is tuning toward, and the
equal-tempered note nearest what they just played — so the presentation layer guesses which it is
holding, and "in tune" is claimed in a mode where it means nothing.

**Blocked by:** 7 — Grade Evidence as a type

**Status:** ready-for-agent

- [ ] A Reading carries either a Target or a Note, never both ambiguously.
- [ ] A chromatic Reading carries a Note and no Target, and does not claim a String is in tune.
- [ ] The String modes continue to carry a Target, and deviation from it remains actionable advice.
- [ ] The presentation layer no longer infers which kind it is holding.
- [ ] The suite is green.
