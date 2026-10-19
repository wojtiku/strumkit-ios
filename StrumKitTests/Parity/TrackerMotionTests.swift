// StrumKitTests/Parity/TrackerMotionTests.swift
import Foundation
import Testing
@testable import StrumKit

@Suite("Tracker Motion, Smoothing, Decay & Confirmation Tests")
struct TrackerMotionTests {

    let comparator = ParityComparator(
        budgets: .frozen,
        discreteRules: .frozen
    )

    // MARK: - 1. Step Response Tests (+40c to -40c, 3c, 8c, 12c, 15c)

    @Test("Step response +40c to -40c enforces slew rate limiting and converges")
    func stepResponseLargeSlewRate() {
        let tracker = FaithfulTracker()
        tracker.auto = false
        tracker.selected = 3 // A4 = 440 Hz

        // Acquire target at +40 cents
        let a4 = 440.0
        let freqPlus40 = a4 * pow(2.0, 40.0 / 1200.0)
        let freqMinus40 = a4 * pow(2.0, -40.0 / 1200.0)

        // Frame 0-1: acquisition
        _ = tracker.push(frequency: freqPlus40, confidence: 0.99, time: 0.0)
        let r1 = tracker.push(frequency: freqPlus40, confidence: 0.99, time: 20.0)
        #expect(r1 != nil)
        #expect(r1?.cents != nil)

        // Feed +40 cents for 100 ms to settle
        for t in stride(from: 40.0, through: 120.0, by: 20.0) {
            _ = tracker.push(frequency: freqPlus40, confidence: 0.99, time: t)
        }

        // Sudden jump to -40 cents at t = 140.0 (elapsed = 20 ms)
        // Max slew per 20 ms step is 0.75 * 20 = 15.0 cents
        let smoothedBefore = tracker.smoothed!
        let rStep = tracker.push(frequency: freqMinus40, confidence: 0.99, time: 140.0)
        #expect(rStep != nil)
        let smoothedAfter = rStep!.cents
        let change = abs(smoothedAfter - smoothedBefore)
        #expect(change <= 15.0 + 1e-9, "Change \(change) exceeded max slew limit of 15 cents")

        // Continue feeding -40 cents until convergence
        var latest: FaithfulReading? = nil
        for t in stride(from: 160.0, through: 1000.0, by: 20.0) {
            latest = tracker.push(frequency: freqMinus40, confidence: 0.99, time: t)
        }
        #expect(latest != nil)
        #expect(abs(latest!.cents - (-40.0)) < 0.1, "Failed to converge to -40c, got \(latest!.cents)")
    }

    @Test("Small step response: 3c, 8c, 12c, 15c behavior")
    func smallAndMediumStepResponses() {
        // 3 cents: small step within 2-12 cents
        do {
            let tracker = FaithfulTracker()
            tracker.auto = false
            tracker.selected = 3
            let a4 = 440.0

            // Settle at 0 cents
            for t in stride(from: 0.0, through: 300.0, by: 20.0) {
                _ = tracker.push(frequency: a4, confidence: 0.99, time: t)
            }
            #expect(abs(tracker.smoothed!) < 0.01)

            // Step to +3 cents
            let freq3 = a4 * pow(2.0, 3.0 / 1200.0)
            for t in stride(from: 320.0, through: 1000.0, by: 20.0) {
                _ = tracker.push(frequency: freq3, confidence: 0.99, time: t)
            }
            // 3c is <= 8c, so innovation responsiveUntil should remain -infinity
            #expect(tracker.responsiveUntil == -.infinity)
            #expect(abs(tracker.smoothed! - 3.0) < 0.1)
        }

        // 8 cents: boundary case (not > 8 cents)
        do {
            let tracker = FaithfulTracker()
            tracker.auto = false
            tracker.selected = 3
            let a4 = 440.0

            for t in stride(from: 0.0, through: 300.0, by: 20.0) {
                _ = tracker.push(frequency: a4, confidence: 0.99, time: t)
            }

            // Step to exactly +8 cents
            let freq8 = a4 * pow(2.0, 8.0 / 1200.0)
            for t in stride(from: 320.0, through: 500.0, by: 20.0) {
                _ = tracker.push(frequency: freq8, confidence: 0.99, time: t)
            }
            // Exactly 8 cents does NOT exceed 8 cents, innovation path not triggered
            #expect(tracker.responsiveUntil == -.infinity)
        }

        // 12 cents: > 8 cents triggers innovation path after 64 ms
        do {
            let tracker = FaithfulTracker()
            tracker.auto = false
            tracker.selected = 3
            let a4 = 440.0

            for t in stride(from: 0.0, through: 300.0, by: 20.0) {
                _ = tracker.push(frequency: a4, confidence: 0.99, time: t)
            }

            let freq12 = a4 * pow(2.0, 12.0 / 1200.0)
            // 4 frames at 20 ms interval = 80 ms > 64 ms duration
            for t in stride(from: 320.0, through: 420.0, by: 20.0) {
                _ = tracker.push(frequency: freq12, confidence: 0.99, time: t)
            }
            #expect(tracker.responsiveUntil > 400.0, "12-cent step should activate fast responsive window")
        }

        // 15 cents: > 8 cents triggers fast responsive window
        do {
            let tracker = FaithfulTracker()
            tracker.auto = false
            tracker.selected = 3
            let a4 = 440.0

            for t in stride(from: 0.0, through: 300.0, by: 20.0) {
                _ = tracker.push(frequency: a4, confidence: 0.99, time: t)
            }

            let freq15 = a4 * pow(2.0, 15.0 / 1200.0)
            for t in stride(from: 320.0, through: 420.0, by: 20.0) {
                _ = tracker.push(frequency: freq15, confidence: 0.99, time: t)
            }
            #expect(tracker.responsiveUntil > 400.0, "15-cent step should activate fast responsive window")
        }
    }

