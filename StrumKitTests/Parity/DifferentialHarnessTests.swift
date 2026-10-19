// StrumKitTests/Parity/DifferentialHarnessTests.swift
import Foundation
import Testing
@testable import StrumKit

@Suite("Parity differential harness")
struct DifferentialHarnessTests {

    // MARK: - 1. Manifest and Budgets Integrity

    @Test("Manifest loads cleanly from filesystem and freezes numeric budgets and discrete rules")
    func manifestIntegrity() throws {
        let manifest = try ParityManifest.load()
        #expect(manifest.schemaVersion == 1)
        #expect(manifest.numericBudgets == ParityBudgets.frozen)
        #expect(manifest.discreteRules == ParityDiscreteRules.frozen)

        #expect(manifest.numericBudgets.frequencyAbsoluteHz == 1e-6)
        #expect(manifest.numericBudgets.rawCentsAbsolute == 1e-6)
        #expect(manifest.numericBudgets.smoothedCentsAbsolute == 1e-6)
        #expect(manifest.numericBudgets.confidenceAbsolute == 1e-9)
        #expect(manifest.numericBudgets.rmsAbsolute == 1e-10)
        #expect(manifest.numericBudgets.rmsRelative == 1e-7)
        #expect(manifest.numericBudgets.sampleIndexExact == true)
        #expect(manifest.numericBudgets.timestampConversionErrorMaxMs == 1e-6)

        #expect(manifest.discreteRules.nullMaskExact == true)
        #expect(manifest.discreteRules.targetNotesExact == true)
        #expect(manifest.discreteRules.targetIndicesExact == true)
        #expect(manifest.discreteRules.publicationSlotsExact == true)
        #expect(manifest.discreteRules.inTuneTransitionsExact == true)
        #expect(manifest.discreteRules.confirmationEventsExact == true)
        #expect(manifest.discreteRules.optionalFlagsExact == true)

        #expect(manifest.summary.totalCases == 282)
        #expect(manifest.summary.productCases == 55)
        #expect(manifest.summary.stressCases == 192)
        #expect(manifest.summary.targetedCases == 35)
        #expect(manifest.cases.count == 282)
    }

    // MARK: - 2. Positive Acceptance (Golden Traces Pass with 0 Divergence)

    @Test("Unchanged golden traces compare green with 0 divergence across multiple categories")
    func positiveAcceptanceGoldenTraces() throws {
        let testCases: [(name: String, category: String)] = [
            ("uke_e.wav", "product-fixtures"),
            ("all-4-with-noise.wav", "product-fixtures"),
            ("steady-G4-44100", "product-controlled-44100"),
            ("steady-A4-48000", "product-controlled-48000"),
            ("vector-boundary-intune-5cents-within", "targeted"),
            ("vector-rate-96000-A4", "targeted")
        ]

        let comparator = ParityComparator()

        for testCase in testCases {
            let trace = try ParityTrace.load(named: testCase.name, in: testCase.category)
            #expect(trace.frameCount > 0)
            #expect(trace.frames.count == trace.frameCount)

            let result = comparator.compare(expected: trace, actual: trace)
            #expect(result.passed, "Golden trace \(testCase.name) must pass when compared against itself: \(result.description)")
            #expect(result.totalDifferences == 0)
            #expect(result.firstDivergence == nil)
        }
    }

    // MARK: - 3. Tolerates Differences Strictly Within Budgets

    @Test("Perturbations strictly within frozen budgets pass comparison")
    func withinBudgetsPass() throws {
        let trace = try ParityTrace.load(named: "uke_e.wav", in: "product-fixtures")
        var mutated = trace

        // Mutate frame 4 (which has valid pitch, target, cents, and publication)
        guard mutated.frames.count > 4 else {
            Issue.record("Expected uke_e.wav to have > 4 frames")
            return
        }

        // Sub-budget deviations:
        // frequency budget: 1e-6 Hz -> delta 5e-7 Hz
        // rawCents/smoothedCents budget: 1e-6 cents -> delta 5e-7 cents
        // confidence budget: 1e-9 -> delta 5e-10
        // rms budget: 1e-10 abs + 1e-7 rel -> delta 5e-11
        // timestamp budget: 1e-6 ms -> delta 5e-7 ms
        if let f = mutated.frames[4].detector.frequency {
            mutated.frames[4].detector.frequency = f + 5e-7
        }
        if let c = mutated.frames[4].detector.confidence {
            mutated.frames[4].detector.confidence = c + 5e-10
        }
        mutated.frames[4].detector.rms = (mutated.frames[4].detector.rms ?? 0.0) + 5e-11
        mutated.frames[4].timeMs += 5e-7
        mutated.frames[4].workletTimeMs += 5e-7

        if let raw = mutated.frames[4].tracker.rawCents {
            mutated.frames[4].tracker.rawCents = raw + 5e-7
        }
        if let sm = mutated.frames[4].tracker.smoothedCents {
            mutated.frames[4].tracker.smoothedCents = sm + 5e-7
        }
        if let rf = mutated.frames[4].tracker.readingFrequency {
            mutated.frames[4].tracker.readingFrequency = rf + 5e-7
        }
        if let pc = mutated.frames[4].publication.cents {
            mutated.frames[4].publication.cents = pc + 5e-7
        }
        if let pf = mutated.frames[4].publication.frequency {
            mutated.frames[4].publication.frequency = pf + 5e-7
        }

        let comparator = ParityComparator()
        let result = comparator.compare(expected: trace, actual: mutated)
        #expect(result.passed, "Mutations strictly within budgets must pass: \(result.description)")
        #expect(result.totalDifferences == 0)
    }

