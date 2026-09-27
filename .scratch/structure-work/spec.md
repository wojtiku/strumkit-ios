# Structure work — spec

**Status:** ready-for-agent
**Date:** 2026-09-27
**Vocabulary:** `CONTEXT.md` is the glossary. Every term below is used as defined there.
**Execution:** `docs/superpowers/plans/2026-09-27-structure-work-execution-plan.md` — the
step-by-step, gates and rollback. This document is the *contract*; that one is the *procedure*.
**Evidence and rationale:** `docs/superpowers/specs/2026-09-26-app-structure-design.md`
(retained; partly superseded, see its banner).

---

## Problem Statement

The tuner's detection layer has grown a set of structural properties that make the next piece
of planned work — the remainder of the detection-layer plan, Tasks 11 and 12 — harder to land
than it needs to be, and that leave the half of the app above the detector untestable.

From the perspective of someone about to do that work:

**The coordinator owns decisions that are not coordination.** The single class that sequences
frames, invalidates in-flight results, and publishes snapshots also carries the evidence
thresholds that decide whether a spectral candidate may name a Note, and those thresholds are
declared as public constants on the coordinator itself. Changing "what counts as enough
evidence" means opening the file whose job is draining a queue. Sixteen thresholds live there.

**Two modules depend on each other.** The trust rule that a Sustained reading may never assert
a String is in tune is expressed as a constant on the coordinator and read back by the state
machine that owns tracking. The lowest-level module in the pipeline, the estimator, reaches
into the state machine for a duration constant. There is no layer that can be read top to
bottom.

**The estimator's interface is larger than the knowledge it carries.** Its entry point takes
seven parameters, two of which exist only so it can re-derive a single yes/no answer its caller
has already computed with the correct clock — and computing that answer is what drags in the
dependency on the state machine.

**Tuning resolution is written four times.** The same validity rule for a custom tuning appears
four times across two modules, and the target list is derived independently of the config it
came from. The two can disagree, and each of three setters performs the resolution by hand a
third time.

**The app above the detector cannot be tested.** The audio capture service is a concrete type
with no interface above it, so there is no way to exercise the ViewModel's audio lifecycle —
permission, start, stop, interruption, route change, reference tones, hold expiry — without
real audio hardware. Roughly a third of the ViewModel is untested as a result, and two genuine
bugs in it are held in place by nothing but explanatory comments.

**The layers are conventions, not boundaries.** One module, every type public, and every test
reaching past every interface. Nothing stops the next change from re-merging what the next
phase separates.

And the vocabulary does not describe what the code does. A single boolean records two different
kinds of weaker Evidence as equivalent, when their failure modes differ in kind. One word
means both "the String you are aiming at" and "the equal-tempered note nearest what you just
played", and the presentation layer guesses which it has.

## Solution

Restructure so that each module owns one idea, the acceptance Evidence lives with the thing
that produces it, and the audio edge becomes a seam that can be crossed by something other
than a microphone.

Six pieces of work. Three of them are code motion in which **no constant changes value** —
they are moves, and the tests that already exist are the gate. One adds behaviour, and it is
the only one that needs a careful revert. Two are cleanup.

The property to aim for is not fewer lines. It is that a reader can answer "where does this
decision live?" in one place, and that Tasks 11–12 can edit the detector without editing the
thing that schedules it.

Deliberately **not** done: a Swift Package Manager split, any change to the detection
algorithms or their thresholds, any Swift concurrency rework, and any view decomposition.
Growth is not a goal, which is what the split would have been for.

## User Stories

The actors here are not the person playing the tuner. Nothing in this spec changes what the
tuner shows a player, and that is deliberate — it is why the first three phases can be gated
entirely on existing tests.

