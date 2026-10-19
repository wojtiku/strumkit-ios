import Foundation
@testable import StrumKit

/// Detailed description of a divergence between expected and actual traces.
public struct ParityDivergence: Sendable, CustomStringConvertible, Equatable {
    public var frameIndex: Int
    public var sampleIndex: Int?
    public var timeMs: Double?
    public var fieldPath: String
    public var expected: String
    public var actual: String
    public var delta: Double?
    public var budget: Double?
    public var message: String

    public init(
        frameIndex: Int,
        sampleIndex: Int? = nil,
        timeMs: Double? = nil,
        fieldPath: String,
        expected: String,
        actual: String,
        delta: Double? = nil,
        budget: Double? = nil,
        message: String
    ) {
        self.frameIndex = frameIndex
        self.sampleIndex = sampleIndex
        self.timeMs = timeMs
        self.fieldPath = fieldPath
        self.expected = expected
        self.actual = actual
        self.delta = delta
        self.budget = budget
        self.message = message
    }

    public var description: String {
        var parts: [String] = []
        parts.append("Frame [\(frameIndex)]")
        if let timeMs = timeMs {
            parts.append(String(format: "t=%.2fms", timeMs))
        }
        if let sampleIndex = sampleIndex {
            parts.append("s=\(sampleIndex)")
        }
        parts.append("field: '\(fieldPath)'")
        parts.append("expected: \(expected)")
        parts.append("actual: \(actual)")
        if let delta = delta {
            parts.append(String(format: "delta: %g", delta))
        }
        if let budget = budget {
            parts.append(String(format: "budget: %g", budget))
        }
        parts.append("message: \(message)")
        return parts.joined(separator: " | ")
    }
}

/// The result of comparing two ParityTraces.
public struct ParityComparisonResult: Sendable, CustomStringConvertible {
    public var passed: Bool { divergences.isEmpty }
    public var totalDifferences: Int { divergences.count }
    public var divergences: [ParityDivergence]
    public var firstDivergence: ParityDivergence? { divergences.first }

    public init(divergences: [ParityDivergence] = []) {
        self.divergences = divergences
    }

    public var description: String {
        if passed {
            return "Parity comparison PASSED (0 divergences)"
        }
        var report = "Parity comparison FAILED: \(totalDifferences) divergence(s) found.\n"
        if let first = firstDivergence {
            report += "First divergence: \(first.description)\n"
        }
        if totalDifferences > 1 {
            report += "First \(min(5, totalDifferences)) divergences:\n"
            for (idx, div) in divergences.prefix(5).enumerated() {
                report += "  [\(idx + 1)] \(div.description)\n"
            }
        }
        return report
    }
}

/// Strict differential comparator implementing the frozen parity acceptance contract.
public struct ParityComparator: Sendable {
    public var budgets: ParityBudgets
    public var discreteRules: ParityDiscreteRules
    public var maxRecordedDivergences: Int

    public init(
        budgets: ParityBudgets = .frozen,
        discreteRules: ParityDiscreteRules = .frozen,
        maxRecordedDivergences: Int = 1000
    ) {
        self.budgets = budgets
        self.discreteRules = discreteRules
        self.maxRecordedDivergences = maxRecordedDivergences
    }