    // MARK: - 4. Negative Controls: Numeric Defect Detection

    @Test("Catches altered detector frequency exceeding budget")
    func alteredFrequencyFails() throws {
        let trace = try ParityTrace.load(named: "uke_e.wav", in: "product-fixtures")
        var mutated = trace

        // Budget is 1e-6 Hz. Incur a 1e-5 Hz error.
        mutated.frames[2].detector.frequency! += 1e-5

        let comparator = ParityComparator()
        let result = comparator.compare(expected: trace, actual: mutated)
        #expect(!result.passed)
        #expect(result.totalDifferences >= 1)
        #expect(result.firstDivergence?.fieldPath == "detector.frequency")
        #expect(result.firstDivergence?.frameIndex == 2)
        #expect(result.firstDivergence?.delta != nil)
        #expect(result.firstDivergence!.delta! > 1e-6)
    }

    @Test("Catches altered raw cents exceeding budget")
    func alteredRawCentsFails() throws {
        let trace = try ParityTrace.load(named: "uke_e.wav", in: "product-fixtures")
        var mutated = trace

        // Budget is 1e-6 cents. Incur a 1e-5 cents error.
        mutated.frames[2].tracker.rawCents! += 1e-5

        let comparator = ParityComparator()
        let result = comparator.compare(expected: trace, actual: mutated)
        #expect(!result.passed)
        #expect(result.firstDivergence?.fieldPath == "tracker.rawCents")
        #expect(result.firstDivergence?.frameIndex == 2)
    }

    @Test("Catches altered smoothed cents exceeding budget")
    func alteredSmoothedCentsFails() throws {
        let trace = try ParityTrace.load(named: "uke_e.wav", in: "product-fixtures")
        var mutated = trace

        mutated.frames[2].tracker.smoothedCents! += 1e-5

        let comparator = ParityComparator()
        let result = comparator.compare(expected: trace, actual: mutated)
        #expect(!result.passed)
        #expect(result.firstDivergence?.fieldPath == "tracker.smoothedCents")
        #expect(result.firstDivergence?.frameIndex == 2)
    }

    @Test("Catches altered confidence exceeding budget")
    func alteredConfidenceFails() throws {
        let trace = try ParityTrace.load(named: "uke_e.wav", in: "product-fixtures")
        var mutated = trace

        // Budget is 1e-9. Incur a 1e-8 error.
        mutated.frames[2].detector.confidence! += 1e-8

        let comparator = ParityComparator()
        let result = comparator.compare(expected: trace, actual: mutated)
        #expect(!result.passed)
        #expect(result.firstDivergence?.fieldPath == "detector.confidence")
        #expect(result.firstDivergence?.frameIndex == 2)
    }

    @Test("Catches altered RMS exceeding compound budget")
    func alteredRMSFails() throws {
        let trace = try ParityTrace.load(named: "uke_e.wav", in: "product-fixtures")
        var mutated = trace

        // Compound budget: 1e-10 abs + 1e-7 rel. Incur a 1e-5 error.
        mutated.frames[2].detector.rms = (mutated.frames[2].detector.rms ?? 0.0) + 1e-5

        let comparator = ParityComparator()
        let result = comparator.compare(expected: trace, actual: mutated)
        #expect(!result.passed)
        #expect(result.firstDivergence?.fieldPath == "detector.rms")
        #expect(result.firstDivergence?.frameIndex == 2)
    }

    // MARK: - 5. Negative Controls: Discrete & Mask Defect Detection