    // MARK: - 2. Peg Adjustment Response (Innovation Path & Fast Window)

    @Test("Peg adjustment triggers innovation path and rearms on near-target plateau")
    func pegAdjustmentAndRearm() {
        let tracker = FaithfulTracker()
        tracker.auto = false
        tracker.selected = 3 // A4 = 440 Hz
        let a4 = 440.0

        // Start at -30 cents (peg turned down)
        let freqMinus30 = a4 * pow(2.0, -30.0 / 1200.0)
        for t in stride(from: 0.0, through: 300.0, by: 20.0) {
            _ = tracker.push(frequency: freqMinus30, confidence: 0.99, time: t)
        }
        #expect(abs(tracker.smoothed! - (-30.0)) < 0.5)

        // Turn peg to +30 cents (60 cents swing)
        let freqPlus30 = a4 * pow(2.0, 30.0 / 1200.0)
        // Feed for 80 ms (> 64 ms)
        for t in stride(from: 320.0, through: 400.0, by: 20.0) {
            _ = tracker.push(frequency: freqPlus30, confidence: 0.99, time: t)
        }
        #expect(tracker.responsiveUntil > 400.0, "Peg adjustment should trigger responsive window")

        // Now move back towards target (0 cents) and hold steady
        for t in stride(from: 420.0, through: 1000.0, by: 20.0) {
            _ = tracker.push(frequency: a4, confidence: 0.99, time: t)
        }

        // Settled within 5c of target and within 2c of smoothed for 64 ms rearms
        #expect(abs(tracker.smoothed!) <= 5.0)
        #expect(tracker.responsiveUntil == -.infinity, "Rearm should clear responsive window")
    }

    // MARK: - 3. Decay Damping Tests (Pluck Decay vs Sustained Tone)

    @Test("Decay damping activates on pluck exponential decay (>10% per 64ms)")
    func decayDampingActivationOnPluck() {
        let tracker = FaithfulTracker()
        tracker.auto = false
        tracker.selected = 3 // A4 = 440 Hz
        let a4 = 440.0

        // Frame 0-1: acquisition at high RMS
        _ = tracker.push(frequency: a4, confidence: 0.99, rms: 0.10, time: 0.0)
        _ = tracker.push(frequency: a4, confidence: 0.99, rms: 0.08, time: 20.0)

        // Exponential decay: drops by ~15% every 20 ms (> 10% per 64 ms)
        var rms = 0.08
        var activated = false
        for t in stride(from: 40.0, through: 120.0, by: 20.0) {
            rms *= 0.85
            _ = tracker.push(frequency: a4, confidence: 0.99, rms: rms, time: t)
            if tracker.dampedDecay {
                activated = true
            }
        }
        #expect(activated || tracker.observedDecay, "Decay damping or observed decay should activate on simulated pluck")
    }