    /// Compares expected and actual traces, checking every frame against numeric budgets
    /// and discrete equality rules.
    public func compare(expected: ParityTrace, actual: ParityTrace) -> ParityComparisonResult {
        var divergences: [ParityDivergence] = []

        // 1. Trace-level metadata checks
        if expected.sampleRate != actual.sampleRate {
            divergences.append(ParityDivergence(
                frameIndex: -1,
                fieldPath: "sampleRate",
                expected: "\(expected.sampleRate)",
                actual: "\(actual.sampleRate)",
                message: "Sample rate mismatch"
            ))
        }

        if expected.frameCount != actual.frameCount {
            divergences.append(ParityDivergence(
                frameIndex: -1,
                fieldPath: "frameCount",
                expected: "\(expected.frameCount)",
                actual: "\(actual.frameCount)",
                message: "Trace frameCount header mismatch"
            ))
        }

        if expected.frames.count != actual.frames.count {
            divergences.append(ParityDivergence(
                frameIndex: min(expected.frames.count, actual.frames.count),
                fieldPath: "frames.count",
                expected: "\(expected.frames.count)",
                actual: "\(actual.frames.count)",
                message: "Actual frame array count mismatch: expected \(expected.frames.count), got \(actual.frames.count)"
            ))
        }

        if expected.confirmedNotes != actual.confirmedNotes {
            divergences.append(ParityDivergence(
                frameIndex: -1,
                fieldPath: "confirmedNotes",
                expected: "\(expected.confirmedNotes)",
                actual: "\(actual.confirmedNotes)",
                message: "Confirmed notes sequence mismatch"
            ))
        }

        // 2. Frame-by-frame comparison
        let maxFrames = max(expected.frames.count, actual.frames.count)
        for i in 0..<maxFrames {
            if divergences.count >= maxRecordedDivergences {
                break
            }

            guard i < expected.frames.count else {
                let actualFrame = actual.frames[i]
                divergences.append(ParityDivergence(
                    frameIndex: i,
                    sampleIndex: actualFrame.sampleIndex,
                    timeMs: actualFrame.timeMs,
                    fieldPath: "frame",
                    expected: "no frame (EOF)",
                    actual: "extra frame present",
                    message: "Unexpected extra frame at index \(i)"
                ))
                continue
            }

            guard i < actual.frames.count else {
                let expFrame = expected.frames[i]
                divergences.append(ParityDivergence(
                    frameIndex: i,
                    sampleIndex: expFrame.sampleIndex,
                    timeMs: expFrame.timeMs,
                    fieldPath: "frame",
                    expected: "frame present",
                    actual: "missing frame (EOF reached prematurely)",
                    message: "Missing expected frame at index \(i)"
                ))
                continue
            }

            let exp = expected.frames[i]
            let act = actual.frames[i]

            compareFrame(
                expected: exp,
                actual: act,
                frameIndex: i,
                divergences: &divergences
            )
        }

        return ParityComparisonResult(divergences: divergences)
    }

    /// Compares expected trace detector frames against actual detector outputs.
    public func compareDetectorOutputs(
        expectedFrames: [ParityFrame],
        actualOutputs: [ParityDetectorOutput]
    ) -> ParityComparisonResult {
        var divergences: [ParityDivergence] = []

        if expectedFrames.count != actualOutputs.count {
            divergences.append(ParityDivergence(
                frameIndex: min(expectedFrames.count, actualOutputs.count),
                fieldPath: "detectorFrames.count",
                expected: "\(expectedFrames.count)",
                actual: "\(actualOutputs.count)",
                message: "Detector frame count mismatch: expected \(expectedFrames.count), got \(actualOutputs.count)"
            ))
        }

        let count = min(expectedFrames.count, actualOutputs.count)
        for i in 0..<count {
            if divergences.count >= maxRecordedDivergences {
                break
            }
            let exp = expectedFrames[i]
            let act = actualOutputs[i]
            let sampleIndex = exp.sampleIndex
            let timeMs = exp.timeMs

            checkOptionalNumeric(
                expected: exp.detector.frequency,
                actual: act.frequency,
                budget: budgets.frequencyAbsoluteHz,
                fieldPath: "detector.frequency",
                frameIndex: i,
                sampleIndex: sampleIndex,
                timeMs: timeMs,
                divergences: &divergences
            )

            checkOptionalNumeric(
                expected: exp.detector.confidence,
                actual: act.confidence,
                budget: budgets.confidenceAbsolute,
                fieldPath: "detector.confidence",
                frameIndex: i,
                sampleIndex: sampleIndex,
                timeMs: timeMs,
                divergences: &divergences
            )

            checkRMS(
                expected: exp.detector.rms,
                actual: act.rms,
                fieldPath: "detector.rms",
                frameIndex: i,
                sampleIndex: sampleIndex,
                timeMs: timeMs,
                divergences: &divergences
            )

            if discreteRules.optionalFlagsExact {
                checkOptionalEqual(
                    expected: exp.detector.foregroundAgrees,
                    actual: act.foregroundAgrees,
                    fieldPath: "detector.foregroundAgrees",
                    frameIndex: i,
                    sampleIndex: sampleIndex,
                    timeMs: timeMs,
                    divergences: &divergences
                )

                checkOptionalEqual(
                    expected: exp.detector.oddOnly,
                    actual: act.oddOnly,
                    fieldPath: "detector.oddOnly",
                    frameIndex: i,
                    sampleIndex: sampleIndex,
                    timeMs: timeMs,
                    divergences: &divergences
                )
            }
        }

        return ParityComparisonResult(divergences: divergences)
    }

