import Foundation

/// Manages pitch stability, target string matching, guided-mode progression,
/// display cents smoothing, and multi-reading acquisition.
/// Faithful native port of chorder/src/audio/tuner/tracker.ts.
public final class PitchTracker: @unchecked Sendable {
    // Tuning thresholds (cents)
    public static let standardEnterTuneCents: Double = 5.0
    public static let standardExitTuneCents: Double = 7.0
    public static let precisionEnterTuneCents: Double = 2.0
    public static let precisionExitTuneCents: Double = 3.0

    // Acquisition & Stability
    public static let acquireReadings: Int = 3
    public static let onsetAcquireReadings: Int = 2
    public static let onsetRmsMultiplier: Double = 3.0

    // Guided mode requirements
    public static let guidedHoldDuration: TimeInterval = 1.0 // 1 full second in tune
    public static let guidedCompletionPeriodicity: Double = 0.85

    // Ambient noise floor tracking
    public static let initialAmbientFloor: Double = 0.0002
    public static let minAmbientFloor: Double = 0.00008
    public static let maxAmbientFloor: Double = 0.015
    public static let foregroundPeriodicityThreshold: Double = 0.75
    public static let ambientCooldown: TimeInterval = 0.35

    /// How far above the learned ambient floor a frame must be before a
    /// periodicity value is allowed to mean "something was played".
    ///
    /// **A periodicity value alone is not evidence of a note.** A CMNDF measures
    /// pseudo-periodicity, and noise has it: over the 6.12 s of −46.3 dBFS room
    /// tone that follows the last strum on `all-4-with-noise.wav`, 53 of 287
    /// frames reach YIN periodicity ≥ 0.75 (median 0.830, max 0.963), and the
    /// frames the display actually acquired a *string* from sit at 0.697–0.940 —
    /// overlapping the quiet plucks' 0.668–0.978 exactly. So periodicity cannot
    /// carry the decision, and the level has to.
    ///
    /// **The multiple is the room's own 99th percentile, not a guess.** Over 256
    /// frames of provable silence on that file (16.5 s–21.95 s, after the
    /// estimator's last real estimate at 16.171 s) the 90 ms RMS has mean 0.004406,
    /// p90 1.57× that mean, p99 2.24×, maximum 2.51×. A 90 ms window is atypical of
    /// the room above p99, and 2.24 / 1.03 = **2.18** is that percentile expressed
    /// in units of the floor once the floor is fixed to estimate the room rather
    /// than a downward-biased subset of it (it measured 0.77× the room's mean
    /// before this change and 1.03× after). 2.0 sits just under it, on the
    /// sensitivity side, because the percentile is a property of one recording and
    /// the cost of being wrong is asymmetric.
    ///
    /// **What the sweep says about that choice.** Sweeping the multiple over
    /// 1.0 … 5.0 with everything else fixed: the post-music tail goes 179 → 112 →
    /// 54 → 34 → 33 → 31 live frames, the fourth string is never lost below 8.0,
    /// and *every* quiet fixture's fresh-frame count and coverage is bit-identical
    /// to the pre-change baseline at 1.0, 1.5 and 2.0. The next step is a cliff:
    /// at 2.5 `quiet_a` drops from 86 fresh frames to 29 and at 3.0 to 17, taking
    /// its recorded 0.40 s coverage gate to 0.62 s and 0.36 s. So 2.0 is the
    /// largest multiple that costs the quiet plucks nothing, and the tail it buys
    /// is 54 of 287 frames — against 50 for the same file with the room tone
    /// replaced by silence, i.e. indistinguishable from the hold's own cost.
    ///
    /// The headroom on the detection side is large either way: the four strum
    /// onsets on that file are 18.8×–66× the room's mean, and the weakest real
    /// acquisition on any recorded fixture is 12.28×.
    public static let foregroundLevelMultiple: Double = 2.0

    // Hold & Sustain Grace Durations
    public static let readingHoldDuration: TimeInterval = 1.0
    public static let priorGraceDuration: TimeInterval = 0.85

