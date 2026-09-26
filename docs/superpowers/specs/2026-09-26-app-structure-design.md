# App structure — seams and module design

> **SUPERSEDED for execution — 2026-09-27.** The reasoning and evidence below are kept as the
> record of *why* the seams sit where they do, and the vocabulary decisions from the grilling
> that produced it. **Some of it no longer describes the code, and the execution plan is the
> document to work from:**
> `docs/superpowers/plans/2026-09-27-structure-work-execution-plan.md`
>
> What changed after this document was written:
> - **§2.1's headline finding is fixed.** Spectral acquisition was dropped at the merge of the
>   detection branch (`RESULTS.md` §13 — its own measurement recorded it as blocked). There is
>   no longer duplicated acceptance logic, because there is only recovery.
> - **§5's `clock` parameter is gone.** The grilling chose `TimelineView` for the hold fade, so
>   the ViewModel takes no clock.
> - **§7's phase list is superseded.** Phases 1–3 now precede the detection plan's remaining
>   Tasks 11–12; this document predates that ordering.
> - **§9's open question is answered.** No Swift Package Manager split. Growth is not a goal.
> - **Every `file:line` reference in §2 is stale** — they point at the pre-merge coordinator.

**Date:** 2026-09-26
**Status:** superseded for execution; retained as design rationale
**Relates to:** `2026-09-25-tuner-detection-layer-design.md` (algorithm) and
`2026-09-25-detection-layer-phases-0-3.md` (its implementation plan).

This document is about **structure**, not behaviour. The detection spec is right that
StrumKit's estimator is sound and that the flapping symptom is a state-transition problem;
neither of those conclusions is disturbed here. What follows is an assessment of where the
app's modules and seams currently sit, which of them earn their keep, and a phased plan to
fix the ones that do not.

**Sequencing note.** Everything in Phase A and B below is a no-op for the DSP: no constant
changes value, no algorithm moves. Phases 0–3 of the detection plan can land in either order.
Phases C and D touch `TunerViewModel` and should land *after* the detection plan, so the
measurement infrastructure in Phase 0 is measuring a stable target.

---

## 1. Summary

Five findings, in descending order of leverage.

1. **The spectral acceptance policy has no module of its own.** ~150 lines that answer one
   question — *may this ranked candidate name a pitch?* — sit inside the concurrency module,
   as two near-duplicate implementations, with their 15 thresholds hung off
   `TunerAnalysisSession` as `public static let`.
2. **`TunerAnalysisSession` and `PitchTracker` depend on each other.** The trust rule for a
   recovered reading lives on the coordinator and is read back by the state machine.
3. **There is no seam at the audio edge.** `AudioCaptureService` is a concrete `final class`,
   so `TunerViewModel`'s entire audio lifecycle — permission, start, stop, interruption,
   route change, tone playback, hold expiry — has no test surface.
4. **`PitchDetector.detectPitch` takes two parameters that re-derive a predicate its caller
   already computed**, and does so by reaching into `PitchTracker` for a constant.
5. **The seams are conventions, not boundaries.** One module, everything `public`, tests use
   `@testable import`. Swift's access control enforces none of the intended layering.

---

## 2. Evidence

### 2.1 The acceptance policy is stranded

`TunerAnalysisSession.swift:473` (`acceptAcquisition`) and `:542` (`applySpectralRecovery`)
are ~150 lines that both:

- pick a candidate out of `WindowAnalysis.candidates`, filtered differently
  (`frequency > 0` vs. *and* within a search window of the prior)
- gate on an absolute score
- read `analysis.evidence[index]`, take the strongest peak, count partials above
  `spectralSupportFraction`
- reject octave-ish competitors, from a list of six hard-coded semitone offsets
  (`1200`, `1902`, `700`, ±) at `spectralAcquisitionRejectOctaveCents` (`:500-511`, `:590-595`)
- construct an identical `PitchResult` with `confidence` capped at `0.70` and `recovered: true`