    /// Compares expected trace tracker frames against actual tracker outputs.
    public func compareTrackerOutputs(
        expectedFrames: [ParityFrame],
        actualOutputs: [ParityTrackerOutput]
    ) -> ParityComparisonResult {
        var divergences: [ParityDivergence] = []

        if expectedFrames.count != actualOutputs.count {
            divergences.append(ParityDivergence(
                frameIndex: min(expectedFrames.count, actualOutputs.count),
                fieldPath: "trackerFrames.count",
                expected: "\(expectedFrames.count)",
                actual: "\(actualOutputs.count)",
                message: "Tracker frame count mismatch: expected \(expectedFrames.count), got \(actualOutputs.count)"
            ))
        }

        let count = min(expectedFrames.count, actualOutputs.count)
        for i in 0..<count {
            if divergences.count >= maxRecordedDivergences {
                break
            }
            let exp = expectedFrames[i]
            compareTracker(
                expected: exp.tracker,
                actual: actualOutputs[i],
                frameIndex: i,
                sampleIndex: exp.sampleIndex,
                timeMs: exp.timeMs,
                divergences: &divergences
            )
        }

        return ParityComparisonResult(divergences: divergences)
    }

    /// Compares expected trace tracker frames and confirmation outputs against actual outputs.
    public func compareTrackerAndConfirmationOutputs(
        expectedFrames: [ParityFrame],
        actualTrackers: [ParityTrackerOutput],
        actualConfirmations: [ParityConfirmationOutput]? = nil
    ) -> ParityComparisonResult {
        var divergences: [ParityDivergence] = []

        if expectedFrames.count != actualTrackers.count {
            divergences.append(ParityDivergence(
                frameIndex: min(expectedFrames.count, actualTrackers.count),
                fieldPath: "trackerFrames.count",
                expected: "\(expectedFrames.count)",
                actual: "\(actualTrackers.count)",
                message: "Tracker frame count mismatch: expected \(expectedFrames.count), got \(actualTrackers.count)"
            ))
        }

        if let actualConfirmations = actualConfirmations, expectedFrames.count != actualConfirmations.count {
            divergences.append(ParityDivergence(
                frameIndex: min(expectedFrames.count, actualConfirmations.count),
                fieldPath: "confirmationFrames.count",
                expected: "\(expectedFrames.count)",
                actual: "\(actualConfirmations.count)",
                message: "Confirmation frame count mismatch: expected \(expectedFrames.count), got \(actualConfirmations.count)"
            ))
        }

        let count = min(expectedFrames.count, actualTrackers.count)
        for i in 0..<count {
            if divergences.count >= maxRecordedDivergences {
                break
            }
            let exp = expectedFrames[i]
            let sampleIndex = exp.sampleIndex
            let timeMs = exp.timeMs

            compareTracker(
                expected: exp.tracker,
                actual: actualTrackers[i],
                frameIndex: i,
                sampleIndex: sampleIndex,
                timeMs: timeMs,
                divergences: &divergences
            )

            if let actualConfirmations = actualConfirmations, i < actualConfirmations.count {
                compareConfirmation(
                    expected: exp.confirmation,
                    actual: actualConfirmations[i],
                    frameIndex: i,
                    sampleIndex: sampleIndex,
                    timeMs: timeMs,
                    divergences: &divergences
                )
            }
        }

        return ParityComparisonResult(divergences: divergences)
    }

    /// Replays detector outputs from a golden trace through FaithfulTracker and TuningFeedback,
    /// comparing every frame's tracker and confirmation outputs against the trace.
    public func compareTrackerReplay(
        trace: ParityTrace,
        tracker: FaithfulTracker = FaithfulTracker(),
        feedback: TuningFeedback? = TuningFeedback()
    ) -> ParityComparisonResult {
        var actualTrackers: [ParityTrackerOutput] = []
        var actualConfirmations: [ParityConfirmationOutput] = []

        for frame in trace.frames {
            let candidate: FaithfulPitchCandidate?
            if let freq = frame.detector.frequency, let conf = frame.detector.confidence {
                candidate = FaithfulPitchCandidate(
                    frequency: freq,
                    confidence: conf,
                    rms: frame.detector.rms ?? 0.0,
                    oddOnly: frame.detector.oddOnly,
                    foregroundAgrees: frame.detector.foregroundAgrees
                )
            } else {
                candidate = nil
            }

            let reading = tracker.push(pitch: candidate, time: frame.timeMs)
            let confirmed = feedback?.observe(reading) ?? false

            let trackerOutput = ParityTrackerOutput(
                reading: reading,
                rawDetector: frame.detector,
                tuning: tracker.tuning
            )
            actualTrackers.append(trackerOutput)

            let confirmationOutput = ParityConfirmationOutput(
                event: confirmed,
                reading: reading
            )
            actualConfirmations.append(confirmationOutput)
        }

        return compareTrackerAndConfirmationOutputs(
            expectedFrames: trace.frames,
            actualTrackers: actualTrackers,
            actualConfirmations: actualConfirmations
        )
    }

