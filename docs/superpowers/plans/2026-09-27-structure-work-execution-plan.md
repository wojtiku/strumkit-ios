# Structure work — execution plan

**Date:** 2026-09-27
**Target branch:** `main` (the detection-layer work is merged; Tasks 11–12 of the detection
plan remain, and are tracked in `2026-09-25-detection-layer-phases-0-3.md`, not here)
**Design:** `2026-09-26-app-structure-design.md` — read its §2 for evidence
**Vocabulary:** `CONTEXT.md` — use these terms in commit messages and test names
**Baseline:** 120 tests in 21 suites, 7.1 s at `-O`. Every phase below must leave that green.

---

## What this is

Six pieces of work, in dependency order, each independently landable and revertible. The
first three are code motion with **no constant changing value** — they are moves, verified by
the tests that already exist. The fourth is new behaviour with new tests. The fifth and sixth
are cleanup.

Nothing here touches the DSP. If a threshold needs to move, that is the detection plan's job,
on its evidence.

### The goals this serves

Recorded because they decide scope, and scope is where this plan is opinionated:

- **(a) Make the detection plan cheaper to execute.** Tasks 11–12 still have to edit
  `TunerAnalysisSession`, `PitchTracker` and `PitchDetector`. Phases 1–3 make those files
  smaller and single-purpose before that happens.
- **(b) Make the app testable through its interfaces.** The audio lifecycle has no test
  surface today. Phase 4 builds it.
- **(d) Hygiene.** `Models/` holds four things that are not models. Two files carry stale
  comments. One type is dead.

**Explicitly not a goal: growth.** No second detector, no third instrument, no watchOS. This
is why Phase 5 has no Swift Package Manager split — its only justification was making a future
detector cheap to add, and that future isn't committed to.

---

## Phase 0 — Verify the baseline (do this first, it is 2 minutes)

```bash
make test          # -O, ~7 s. Must be 120 tests / 21 suites, all passing.
make test SLOW=1   # -Onone. Expected: slow (~272 s) and the host may be killed.
```

The second command is expected to misbehave. That is the documented reason `-O` is the
default (`RESULTS.md` §11, "Build configuration": 276 s → 2.5 s, byte-identical output). Run
it once so you have seen the failure mode, then never again unless debugging unoptimized
behaviour.

**Gate:** 120/21 green. If not, stop — the merge is the thing to fix, not this plan.

---

## Phase 1 — Break the cycle and shrink `detectPitch`

The smallest phase, and the one that makes Phase 2 possible. Two changes, no new tests: the
existing `PitchTests` and `TrackerTests` already cover prior-continuity behaviour extensively.

### 1a. Move the trust rule onto the type it constrains

`PitchTracker.swift:454` currently reads:

```swift
let inTuneMayBeAsserted = !pitchResult.recovered || TunerAnalysisSession.recoveredFramesMayAssertInTune
```

That is a cycle: the session owns the tracker *and* the tracker reaches back for a constant
on the session. The rule being expressed — *a spectrally recovered estimate may move the
needle but never become tuning advice* — is a property of the estimate, not of the
coordinator.

Move it to `PitchResult` beside the `recovered` flag it governs:

```swift
// In MusicalNote.swift, on PitchResult:
public static let recoveredMayAssertInTune: Bool = false
```

Update the call site. Delete `TunerAnalysisSession.recoveredFramesMayAssertInTune`.

**Gate:** suite green, no assertion edited. The cycle is gone — `grep -rn "TunerAnalysisSession\." StrumKit/Audio/PitchTracker.swift` returns nothing.

### 1b. `detectPitch`: seven parameters to four

`priorAt` and `now` exist for one purpose, at `PitchDetector.swift:280-281`:

```swift
hasPrior = (now >= priorAt) && (now - priorAt <= priorWindow) && priorFrequency.isFinite
```

where `priorWindow` is `PitchTracker.priorGraceDuration` — the second reach across the seam.
But the caller already computed exactly this predicate, with the right clock, at
`TunerAnalysisSession.swift` before it branches on recovery. It is re-deriving a `Bool` its
caller is holding.