The thresholds are declared at `TunerAnalysisSession.swift:40-130` — sixteen `public static
let`s whose only purpose is to be read by those two methods. A caller who wants to know "what
counts as enough spectral evidence" must open the file whose job is draining a queue.

The two call sites are not meaningfully different in kind. They differ in *policy*: recovery
may lean on a continuity prior and so uses a loose gate plus a local search window;
acquisition has nothing to lean on, so it uses a strict gate over the whole grid and demands
two-frame corroboration. That difference is four numbers and a `Double?`.

### 2.2 The cycle

```
TunerAnalysisSession  ──owns──▶  PitchTracker          (TunerAnalysisSession.swift:31, :703-706, :782)
PitchTracker          ──reads─▶  TunerAnalysisSession  (PitchTracker.swift:295)
```

`PitchTracker.swift:295`:

```swift
let inTuneMayBeAsserted = !pitchResult.recovered || TunerAnalysisSession.recoveredFramesMayAssertInTune
```

The rule being expressed — *a spectrally recovered estimate may move the needle but must never
become tuning advice* — is a property of the estimate, not of the coordinator that happens to
produce it. It is currently unreachable from `PitchResult` without importing the whole
concurrency module, so it is stated on the wrong type.

A second, non-cyclic layering inversion: `PitchDetector.swift:201` reads
`PitchTracker.priorGraceDuration` to decide whether a continuity prior is still live. The
lowest-level module in the pipeline depends on the state machine for a number.

### 2.3 `detectPitch` re-derives what its caller knows

`PitchDetector.detectPitch` takes seven parameters. Two of them, `priorAt` and `now`, are used
at exactly one place, `:204`:

```swift
hasPrior = (now >= priorAt) && (now - priorAt <= priorWindow) && priorFrequency.isFinite
```

`priorWindow` is `PitchTracker.priorGraceDuration` — the back-reference from §2.2.

The caller already computes precisely this predicate, with the correct clock, at
`TunerAnalysisSession.swift:747-748`:

```swift
(frame.captureEndSeconds >= prior.at),
(frame.captureEndSeconds - prior.at) <= PitchTracker.priorGraceDuration
```

and already branches on it. So the detector receives two parameters, plus a dependency on the
tracker, in order to recompute a `Bool` its caller is holding. Passing `nil` for
"no live prior" collapses the interface from seven parameters to four and removes the
detector's only dependency on the state machine.

### 2.4 No seam at the audio edge

`AudioCaptureService` is the only route from hardware to the app, and it is a `public final
class` with no protocol above it.

The suite is 15 files. Fourteen of them cross `TunerAnalysisSession.processFrameSync`,
`PitchTracker.process`, or the pure helpers. The exception is `PreferencesTests:93-172`, which
contains three `@MainActor` tests that construct a real `TunerViewModel` and drive
`setInstrument`, `setTuningPreset`, `updateA4` and `updateCustomMidi`. This works because
merely constructing an `AVAudioEngine` is inert — only `startCapture` touches hardware.

So `TunerViewModel` is **not** untested, and Phase C below extends existing coverage across a
new seam rather than inventing the first one. What the existing coverage does not reach is
everything past the configuration boundary:

| | Lines | Tests |
|---|---:|---:|
| `TunerViewModel` — config, preferences, targets | ~200 | 3 (`PreferencesTests:93-172`) |
| `TunerViewModel` — audio lifecycle, hold expiry, tones | ~290 | **0** |
| `Views/` (8 files incl. `TunerTheme`) | 1,202 | 0 |
| `TunerPreferences` + store | 129 | 5 |
| `TunerPresentation` | 55 | 237 lines |
| `AudioCaptureService` | 363 | 0 |
| `AcousticStringSynthesizer` | 142 | 1 integration (`PreferencesTests:174`) |

The untested half of the ViewModel is the half that owns the microphone, and it is where the
`start()` error mapping (`:185-202`), the interruption and route-change handlers (`:88-115`),
and the hold-expiry clock (`:266-291`) live.