    @Test("Sustained tone with constant RMS does not activate decay damping")
    func sustainedToneNoDecayDamping() {
        let tracker = FaithfulTracker()
        tracker.auto = false
        tracker.selected = 3
        let a4 = 440.0

        for t in stride(from: 0.0, through: 300.0, by: 20.0) {
            _ = tracker.push(frequency: a4, confidence: 0.99, rms: 0.08, time: t)
            #expect(!tracker.dampedDecay, "Constant RMS should not trigger dampedDecay at t=\(t)")
        }
        #expect(!tracker.observedDecay)
    }

    @Test("Sudden RMS jump resets decay damping")
    func decayDampingResetOnNewPluck() {
        let tracker = FaithfulTracker()
        tracker.auto = false
        tracker.selected = 3
        let a4 = 440.0

        // Establish decay: acquisition at t=20, decay envelope spans 20ms to 100ms (80ms >= 64ms)
        _ = tracker.push(frequency: a4, confidence: 0.99, rms: 0.10, time: 0.0)
        _ = tracker.push(frequency: a4, confidence: 0.99, rms: 0.08, time: 20.0)
        _ = tracker.push(frequency: a4, confidence: 0.99, rms: 0.06, time: 40.0)
        _ = tracker.push(frequency: a4, confidence: 0.99, rms: 0.04, time: 60.0)
        _ = tracker.push(frequency: a4, confidence: 0.99, rms: 0.02, time: 80.0)
        _ = tracker.push(frequency: a4, confidence: 0.99, rms: 0.01, time: 100.0)
        #expect(tracker.observedDecay, "Decay damping should be active before new pluck")

        // New pluck: RMS jumps above decay level (0.08)
        _ = tracker.push(frequency: a4, confidence: 0.99, rms: 0.12, time: 120.0)
        #expect(!tracker.dampedDecay, "RMS increase above decay level must clear dampedDecay")
        #expect(!tracker.observedDecay, "RMS increase above decay level must clear observedDecay")
        #expect(tracker.decayMotionUntil == 120.0 + 300.0)
    }

    // MARK: - 4. Measured Confirmation Boundary (380 ms vs 420 ms)

    @Test("Exact 400 ms confirmation boundary: 380 ms does not confirm, 420 ms confirms")
    func confirmationBoundary380Vs420() {
        let a4 = 440.0

        // 380 ms test: held at 0c from t=20 to t=380 (span = 360 ms settled)
        // Acquisition takes 2 frames (t=0, t=20), settledSince = 20.
        // At t=380, time - settledSince = 360 ms < 400 ms -> inTune is false!
        do {
            let tracker = FaithfulTracker()
            tracker.auto = false
            tracker.selected = 3
            var maxInTune = false

            for t in stride(from: 0.0, through: 380.0, by: 20.0) {
                let reading = tracker.push(frequency: a4, confidence: 0.99, time: t)
                if reading?.inTune == true {
                    maxInTune = true
                }
            }
            #expect(!maxInTune, "380 ms hold must not achieve inTune confirmation")

            // Dropout at t = 400 ms: settledSince cleared
            let dropout = tracker.push(frequency: nil, confidence: nil, time: 400.0)
            #expect(dropout == nil)
            #expect(tracker.settledSince == nil, "Dropout must clear settledSince when < 400ms")
        }

        // 420 ms test: held at 0c from t=0 to t=440
        // Settled from t=20, at t=420: time - settledSince = 400 ms >= 400 ms -> inTune is true!
        do {
            let tracker = FaithfulTracker()
            tracker.auto = false
            tracker.selected = 3
            var reachedInTuneAt: Double? = nil

            for t in stride(from: 0.0, through: 500.0, by: 20.0) {
                let reading = tracker.push(frequency: a4, confidence: 0.99, time: t)
                if reading?.inTune == true && reachedInTuneAt == nil {
                    reachedInTuneAt = t
                }
            }
            #expect(reachedInTuneAt != nil, "420 ms hold must achieve inTune confirmation")
            #expect(reachedInTuneAt! >= 420.0, "Must not confirm before 400 ms settled elapsed")
        }
    }

    // MARK: - 5. Golden Trace Parity Tests

    @Test("Golden Trace Parity: vector-boundary-confirmation-380ms")
    func goldenTraceConfirmation380ms() throws {
        let trace = try ParityTrace.load(named: "vector-boundary-confirmation-380ms", in: "targeted")
        let tracker = FaithfulTracker()
        tracker.tuning = "standard"
        tracker.auto = true
        let feedback = TuningFeedback()

        let result = comparator.compareTrackerReplay(trace: trace, tracker: tracker, feedback: feedback)
        #expect(result.passed, "Divergences: \(result.description)")
    }