```swift
// before
public func detectPitch(
    in buffer: [Float],
    noiseGateRMS: Float = 0.0001,
    yinThreshold: Float = 0.15,
    referenceA4: Double = TunerConstants.defaultA4Hz,
    priorFrequency: Double? = nil,
    priorAt: TimeInterval? = nil,
    now: TimeInterval = 0
) -> PitchResult

// after — nil means "no live prior"
public func detectPitch(
    in buffer: [Float],
    noiseGateRMS: Float = 0.0001,
    yinThreshold: Float = 0.15,
    referenceA4: Double = TunerConstants.defaultA4Hz,
    livePriorFrequency: Double? = nil
) -> PitchResult
```

The session passes `prior?.frequency` only when it has already established the prior is inside
the grace window. The detector then no longer knows a grace window exists — which is the
correct division of labour. How long a prior survives is tracker state.

**Gate:** suite green. This is the only change in the plan that *removes* something a caller
must know.

---

## Phase 2 — One place for tuning resolution

The custom-MIDI validity check — `count == expectedCount && allSatisfy { in
customMidiMin...max }` — is written **four times**: three in `TunerViewModel` (`setInstrument`,
`setTuningPreset`, `updateCustomMidi`) and once in `TunerPreferences.activeConfig`. Separately,
`TunerViewModel.computeTargets` re-derives target construction from `tuningId` + `customMidi`,
which is the same resolution `activeConfig` already performed to produce the config. The two
can disagree, and each setter performs the resolution a third time by hand.

Collapse into one module:

```swift
/// Resolves what the player has chosen into what the tuner will actually do.
public enum Tuning {
    public struct Resolved: Sendable {
        public let config: TunerConfig
        public let targets: [StringTarget]
    }

    /// Validates and falls back: an unknown preset id, a wrong-length custom array, or an
    /// out-of-range MIDI note resolves to the instrument's default rather than trapping.
    public static func resolve(
        instrument: InstrumentCategory,
        tuningId: String,
        customMidi: [Int],
        mode: TunerMode,
        a4: Double,
        precision: Bool
    ) -> Resolved
}
```

- `TunerPreferences.activeConfig()` becomes `Tuning.resolve(...).config`
- `TunerViewModel.computeTargets` is deleted; the ViewModel holds one `Resolved` and both
  `config` and `targets` read from it
- Delete the three hand-rolled copies in the ViewModel

**Already protected.** `PreferencesTests:93-172` drives `setInstrument`, `setTuningPreset`,
`updateCustomMidi` and `updateA4` through a real ViewModel and asserts the resulting config
and targets. Those three tests are the gate — they must pass **unmodified**.

**Known gap to close while you are here:** those tests only ever pass *valid* custom-MIDI
arrays, so no fallback path is currently pinned. Add one case per rule: wrong count,
out-of-range note, unknown preset id. This is the one place Phase 2 adds tests.

**Gate:** 120 + 3 green, the original three `PreferencesTests` untouched.

---

## Phase 3 — Dead code and stale comments

Cheap, and it is what makes the Phase 5 layout move unambiguous.

| Item | Action | Evidence |
|---|---|---|
| `SpectralNoiseFilter` (99 lines) | **Delete** | Never instantiated. Not a working filter — `observeFrame` bins time-domain samples by index as though they were frequency bins. `PitchTracker`'s ambient floor covers the function. |
| `SignalCondition` | Delete | Declared `TunerTypes.swift:56`, referenced nowhere. |
| `SpectralPitchScorer.isScoringEnabled` | Delete | Guard at `:279`, never set false. |
| `Resampler.getCoefficients` | Make `private` | Called only from `resampleWindow`. |
| `AnalysisFrame.newSampleCount` + the 5th tap-closure parameter + its 2 call sites | Delete | Vestigial after the merge. It existed only for the WebTuna stateful ring; that consumer is the separate SPM package at `docs/tuner-reliability/webtuna/swift-reference/`, driven by `CrossEngineComparisonTests`, not the live capture tap. Nothing reads it. Touches `TunerTypes.swift`, `AudioCaptureService.swift`, `TunerViewModel.swift`, `InputLevelMeasurementTests.swift`. |
| `TunerTypes.swift:204` doc comment | Fix | Reads *"Selects which detector advances the tracker"* — a leftover from a type deleted in `9f00938`. |
| `TunerAnalysisSession.swift:50` comment | Already fixed | Said "further into a decay than acquisition"; acquisition no longer exists. |