    /// Compares expected trace publication and confirmation frames against actual outputs.
    public func comparePublicationAndConfirmationOutputs(
        expectedFrames: [ParityFrame],
        actualPublications: [ParityPublicationOutput],
        actualConfirmations: [ParityConfirmationOutput]? = nil
    ) -> ParityComparisonResult {
        var divergences: [ParityDivergence] = []

        if expectedFrames.count != actualPublications.count {
            divergences.append(ParityDivergence(
                frameIndex: min(expectedFrames.count, actualPublications.count),
                fieldPath: "publicationFrames.count",
                expected: "\(expectedFrames.count)",
                actual: "\(actualPublications.count)",
                message: "Publication frame count mismatch: expected \(expectedFrames.count), got \(actualPublications.count)"
            ))
        }

        if let actualConfirmations = actualConfirmations, expectedFrames.count != actualConfirmations.count {
            divergences.append(ParityDivergence(
                frameIndex: min(expectedFrames.count, actualConfirmations.count),
                fieldPath: "confirmationFrames.count",
                expected: "\(expectedFrames.count)",
                actual: "\(actualConfirmations.count)",
                message: "Confirmation frame count mismatch: expected \(expectedFrames.count), got \(actualConfirmations.count)"
            ))
        }

        let count = min(expectedFrames.count, actualPublications.count)
        for i in 0..<count {
            if divergences.count >= maxRecordedDivergences {
                break
            }
            let exp = expectedFrames[i]
            let sampleIndex = exp.sampleIndex
            let timeMs = exp.timeMs

            comparePublication(
                expected: exp.publication,
                actual: actualPublications[i],
                frameIndex: i,
                sampleIndex: sampleIndex,
                timeMs: timeMs,
                divergences: &divergences
            )

            if let actualConfirmations = actualConfirmations, i < actualConfirmations.count {
                compareConfirmation(
                    expected: exp.confirmation,
                    actual: actualConfirmations[i],
                    frameIndex: i,
                    sampleIndex: sampleIndex,
                    timeMs: timeMs,
                    divergences: &divergences
                )
            }
        }

        return ParityComparisonResult(divergences: divergences)
    }

    /// Replays detector outputs from a golden trace through FaithfulTracker, FaithfulPresentation, and TuningFeedback,
    /// comparing every frame's publication slots and confirmation events against the trace.
    public func comparePublicationReplay(
        trace: ParityTrace,
        tracker: FaithfulTracker = FaithfulTracker(),
        presentation: FaithfulPresentation = FaithfulPresentation(),
        feedback: TuningFeedback? = TuningFeedback(),
        onFrame: ((Int, FaithfulTracker, FaithfulPresentation, TuningFeedback?) -> Void)? = nil
    ) -> ParityComparisonResult {
        if trace.category.contains("slack") {
            tracker.tuning = "slack"
        }
        var actualPublications: [ParityPublicationOutput] = []
        var actualConfirmations: [ParityConfirmationOutput] = []

        for (frameIndex, frame) in trace.frames.enumerated() {
            onFrame?(frameIndex, tracker, presentation, feedback)

            let candidate: FaithfulPitchCandidate?
            if let freq = frame.detector.frequency, let conf = frame.detector.confidence {
                candidate = FaithfulPitchCandidate(
                    frequency: freq,
                    confidence: conf,
                    rms: frame.detector.rms ?? 0.0,
                    oddOnly: frame.detector.oddOnly,
                    foregroundAgrees: frame.detector.foregroundAgrees
                )
            } else {
                candidate = nil
            }

            let reading = tracker.push(pitch: candidate, time: frame.timeMs)
            let confirmed = feedback?.observe(reading) ?? false
            let action = presentation.push(reading: reading, time: frame.timeMs)

            actualPublications.append(action.parityOutput)
            actualConfirmations.append(ParityConfirmationOutput(
                event: confirmed,
                reading: reading
            ))
        }

        return comparePublicationAndConfirmationOutputs(
            expectedFrames: trace.frames,
            actualPublications: actualPublications,
            actualConfirmations: actualConfirmations
        )
    }