    @Test("Catches flipped null mask on detector frequency")
    func flippedNullMaskDetectorFrequencyFails() throws {
        let trace = try ParityTrace.load(named: "uke_e.wav", in: "product-fixtures")

        // Case A: expected non-null, actual is null
        var mutatedA = trace
        mutatedA.frames[1].detector.frequency = nil

        let comparator = ParityComparator()
        let resultA = comparator.compare(expected: trace, actual: mutatedA)
        #expect(!resultA.passed)
        #expect(resultA.firstDivergence?.fieldPath == "detector.frequency")
        #expect(resultA.firstDivergence?.actual == "null")

        // Case B: expected null, actual is non-null
        let roomNoiseTrace = try ParityTrace.load(named: "room-noise-44100", in: "product-controlled-44100")
        var mutatedB = roomNoiseTrace
        #expect(roomNoiseTrace.frames[0].detector.frequency == nil)
        mutatedB.frames[0].detector.frequency = 440.0

        let resultB = comparator.compare(expected: roomNoiseTrace, actual: mutatedB)
        #expect(!resultB.passed)
        #expect(resultB.firstDivergence?.fieldPath == "detector.frequency")
        #expect(resultB.firstDivergence?.expected == "null")
    }

    @Test("Catches flipped null mask on tracker target")
    func flippedNullMaskTrackerTargetFails() throws {
        let trace = try ParityTrace.load(named: "uke_e.wav", in: "product-fixtures")

        // Frame 1 has a target (E4)
        var mutated = trace
        #expect(trace.frames[1].tracker.target != nil)
        mutated.frames[1].tracker.target = nil

        let comparator = ParityComparator()
        let result = comparator.compare(expected: trace, actual: mutated)
        #expect(!result.passed)
        #expect(result.firstDivergence?.fieldPath == "tracker.target")
        #expect(result.firstDivergence?.actual == "null")
    }

    @Test("Catches altered target note and index")
    func alteredTargetNoteAndIndexFails() throws {
        let trace = try ParityTrace.load(named: "uke_e.wav", in: "product-fixtures")
        let comparator = ParityComparator()

        // Alter target note
        var mutatedNote = trace
        mutatedNote.frames[1].tracker.target?.note = "A4"
        let resultNote = comparator.compare(expected: trace, actual: mutatedNote)
        #expect(!resultNote.passed)
        #expect(resultNote.firstDivergence?.fieldPath == "tracker.target.note")
        #expect(resultNote.firstDivergence?.expected == "E4")
        #expect(resultNote.firstDivergence?.actual == "A4")

        // Alter target index
        var mutatedIdx = trace
        mutatedIdx.frames[1].tracker.target?.index = 0
        let resultIdx = comparator.compare(expected: trace, actual: mutatedIdx)
        #expect(!resultIdx.passed)
        #expect(resultIdx.firstDivergence?.fieldPath == "tracker.target.index")
        #expect(resultIdx.firstDivergence?.expected == "2")
        #expect(resultIdx.firstDivergence?.actual == "0")
    }

    @Test("Catches altered inTune flag")
    func alteredInTuneFlagFails() throws {
        let trace = try ParityTrace.load(named: "vector-boundary-intune-5cents-within", in: "targeted")
        var mutated = trace

        // Find a frame where inTune is true
        guard let inTuneIndex = trace.frames.firstIndex(where: { $0.tracker.inTune == true }) else {
            Issue.record("Expected trace to have at least one inTune frame")
            return
        }

        mutated.frames[inTuneIndex].tracker.inTune = false

        let comparator = ParityComparator()
        let result = comparator.compare(expected: trace, actual: mutated)
        #expect(!result.passed)
        #expect(result.firstDivergence?.fieldPath == "tracker.inTune")
        #expect(result.firstDivergence?.frameIndex == inTuneIndex)
    }

    @Test("Catches altered confirmation state transitions")
    func alteredConfirmationStateFails() throws {
        let trace = try ParityTrace.load(named: "tuning_g.wav", in: "product-fixtures")
        var mutated = trace

        // Find confirmed frame
        guard let confIndex = trace.frames.firstIndex(where: { $0.confirmation.event == true }) else {
            Issue.record("Expected tuning_g.wav to contain confirmation events")
            return
        }

        mutated.frames[confIndex].confirmation.event = false

        let comparator = ParityComparator()
        let result = comparator.compare(expected: trace, actual: mutated)
        #expect(!result.passed)
        #expect(result.firstDivergence?.fieldPath == "confirmation.event")
        #expect(result.firstDivergence?.frameIndex == confIndex)
    }

    @Test("Catches altered publication slot")
    func alteredPublicationSlotFails() throws {
        let trace = try ParityTrace.load(named: "uke_e.wav", in: "product-fixtures")
        let comparator = ParityComparator()

        // Frame 4 publication action is 'published'
        #expect(trace.frames[4].publication.action == .published)

        var mutated = trace
        mutated.frames[4].publication.action = .held

        let result = comparator.compare(expected: trace, actual: mutated)
        #expect(!result.passed)
        #expect(result.firstDivergence?.fieldPath == "publication.action")
        #expect(result.firstDivergence?.expected == "published")
        #expect(result.firstDivergence?.actual == "held")
        #expect(result.firstDivergence?.frameIndex == 4)
    }