**Gate:** 120 green. `grep -rn "SpectralNoiseFilter\|SignalCondition" StrumKit` returns nothing.

---

## Phase 4 — The microphone seam

The biggest phase, and the only one that adds behaviour. It is also the only place in this plan
where *two adapters means a real seam*: `AVAudioEngineMicrophone` exists, and the replay path
in `AudioTestHelpers` is already a second implementation with no interface to satisfy.

**This is what buys goal (b).** Everything above the detection layer is currently untested
except the three preference tests, because `AudioCaptureService` is a concrete `final class`
and there is no way to observe a request without making real audio hardware noise.

### The interface

```swift
/// What the tuner needs from a microphone: windows of audio, timestamped on the host
/// monotonic clock, at whatever cadence the hardware provides.
///
/// An implementation owns the sample rate, the tap size, the ring buffer, and the
/// device-specific `AVAudioSession` configuration. A caller knows none of that.
public protocol MicrophoneSource: AnyObject, Sendable {
    /// Delivered on an arbitrary thread.
    var onEvent: (@Sendable (MicrophoneEvent) -> Void)? { get set }

    /// Valid only while started; the hardware rate is not knowable before that.
    var sampleRate: Double { get }

    func start(delivering: @escaping @Sendable (CapturedWindow) -> Void) throws
    func stop()
}

public enum MicrophoneEvent: Sendable {
    case interrupted(resumable: Bool)
    case routeChanged
}

/// One window of newly-captured audio.
public struct CapturedWindow: Sendable {
    public let samples: [Float]
    public let sampleRate: Double
    /// Host monotonic time of the window's *trailing edge*. The DSP's age maths
    /// (`resultAgeMs`) is measured from here, so it must not be a media timeline.
    public let captureEnd: TimeInterval
}
```

What this fixes at the seam:

- **Tap size stops being the caller's problem.** `bufferSize:` leaves the interface; it is the
  adapter's decision. `requiredInputSamples` and the ring-buffer sizing go behind the seam.
- **The 5-parameter closure collapses** to one typed value.
- **Generation and sequence stop crossing the seam.** The source does not know about the
  session's generational invalidation; the session stamps `AnalysisFrame(sequence:generation:)`
  from its own counters. One less thing an implementer can get wrong.

### Order of work — each step compiles

1. `CapturedWindow`, `MicrophoneEvent`, the `MicrophoneSource` protocol. Additive.
2. `ScriptedMicrophone` in the test target. One implementer for one commit — a hypothetical
   seam that brief, by design.
3. `AVAudioEngineMicrophone`, extracted from `AudioCaptureService`. `AudioRingBuffer` and
   `ScratchBuffer` to their own file. `AudioCaptureService` becomes a thin caller, or is
   deleted if nothing else needs it.
4. `ReferenceTonePlayer` protocol + `AcousticStringSynthesizer` adapter + recording fake.
   **Note:** the synth already has an integration test (`PreferencesTests:174`). The protocol
   is **not** to make the synth testable — it is so a test can assert *which tone the ViewModel
   asked for*, which today is only observable by ear.
5. `TunerAnalysisSession.start(source:config:targets:)`, owning the wiring from source delivery
   into `submitLiveAudio`, `MicrophoneEvent` → generation bump, and source teardown. Callers get
   one verb instead of remembering to stop capture, stop analysis, and re-arm both.
6. `TunerViewModel` takes its dependencies instead of building them:
   ```swift
   public init(
       source: MicrophoneSource,
       referenceTone: ReferenceTonePlayer,
       preferencesStore: TunerPreferencesStore = .init()
   )
   ```
   No `clock` parameter — Phase 5 removes the need for one.
7. Write the tests below.

### The tests

`ScriptedMicrophone` emits scripted windows and records what it was asked to do:

```swift
final class ScriptedMicrophone: MicrophoneSource, @unchecked Sendable {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var isStarted = false
    private var deliver: (@Sendable (CapturedWindow) -> Void)?
    var onEvent: (@Sendable (MicrophoneEvent) -> Void)?
    var sampleRate: Double { 44_100 }

    func start(delivering: @escaping @Sendable (CapturedWindow) -> Void) throws {
        startCount += 1; isStarted = true; deliver = delivering
    }
    func stop() { stopCount += 1; isStarted = false; deliver = nil }
    func emit(_ window: CapturedWindow) { deliver?(window) }
}
```