    // Responsiveness & Confirmation Constants
    public static let standardEvidenceSpan: TimeInterval = 0.040 // 40 ms
    public static let onsetEvidenceSpan: TimeInterval = 0.020    // 20 ms
    public static let maxCandidateGap: TimeInterval = 0.250      // 250 ms: accommodates worker queue & mailbox replacement
    public static let displayEmaTimeConstant: TimeInterval = 0.050 // tau = 50 ms

    // Continuation hysteresis. Acquisition has always demanded more than one frame
    // of evidence before it will put a note on screen; continuation had no
    // equivalent, which is why the display could leave and rejoin a note it had
    // already found. These two streaks are that missing requirement, and they are
    // asymmetric on purpose: giving up is the visible failure a player notices, so
    // it is the sticky direction; coming back is the visible correction, so it is
    // the prompt one.
    public static let continuationYinFailuresToWeaken: Int = 3     // ~70 ms at the 43.1 Hz capture cadence
    public static let continuationYinSuccessesToStrengthen: Int = 2 // ~46 ms

    private struct TargetKey: Equatable {
        let index: Int
        let midi: Int
    }

    /// How much the reading currently on screen is worth, which is the only thing
    /// the continuation hysteresis reasons about.
    ///
    /// Ordered so `>` reads as "better evidence for the display to move to".
    /// `recovery` sits above `held` because a spectrally recovered estimate is a
    /// fresh measurement of something real, while a held reading is the absence of
    /// one; the display already treats them as different states, so the gate can
    /// too, and ordering them makes "weakening" and "strengthening" mean the same
    /// thing in both.
    private enum DisplayEvidence: Int, Comparable {
        case dark = 0
        case held = 1
        case recovery = 2
        case yin = 3

        init(reading: TunerReading?) {
            guard let reading else { self = .dark; return }
            guard reading.freshness == .fresh else { self = .held; return }
            self = reading.recovered ? .recovery : .yin
        }

        static func < (lhs: DisplayEvidence, rhs: DisplayEvidence) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    // State
    private var lastReadingTime: TimeInterval = 0
    private var displayCentsEma: Double = 0.0
    private var lastInTuneState: Bool = false
    private var guidedHoldStartTime: TimeInterval? = nil
    private var activeTargetKey: TargetKey? = nil

    private var candidateKey: TargetKey? = nil
    private var candidateCount: Int = 0
    private var candidateFirstSeenAt: TimeInterval = 0
    private var candidateLastSeenAt: TimeInterval = 0
    private var candidateIsOnset: Bool = false
    private var lastRms: Double = 0.0
    private var lastForegroundTime: TimeInterval = 0
    private var lastReading: TunerReading? = nil

    /// The last reading the display was actually handed, whatever its state.
    ///
    /// `lastReading` is the last reading the tracker *estimated*, and the hold
    /// branches repeat it without replacing it; this is what the player is looking
    /// at. The two differ exactly while a hold is on screen, and a gate reading the
    /// wrong one believes it has weakened to `held` while the screen still says
    /// `fresh` — which puts a `held → fresh` step back in the middle of a dropout
    /// and rebuilds the flicker the gate exists to remove.
    private var displayedReading: TunerReading? = nil

    public private(set) var ambientFloor: Double = initialAmbientFloor
    public private(set) var guidedProgress: [Bool] = []
    public private(set) var guidedTargetIndex: Int = 0
    public private(set) var feedbackState: SignalFeedbackState = .inactive
    public private(set) var continuityPrior: (frequency: Double, at: TimeInterval)? = nil

    /// Consecutive frames on which YIN, rather than spectral recovery, produced
    /// the estimate the display is acting on.
    public private(set) var consecutiveYinSuccesses: Int = 0
    /// Consecutive frames on which it did not: no pitch, or a recovered one.
    public private(set) var consecutiveYinFailures: Int = 0

    /// True while the dropout streak is short enough that the display has not yet
    /// earned the right to weaken to a recovery or a hold.
    public var shouldHoldThroughDropout: Bool {
        consecutiveYinFailures < Self.continuationYinFailuresToWeaken
    }