1. As whoever executes the remaining detection-plan tasks, I want the coordinator to own only coordination, so that Tasks 11 and 12 edit a file with one job rather than three.
2. As whoever executes the remaining detection-plan tasks, I want the Evidence thresholds declared next to the Evidence they judge, so that tuning them does not mean opening the queue-draining module.
3. As whoever executes the remaining detection-plan tasks, I want no module to depend on the module above it, so that I can read the detection path top to bottom without a reach-through.
4. As whoever executes the remaining detection-plan tasks, I want the estimator's interface to state only what it cannot infer, so that I am not maintaining a second copy of the caller's liveness decision.
5. As whoever executes the remaining detection-plan tasks, I want the detection suites to stay byte-identical through a structural change, so that a red suite always means behaviour changed rather than code moved.
6. As a future agent picking up this work cold, I want a spec that says what problem is being solved, so that I do not re-derive the reasoning from the code.
7. As a future agent picking up this work cold, I want the execution order and its blocking edges stated, so that I do not reorder phases and invalidate a gate.
8. As a future agent, I want the domain glossary to be accurate at the time I read it, so that I do not implement a third Evidence level that no longer exists.
9. As a maintainer changing tuning resolution, I want one place that validates a custom tuning and derives the resulting config and target list, so that I cannot fix one copy and leave three stale.
10. As a maintainer changing tuning resolution, I want the config and the target list to come from the same resolution, so that "the config says one thing and the targets another" becomes unrepresentable rather than merely unlikely.
11. As a maintainer, I want a change to the tuner's behaviour policy to require reading one file, so that I can find it without a text search across the audio layer.
12. As a maintainer, I want the sustained-versus-uncertain distinction recorded as a type rather than a flag, so that a future path cannot silently inherit the wrong trust level.
13. As a maintainer, I want a Reading in chromatic mode to be honest about having no Target, so that "in tune" stops being a claim in a mode where it means nothing.
14. As a maintainer of the display, I want the hold fade driven by the timeline rather than by a 30 Hz poll, so that the display's lifetime is owned where the display is.
15. As a maintainer, I want dead code and stale comments removed, so that the next reader is not sent to a file that no longer describes the code.
16. As a maintainer, I want the generated project file regenerated rather than merged, so that I never hand-resolve a conflict in a build artefact.
17. As a maintainer, I want the layers to be something the compiler enforces, so that they survive the next change without review discipline.
18. As a developer testing anything above the detector, I want an interface at the audio edge, so that I can exercise the lifecycle without a microphone.
19. As a developer testing interruption handling, I want to assert that the tap is actually removed, so that a cosmetic "stop" cannot pass as a real one.
20. As a developer testing route changes, I want to assert that capture restarts, so that the handler is covered rather than merely present.
21. As a developer testing permission denial, I want to assert that the source is never started, so that a denied microphone cannot reach the audio stack.
22. As a player whose microphone permission is denied, I want reference tones to still be offered, so that the app remains useful when tuning is impossible — and I want that guaranteed by a test rather than by a copy string.
23. As a player, I want the tuner to restart after an interruption I did not cause, so that a phone call does not end my session — and I want that guaranteed by a test.
24. As a player, I want the tuner not to restart when I deliberately stopped it, so that an interruption does not override my intent.
25. As a developer, I want a test double for the microphone that records what it was asked to do, so that I can assert on requests rather than on sound.
26. As a developer, I want the tap size and the ring-buffer sizing to be the adapter's decision, so that the caller's interface does not carry transport details it cannot use.
27. As a developer, I want a window of captured audio to arrive as one typed value, so that a caller is not handed five positional parameters and must know which are safe to ignore.
28. As a developer, I want the session's own generation counters applied inside the session, so that a source implementation cannot get invalidation wrong.
29. As a developer, I want a full test suite I can run in seconds, so that I run it instead of guessing.
30. As a developer, I want the reason the test build is optimised recorded next to the setting, so that nobody reverts it as a performance mistake.
31. As a developer, I want to be able to run the suite unoptimised deliberately, so that I can debug unoptimised behaviour when I need to.

## Implementation Decisions

**Vocabulary and Evidence**

1. Evidence becomes a two-level type on the pitch result: *Measured* (periodicity found in the
   audio) and *Sustained* (a Note already being tracked, extended through a decay). The boolean
   it replaces is removed.
2. This is a naming change, not a behaviour change. Only Measured Evidence may assert a String
   in tune and only Measured Evidence may complete a Tuning sequence — identical to the policy
   in force. No existing assertion changes.
3. The grade is an enum with two live cases rather than a boolean even though only two
   behaviours exist, so that a third path added later has to choose a level explicitly instead
   of inheriting Sustained's.
4. A third level, for naming a Note no other evidence has confirmed, **does not exist in this
   codebase.** The path that produced it was dropped at the merge because its own measurement
   recorded it as blocked: its separation gate rejected exactly the weak fundamentals it existed
   to rescue. The finding is retained in the measurement log. Any future attempt is a new
   decision, gated on a discriminator measured to work.
5. The rule governing whether recovered evidence may assert in tune moves from the coordinator
   to the type carrying the evidence. This removes the only dependency the state machine had on
   the coordinator.

**Target and Note**

6. A Reading carries either a Target or a Note, never both ambiguously. In the String modes it
   carries a Target; in chromatic mode it carries a Note and no Target.
7. "In tune" is only meaningful against a Target, so a chromatic Reading does not assert it.
   The presentation layer stops inferring which kind it is holding.