| Test | Pins down |
|---|---|
| `testDeniedPermissionNeverStartsTheSource` | `start()` on `.denied` never touches the source |
| `testInterruptionStopsTheTapNotJustTheAnalysis` | `.interrupted` leaves `isStarted == false`. This is the bug the comment at `TunerViewModel.swift:93-96` describes — a cosmetic "stop" leaving the tap installed — currently held in place by nothing but that comment. |
| `testResumableInterruptionRestartsOnlyIfListeningWasIntentional` | Restarts when `listeningIntent`, does not when the user stopped |
| `testRouteChangeRestartsCapture` | The second handler — a different bug class: it stops and restarts unconditionally when listening |
| `testReferenceToneIsRequestedEvenWhenTheMicIsDenied` | Reference tones are the documented fallback for a denied mic (`EngineStatus.guidanceError`); nothing enforces it |
| `testChangingInstrumentReplacesTargetsAndClearsReading` | Extends `testPerInstrumentTuningPersistenceInViewModel`, which stops at `config` and never checks the reading was cleared |

**Before step 6 lands, the first four of these should fail.** If they pass already, the seam
was not the problem and the test is not earning its keep — delete it rather than keep it.

`AVAudioEngineMicrophone` is not unit-tested. It is the hardware adapter; its correctness is
the fixture-replay suite's job, which exists.

**Gate:** the six tests green, 120 unchanged. `AnalysisSessionTests` and `TrackerTests` are not
touched — they cross the detection seam and are good tests of a good module. Per
`DEEPENING.md`: replace, don't layer.

---

## Phase 5 — Vocabulary, display ownership, and layout

Four smaller changes, grouped because each is small and none depends on the others.

### 5a. Grade Evidence (do this one on its own commit)

`PitchResult.recovered` is a `Bool` set in two places that mean different things: extending a
`Note` already tracked (safe — the `Note` is known to exist) versus naming one nothing has
confirmed. `CONTEXT.md` calls these **Sustained** and, formerly, **Acquired**.

**Acquired no longer exists** — acquisition was dropped at the merge (`RESULTS.md` §13). So the
grade has two live levels, not three. Record it as an enum anyway, so a future acquisition
attempt has somewhere to put itself and cannot silently inherit Sustained's trust level:

```swift
public enum Evidence: Sendable { case measured, sustained }
```

with `recovered: Bool` becoming `evidence: Evidence`. Only `measured` asserts in tune. This is
**naming, not behaviour** — same policy, expressed as a type. No test should change.

### 5b. Split Target from Note

In chromatic mode `PitchTracker` synthesises a `StringTarget` per frame from the frequency just
detected, with `number: 0` and `targetIndex = -1`. Deviation from it is distance to equal
temperament, not advice about a string. `TunerReading.target` carries both meanings, and
`TunerPresentation.guidanceText` switches on `inTune`/`cents` without knowing which it has.

Make chromatic readings carry a `Note` and **no** `Target`, and have the presentation layer
stop guessing. This is a small change with a real payoff: "in tune" stops being a claim in a
mode where it is meaningless.

### 5c. `TimelineView` for the hold fade

`TunerViewModel` runs a 30 fps `Task` polling `CACurrentMediaTime` to fade one number, and
clears the reading when the hold expires. Move the fade to `TimelineView(.animation)` in the
view, derived from `reading.lastFreshAt`. Deletes the poll, the published `holdOpacity`, and
the `activeHoldFreshAt` bookkeeping.

**Keep** the clearing of the reading in the ViewModel — it changes observed state — as a
one-shot scheduled task, not a poll.

### 5d. Layout and access control

```
Domain/        InstrumentCategory, MusicalNote, PitchMath, PitchResult, TunerConstants,
               StringTarget, TunerReading, ReadingAim, Evidence, TunerMode, ToneMemory,
               TuningPreset, Presets
Tuning/        Tuning, TunerConfig, TunerPreferences, TunerPreferencesStore
Detection/     AnalysisFrame, AnalysisSnapshot, TunerDiagnostics, PitchDetector,
               SpectralPitchScorer, PitchTracker, Resampler, HannProjection
Analysis/      TunerAnalysisSession
AudioIO/       MicrophoneSource, MicrophoneEvent, CapturedWindow, AudioPermissionStatus,
               AudioCaptureError, AVAudioEngineMicrophone, AudioRingBuffer,
               AudioSessionConfiguration, ReferenceTonePlayer, AcousticStringSynthesizer
Presentation/  TunerPresentation, TunerTheme, EngineStatus, SignalFeedbackState,
               ViewModels/, Views/ (Components/ survives)
```