    private func compareFrame(
        expected exp: ParityFrame,
        actual act: ParityFrame,
        frameIndex i: Int,
        divergences: inout [ParityDivergence]
    ) {
        let sampleIndex = act.sampleIndex
        let timeMs = act.timeMs

        // Frame index
        if exp.frameIndex != act.frameIndex {
            recordDiscreteMismatch(
                expected: "\(exp.frameIndex)",
                actual: "\(act.frameIndex)",
                fieldPath: "frameIndex",
                frameIndex: i,
                sampleIndex: sampleIndex,
                timeMs: timeMs,
                divergences: &divergences
            )
        }

        // Sample index exact match
        if budgets.sampleIndexExact {
            if exp.sampleIndex != act.sampleIndex {
                recordDiscreteMismatch(
                    expected: "\(exp.sampleIndex)",
                    actual: "\(act.sampleIndex)",
                    fieldPath: "sampleIndex",
                    frameIndex: i,
                    sampleIndex: sampleIndex,
                    timeMs: timeMs,
                    divergences: &divergences
                )
            }
        }

        // Timestamps
        checkNumeric(
            expected: exp.timeMs,
            actual: act.timeMs,
            budget: budgets.timestampConversionErrorMaxMs,
            fieldPath: "timeMs",
            frameIndex: i,
            sampleIndex: sampleIndex,
            timeMs: timeMs,
            divergences: &divergences
        )

        checkNumeric(
            expected: exp.workletTimeMs,
            actual: act.workletTimeMs,
            budget: budgets.timestampConversionErrorMaxMs,
            fieldPath: "workletTimeMs",
            frameIndex: i,
            sampleIndex: sampleIndex,
            timeMs: timeMs,
            divergences: &divergences
        )

        // MARK: - Detector
        checkOptionalNumeric(
            expected: exp.detector.frequency,
            actual: act.detector.frequency,
            budget: budgets.frequencyAbsoluteHz,
            fieldPath: "detector.frequency",
            frameIndex: i,
            sampleIndex: sampleIndex,
            timeMs: timeMs,
            divergences: &divergences
        )

        checkOptionalNumeric(
            expected: exp.detector.confidence,
            actual: act.detector.confidence,
            budget: budgets.confidenceAbsolute,
            fieldPath: "detector.confidence",
            frameIndex: i,
            sampleIndex: sampleIndex,
            timeMs: timeMs,
            divergences: &divergences
        )

        checkRMS(
            expected: exp.detector.rms,
            actual: act.detector.rms,
            fieldPath: "detector.rms",
            frameIndex: i,
            sampleIndex: sampleIndex,
            timeMs: timeMs,
            divergences: &divergences
        )

        if discreteRules.optionalFlagsExact {
            checkOptionalEqual(
                expected: exp.detector.foregroundAgrees,
                actual: act.detector.foregroundAgrees,
                fieldPath: "detector.foregroundAgrees",
                frameIndex: i,
                sampleIndex: sampleIndex,
                timeMs: timeMs,
                divergences: &divergences
            )

            checkOptionalEqual(
                expected: exp.detector.oddOnly,
                actual: act.detector.oddOnly,
                fieldPath: "detector.oddOnly",
                frameIndex: i,
                sampleIndex: sampleIndex,
                timeMs: timeMs,
                divergences: &divergences
            )
        }

        // MARK: - Tracker
        compareTracker(
            expected: exp.tracker,
            actual: act.tracker,
            frameIndex: i,
            sampleIndex: sampleIndex,
            timeMs: timeMs,
            divergences: &divergences
        )

        // MARK: - Publication
        comparePublication(
            expected: exp.publication,
            actual: act.publication,
            frameIndex: i,
            sampleIndex: sampleIndex,
            timeMs: timeMs,
            divergences: &divergences
        )

        // MARK: - Confirmation
        compareConfirmation(
            expected: exp.confirmation,
            actual: act.confirmation,
            frameIndex: i,
            sampleIndex: sampleIndex,
            timeMs: timeMs,
            divergences: &divergences
        )
    }