    public init() {}

    /// Recommends the noise gate threshold based on current ambient noise floor and sustain status.
    public func recommendedNoiseGate(isSustaining: Bool) -> Float {
        let multiplier = isSustaining ? 1.15 : 1.4
        let gate = max(0.00015, ambientFloor * multiplier)
        return Float(gate)
    }

    /// Recommends the YIN threshold (0.15 for attack acquisition, 0.25 for sustaining pitch).
    public func recommendedYinThreshold(isSustaining: Bool) -> Float {
        return isSustaining ? 0.25 : 0.15
    }

    /// Resets tracker state when configuration or instrument changes.
    public func reset(targetCount: Int) {
        reset(targetCount: targetCount, preservingGuidedProgress: false)
    }

    /// Resets tracker state, optionally keeping the guided session's completed
    /// strings.
    ///
    /// A mode, precision or string-lock change invalidates in-flight *readings* but
    /// must not discard strings the player has already tuned. An instrument or
    /// preset change does discard them, because the strings are different ones.
    public func reset(targetCount: Int, preservingGuidedProgress: Bool) {
        let previousProgress = guidedProgress
        let previousTarget = guidedTargetIndex
        guidedProgress = Array(repeating: false, count: targetCount)
        guidedTargetIndex = 0
        displayCentsEma = 0.0
        lastInTuneState = false
        guidedHoldStartTime = nil
        activeTargetKey = nil
        candidateKey = nil
        candidateCount = 0
        candidateFirstSeenAt = 0
        candidateLastSeenAt = 0
        candidateIsOnset = false
        lastRms = 0.0
        continuityPrior = nil
        displayedReading = nil
        consecutiveYinSuccesses = 0
        consecutiveYinFailures = 0
        feedbackState = .inactive
        ambientFloor = Self.initialAmbientFloor
        lastForegroundTime = 0
        lastReading = nil
        lastReadingTime = 0

        if preservingGuidedProgress, previousProgress.count == targetCount {
            guidedProgress = previousProgress
            guidedTargetIndex = min(previousTarget, max(0, targetCount - 1))
        }
    }

    /// Restarts the guided tuning session while retaining settings.
    public func resetGuidedSession(targetCount: Int) {
        guidedProgress = Array(repeating: false, count: targetCount)
        guidedTargetIndex = 0
        guidedHoldStartTime = nil
    }