`App/` (entry point and `Info.plist`, which `project.yml` points at) and `Resources/` stay
where they are — they are not part of the six ideas.

Three placements this list did not settle, decided while doing the work:

- **`ReferenceTonePlayer` and `AcousticStringSynthesizer` are in `AudioIO/`,** read as "the
  audio device, both directions" rather than input-only. The synthesiser is an `AVAudioEngine`
  and `AVAudioSession` adapter sharing the hardware edge with the microphone, and splitting a
  protocol from its only implementation across two groups would be worse than either single
  reading. If `AudioIO` should mean input-only, these two move to `Presentation/` and nothing
  else changes.
- **`TunerConfig` is in `Tuning/`,** not `Domain/`. It is the output of the resolution and an
  input to detection, so it belongs to resolution rather than to vocabulary.
- **`AudioCaptureError` is in `AudioIO/` while `EngineStatus` is in `Presentation/`,** which
  looks inconsistent and is not. The error is thrown only by the audio edge and is part of
  what the seam promises; the status is read only by things that render it.

**Then drop the `public`s that are not needed.** One module, `@testable import` in every test
file, so this costs nothing and the compiler starts rejecting reach-throughs. This is the
enforcement story, and it is deliberately *not* an SPM split: that would touch `project.yml`
and the Makefile in the same cycle as Tasks 11–12, for enforcement obtainable here for free.

**Gate:** suite green. If a test needs a `public` back, that test is reaching past an interface
— note which, because that is the finding.

---

## Ordering, and one thing to do first

```
Phase 0  verify baseline                        2 min
Phase 1  cycle break + detectPitch 7→4          ~1 hour   ─┐
Phase 2  Tuning.resolve                         ~2 hours  ─┤ before detection
Phase 3  dead code + stale comments             ~1 hour   ─┘  Tasks 11-12
Phase 4  microphone seam + 6 tests              ~1 day
Phase 5  Evidence, Target, TimelineView, layout ~1 day
```

**Phases 1–3 before the detection plan's Tasks 11–12.** Those tasks edit the same three files
(33 commits have already gone through them). Doing 1–3 first means 11–12 land against a
coordinator that owns coordination and nothing else.

**Phase 4 is the one that could go either way.** Its argument is goal (b), which is durable
rather than urgent. If you would rather finish the detection work first, it is safe to defer —
it touches `AudioCaptureService` and `TunerViewModel`, not the detection path, so it will not
conflict with Tasks 11–12.

---

## Known flaky tests

Two tests fail intermittently under machine load. Both are timing races, neither is logic
errors, and neither should ever be fixed by loosening an assertion.

**`PreferencesTests.testAcousticStringSynthesizerPluck()`** drives real audio hardware through
the simulator. `playString` synthesises ~123k samples and starts an `AVAudioEngine` on a
background queue, and only then sets the state the test polls for; the test allows 1 second.
Under load, or if the engine fails to start, that budget can expire and the state stays `nil`,
behind a `print` nobody reads. Observed once, immediately after a run killed
mid-audio-teardown. Passed 3/3 full-suite runs and 6/6 in isolation afterwards.

**`AnalysisSessionTests.testBoundedMailboxAndReplacement()`** races a 10 ms sleep against a
background worker that then sleeps 60 ms in the analysis hook. If the process is descheduled
before the worker starts, the frame under test is drained as the next pending frame instead of
being replaced, and `replacedFrames` comes back 1 where 2 is expected. Observed twice, both
times while the machine was busy; 5/6 and 5/5 full-suite runs green before and after the
change it was suspected in.

**Two tests in the analysis-session suite are load-sensitive, and share one cause.**
`testBoundedMailboxAndReplacement()` and `testFrameAccountingCountsDrops()` both need the
background analysis worker not to have dequeued a frame before the next one arrives, because
the coordinator only counts a replacement while a frame is still sitting in the mailbox. They
race a 10 ms sleep against a worker that then sleeps 60 ms in the analysis hook, so under load
the worker wins and a replacement is never counted. Observed twice and once respectively, all
while the machine was busy; 5/6 and 5/5 full-suite runs green before and after the changes
they were suspected in. If either fails, re-run the full suite once before concluding anything.