8. Tuning resolution becomes one module returning both the config and the target list, derived
   together. The three hand-rolled copies in the ViewModel are deleted.

**Layers and interfaces**

9. The estimator's entry point takes four parameters instead of seven. The two removed carried a
   timestamp pair used solely to decide whether a **Sustain**ed **Note** was still live — a
   decision the caller makes with the correct clock before it branches. The estimator no longer
   knows a grace window exists; how long a **Sustain** lasts is tracker state.
10. A sustained **Note** crossing that interface is passed only when already known to be live, so
    "no argument" and "expired argument" cannot be confused.
11. A new seam sits at the audio edge: a microphone source protocol plus a typed window value
    and an event type. The implementation owns the sample rate, tap size, ring buffer and
    device-specific session configuration; the caller knows none of it.
12. Tap size and callback-frame diagnostics leave the caller's interface. The tap size is the
    adapter's decision; the diagnostic is derived from what the window already reports.
13. Generation and sequence counters are applied inside the session when it builds a frame, not
    supplied by the source. A source implementation cannot get invalidation wrong.
14. The session gains a single start verb that owns wiring the source into frame submission,
    translating interruption and route-change events into invalidation, and stopping the source
    on teardown. Callers stop having to remember to stop capture, stop analysis, and re-arm
    both.
15. A reference-tone player seam is introduced. The synthesiser is already integration-tested;
    the seam exists so a test can assert *which tone was requested*, which today is only
    observable by ear.
16. The ViewModel accepts its dependencies rather than constructing them, and they are required
    rather than defaulted, so a test cannot be handed a real microphone by omission.
17. The ViewModel does **not** take a clock. The hold fade moves to a timeline-driven view, which
    removes the need.

**Display ownership**

18. The hold fade is derived from the timeline in the view. The 30 Hz poll, the published
    opacity value, and the associated bookkeeping are deleted.
19. Clearing the Reading when the hold expires stays in the ViewModel, because it changes
    observed state — but as a one-shot scheduled task rather than a poll.

**Build and layout**

20. The test target is optimised; the app target is not. This is not a preference: the
    unoptimised suite takes long enough that the test host is killed partway through, and the
    test runner reports the tests that never ran as failures. At the optimised setting the same
    traces finish in a small fraction of the time with byte-identical output, measured and
    recorded in the measurement log.
21. The reason, the numbers, and the citation live beside the setting, so the next person does
    not revert it as a performance mistake.
22. A slow path remains available by explicit request, for debugging unoptimised behaviour.
23. The generated project file is regenerated from its source of truth, never hand-merged. It is
    added to version control changes only when regeneration is genuinely required.
24. Files are grouped so each group holds one idea: domain vocabulary, tuning resolution,
    detection, coordination, audio input, presentation.
25. Visibility is reduced to what is actually needed across each seam. This is the enforcement
    mechanism, and it is deliberately not a package split.
26. A package split is explicitly rejected. Its only justification was making a future second
    detector cheap to add, and that future is not committed to. It would also churn the build
    configuration in the same cycle as the remaining detection work.

**Dead code**

27. The spectral noise filter is deleted. It is never instantiated, it is not a working filter,
    and the tracker's ambient floor already covers its function.
28. An unused signal-condition enumeration, an unused scorer feature flag, and an
    over-visible resampling method are removed.
29. The "new samples in this window" field, its tap parameter, and its call sites are deleted.
    It existed to feed a stateful consumer of the WebTuna engine; that consumer is a separate
    package driven by tests, not the live capture path, and nothing reads the field.
30. Two stale documentation comments are corrected, one of which described a type deleted
    several commits earlier.

## Testing Decisions

**What makes a good test here:** it asserts on observable outcomes through the module's
interface, and it survives an internal refactor. If a test has to change when the
implementation changes, it is reaching past the interface. Concretely — assert that the
microphone was stopped, not that a private flag was set; assert that a Reading was dropped, not
that a counter incremented.

**Seams.** Two in total.

- The existing highest seam, the session's synchronous frame-processing entry point, is where
  all detection testing already happens and stays there. The 120 existing tests cross it and are
  not modified by this work.
- One new seam, at the audio edge, proposed at the highest point that works — the microphone —
  so that the ViewModel's entire lifecycle becomes reachable rather than just its configuration
  half.

Deliberately **not** new seams: the state machine, the spectral scorer, the estimator. Each is
already tested through its interface with the largest test file in the suite. Adding a seam
there would be a hypothetical one.

**Which modules get tested, and how**

- The estimator's interface change and the trust-rule move are covered by existing tests for
  sustain behaviour. No new test is required, and no existing assertion is edited.