    /// Evaluates raw DSP pitch result against tuner configuration and targets.
    public func process(
        pitchResult: PitchResult,
        at now: TimeInterval,
        config: TunerConfig,
        targets: [StringTarget]
    ) -> TunerReading? {
        guard !targets.isEmpty || config.mode == .chromatic else { return nil }

        if config.mode != .chromatic && guidedProgress.count != targets.count {
            guidedProgress = Array(repeating: false, count: targets.count)
            guidedTargetIndex = 0
        }

        // The streak is counted on the estimator, not on the pitch. A spectrally
        // recovered estimate is a success for the pipeline — it is a reading, and
        // it is steadier than the YIN frames it replaces — but it is a *failure*
        // for YIN, and conflating the two is what makes the state flap. Counting
        // them as one thing gives a frame that is weaker evidence exactly the same
        // vote as the frame before it, so the display alternates between two
        // readings of the same note at the estimator's own cadence.
        if pitchResult.isSignalPresent && !pitchResult.recovered {
            consecutiveYinSuccesses += 1
            consecutiveYinFailures = 0
        } else {
            consecutiveYinFailures += 1
            consecutiveYinSuccesses = 0
        }

        // What counts as evidence that something was actually played. The level
        // conjunct is load-bearing, and it is the same predicate the display uses
        // below, so "foreground" means one thing throughout the tracker.
        //
        // A recovered estimate is exempt from the *periodicity* conjunct only.
        // `TunerAnalysisSession` deliberately reports it as a salience capped at
        // 0.70 — below `foregroundPeriodicityThreshold` — precisely because
        // salience is not periodicity, so reading it as one is meaningless. It is
        // also the estimate that exists to carry a display through a decay YIN has
        // lost, so it must be able to; demanding a YIN periodicity of it would
        // make the whole recovery path inert. Its level still has to clear the same
        // bar, on top of the harmonic-support, score and separation gates
        // `TunerAnalysisSession` already applied to produce it at all.
        let isForeground = pitchResult.isSignalPresent
            && pitchResult.frequency >= TunerConstants.detectorMinHz
            && (pitchResult.recovered || pitchResult.confidence >= Self.foregroundPeriodicityThreshold)
            && pitchResult.amplitudeRMS >= Self.foregroundLevelMultiple * ambientFloor

        if isForeground {
            lastForegroundTime = now
        } else if displayedReading == nil
                    && (now - lastForegroundTime) >= Self.ambientCooldown
                    && pitchResult.amplitudeRMS > 0 {
            // The floor estimates the *room*, and the room is only observable while
            // nothing is on the display. Without the `displayedReading == nil` guard
            // a decaying note is not foreground (its level is below the floor's
            // multiple) and so feeds the floor, which raises the floor, which makes
            // the next frame of the same decay even less foreground. Measured on
            // `quiet_a.wav`, that feedback alone takes fresh coverage from 1.17 s to
            // 0.17 s — below the 0.40 s acceptance gate — while four of the eight
            // recorded fixtures lose their decay display entirely.
            let alpha = 0.05
            ambientFloor = max(Self.minAmbientFloor, min(Self.maxAmbientFloor, (1.0 - alpha) * ambientFloor + alpha * pitchResult.amplitudeRMS))
        }

        // 1. Check signal presence
        guard pitchResult.isSignalPresent && pitchResult.frequency >= TunerConstants.detectorMinHz else {
            return handleLostSignal(at: now, rms: pitchResult.amplitudeRMS)
        }

        let frequency = pitchResult.frequency
        let currentRms = pitchResult.amplitudeRMS
        let isOnset = (currentRms >= ambientFloor * 3.5) || ((lastRms > 0) && (currentRms >= lastRms * Self.onsetRmsMultiplier))
        lastRms = currentRms

        // 2. Determine target string according to mode
        let targetIndex: Int
        let target: StringTarget

        switch config.mode {
        case .guided:
            targetIndex = min(guidedTargetIndex, targets.count - 1)
            target = targets[targetIndex]

        case .manual:
            targetIndex = min(max(0, config.selectedString), targets.count - 1)
            target = targets[targetIndex]

        case .chromatic:
            if let nearest = PitchMath.nearestMidi(for: frequency, a4: config.a4) {
                target = StringTarget(
                    note: nearest.note,
                    midi: nearest.midi,
                    frequency: PitchMath.midiFrequency(nearest.midi, a4: config.a4),
                    number: 0
                )
                targetIndex = -1
            } else {
                return handleLostSignal(at: now, rms: currentRms)
            }

        case .auto:
            // Match closest string within MAX_DETUNING_CENTS with 20¢ hysteresis
            var closestIdx = 0
            var minCentsDist = Double.greatestFiniteMagnitude

            for (idx, candidate) in targets.enumerated() {
                let dist = abs(PitchMath.centsBetween(measured: frequency, reference: candidate.frequency))
                let hysteresis = (idx == activeTargetKey?.index) ? 20.0 : 0.0
                if (dist - hysteresis) < minCentsDist {
                    minCentsDist = dist - hysteresis
                    closestIdx = idx
                }
            }

            let centsToClosest = abs(PitchMath.centsBetween(measured: frequency, reference: targets[closestIdx].frequency))
            if centsToClosest <= TunerConstants.maxDetuningCents {
                targetIndex = closestIdx
                target = targets[closestIdx]
            } else {
                handleAmbiguousSignal(at: now)
                return handleLostSignal(at: now, rms: currentRms)
            }
        }

        // Elapsed fresh evidence target confirmation
        let currentTargetKey = TargetKey(index: targetIndex, midi: target.midi)

        // Reset candidate confirmation if gap exceeds candidate gap limit (> 250ms)
        if candidateKey != nil && (now - candidateLastSeenAt) > Self.maxCandidateGap {
            candidateKey = nil
            candidateCount = 0
            candidateFirstSeenAt = 0
            candidateLastSeenAt = 0
            candidateIsOnset = false
        }

        // Continuing a note the display already shows is not a second look at the
        // same question — it is the shortcut that kept the post-music tail alive.
        // `isContinuingTarget` bypasses the candidate requirement entirely, so any
        // frame with an in-vocabulary estimate inside `priorGraceDuration` reached
        // `lastReadingTime = now` and restarted the 1.0 s display hold. Measured on
        // `all-4-with-noise.wav`, a room-tone frame at 0.41× the floor was enough to
        // hold the needle up for 5.85 s over 6.12 s of silence, naming G4, C4 and A4
        // out of −46 dBFS room tone. Gating the shortcut on the same foreground test
        // is what takes the tail from 199 live frames to 33.
        let isContinuingTarget = isForeground
            && currentTargetKey == activeTargetKey
            && continuityPrior != nil
            && (now - lastReadingTime) <= Self.priorGraceDuration

        if candidateKey == currentTargetKey {
            candidateCount += 1
            candidateLastSeenAt = now
            if isOnset {
                candidateIsOnset = true
            }
        } else {
            candidateKey = currentTargetKey
            candidateCount = 1
            candidateFirstSeenAt = now
            candidateLastSeenAt = now
            candidateIsOnset = isOnset
        }

        let elapsedSpan = candidateLastSeenAt - candidateFirstSeenAt
        let neededSpan = candidateIsOnset ? Self.onsetEvidenceSpan : Self.standardEvidenceSpan
        // A candidate that has only ever seen non-foreground frames has only ever
        // seen the room agree with itself, and the room agrees with itself for as
        // long as you ask. Manual and chromatic mode still bypass this: manual's
        // player has already chosen the string, and chromatic's whole job is to
        // report whatever it hears.
        let isConfirmed = (candidateCount >= 2 && (candidateIsOnset || elapsedSpan >= (neededSpan - 0.001) || candidateCount >= 3))
            && (isForeground || config.mode == .manual || (config.mode == .chromatic && candidateCount >= 2))

        guard isContinuingTarget || isConfirmed || config.mode == .manual || (config.mode == .chromatic && candidateCount >= 2) else {
            feedbackState = .checking
            let elapsed = now - lastReadingTime
            if elapsed > Self.priorGraceDuration {
                continuityPrior = nil
            }
            // Past the hold duration the display expires whatever the streak says:
            // that is a duration, not a judgement about the estimator, and letting
            // the hysteresis reach it would leave a needle live over silence.
            if elapsed <= Self.readingHoldDuration, let last = lastReading {
                guard mayChangeDisplay(to: .held) else { return pinnedReading(at: now) }
                return publish(TunerReading(
                    at: now,
                    lastFreshAt: last.lastFreshAt,
                    frequency: last.frequency,
                    note: last.note,
                    target: last.target,
                    targetIndex: last.targetIndex,
                    cents: last.cents,
                    displayCents: displayCentsEma,
                    freshness: .held,
                    inTune: last.inTune,
                    recovered: last.recovered
                ))
            }
            return publish(nil)
        }

        // 3. Calculate cents deviation
        let rawCents = PitchMath.centsBetween(measured: frequency, reference: target.frequency)
        let clampedCents = max(-50.0, min(50.0, rawCents))

        // 4. Smooth display cents (Time-based EMA with tau = 50ms) & Target Change Reset
        let targetChanged = (currentTargetKey != activeTargetKey || continuityPrior == nil || lastReadingTime == 0)

        if targetChanged {
            displayCentsEma = clampedCents
            lastInTuneState = false
            guidedHoldStartTime = nil
            activeTargetKey = currentTargetKey
        } else {
            let deltaSeconds = max(0.0, now - lastReadingTime)
            let alpha = 1.0 - exp(-deltaSeconds / Self.displayEmaTimeConstant)
            displayCentsEma += alpha * (clampedCents - displayCentsEma)
        }

        // 5. In-tune check with hysteresis
        let enterThreshold = config.precision ? Self.precisionEnterTuneCents : Self.standardEnterTuneCents
        let exitThreshold = config.precision ? Self.precisionExitTuneCents : Self.standardExitTuneCents

        // A spectrally recovered estimate may update the display and the prior, but
        // must not assert that a string is in tune. Cents error on recovery is
        // noisier than YIN's, and "you are flat" is directly actionable advice, so
        // a wrong recovered value must never be able to tell the player to move a
        // peg. The rule itself lives on the estimate it governs, `PitchResult`.
        // The tracker records the true `inTune` state for later YIN frames.
        let inTuneMayBeAsserted = !pitchResult.recovered || PitchResult.recoveredMayAssertInTune

        let inTune: Bool
        if lastInTuneState {
            inTune = abs(rawCents) <= exitThreshold
        } else {
            inTune = abs(rawCents) <= enterThreshold
        }
        if inTuneMayBeAsserted {
            lastInTuneState = inTune
        }

        // 6. Guided Mode Progress Advancement (1-second uninterrupted fresh hold requirement)
        if config.mode == .guided && targetIndex == guidedTargetIndex {
            if inTune && pitchResult.confidence >= Self.guidedCompletionPeriodicity && !pitchResult.recovered {
                if let startTime = guidedHoldStartTime {
                    if (now - startTime) >= Self.guidedHoldDuration {
                        guidedProgress[targetIndex] = true
                        if guidedTargetIndex + 1 < targets.count {
                            guidedTargetIndex += 1
                        }
                        guidedHoldStartTime = nil
                    }
                } else {
                    guidedHoldStartTime = now
                }
            } else {
                guidedHoldStartTime = nil
            }
        }

        lastReadingTime = now
        activeTargetKey = currentTargetKey
        continuityPrior = (frequency: frequency, at: now)
        feedbackState = .tracking

        // 7. Continuation hysteresis. Everything above has decided what the
        //    display *could* show on this frame; this decides whether the estimator
        //    has been saying the same thing long enough for the display to act on
        //    it. Held here, the frame's estimate is still recorded in the candidate,
        //    the prior and the reading clock — the evidence is real, only the display
        //    is not yet entitled to move — so acquisition and responsiveness are
        //    untouched and only the visible state waits. Letting the clock advance
        //    is deliberate: the frame is evidence about the note even when it is not
        //    evidence about the display, and the display's own expiry is a duration
        //    that the streak must not be able to reach.
        guard mayChangeDisplay(to: pitchResult.recovered ? .recovery : .yin) else {
            return pinnedReading(at: now)
        }

        let noteDisplay = PitchMath.midiNoteName(target.midi)

        let reading = TunerReading(
            at: now,
            lastFreshAt: now,
            frequency: frequency,
            note: noteDisplay,
            target: target,
            targetIndex: targetIndex,
            cents: rawCents,
            displayCents: displayCentsEma,
            freshness: .fresh,
            inTune: inTune && inTuneMayBeAsserted,
            recovered: pitchResult.recovered
        )
        lastReading = reading
        return publish(reading)
    }