    private func compareTracker(
        expected expTracker: ParityTrackerOutput,
        actual actTracker: ParityTrackerOutput,
        frameIndex i: Int,
        sampleIndex: Int?,
        timeMs: Double?,
        divergences: inout [ParityDivergence]
    ) {
        switch (expTracker.target, actTracker.target) {
        case (nil, nil):
            break
        case (.some(let expTarget), nil):
            if discreteRules.nullMaskExact {
                recordFlippedNullMask(
                    expected: "\(expTarget.note) (idx: \(expTarget.index))",
                    actual: "null",
                    fieldPath: "tracker.target",
                    frameIndex: i,
                    sampleIndex: sampleIndex,
                    timeMs: timeMs,
                    divergences: &divergences
                )
            }
        case (nil, .some(let actTarget)):
            if discreteRules.nullMaskExact {
                recordFlippedNullMask(
                    expected: "null",
                    actual: "\(actTarget.note) (idx: \(actTarget.index))",
                    fieldPath: "tracker.target",
                    frameIndex: i,
                    sampleIndex: sampleIndex,
                    timeMs: timeMs,
                    divergences: &divergences
                )
            }
        case (.some(let expTarget), .some(let actTarget)):
            if discreteRules.targetNotesExact && expTarget.note != actTarget.note {
                recordDiscreteMismatch(
                    expected: expTarget.note,
                    actual: actTarget.note,
                    fieldPath: "tracker.target.note",
                    frameIndex: i,
                    sampleIndex: sampleIndex,
                    timeMs: timeMs,
                    divergences: &divergences
                )
            }
            if discreteRules.targetIndicesExact && expTarget.index != actTarget.index {
                recordDiscreteMismatch(
                    expected: "\(expTarget.index)",
                    actual: "\(actTarget.index)",
                    fieldPath: "tracker.target.index",
                    frameIndex: i,
                    sampleIndex: sampleIndex,
                    timeMs: timeMs,
                    divergences: &divergences
                )
            }
            checkNumeric(
                expected: expTarget.frequency,
                actual: actTarget.frequency,
                budget: budgets.frequencyAbsoluteHz,
                fieldPath: "tracker.target.frequency",
                frameIndex: i,
                sampleIndex: sampleIndex,
                timeMs: timeMs,
                divergences: &divergences
            )
        }

        checkOptionalNumeric(
            expected: expTracker.rawCents,
            actual: actTracker.rawCents,
            budget: budgets.rawCentsAbsolute,
            fieldPath: "tracker.rawCents",
            frameIndex: i,
            sampleIndex: sampleIndex,
            timeMs: timeMs,
            divergences: &divergences
        )

        checkOptionalNumeric(
            expected: expTracker.smoothedCents,
            actual: actTracker.smoothedCents,
            budget: budgets.smoothedCentsAbsolute,
            fieldPath: "tracker.smoothedCents",
            frameIndex: i,
            sampleIndex: sampleIndex,
            timeMs: timeMs,
            divergences: &divergences
        )

        checkOptionalNumeric(
            expected: expTracker.readingFrequency,
            actual: actTracker.readingFrequency,
            budget: budgets.frequencyAbsoluteHz,
            fieldPath: "tracker.readingFrequency",
            frameIndex: i,
            sampleIndex: sampleIndex,
            timeMs: timeMs,
            divergences: &divergences
        )

        if discreteRules.inTuneTransitionsExact && expTracker.inTune != actTracker.inTune {
            recordDiscreteMismatch(
                expected: "\(expTracker.inTune)",
                actual: "\(actTracker.inTune)",
                fieldPath: "tracker.inTune",
                frameIndex: i,
                sampleIndex: sampleIndex,
                timeMs: timeMs,
                divergences: &divergences
            )
        }
    }

    private func comparePublication(
        expected expPub: ParityPublicationOutput,
        actual actPub: ParityPublicationOutput,
        frameIndex i: Int,
        sampleIndex: Int?,
        timeMs: Double?,
        divergences: inout [ParityDivergence]
    ) {
        if discreteRules.publicationSlotsExact && expPub.action != actPub.action {
            recordDiscreteMismatch(
                expected: expPub.action.rawValue,
                actual: actPub.action.rawValue,
                fieldPath: "publication.action",
                frameIndex: i,
                sampleIndex: sampleIndex,
                timeMs: timeMs,
                divergences: &divergences
            )
        }

        checkOptionalEqual(
            expected: expPub.note,
            actual: actPub.note,
            fieldPath: "publication.note",
            frameIndex: i,
            sampleIndex: sampleIndex,
            timeMs: timeMs,
            divergences: &divergences
        )

        checkOptionalNumeric(
            expected: expPub.cents,
            actual: actPub.cents,
            budget: budgets.smoothedCentsAbsolute,
            fieldPath: "publication.cents",
            frameIndex: i,
            sampleIndex: sampleIndex,
            timeMs: timeMs,
            divergences: &divergences
        )

        checkOptionalNumeric(
            expected: expPub.frequency,
            actual: actPub.frequency,
            budget: budgets.frequencyAbsoluteHz,
            fieldPath: "publication.frequency",
            frameIndex: i,
            sampleIndex: sampleIndex,
            timeMs: timeMs,
            divergences: &divergences
        )

        if discreteRules.inTuneTransitionsExact {
            checkOptionalEqual(
                expected: expPub.inTune,
                actual: actPub.inTune,
                fieldPath: "publication.inTune",
                frameIndex: i,
                sampleIndex: sampleIndex,
                timeMs: timeMs,
                divergences: &divergences
            )
        }
    }