    @Test("Golden Trace Parity: vector-boundary-confirmation-420ms")
    func goldenTraceConfirmation420ms() throws {
        let trace = try ParityTrace.load(named: "vector-boundary-confirmation-420ms", in: "targeted")
        let tracker = FaithfulTracker()
        tracker.tuning = "standard"
        tracker.auto = true
        let feedback = TuningFeedback()

        let result = comparator.compareTrackerReplay(trace: trace, tracker: tracker, feedback: feedback)
        #expect(result.passed, "Divergences: \(result.description)")
    }

    @Test("Golden Trace Parity: vector-boundary-intune-5cents-within and sharp")
    func goldenTraceIntuneBoundaries() throws {
        // Within 5 cents (+4.99 cents): in-tune confirmed
        let traceWithin = try ParityTrace.load(named: "vector-boundary-intune-5cents-within", in: "targeted")
        let trackerWithin = FaithfulTracker()
        let resultWithin = comparator.compareTrackerReplay(trace: traceWithin, tracker: trackerWithin, feedback: TuningFeedback())
        #expect(resultWithin.passed, "Within 5c divergences: \(resultWithin.description)")

        // Sharp 5 cents (+5.01 cents): in-tune rejected
        let traceSharp = try ParityTrace.load(named: "vector-boundary-intune-5cents-sharp", in: "targeted")
        let trackerSharp = FaithfulTracker()
        let resultSharp = comparator.compareTrackerReplay(trace: traceSharp, tracker: trackerSharp, feedback: TuningFeedback())
        #expect(resultSharp.passed, "Sharp 5c divergences: \(resultSharp.description)")
    }

    @Test("Golden Trace Parity: vector-step-3cents, 8cents, 12cents, 15cents")
    func goldenTraceSteps() throws {
        for cents in [3, 8, 12, 15] {
            let trace = try ParityTrace.load(named: "vector-step-\(cents)cents", in: "targeted")
            let tracker = FaithfulTracker()
            let result = comparator.compareTrackerReplay(trace: trace, tracker: tracker, feedback: TuningFeedback())
            #expect(result.passed, "Step \(cents)c divergences: \(result.description)")
        }
    }

    @Test("Golden Trace Parity: vector-peg-adjustment-48000")
    func goldenTracePegAdjustment() throws {
        let trace = try ParityTrace.load(named: "vector-peg-adjustment-48000", in: "targeted")
        let tracker = FaithfulTracker()
        let result = comparator.compareTrackerReplay(trace: trace, tracker: tracker, feedback: TuningFeedback())
        #expect(result.passed, "Peg adjustment divergences: \(result.description)")
    }

    @Test("Golden Trace Parity: vector-quiet-onset-bootstrap")
    func goldenTraceQuietOnsetBootstrap() throws {
        let trace = try ParityTrace.load(named: "vector-quiet-onset-bootstrap", in: "targeted")
        let tracker = FaithfulTracker()
        let result = comparator.compareTrackerReplay(trace: trace, tracker: tracker, feedback: TuningFeedback())
        #expect(result.passed, "Quiet onset bootstrap divergences: \(result.description)")
    }

    @Test("Golden Trace Parity: vector-continuous-sweep-40cents")
    func goldenTraceContinuousSweep() throws {
        let trace = try ParityTrace.load(named: "vector-continuous-sweep-40cents", in: "targeted")
        let tracker = FaithfulTracker()
        let result = comparator.compareTrackerReplay(trace: trace, tracker: tracker, feedback: TuningFeedback())
        #expect(result.passed, "Continuous sweep divergences: \(result.description)")
    }

    @Test("Golden Trace Parity: steady-G4-44100 product controlled case")
    func goldenTraceSteadyG4() throws {
        let trace = try ParityTrace.load(named: "steady-G4-44100", in: "product-controlled-44100")
        let tracker = FaithfulTracker()
        let result = comparator.compareTrackerReplay(trace: trace, tracker: tracker, feedback: TuningFeedback())
        #expect(result.passed, "Steady G4 divergences: \(result.description)")
    }

    @Test("Golden Trace Parity: all-4-with-noise.wav fixture")
    func goldenTraceAll4WithNoise() throws {
        let trace = try ParityTrace.load(at: "traces/product-fixtures/all-4-with-noise.wav.json")
        let tracker = FaithfulTracker()
        let result = comparator.compareTrackerReplay(trace: trace, tracker: tracker, feedback: TuningFeedback())
        #expect(result.passed, "all-4-with-noise divergences: \(result.description)")
    }
}