    @Test("Catches shifted sample index and timestamp")
    func shiftedTimestampAndSampleIndexFails() throws {
        let trace = try ParityTrace.load(named: "uke_e.wav", in: "product-fixtures")
        let comparator = ParityComparator()

        // Shift sample index
        var mutatedSample = trace
        mutatedSample.frames[1].sampleIndex += 1024
        let resultSample = comparator.compare(expected: trace, actual: mutatedSample)
        #expect(!resultSample.passed)
        #expect(resultSample.firstDivergence?.fieldPath == "sampleIndex")
        #expect(resultSample.firstDivergence?.frameIndex == 1)

        // Shift timeMs beyond budget (1e-6 ms)
        var mutatedTime = trace
        mutatedTime.frames[1].timeMs += 0.05
        let resultTime = comparator.compare(expected: trace, actual: mutatedTime)
        #expect(!resultTime.passed)
        #expect(resultTime.firstDivergence?.fieldPath == "timeMs")
        #expect(resultTime.firstDivergence?.frameIndex == 1)
    }

    @Test("Catches missing or extra frames")
    func frameCountMismatchFails() throws {
        let trace = try ParityTrace.load(named: "uke_e.wav", in: "product-fixtures")
        let comparator = ParityComparator()

        // Missing frame (truncated)
        var truncated = trace
        truncated.frames.removeLast()
        truncated.frameCount = truncated.frames.count

        let resultMissing = comparator.compare(expected: trace, actual: truncated)
        #expect(!resultMissing.passed)
        #expect(resultMissing.divergences.contains(where: { $0.fieldPath == "frames.count" || $0.fieldPath == "frame" }))

        // Extra frame
        var expanded = trace
        let extra = trace.frames.last!
        expanded.frames.append(extra)
        expanded.frameCount = expanded.frames.count

        let resultExtra = comparator.compare(expected: trace, actual: expanded)
        #expect(!resultExtra.passed)
        #expect(resultExtra.divergences.contains(where: { $0.fieldPath == "frames.count" || $0.fieldPath == "frame" }))
    }

    @Test("Catches non-finite numbers (NaN and Infinity)")
    func nonFiniteNumbersFails() throws {
        let trace = try ParityTrace.load(named: "uke_e.wav", in: "product-fixtures")
        let comparator = ParityComparator()

        // Injected NaN into detector.frequency
        var mutatedNaN = trace
        mutatedNaN.frames[2].detector.frequency = Double.nan
        let resultNaN = comparator.compare(expected: trace, actual: mutatedNaN)
        #expect(!resultNaN.passed)
        #expect(resultNaN.firstDivergence?.fieldPath == "detector.frequency")
        #expect(resultNaN.firstDivergence?.message.contains("Non-finite") == true)

        // Injected +Infinity into detector.rms
        var mutatedInf = trace
        mutatedInf.frames[2].detector.rms = Double.infinity
        let resultInf = comparator.compare(expected: trace, actual: mutatedInf)
        #expect(!resultInf.passed)
        #expect(resultInf.firstDivergence?.fieldPath == "detector.rms")
        #expect(resultInf.firstDivergence?.message.contains("Non-finite") == true)

        // Injected -Infinity into tracker.smoothedCents
        var mutatedNegInf = trace
        mutatedNegInf.frames[2].tracker.smoothedCents = -Double.infinity
        let resultNegInf = comparator.compare(expected: trace, actual: mutatedNegInf)
        #expect(!resultNegInf.passed)
        #expect(resultNegInf.firstDivergence?.fieldPath == "tracker.smoothedCents")
        #expect(resultNegInf.firstDivergence?.message.contains("Non-finite") == true)
    }

    @Test("Stub replay engine fails decisively against golden trace")
    func stubReplayEngineFailsDecisively() throws {
        let goldenTrace = try ParityTrace.load(named: "uke_e.wav", in: "product-fixtures")
        let stub = StubReplayEngine()

        // Replay arbitrary mock input through the stub engine
        let mockSamples = [Float](repeating: 0.0, count: goldenTrace.sampleCount)
        let actualTrace = try stub.replay(
            samples: mockSamples,
            sampleRate: goldenTrace.sampleRate,
            name: goldenTrace.name,
            category: goldenTrace.category
        )

        let comparator = ParityComparator()
        let result = comparator.compare(expected: goldenTrace, actual: actualTrace)

        #expect(!result.passed, "A stub replay engine must not pass comparison with a real golden trace")
        #expect(result.totalDifferences > 0)
        #expect(result.firstDivergence != nil)
        #expect(result.description.contains("FAILED"))
    }
}