    private func compareConfirmation(
        expected expConf: ParityConfirmationOutput,
        actual actConf: ParityConfirmationOutput,
        frameIndex i: Int,
        sampleIndex: Int?,
        timeMs: Double?,
        divergences: inout [ParityDivergence]
    ) {
        if discreteRules.confirmationEventsExact && expConf.event != actConf.event {
            recordDiscreteMismatch(
                expected: "\(expConf.event)",
                actual: "\(actConf.event)",
                fieldPath: "confirmation.event",
                frameIndex: i,
                sampleIndex: sampleIndex,
                timeMs: timeMs,
                divergences: &divergences
            )
        }

        checkOptionalEqual(
            expected: expConf.stringIndex,
            actual: actConf.stringIndex,
            fieldPath: "confirmation.stringIndex",
            frameIndex: i,
            sampleIndex: sampleIndex,
            timeMs: timeMs,
            divergences: &divergences
        )

        checkOptionalEqual(
            expected: expConf.note,
            actual: actConf.note,
            fieldPath: "confirmation.note",
            frameIndex: i,
            sampleIndex: sampleIndex,
            timeMs: timeMs,
            divergences: &divergences
        )
    }

    // MARK: - Numeric and Non-Finite Checks

    private func checkFinite(
        _ value: Double,
        fieldPath: String,
        frameIndex: Int,
        sampleIndex: Int?,
        timeMs: Double?,
        divergences: inout [ParityDivergence]
    ) -> Bool {
        if !value.isFinite {
            divergences.append(ParityDivergence(
                frameIndex: frameIndex,
                sampleIndex: sampleIndex,
                timeMs: timeMs,
                fieldPath: fieldPath,
                expected: "finite number",
                actual: "\(value)",
                message: "Non-finite value detected: \(value)"
            ))
            return false
        }
        return true
    }

    private func checkNumeric(
        expected: Double,
        actual: Double,
        budget: Double,
        fieldPath: String,
        frameIndex: Int,
        sampleIndex: Int?,
        timeMs: Double?,
        divergences: inout [ParityDivergence]
    ) {
        guard checkFinite(expected, fieldPath: "\(fieldPath) (expected)", frameIndex: frameIndex, sampleIndex: sampleIndex, timeMs: timeMs, divergences: &divergences),
              checkFinite(actual, fieldPath: fieldPath, frameIndex: frameIndex, sampleIndex: sampleIndex, timeMs: timeMs, divergences: &divergences) else {
            return
        }

        let delta = abs(actual - expected)
        if delta > budget {
            divergences.append(ParityDivergence(
                frameIndex: frameIndex,
                sampleIndex: sampleIndex,
                timeMs: timeMs,
                fieldPath: fieldPath,
                expected: String(format: "%.9g", expected),
                actual: String(format: "%.9g", actual),
                delta: delta,
                budget: budget,
                message: "Numeric delta \(delta) exceeds budget \(budget)"
            ))
        }
    }

    private func checkRMS(
        expected: Double?,
        actual: Double?,
        fieldPath: String,
        frameIndex: Int,
        sampleIndex: Int?,
        timeMs: Double?,
        divergences: inout [ParityDivergence]
    ) {
        switch (expected, actual) {
        case (nil, nil):
            break
        case (.some(let exp), nil):
            if discreteRules.nullMaskExact {
                recordFlippedNullMask(
                    expected: "\(exp)",
                    actual: "null",
                    fieldPath: fieldPath,
                    frameIndex: frameIndex,
                    sampleIndex: sampleIndex,
                    timeMs: timeMs,
                    divergences: &divergences
                )
            }
        case (nil, .some(let act)):
            if discreteRules.nullMaskExact {
                recordFlippedNullMask(
                    expected: "null",
                    actual: "\(act)",
                    fieldPath: fieldPath,
                    frameIndex: frameIndex,
                    sampleIndex: sampleIndex,
                    timeMs: timeMs,
                    divergences: &divergences
                )
            }
        case (.some(let exp), .some(let act)):
            guard checkFinite(exp, fieldPath: "\(fieldPath) (expected)", frameIndex: frameIndex, sampleIndex: sampleIndex, timeMs: timeMs, divergences: &divergences),
                  checkFinite(act, fieldPath: fieldPath, frameIndex: frameIndex, sampleIndex: sampleIndex, timeMs: timeMs, divergences: &divergences) else {
                return
            }

            let delta = abs(act - exp)
            let allowedBudget = budgets.rmsAbsolute + budgets.rmsRelative * abs(exp)
            if delta > allowedBudget {
                divergences.append(ParityDivergence(
                    frameIndex: frameIndex,
                    sampleIndex: sampleIndex,
                    timeMs: timeMs,
                    fieldPath: fieldPath,
                    expected: String(format: "%.11g", exp),
                    actual: String(format: "%.11g", act),
                    delta: delta,
                    budget: allowedBudget,
                    message: "RMS delta \(delta) exceeds compound budget \(allowedBudget) (abs: \(budgets.rmsAbsolute), rel: \(budgets.rmsRelative))"
                ))
            }
        }
    }