    private func handleLostSignal(at now: TimeInterval, rms: Double = 0) -> TunerReading? {
        // A dropout shorter than the continuation streak is not evidence that the
        // note stopped. It is evidence that this frame is bad, so it must not cost
        // the player a guided hold they have already earned, and it must not throw
        // away a candidate that is one frame from confirming. Both stay bounded:
        // `maxCandidateGap` is still the only thing that ends a candidate, and it
        // ends one however short the dropouts were.
        let isTransient = shouldHoldThroughDropout
        if !isTransient {
            guidedHoldStartTime = nil
        }
        if (now - candidateLastSeenAt) > Self.maxCandidateGap {
            candidateKey = nil
            candidateCount = 0
            candidateFirstSeenAt = 0
            candidateLastSeenAt = 0
            candidateIsOnset = false
        }
        lastRms = rms

        let elapsed = now - lastReadingTime

        // 1. Evaluate prior expiry independently (priorGraceDuration = 0.85s)
        if elapsed > Self.priorGraceDuration {
            continuityPrior = nil
        }

        // 2. Evaluate display hold independently (readingHoldDuration = 1.0s)
        if elapsed <= Self.readingHoldDuration, let last = lastReading {
            feedbackState = .tracking
            guard mayChangeDisplay(to: .held) else { return pinnedReading(at: now) }
            return publish(TunerReading(
                at: now,
                lastFreshAt: last.lastFreshAt,
                frequency: last.frequency,
                note: last.note,
                target: last.target,
                targetIndex: last.targetIndex,
                cents: last.cents,
                displayCents: displayCentsEma,
                freshness: .held,
                inTune: last.inTune, // Preserve last confirmed in-tune visual state
                recovered: last.recovered
            ))
        }

        // 3. Past readingHoldDuration: full display expiration
        continuityPrior = nil
        activeTargetKey = nil
        lastReading = nil
        if rms > 0 && rms < Double(recommendedNoiseGate(isSustaining: false)) && rms > ambientFloor * 0.85 {
            feedbackState = .quiet
        } else if elapsed > 0.4 {
            feedbackState = .ready
        }
        return publish(nil)
    }