**Re-run the full suite once before treating any of these as a real failure.** Fixing them
properly means waiting on real preconditions instead of time budgets — which is its own ticket,
not a drive-by, and not something to do while a refactor is in flight.

## Reach-throughs to record, not accommodate

Ticket 11's criterion is that a test needing a widened visibility is reaching past an
interface. Record it rather than accommodating it. One is already known:

- `PitchDetectionTests.testAudioRingBufferAccumulation` reaches the ring buffer directly
  through `@testable`, rather than crossing the microphone seam. It tests the ring buffer's
  own contract — accumulation across writes — which no seam test would exercise, so it is a
  legitimate direct test of a module that now sits behind the audio edge. Ticket 11 should
  record it as a deliberate exception rather than move or delete it, and say why.

Ticket 11 found seven more, and accommodated none of them. In each case the declaration
stayed `internal` — which is what `@testable` already sees — and the site now says in a
comment that it is visible for a test. None of them needed a visibility *widened*; that is
the point, and it is why the whole list could be recorded instead.

**A test reaching past a protocol it was handed.** `PreferencesTests.testAcousticStringSynthesizerPluck`
constructs `AcousticStringSynthesizer` concretely rather than through `ReferenceTonePlayer`,
and polls `activeStringIndex` to learn that the background queue has finished. It is the same
shape as the flake recorded above: a state flag standing in for "the work is done", with a
sleep loop in front of it. `activeStringIndex` is `private(set)`, so the test can read it and
cannot write it, which is the correct fence — but it is not on the protocol, and nothing in the
app reads it. The real fix is a completion the tone player reports, not a pollable field; that
is a change to `ReferenceTonePlayer`'s contract and belongs to its own ticket.

**Test-only entry points on production types.** Four types carry members that no app code
calls and that exist because a test does. They are not reaching *past* an interface so much as
being the interface's test-only annex, but they are the reason those members are visible at
all, so they are listed:

- `HannProjection.rawPower` and `HannProjection.phaseAndPower`. The detector uses
  `normalizedPower`; `CorrelationTests` needs the other two to check that the normalisation
  divides by the right thing and that the phase convention is the negative-imaginary one.
  Two functions in production code with no production caller.
- `SpectralPitchScorer.scoreAudio`, `.scoreWindow`, `.computeMagnitudes` and `.directDFT`.
  The Analysis group enters the scorer through `analyzeAudio` alone; these four are how
  `SpectralPitchScorerTests` checks the scorer against itself, `directDFT` being the
  hand-written reference the accelerated path is compared to. All four are now marked
  `internal` explicitly, so the test-facing surface is greppable.
- `TunerAnalysisSession.submitLiveAudio` and `.processFrameSync`. The second is already
  labelled a seam for "replay & tests", and replay only ever happens in the suite, so it is a
  test seam end to end. The first is the live path's own conversion from `CapturedWindow`,
  and `AnalysisSessionTests` calls it directly — below the `MicrophoneSource` seam that tickets
  04 and 06 built, in a file that also has `AudioSeamDoubles` for driving the same thing
  through the seam.
- `TunerPreferences.activeConfig()`. A one-line wrapper over `Tuning.resolve(self).config`,
  used only by `PreferencesTests`. It does go through the real resolution, so the test is not
  asserting against a parallel implementation — but the app never calls it, and it could not
  be made private without rewriting the test.

**Reaching into a value another group hands over.** Not a test: `TunerAnalysisSession`'s
spectral-recovery gate reads `HarmonicEvidence.peakFrequency` and `.peakMagnitude` out of
`SpectralPitchScorer.WindowAnalysis.evidence`, then does the scorer's arithmetic itself —
strongest partial, support fraction, count of supporting partials. The gate is written on the
far side of the scorer's diagnostic result, in a group that has no business knowing what a
harmonic's whitened peak is. Visibility cannot fix this one, because the scorer does not offer
the question the gate is asking; only the two fields the gate reads are visible now, and the
other four are private. The fix is a scorer-side answer to "how many supporting partials does
this candidate have", which is a design change and not a visibility one.