`AudioCaptureService` is also where two of its own concerns are buried: `AudioRingBuffer`
(:302-363) and `ScratchBuffer` (:286-293) live in the adapter's file, and the ring buffer is a
generally useful real-time-safe module with no seam of its own.

The interface also leaks transport. `startCapture` takes a five-parameter closure
(`window, sampleRate, captureEndSeconds, callbackFrameCount, newSampleCount`) and offers a
second, two-parameter overload (:240-247) that silently discards three of them. Callers must
know that `newSampleCount` exists at all — it is there only because the WebTuna port is a
stateful ring that must receive each sample exactly once (`TunerTypes.swift:219-227`).
`callbackFrameCount` exists only to reach `TunerDiagnostics`.

### 2.5 `TunerViewModel` duplicates policy that already has an owner

- The custom-MIDI validity check — `count == expectedCount && allSatisfy { in
  TunerConstants.customMidiMin...max }` — is written **four** times: `TunerViewModel.swift:305`,
  `:360`, and twice more in the same function's neighbourhood, plus
  `TunerPreferences.activeConfig` (`TunerPreferences.swift:53-56`).
- `TunerViewModel.computeTargets` (:122-141) re-derives target construction from
  `config.tuningId` + `config.customMidi`, which is the same resolution
  `TunerPreferences.activeConfig` (:43-79) already performs in order to produce the config.
  The two can disagree, and `setInstrument` / `setTuningPreset` each perform the resolution a
  third time by hand.
- Hold expiry has two owners. `TunerPresentation` owns the *policy*
  (`displayHoldDuration`, `holdOpacity`); `TunerViewModel` owns the *clock* by running a 30 fps
  `Task` that polls `CACurrentMediaTime` (:272-290). Neither can be tested alone, and the
  ViewModel's half has a hidden interface fact — **hold expiry depends on the wall clock** —
  which is not visible anywhere in its signature.

### 2.6 The layering is not enforced

One app target, one module. All 38 types are `public`; all 16 test files use
`@testable import StrumKit`. Folders in a single Swift module create no boundaries: the
compiler will not stop `TunerPresentation` from reaching into `AudioCaptureService`, and does
not today.

### 2.7 Dead code and misfiling

| Item | Evidence |
|---|---|
| `SpectralNoiseFilter` (99 lines) | Never instantiated. Already scheduled for deletion as spec §7.3 — and confirmed not working: `observeFrame` bins time-domain samples by index as if they were frequency bins. |
| `SignalCondition` | Declared `TunerTypes.swift:56`, referenced nowhere. |
| `TunerAnalysisSession.reset(targetCount:)` | `:298`, referenced only within its own file. |
| `SpectralPitchScorer.isScoringEnabled` | `:69`, guard at `:279`, never set to `false`. |
| `Resampler.getCoefficients` | `public`, called only from `resampleWindow` (:76). |
| `TunerTypes.swift:204` | Doc comment reads *"Selects which detector advances the tracker"* — a leftover from a type deleted in `9f00938`. `AnalysisFrame` now follows it. |
| `Models/` | Holds `PitchResult` (DSP output), `TunerDiagnostics`, `AnalysisFrame`, `AnalysisSnapshot`, `EngineStatus` — none of which are models. Meanwhile `MusicalNote.swift` holds `InstrumentCategory`, `TunerConstants`, `PitchMath`, `MusicalNote` and `PitchResult`. |

---

## 3. Goals

- **S1** Every acceptance constant lives on the type whose behaviour it constrains, and is
  reachable from there.
- **S2** No dependency cycles between modules; the detection layer depends on nothing above it.
- **S3** The app's audio lifecycle is testable through its interfaces. `TunerViewModel`'s
  configuration half already is; its audio half is not, and after this both are.
- **S4** `PitchDetector`, `SpectralPitchScorer`, and `PitchTracker` change without touching the
  coordinator, and the coordinator changes without touching them.
- **S5** The compiler enforces the layering, not reviewer discipline.

## 4. Non-goals

- **No algorithm changes.** No threshold moves value. The DSP stays exactly as measured in
  `docs/tuner-reliability/RESULTS.md`; if a value needs to change, that is the detection
  spec's job, on its evidence.
