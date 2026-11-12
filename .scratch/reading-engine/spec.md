# Reading engine — spec

**Status:** ready-for-agent
**Date:** 2026-11-12
**Vocabulary:** `CONTEXT.md` is the glossary; module, interface, seam, adapter, depth,
leverage and locality are used as in the codebase-design vocabulary.
**Decisions recorded:** `docs/adr/0001-stream-clock-inside-host-clock-on-readings.md`,
`docs/adr/0002-overload-is-an-explicit-discontinuity.md`.

## Problem Statement

The test-tuner port landed the engine in thirteen pieces, and the analysis session is where
the pieces are glued together. That glue has no module of its own, and it shows:

- **Two assemblies.** The session builds framer → detector → tracker → confirmation →
  throttle → adapt for the app; the parity suite builds its own copy. Parity is proven on an
  assembly the app does not run.
- **String completion three times.** `TuningFeedback` computes it before the 12 Hz throttle
  and the session discards the result; `FaithfulGuidedSequence` is tested and unused; the
  live rule is inline in the session and runs only on published **Readings**.
- **One timestamp, two clocks.** The frame's capture time feeds the tracker (which needs the
  stream clock) and the hold fade (which needs the host clock).
- **A latest-wins mailbox in front of a stateful stream**, and engine state that the main
  thread resets under a lock while the worker mutates it without one.
- **Two engines behind one interface.** The previous detector, tracker and spectral scorer
  (2,110 lines) are in the app target and reachable only when a test injects a tracker; nine
  test files drive them through the session.
- **Two Target types and three resolvers**, translated in five places in the session and
  back again in the adapter, with fallbacks that invent a **Target**.
- **Engine input wider than what it reads.** Toggling display precision resets a **Reading**
  in progress.
- **The listening lifecycle is five flags in the view model**, with the same teardown
  written four times.

## Solution

1. **A Reading engine module.** Synchronous, no threads, no locks. Raw captured audio of any
   chunk size plus a resolved **Tuning** in; one outcome per hop out: nothing to show, clear
   the display, or a **Reading** to publish — with guided progress and **Level**. It owns
   framing, detection, tracking, confirmation, the throttle and hold, the translation to
   domain types, and the guided sequence.
2. **The session keeps concurrency only**: a bounded queue of raw audio, one worker that is
   the engine's sole owner, generation, publication. Configuration reaches the engine as a
   message on the worker. Overload is an explicit discontinuity (ADR 0002).
3. **Host clock on every Reading**, stream clock confined to the engine (ADR 0001).
4. **String completion at tracker cadence**, before the throttle, credited only to the
   **String** currently being guided.
5. **The parity suite drives the Reading engine.** The separate replay assembly is deleted.
6. **The previous engine moves to the test target** as a comparison oracle with its own
   replay helper; its suites are kept unchanged. Which of them get re-expressed against the
   Reading engine is decided later, suite by suite. The five signal-advice states only it
   could produce (faint, quiet, noisy, clipping, ambiguous) are removed from the app.
7. **One Target translation, at the engine's seam.** The ported tracker stays frozen,
   including its tuning-id lookup and `TUNINGS`; the engine always hands it explicit
   **Targets** from `Tuning.resolve`. `FaithfulTargetResolver` and
   `FaithfulPrecisionPreference` are deleted.
8. **Engine input is what changes what is heard**: **Instrument**, **Targets**,
   **Calibration**, mode, locked **String**. Precision is a display preference;
   `TunerConfig.guided` goes in favour of `mode == .guided`. Stored preferences keep their
   `guided` field so existing saves load.
9. **A listening lifecycle module** owns permission, the player's intent, interruptions,
   route changes and the tone/capture handoff, drives the session, and reports one status.

## Out of scope

- Changing anything the parity contract measures. Detector, tracker and presentation ports
  are not edited.
- Re-expressing the previous engine's suites against the Reading engine.
- New signal advice (clipping, too quiet) on the Reading engine.

## Acceptance

- The app target contains no previous-engine source and no session branch for it.
- The parity suite passes while exercising the same module the session runs.
- A **Held reading** fades over its hold window when the display compares it with the host
  clock, proven by a test at the engine's interface.
- A capture callback carrying several hops delivers every hop to the detector, proven by a
  test at the session's interface.
- Toggling precision does not change the session's generation.
- The view model contains no microphone, permission or tone sequencing.
- The suite is green at every ticket (one known flaky test is recorded in
  `docs/tuner-reliability`).