    private func handleAmbiguousSignal(at now: TimeInterval) {
        guidedHoldStartTime = nil
        feedbackState = .ambiguous
    }

    /// Whether the display may change its relationship to the estimator on this
    /// frame, given how long the estimator has been saying the same thing.
    ///
    /// Not changing costs nothing: the frame's estimate is still recorded, and the
    /// next frame sees the streak it would have seen anyway. So the cheap error
    /// here is a frame or two of a stale reading, and the expensive one is a
    /// needle that blinks. Hence the asymmetry — weaken slowly, strengthen
    /// quickly — and hence that the question is asked about the *estimator* and
    /// not about the pitch: a decaying note produces confident, in-vocabulary,
    /// wildly different pitches, and no threshold on the pitch can tell that from a
    /// player tuning.
    private func mayChangeDisplay(to evidence: DisplayEvidence) -> Bool {
        let current = DisplayEvidence(reading: displayedReading)
        if evidence == current { return true }
        // Going from nothing to something is acquisition, not continuation, and
        // acquisition already has its own requirements — the candidate count, the
        // evidence span, the onset shortcut. Applying a second, stricter one here
        // would cost manual mode its first frame, and manual mode is the mode where
        // the player has already chosen the string and is waiting for a number.
        guard current != .dark else { return true }
        if evidence > current {
            return consecutiveYinSuccesses >= Self.continuationYinSuccessesToStrengthen
        }
        return consecutiveYinFailures >= Self.continuationYinFailuresToWeaken
    }