- **No Swift Package Manager split.** See §9.
- **Not a rewrite of `PitchTracker`.** It is the best-structured module in the app: one
  `process` entry point, 590 lines of tests crossing it, no changes proposed.
- **Not touching view layout.** `Views/` is reorganised into a folder and otherwise left alone.

---

## 5. The seams

Four, in the order they should be cut.

### Seam 1 — Spectral acceptance (Phase A)

The scorer *ranks*; something must *decide*. Today the deciding is duplicated inside the
coordinator. It gets its own module with one entry point and two policy values.

```swift
/// Decides whether a ranked spectral candidate may name a pitch.
///
/// Evidence rules live here, not in the caller: the scorer produces candidates and
/// supporting-partial evidence, and this decides what is sufficient to believe one.
public enum SpectralGate {
    /// The evidence a candidate must clear. Two values ship — `.acquisition` has no
    /// prior to lean on and is correspondingly strict; `.recovery` may lean on one.
    public struct Policy: Sendable {
        public let minScore: Double
        public let minRMS: Double
        public let separationRatio: Double
        public let minHarmonics: Int
        public let supportFraction: Double
        /// Half-width of the local search around `prior`, or `nil` to search the whole
        /// grid. This is a *search* setting; acceptance still depends on the fields above.
        public let searchRadiusCents: Double?
        /// Maximum disagreement with `corroborating`, or `nil` to accept a first sighting.
        public let agreementCents: Double?
    }

    public static let acquisition = Policy(
        minScore: 0.12, minRMS: 0.0012, separationRatio: 1.60, minHarmonics: 3,
        supportFraction: 0.15, searchRadiusCents: nil, agreementCents: 30.0)
    public static let recovery = Policy(
        minScore: 0.035, minRMS: 0.0003, separationRatio: 1.25, minHarmonics: 2,
        supportFraction: 0.15, searchRadiusCents: 70.0, agreementCents: nil)

    /// - Parameters:
    ///   - corroborating: a frequency proposed on the previous frame. Supplying it is
    ///     what makes acquisition take two frames instead of one.
    ///   - prior: the tracker's continuity prior, or `nil` if there is none.
    public static func accept(
        analysis: SpectralPitchScorer.WindowAnalysis,
        corroborating: Double?,
        prior: (frequency: Double, at: TimeInterval)?,
        policy: Policy,
        config: TunerConfig,
        rms: Double
    ) -> PitchResult?
}
```

The two call sites become:

```swift
// acquisition
pitchResult = SpectralGate.accept(analysis: analysis, corroborating: pending,
                                  prior: nil, policy: .acquisition,
                                  config: config, rms: currentRms)

// recovery
SpectralGate.accept(analysis: analysis, corroborating: nil, prior: prior,
                    policy: .recovery, config: config, rms: currentRms)
```

Callers now express *what they want* rather than *how evidence is judged*. ~150 lines become
~60, and the octave-offset table, the partial-counting, and the score comparison exist once.

**Behaviour must not change.** The gate is extracted, not rewritten. §7 has the gate for it.

### Seam 2 — Vocabulary ownership (Phase B)

Two changes, no logic, and neither is a constant move for its own sake:

**a. Break the cycle.** `TunerAnalysisSession.recoveredFramesMayAssertInTune` (`:130`) becomes
`PitchResult.recoveredMayAssertInTune`, beside the `recovered` flag it governs. Breaks the
cycle in §2.2 and puts S1 into effect.

**b. Shrink `detectPitch` from seven parameters to four.** `priorAt` and `now` exist only to
re-derive liveness (§2.3), and doing so requires the detector to reach into `PitchTracker` for
`priorGraceDuration`. The caller already holds the answer, computed with the correct clock at
`TunerAnalysisSession.swift:747-748`. So:

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
the grace window. The detector no longer knows that a grace window exists, which is the
correct division: how long a prior survives is the tracker's state, not the detector's.

This is the clearest example in the app of the interface being larger than the knowledge it
carries, and the only change here that *removes* something a caller must know.

