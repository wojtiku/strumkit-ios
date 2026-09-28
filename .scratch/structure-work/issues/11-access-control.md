# 11: Access control

**What to build:** The layers become something the compiler enforces rather than something review
discipline enforces. Today one module makes every type public and every test reaches past every
interface, so nothing stops the next change from re-merging what the earlier tickets separated.

This is deliberately not a package split. A split would churn the build configuration in the same
cycle as the remaining detection work, to buy enforcement obtainable here for free.

**Blocked by:** 10 — File layout

**Status:** ready-for-agent

- [ ] Each declaration is as visible as it needs to be across its seam, and no more.
- [ ] No test needs a visibility widened. Where one does, that test is reaching past an interface — record it rather than accommodate it.
      *Note added after implementation: this criterion was met vacuously. The baseline was `public`
      everywhere, so `@testable` already saw everything and nothing could have needed widening.
      The substantive work was the eight reach-throughs recorded in the plan, which were
      accommodated in substance while satisfying the letter of this line.*
- [ ] No package split is introduced.
- [ ] The suite is green, with no test modified to accommodate a visibility change.