- Tuning resolution is covered by three existing tests that drive a real ViewModel through
  instrument change, preset change, calibration and custom-tuning edits. Those tests must pass
  **unmodified** — they are the gate for the collapse of four copies into one.
- One genuine gap gets closed while there: those tests only ever pass *valid* custom tunings, so
  no fallback path is pinned. Add one case per rule — wrong string count, out-of-range note,
  unknown preset id.
- The microphone seam gets a recording test double that emits scripted windows and records what
  it was asked to do. Six tests: denied permission never starts the source; interruption removes
  the tap, not just the analysis; resumable interruption restarts only if listening was
  intentional; route change restarts capture; a reference tone is requested even when the
  microphone is denied; changing instrument replaces targets and clears the reading.
- Two of the six extend existing coverage rather than opening new ground. The remaining four are
  currently impossible.
- The hardware adapter is not unit-tested. Its correctness is the fixture-replay suite's job,
  which exists.

**Discipline on the new tests.** Four of the six must **fail** before the ViewModel's
dependencies become injectable. If they pass already, the seam was not the problem and the test
is not earning its keep — delete it rather than keep it.

**Prior art.** The fixture-replay suites are the model: recorded audio, a deterministic frame
trace, and assertions phrased as measured figures printed alongside the verdict rather than
magic numbers in isolation.

**Standing constraint on all of it.** No assertion may be loosened to reach green. The
measurement log records why: a separation gate set to an arbitrary 1.60 rejected exactly the
cases its path existed to rescue, and lowering it to make a suite pass was explicitly not
justified by anything measured. A structural change that requires moving a number is not a
structural change.

**Gate for every phase:** the full suite stays green and no phase reduces coverage. Plus four
standing numbers that must not move: correct readings per fixture, zero wrong readings, zero
transitions between Strings, and trailing held readout in its measured range. If a structure
change moves those, it is not a structure change.

## Out of Scope

- **Any change to the detection algorithms or their thresholds.** Every acceptance number belongs
  to the detection spec, on evidence. This work relocates constants; it does not retune them.
  If a constant needs to change, that is a separate decision with its own evidence.
- **Acquisition.** Dropped at the merge, with its finding retained. Not to be revived here.
- **A Swift Package Manager split.** Rejected: its only justification was growth optionality, and
  growth is not a goal.
- **Swift concurrency rework.** Ten unchecked-sendable annotations, strict concurrency on, and
  the reasoning recorded at each site. Changing them is a separate and larger piece of work.
- **Any change to the state machine.** It is the module the rest of the app should resemble: one
  processing entry point, the largest test file in the suite crossing it.
- **View decomposition.** The existing component split is reasonable. A large view is not the
  same as a shallow one.
- **Anything a player sees**, with one exception. No reading, colour, message, or timing a
  player can perceive changes. That is what lets the first three phases be gated on existing
  tests alone. The exception is the chromatic-mode verdict, which is a correction rather
  than a change: the glossary says chromatic mode is never "in tune", and the player was
  being told "Tune up" or "Tune down" about a String that mode never chose. Removing that
  advice is the ticket's purpose, not a side effect of it. The cents deviation and the
  needle direction are still shown — a chromatic tuner still reports distance from equal
  temperament; only the instruction about a String it is not aiming at is gone.
- **Acquiring new audio, hardware, or a physical device.** No phase requires one.

## Further Notes

**Why the first three phases change no behaviour.** They are moves, and the gate is that the
existing suite stays green without an assertion being touched. The reviewer of such a change
should read it as a diff with no constant changes; any constant that moves is a rejected change.
The value is not in the result but in what Tasks 11 and 12 no longer have to unpick.

**One merge has already shaped this work.** The detector's coordinator was recently reconciled
from two divergent lines, and the reconciliation is worth knowing about because it produced
three compile failures in the same shape: modules that changed on only one side merged in
whole, carrying call sites written against a coordinator that no longer existed. That is the
concrete argument for reducing the coordinator's surface — a smaller interface has fewer call
sites to invalidate. This is anecdote rather than argument, but it is the kind that predicts
where the next merge will hurt.

**Sequencing against the detection plan.** Phases 1–3 go before the remaining detection tasks,
because those tasks edit the same three files and 33 commits have already gone through them.
Phase 4 is the deferrable one: its argument is durability rather than urgency, and it touches
the audio edge and the ViewModel, not the detection path — so it will not conflict.

**Deliberate deferral.** The design document that seeded this spec is retained but marked
superseded, including its now-fixed headline finding. It is kept for the reasoning and the
vocabulary decisions, not for its conclusions.