### Seam 3 — Tuning resolution (Phase B)

Instrument, preset id, custom MIDI array and A4 are resolved into a config and a target list
in **one** place instead of four.

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

`TunerPreferences.activeConfig()` becomes `Tuning.resolve(...).config`.
`TunerViewModel.computeTargets` is deleted; the ViewModel holds one `Resolved` and both
`config` and `targets` read from it. `setInstrument` and `setTuningPreset` stop hand-rolling
the fallback chain.

**This is the highest-leverage small change in the document:** four copies of a validation
rule become one, and the "config says X but targets say Y" class of bug becomes
unrepresentable rather than merely unlikely.

### Seam 4 — Microphone source (Phase C)

The one place where *two adapters means a real seam*: `AVAudioEngineMicrophone` exists, and
the replay path in `AudioTestHelpers` is already a de-facto second adapter with no interface
to satisfy. This seam is the whole point of Phase C.

```swift
/// What the tuner needs from a microphone: windows of audio, timestamped on the host
/// monotonic clock, at whatever cadence the hardware provides.
///
/// An implementation owns the sample rate, the tap size, the ring buffer, and the
/// device-specific `AVAudioSession` configuration. A caller knows none of that.
public protocol MicrophoneSource: AnyObject, Sendable {
    /// Delivered on an arbitrary thread. `.interrupted(resumable:)` fires again as
    /// `.resumed`; a source that cannot resume must not send `.resumed`.
    var onEvent: (@Sendable (MicrophoneEvent) -> Void)? { get set }

    /// Valid only while started; the hardware's rate is not knowable before that.
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
    /// How many samples at the end of `samples` arrived since the previous window.
    /// `samples` is a trailing window, so consecutive windows overlap; a stateful
    /// consumer needs to know which tail is new.
    public let newSampleCount: Int
}
```

What this fixes at the seam:

- **Tap size stops being the caller's problem.** `bufferSize:` disappears from the interface;
  it is the adapter's implementation decision. `AudioCaptureService.requiredInputSamples` and
  the ring-buffer sizing move behind the seam with it.
- **`callbackFrameCount` disappears.** It is a diagnostic; derive it by summing
  `newSampleCount`.
- **Generation and sequence stop travelling across the seam.** The source does not know about
  `TunerAnalysisSession`'s generational invalidation. The session stamps
  `AnalysisFrame(sequence:generation:)` from its own counters when it builds the frame. One
  less thing a source implementer must get right.
- **The five-parameter closure and its discarding two-parameter overload** collapse to one
  typed value. The overload at `AudioCaptureService.swift:240-247` is not an adapter — it is
  an invitation to lose data.
- **`AudioRingBuffer` gets its own file** and is no longer a type buried inside a concrete
  adapter.

Adapters: `AVAudioEngineMicrophone` (production) and `ScriptedMicrophone` (§6).

`TunerAnalysisSession` gains one method and loses nothing:

```swift
public func start(source: MicrophoneSource, config: TunerConfig, targets: [StringTarget])
```

which owns wiring the source's delivery into `submitLiveAudio`, translating `MicrophoneEvent`
into generation bumps, and stopping the source on teardown. Callers get one verb instead of
remembering to stop capture, stop the session, and re-arm both.

### What Phase C does to `TunerViewModel` (Seam 4)

`TunerViewModel` stops *creating* its dependencies and starts *accepting* them:

```swift
public init(
    source: MicrophoneSource,
    referenceTone: ReferenceTonePlayer,
    preferencesStore: TunerPreferencesStore = .init(),
    clock: @escaping @Sendable () -> TimeInterval = { CACurrentMediaTime() }
)
```

- `source` and `referenceTone` are the two external dependencies.
  `AcousticStringSynthesizer` already has an integration test
  (`PreferencesTests:174`), so `ReferenceTonePlayer` is **not** proposed so the synth becomes
  testable — it already is. It is proposed so a test can assert *which tone the ViewModel
  asked for*: today `playReferenceTone` writes `lastTone` and calls into a concrete synth
  (`TunerViewModel.swift:436-451`), and there is no way to check the request without hearing
  it. A recording adapter makes that observable, and is about ten lines.
