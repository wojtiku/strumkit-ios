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

    // Hold & Sustain Grace Durations
    public static let readingHoldDuration: TimeInterval = 0.85
    public static let priorGraceDuration: TimeInterval = 0.85

    // State
    private var lastReadingTime: TimeInterval = 0
    private var displayCentsEma: Double = 0.0
    private var lastInTuneState: Bool = false
    private var guidedHoldStartTime: TimeInterval? = nil
    private var previousTargetIndex: Int = -1

    private var candidateIndex: Int? = nil
    private var candidateCount: Int = 0
    private var lastRms: Double = 0.0
    private var lastForegroundTime: TimeInterval = 0
    private var lastReading: TunerReading? = nil

    public private(set) var ambientFloor: Double = initialAmbientFloor
    public private(set) var guidedProgress: [Bool] = []
    public private(set) var guidedTargetIndex: Int = 0
    public private(set) var feedbackState: SignalFeedbackState = .inactive
    public private(set) var continuityPrior: (frequency: Double, at: TimeInterval)? = nil

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
        guidedProgress = Array(repeating: false, count: targetCount)
        guidedTargetIndex = 0
        displayCentsEma = 0.0
        lastInTuneState = false
        guidedHoldStartTime = nil
        previousTargetIndex = -1
        candidateIndex = nil
        candidateCount = 0
        lastRms = 0.0
        continuityPrior = nil
        feedbackState = .inactive
        ambientFloor = Self.initialAmbientFloor
        lastForegroundTime = 0
        lastReading = nil
        lastReadingTime = 0
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
        guard !targets.isEmpty else { return nil }

        if guidedProgress.count != targets.count {
            guidedProgress = Array(repeating: false, count: targets.count)
            guidedTargetIndex = 0
        }

        // Update ambient noise floor during quiet / unvoiced intervals
        let isForeground = pitchResult.isSignalPresent
            && pitchResult.frequency >= TunerConstants.detectorMinHz
            && pitchResult.confidence >= Self.foregroundPeriodicityThreshold

        if isForeground {
            lastForegroundTime = now
        } else if (now - lastForegroundTime) >= Self.ambientCooldown && pitchResult.amplitudeRMS > 0 {
            let alpha = 0.05
            ambientFloor = max(Self.minAmbientFloor, min(Self.maxAmbientFloor, (1.0 - alpha) * ambientFloor + alpha * pitchResult.amplitudeRMS))
        }

        // 1. Check signal presence
        guard pitchResult.isSignalPresent && pitchResult.frequency >= TunerConstants.detectorMinHz else {
            return handleLostSignal(at: now, rms: pitchResult.amplitudeRMS)
        }

        let frequency = pitchResult.frequency
        let currentRms = pitchResult.amplitudeRMS
        let isOnset = (lastRms > 0) && (currentRms >= lastRms * Self.onsetRmsMultiplier)
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
                let hysteresis = (idx == previousTargetIndex) ? 20.0 : 0.0
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

        // Multi-reading target confirmation (ACQUIRE_READINGS = 3, or 2 on onset, or immediate on continuing note)
        let isContinuingTarget = (targetIndex == previousTargetIndex && continuityPrior != nil && (now - lastReadingTime) <= Self.priorGraceDuration)
        let neededReadings = isOnset ? Self.onsetAcquireReadings : Self.acquireReadings
        if candidateIndex == targetIndex {
            candidateCount += 1
        } else {
            candidateIndex = targetIndex
            candidateCount = 1
        }

        guard isContinuingTarget || candidateCount >= neededReadings || config.mode == .chromatic || config.mode == .manual else {
            feedbackState = .checking
            if (now - lastReadingTime) <= Self.priorGraceDuration, let last = lastReading {
                return TunerReading(
                    at: now,
                    frequency: last.frequency,
                    note: last.note,
                    target: last.target,
                    targetIndex: last.targetIndex,
                    cents: last.cents,
                    displayCents: displayCentsEma,
                    freshness: .held,
                    inTune: false
                )
            }
            return nil
        }

        // 3. Calculate cents deviation
        let rawCents = PitchMath.centsBetween(measured: frequency, reference: target.frequency)
        let clampedCents = max(-50.0, min(50.0, rawCents))

        // 4. Smooth display cents (Exponential Moving Average)
        let smoothingAlpha = 0.35
        displayCentsEma = (1.0 - smoothingAlpha) * displayCentsEma + smoothingAlpha * clampedCents

        // 5. In-tune check with hysteresis
        let enterThreshold = config.precision ? Self.precisionEnterTuneCents : Self.standardEnterTuneCents
        let exitThreshold = config.precision ? Self.precisionExitTuneCents : Self.standardExitTuneCents

        let inTune: Bool
        if lastInTuneState {
            inTune = abs(rawCents) <= exitThreshold
        } else {
            inTune = abs(rawCents) <= enterThreshold
        }
        lastInTuneState = inTune

        // 6. Guided Mode Progress Advancement (1-second hold requirement)
        if config.mode == .guided && targetIndex == guidedTargetIndex {
            if inTune && pitchResult.confidence >= Self.guidedCompletionPeriodicity {
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
        previousTargetIndex = targetIndex
        continuityPrior = (frequency: frequency, at: now)
        feedbackState = .tracking

        let noteDisplay = PitchMath.midiNoteName(target.midi)

        let reading = TunerReading(
            at: now,
            frequency: frequency,
            note: noteDisplay,
            target: target,
            targetIndex: targetIndex,
            cents: rawCents,
            displayCents: displayCentsEma,
            freshness: .fresh,
            inTune: inTune
        )
        lastReading = reading
        return reading
    }

    private func handleLostSignal(at now: TimeInterval, rms: Double = 0) -> TunerReading? {
        guidedHoldStartTime = nil
        candidateCount = 0
        candidateIndex = nil

        let elapsed = now - lastReadingTime

        // If a reading occurred recently, keep continuity prior and return held reading
        if elapsed <= Self.priorGraceDuration, let last = lastReading {
            feedbackState = .tracking
            return TunerReading(
                at: now,
                frequency: last.frequency,
                note: last.note,
                target: last.target,
                targetIndex: last.targetIndex,
                cents: last.cents,
                displayCents: displayCentsEma,
                freshness: .held,
                inTune: false
            )
        }

        continuityPrior = nil
        lastReading = nil
        if rms > 0 && rms < Double(recommendedNoiseGate(isSustaining: false)) && rms > ambientFloor * 0.85 {
            feedbackState = .quiet
        } else if elapsed > 0.4 {
            feedbackState = .ready
        }
        return nil
    }

    private func handleAmbiguousSignal(at now: TimeInterval) {
        guidedHoldStartTime = nil
        feedbackState = .ambiguous
    }
}