    private func checkOptionalNumeric(
        expected: Double?,
        actual: Double?,
        budget: Double,
        fieldPath: String,
        frameIndex: Int,
        sampleIndex: Int?,
        timeMs: Double?,
        divergences: inout [ParityDivergence]
    ) {
        switch (expected, actual) {
        case (nil, nil):
            break
        case (.some(let exp), nil):
            if discreteRules.nullMaskExact {
                recordFlippedNullMask(
                    expected: "\(exp)",
                    actual: "null",
                    fieldPath: fieldPath,
                    frameIndex: frameIndex,
                    sampleIndex: sampleIndex,
                    timeMs: timeMs,
                    divergences: &divergences
                )
            }
        case (nil, .some(let act)):
            if discreteRules.nullMaskExact {
                recordFlippedNullMask(
                    expected: "null",
                    actual: "\(act)",
                    fieldPath: fieldPath,
                    frameIndex: frameIndex,
                    sampleIndex: sampleIndex,
                    timeMs: timeMs,
                    divergences: &divergences
                )
            }
        case (.some(let exp), .some(let act)):
            checkNumeric(
                expected: exp,
                actual: act,
                budget: budget,
                fieldPath: fieldPath,
                frameIndex: frameIndex,
                sampleIndex: sampleIndex,
                timeMs: timeMs,
                divergences: &divergences
            )
        }
    }

    private func checkOptionalEqual<T: Equatable>(
        expected: T?,
        actual: T?,
        fieldPath: String,
        frameIndex: Int,
        sampleIndex: Int?,
        timeMs: Double?,
        divergences: inout [ParityDivergence]
    ) {
        switch (expected, actual) {
        case (nil, nil):
            break
        case (.some(let exp), nil):
            if discreteRules.nullMaskExact {
                recordFlippedNullMask(
                    expected: "\(exp)",
                    actual: "null",
                    fieldPath: fieldPath,
                    frameIndex: frameIndex,
                    sampleIndex: sampleIndex,
                    timeMs: timeMs,
                    divergences: &divergences
                )
            }
        case (nil, .some(let act)):
            if discreteRules.nullMaskExact {
                recordFlippedNullMask(
                    expected: "null",
                    actual: "\(act)",
                    fieldPath: fieldPath,
                    frameIndex: frameIndex,
                    sampleIndex: sampleIndex,
                    timeMs: timeMs,
                    divergences: &divergences
                )
            }
        case (.some(let exp), .some(let act)):
            if exp != act {
                recordDiscreteMismatch(
                    expected: "\(exp)",
                    actual: "\(act)",
                    fieldPath: fieldPath,
                    frameIndex: frameIndex,
                    sampleIndex: sampleIndex,
                    timeMs: timeMs,
                    divergences: &divergences
                )
            }
        }
    }

    private func recordFlippedNullMask(
        expected: String,
        actual: String,
        fieldPath: String,
        frameIndex: Int,
        sampleIndex: Int?,
        timeMs: Double?,
        divergences: inout [ParityDivergence]
    ) {
        divergences.append(ParityDivergence(
            frameIndex: frameIndex,
            sampleIndex: sampleIndex,
            timeMs: timeMs,
            fieldPath: fieldPath,
            expected: expected,
            actual: actual,
            message: "Flipped null mask: expected \(expected), got \(actual)"
        ))
    }

    private func recordDiscreteMismatch(
        expected: String,
        actual: String,
        fieldPath: String,
        frameIndex: Int,
        sampleIndex: Int?,
        timeMs: Double?,
        divergences: inout [ParityDivergence]
    ) {
        divergences.append(ParityDivergence(
            frameIndex: frameIndex,
            sampleIndex: sampleIndex,
            timeMs: timeMs,
            fieldPath: fieldPath,
            expected: expected,
            actual: actual,
            message: "Discrete mismatch: expected \(expected), got \(actual)"
        ))
    }
}