- `clock` is injected so hold expiry is testable. Today it is a hidden interface fact (§2.5);
  after this it is a constructor argument, and `TunerViewModel` can be tested without
  sleeping for a second.
- The default arguments that construct `AudioCaptureService()` and
  `AcousticStringSynthesizer()` inline (`:57-58`) go away. The test target cannot supply a
  fake to something the type builds for itself. Note that the three existing ViewModel tests
  survive this unchanged — they inject only `preferencesStore` and touch no audio, so
  `source` and `referenceTone` can be required rather than defaulted.

### Seam 5 — Enforced layering (Phase D)

Swift folders are not boundaries. Two options, §9 argues for the second:

1. Drop everything not used across the seam to `internal`, keep `@testable import`. Cheap,
   and the compiler starts catching the violations. But it does not stop a *new* file from
   being `public` by default out of habit.
2. Split into Swift Package Manager targets, so the seams are compiler-enforced module
   boundaries and `import` becomes the enforcement mechanism.

The testable core is already in place for option 2: all 16 test files use `@testable import`,
so they would keep working if `StrumKitCore` were a library the test target depended on.
`TunerView` and `SettingsView` stay in the app target.

---

## 6. Test plan for the upper half

The point of Seam 4. `ScriptedMicrophone` is a test adapter that emits a caller-supplied list
of `CapturedWindow`s and records what it was asked to do:

```swift
final class ScriptedMicrophone: MicrophoneSource, @unchecked Sendable {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var isStarted = false
    var windows: [CapturedWindow] = []
    private var deliver: (@Sendable (CapturedWindow) -> Void)?

    var sampleRate: Double { 44_100 }
    var onEvent: (@Sendable (MicrophoneEvent) -> Void)?

    func start(delivering: @escaping @Sendable (CapturedWindow) -> Void) throws {
        startCount += 1; isStarted = true; deliver = delivering
    }
    func stop() { stopCount += 1; isStarted = false; deliver = nil }

    func emit(_ window: CapturedWindow) { deliver?(window) }
}
```

The tests it makes possible. The first four are currently impossible; the rest extend
coverage that exists but does not cross this seam:

| Test | What it pins down |
|---|---|
| `testDeniedPermissionNeverStartsTheSource` | `start()` on a `.denied` status does not touch the source and leaves `engineStatus == .denied`. Today: unreachable, `AudioCaptureService` is concrete. |
| `testInterruptionStopsTheTapNotJustTheAnalysis` | `.interrupted` leaves `source.isStarted == false`. This is the bug the comment at `TunerViewModel.swift:93-96` describes — a cosmetic "stop" that leaves the tap installed — and it is currently protected only by a comment. |
| `testResumableInterruptionRestartsOnlyIfListeningWasIntentional` | `.interrupted(resumable: true)` followed by `.resumed` restarts when `listeningIntent` is set and does not when the user had stopped. |
| `testReferenceToneIsRequestedEvenWhenTheMicIsDenied` | Reference tones are the documented fallback for a denied mic (`EngineStatus.guidanceError`). The recording `ReferenceTonePlayer` makes the request observable; nothing enforces it today. |
| `testRouteChangeRestartsCapture` | The second handler at `:107-114`, which is a different bug class from interruption: it stops and restarts unconditionally when listening. |
| `testChangingInstrumentReplacesTargetsAndClearsReading` | The `setInstrument` path, through the seam, with no `AVAudioSession`. Extends `testPerInstrumentTuningPersistenceInViewModel`, which stops at `config` and never checks that the reading was cleared. |
| `testCustomMidiOfWrongLengthFallsBackToTheDefault` | The rule written four times (§2.5). The existing tests only ever pass *valid* arrays, so no fallback path is currently pinned. |
| `testRecoveryCannotAssertInTune` | End-to-end, through a session, not through `PitchTracker` in isolation. |
| `testHeldReadingExpiresAtDisplayHoldDuration` | With an injected `clock`, this becomes a synchronous assertion instead of a one-second sleep. |
| `testCalibrationChangeInvalidatesInFlightFrames` | The generation bump on `updateA4`, observed as a stale frame being dropped rather than as an internal counter. |