    /// The reading the display is already showing, published again unchanged.
    ///
    /// Every field the player can see is the field they saw on the previous frame,
    /// which is the entire point: the display's relationship to the estimator did
    /// not change, so nothing on screen moves. `at` advances and `lastFreshAt`
    /// does not, so a consumer that ages a reading by `lastFreshAt` still sees this
    /// one for exactly as long as it is true. The copy is of `displayedReading`
    /// rather than of `lastReading`, so pinning a hold stays a hold.
    private func pinnedReading(at now: TimeInterval) -> TunerReading? {
        guard let shown = displayedReading else { return nil }
        return TunerReading(
            at: now,
            lastFreshAt: shown.lastFreshAt,
            frequency: shown.frequency,
            note: shown.note,
            target: shown.target,
            targetIndex: shown.targetIndex,
            cents: shown.cents,
            displayCents: shown.displayCents,
            freshness: shown.freshness,
            inTune: shown.inTune,
            recovered: shown.recovered
        )
    }

    /// Hands `reading` to the display and records it as what is now on screen.
    ///
    /// Every path that returns a reading goes through here, so the continuation
    /// gate and the screen can never disagree about what the player is looking at.
    private func publish(_ reading: TunerReading?) -> TunerReading? {
        displayedReading = reading
        return reading
    }
}