**An inverted dependency no visibility can express.** `SignalFeedbackState` lives in
`Presentation/`, and `Detection/` depends on it: `PitchTracker` produces it and
`AnalysisSnapshot` carries it. Both groups have to see each other, so there is no width that
makes the arrow point one way. It reads like Domain vocabulary — it describes the signal, not
the screen — and moving it is a layout change, which is ticket 10's subject and not this
ticket's. Recorded here because visibility work is what made it visible.

**Deliberately not reach-throughs**, so the next reader does not re-open them: the tracker's
`private(set)` hysteresis state (`ambientFloor`, `consecutiveYinSuccesses`,
`consecutiveYinFailures`, `shouldHoldThroughDropout`) is read by `TrackerTests` and the plan
already names `PitchTracker` as the module the rest of the app should look like.
`private(set)` is the right fence — a test can observe the streak and cannot fabricate it. The
`CoverageMatrixTests` reads of `PitchDetector`'s three energy gates are the spec's own gate
table, asserted as numbers. `TunerPreferencesStore.storageKey` is how a test plants corrupt
data. `AudioCaptureError.errorDescription` is a `LocalizedError` requirement, not an interface.

## Test-only entry points on production types

Production members that exist because a test needs them, and so are wider than the app
requires. Recorded rather than removed, because each answers a question no seam can:

- The coordinator's synchronous frame-processing entry point, for replay. Replay only ever
  happens in the suite, so it is a test seam end to end.
- Its live-audio submission, which the suite also calls directly — *below* the microphone
  seam, in a file that holds doubles for driving the same thing through the seam.
- The coordinator's analysis hook, written only from the session tests, and lock-guarded:
  the seam offers no way to observe work between submission and publication.
- The coordinator's spectral-recovery switch, written only from a test helper. It gates an
  experimental path that ships enabled, so no UI sets it.
- The scorer's four scoring methods, which the Analysis group does not use: the suite checks
  the scorer against itself through them, `directDFT` being the hand-written reference for
  the accelerated path.
- The stored preferences' active-config wrapper, with no app caller. It does go through the
  real resolution, so the test is not asserting against a parallel implementation, but it
  cannot be made private without rewriting the test.
- The correlation helpers' two functions, which the detector does not use; the suite needs
  them to check the normalisation and the phase convention.

## Gates

1. **The suite stays green after every phase.** No phase may reduce coverage.
2. **No constant changes value in Phases 1–3 or 5a.** Any threshold that moves is a rejected
   change; it belongs to the detection plan, on evidence.
3. **No assertion is loosened to reach green.** `SustainContinuityTests` is the standing
   example of why: `RESULTS.md` §11.4 records what happens when a threshold is moved until the
   suite passes — the acquisition gate at 1.60 was an arbitrary pick that rejected exactly the
   cases it existed to rescue, and lowering it was not justified by anything measured.
4. **North-star numbers stay put.** `quiet_a/c/e/g`: correct 86/149/103/99, `wrong=0`,
   `transitions=0`, trailing held 149/21/213/85 ms. If a structure change moves these, it is
   not a structure change.
5. **Suite wall clock stays in single-digit seconds** at `-O`. If a phase makes it slow, that
   phase added work to the hot path.

## Rollback

Phases 1–3 are code motion. `git revert` is sufficient; no threshold hunt. Phase 4 is the only
one that needs its own careful revert, which is why it is a single commit boundary per step.

## What this plan does not do

- **No DSP changes.** The detection spec owns every acceptance number.
- **No SPM split.** Growth is not a goal; see the goals section.
- **No Swift 6 concurrency rework.** `@unchecked Sendable` is in ten places,
  `SWIFT_STRICT_CONCURRENCY: complete` is on, and the annotations are load-bearing with the
  reasoning recorded at each site.
- **No change to `PitchTracker`.** It is the module the rest of the app should look like: one
  `process` entry point, and the largest test file in the suite crossing it.
- **No view decomposition.** `Views/Components/` already exists and is reasonable. `TunerView`
  is large but not shallow.
- **No acquisition.** Dropped at the merge, with the reasoning in `RESULTS.md` §13. Any future
  attempt is a new decision gated on a discriminator that is *measured* to work.