Per `DEEPENING.md`: **replace, don't layer.** `AnalysisSessionTests` and `TrackerTests` already
cross the detection seam and stay exactly as they are — they are good tests of a good module.
The new tests cross the *new* seam. Nothing is added on top of a shallow module that is about
to disappear.

`AVAudioEngineMicrophone` itself is not unit-tested — it is the hardware adapter, and its
correctness is the recording-fixture replay suite's job, which already exists
(`RecordedAudioTests`, `SustainContinuityTests`).

---

## 7. Phases

Each phase is separately landable and separately revertible. Gates are the existing
`RESULTS.md` numbers, asserted, so "no regression" is measured.

### Phase A — Extract `SpectralGate`

1. Create `Detection/SpectralGate.swift` with `Policy`, `.acquisition`, `.recovery`, `accept`.
2. Move all sixteen constants from `TunerAnalysisSession.swift:40-130` onto the two policies,
   **values unchanged**.
3. Rewrite `acceptAcquisition` and `applySpectralRecovery` as calls into it.
4. Delete the originals.

**Gate:** the existing suite passes unchanged, and `RESULTS.md` fixtures reproduce. There is
no new behaviour to test — this is a move, verified by the old tests. Reviewers should read
the extraction as a diff with no constant changes; any constant that changes value here is a
rejected change.

### Phase B — Vocabulary and resolution

1. `recoveredFramesMayAssertInTune` → `PitchResult.recoveredMayAssertInTune`. Cycle gone.
2. `detectPitch` loses `priorAt` and `now` (§5 Seam 2b); the session passes a live prior or
   `nil`. The detector's dependency on `PitchTracker` is gone.
3. `Tuning.resolve(...)`; collapse `activeConfig()` and `computeTargets` onto it; delete the
   three hand-rolled copies in the ViewModel.
4. Delete `SignalCondition`, `TunerAnalysisSession.reset(targetCount:)`,
   `SpectralPitchScorer.isScoringEnabled`, `SpectralNoiseFilter` (already spec §7.3); make
   `Resampler.getCoefficients` `private`.
5. Fix the `TunerTypes.swift:204` doc comment.

**Gate:** the suite passes, and specifically the three ViewModel tests at
`PreferencesTests:93-172` are unchanged and green. They already drive `setInstrument`,
`setTuningPreset`, `updateCustomMidi` and `updateA4` through every fallback rule that step 3
collapses, so the collapse is protected by tests that exist today. Step 2 is protected by
`PitchTests` and `TrackerTests`, which exercise prior-continuity behaviour extensively.

### Phase C — The microphone seam

Follow §5 Seam 4 in order, so each step compiles:

1. `CapturedWindow`, `MicrophoneEvent`, `MicrophoneSource` protocol.
2. `ScriptedMicrophone` in the test target. Nothing else changes yet — the protocol has one
   implementer, so this is a hypothetical seam for exactly one commit.
3. `AVAudioEngineMicrophone`, extracted from `AudioCaptureService`; `AudioRingBuffer` and
   `ScratchBuffer` to their own file. `AudioCaptureService` becomes a thin caller or is
   deleted if nothing else needs it.
4. `ReferenceTonePlayer` protocol + `AcousticStringSynthesizer` adapter + recording fake.
5. `TunerAnalysisSession.start(source:config:targets:)`.
6. `TunerViewModel` takes all four dependencies, including the clock.
7. Write the §6 tests. The first four of them should each fail against the current
   `TunerViewModel` before step 6 lands — if they pass already, the seam was not the problem
   and the test is not earning its keep.

**Gate:** §6 suite green; existing detection suite unchanged.

### Phase D — Layout and enforcement

Move files so each folder holds one idea:

```
Domain/        InstrumentCategory, MusicalNote, PitchMath, PitchResult, TunerConstants,
               StringTarget, TunerReading, TunerMode, TuningPreset, ToneMemory
Tuning/        Tuning, TunerPreferences, TunerPreferencesStore
Detection/     AnalysisFrame, AnalysisSnapshot, TunerDiagnostics,
               PitchDetector, SpectralPitchScorer, SpectralGate,
               PitchTracker, Resampler, HannProjection
Analysis/      TunerAnalysisSession
AudioIO/       MicrophoneSource, AVAudioEngineMicrophone, CapturedWindow,
               MicrophoneEvent, AudioRingBuffer, MicrophonePermission
Presentation/  TunerPresentation, TunerTheme, ViewModels/, Views/
```

`EngineStatus`, `SignalFeedbackState` and `AudioCaptureError` go to whichever of
`Presentation` / `AudioIO` owns them — they are status vocabularies, and their real home is
decided by who reads them.

Then decide option 1 or 2 from §9.

---

## 8. Risks

| Risk | Mitigation |
|---|---|
| Extracting `SpectralGate` silently changes a gate | The two implementations are compared line by line during the move, and the old tests are the gate. A behavioural change here is a defect in the extraction, not a tuning decision. |
| `ReferenceTonePlayer` risks being a hypothetical seam — one adapter | It gets its second adapter (the recording fake) in the same phase, and `testReferenceToneIsRequestedEvenWhenTheMicIsDenied` is what justifies it. If only `playString`/`stop` are ever needed, the protocol stays two methods wide. |
| Phase C is a large diff on the file with the most untested behaviour | Staged so steps 1–2 are additive and land first. `ScriptedMicrophone` exists and is unused before step 5, which is the intended order. |
| Splitting into SPM targets churns `project.yml` and the Makefile | Deferred to Phase D and separately revertible. No source change depends on it. |
| The upper-half tests pass immediately | Then the seam was not the problem, and the test is deleted rather than kept. Step 7 of Phase C says so up front. |

**Rollback:** Phases A–C are code motion with no value changes. Reverting a phase is a
`git revert`, not a threshold hunt — which is itself the main argument for doing them in this
order rather than folding them into the detection plan.

---

## 9. Open question: enforced layering, and how

Two ways to make the seams real:

- **Drop `public` where it is not needed.** One module, `@testable import` in tests. The
  compiler starts rejecting reach-throughs the moment someone writes one. Cheap, no build
  change, no new target. Does not stop the *next* file from being `public` by default.
- **Split into SPM targets** (`StrumKitCore` library + app target + test target). `import`
  becomes the enforcement mechanism and cannot be forgotten. Costs: a `project.yml`
  restructure, Makefile updates, and a slower iteration loop.

The second is the more durable answer, and the test suite is already shaped for it — 16 files
use `@testable import`, so a library target drops in without touching a single test. It is
deferred to Phase D only because it is the one change here that touches build configuration,
and build-configuration churn is a bad place to be when the detection plan is mid-flight.

**Recommendation:** Phase D, option 2, as its own change, after the detection plan lands.
Until then, the Phase A–C moves are worth doing on their own merits: they fix real locality
and cycle problems whether or not the compiler is watching.

---

## 10. What this design deliberately does not do

- **No new DSP.** The detection spec owns every acceptance number. This document's only claim
  about thresholds is that they are *located* badly, not that they are *valued* wrongly.
- **No Swift 6 concurrency rework.** `@unchecked Sendable` is used in ten places and
  `SWIFT_STRICT_CONCURRENCY: complete` is on. The annotations are load-bearing and the
  reasoning is recorded at each site. Replacing them is a separate, larger piece of work.
- **No change to `PitchTracker`.** It is the module the rest of the app should look like.
- **No SwiftUI view decomposition.** The `Views/Components/` split already exists and is
  reasonable. `TunerView` at 271 lines is large but is not shallow — it is layout.
- **No new persistence.** `TunerPreferencesStore` is a fine shallow module around
  `UserDefaults`, and a store around a store would be a hypothetical seam.
