import Testing
import Foundation
@testable import StrumKit

@Suite("Pitch Tracker State Machine Tests")
struct TrackerTests {

    @Test("Tracker detects guitar open strings in auto mode")
    func testAutoStringDetection() {
        let tracker = PitchTracker()
        let config = TunerConfig(instrument: .guitar, tuningId: "standard", mode: .auto)
        let targets = Presets.guitar[0].midi.enumerated().map { index, midi in
            StringTarget(note: PitchMath.midiNoteName(midi), midi: midi, frequency: PitchMath.midiFrequency(midi), number: 6 - index)
        }

        // Test frequency near Guitar Low E (82.41 Hz) -> String 6
        let resultE2 = PitchResult(
            frequency: 82.5,
            closestNote: MusicalNote(midiNoteNumber: 40),
            centsDeviation: 1.8,
            confidence: 0.9,
            amplitudeRMS: 0.05,
            isSignalPresent: true,
            evidence: .measured
        )

        // Feed 3 consecutive observations (40ms total) to confirm target acquisition
        _ = tracker.process(pitchResult: resultE2, at: 0.00, config: config, targets: targets)
        _ = tracker.process(pitchResult: resultE2, at: 0.02, config: config, targets: targets)
        let reading = tracker.process(pitchResult: resultE2, at: 0.04, config: config, targets: targets)

        #expect(reading != nil)
        #expect(reading?.target.number == 6)
        #expect(reading?.target.note == "E2")
        #expect(reading?.inTune == true)
    }

    @Test("Guided mode advances only after 1 second continuous in-tune hold")
    func testGuidedModeProgression() {
        let tracker = PitchTracker()
        let config = TunerConfig(instrument: .guitar, tuningId: "standard", mode: .guided, guided: true)
        let targets = Presets.guitar[0].midi.enumerated().map { index, midi in
            StringTarget(note: PitchMath.midiNoteName(midi), midi: midi, frequency: PitchMath.midiFrequency(midi), number: 6 - index)
        }

        tracker.reset(targetCount: targets.count)
        #expect(tracker.guidedTargetIndex == 0)
        #expect(tracker.guidedProgress[0] == false)

        // Perfect pitch for String 6 (target 0, E2)
        let inTuneResult = PitchResult(
            frequency: 82.41,
            closestNote: MusicalNote(midiNoteNumber: 40),
            centsDeviation: 0.0,
            confidence: 0.95,
            amplitudeRMS: 0.05,
            isSignalPresent: true,
            evidence: .measured
        )

        // Stream 20ms hops for 0.5 seconds: hold in progress, not yet completed
        for t in stride(from: 10.0, through: 10.5, by: 0.02) {
            _ = tracker.process(pitchResult: inTuneResult, at: t, config: config, targets: targets)
        }
        #expect(tracker.guidedProgress[0] == false)
        #expect(tracker.guidedTargetIndex == 0)

        // Stream up to 1.15 seconds (> 1.0s continuous hold required)
        for t in stride(from: 10.52, through: 11.15, by: 0.02) {
            _ = tracker.process(pitchResult: inTuneResult, at: t, config: config, targets: targets)
        }
        #expect(tracker.guidedProgress[0] == true)
        #expect(tracker.guidedTargetIndex == 1)
    }

    @Test("Tracker sustains detection across momentary drops and expires cleanly after hold duration")
    func testSustainHoldAndPriorRetention() {
        let tracker = PitchTracker()
        let config = TunerConfig(instrument: .guitar, tuningId: "standard", mode: .auto)
        let targets = Presets.guitar[0].midi.enumerated().map { index, midi in
            StringTarget(note: PitchMath.midiNoteName(midi), midi: midi, frequency: PitchMath.midiFrequency(midi), number: 6 - index)
        }

        let resultE2 = PitchResult(
            frequency: 82.41,
            closestNote: MusicalNote(midiNoteNumber: 40),
            centsDeviation: 0.0,
            confidence: 0.9,
            amplitudeRMS: 0.03,
            isSignalPresent: true,
            evidence: .measured
        )

        // 1. Initial 3 frames to acquire String 6 (E2)
        _ = tracker.process(pitchResult: resultE2, at: 1.00, config: config, targets: targets)
        _ = tracker.process(pitchResult: resultE2, at: 1.02, config: config, targets: targets)
        let freshReading = tracker.process(pitchResult: resultE2, at: 1.04, config: config, targets: targets)

        #expect(freshReading != nil)
        #expect(freshReading?.freshness == .fresh)
        #expect(freshReading?.note == "E2")
        #expect(tracker.continuityPrior != nil)

        let emptyResult = PitchResult(
            frequency: 0,
            closestNote: MusicalNote(midiNoteNumber: 69),
            centsDeviation: 0,
            confidence: 0,
            amplitudeRMS: 0.0003,
            isSignalPresent: false,
            evidence: .measured
        )

        // Two more confirming frames, so the times below are "2 frames after the
        // last measurement" rather than "1 frame after acquisition".
        _ = tracker.process(pitchResult: resultE2, at: 1.06, config: config, targets: targets)
        let lastFresh = tracker.process(pitchResult: resultE2, at: 1.08, config: config, targets: targets)
        #expect(lastFresh?.freshness == .fresh, "test setup: 1.08 s should be a measured reading")

        // 2. A momentary silent/unvoiced frame (phase dip or quiet decay) at 1.10s.
        //
        //    **What this used to assert.** That one silent frame 20 ms after a
        //    measured one puts `.held` on the display: the display follows the
        //    estimator's very next verdict.
        //
        //    **Why that was wrong.** It is the jitter. Every 2-frame excursion
        //    costs two visible transitions — in and out — and on the real
        //    four-strum recording it accounted for 25 of the 73 non-`none` display
        //    runs that lasted two frames or fewer: 34 % of all runs, median 107 ms.
        //    Nothing distinguishes "this frame is bad" from "the note stopped", and
        //    the display was betting on the first interpretation every time.
        //
        //    **What it asserts now.** A short dropout is *held through*: the
        //    display keeps the last measured reading, verbatim, and says so by not
        //    advancing `lastFreshAt`. The evidence is still counted — one YIN
        //    failure, and the streak is what decides whether the display may act on
        //    it.
        let heldThrough = tracker.process(pitchResult: emptyResult, at: 1.10, config: config, targets: targets)
        #expect(heldThrough != nil)
        #expect(heldThrough?.freshness == .fresh,
                "One silent frame is a held-through dropout, not a weakened display: freshness is \(heldThrough?.freshness.rawValue ?? "no reading")")
        #expect(heldThrough?.lastFreshAt == 1.08,
                "A held-through frame must not claim to be a measurement; `lastFreshAt` is the honest signal and it must stay at the last frame YIN actually produced")
        #expect(heldThrough?.note == "E2")
        #expect(tracker.continuityPrior != nil, "Continuity prior should be retained during sustain hold")
        #expect(tracker.consecutiveYinFailures == 1)
        #expect(tracker.shouldHoldThroughDropout)

        // 3. A *sustained* dropout does engage the hold. The gate is a streak, not
        //    a freeze: three consecutive failures are the display's evidence that
        //    this is a decay rather than a bad frame, and only then does it weaken.
        let secondFailure = tracker.process(pitchResult: emptyResult, at: 1.12, config: config, targets: targets)
        #expect(secondFailure?.freshness == .fresh, "Two silent frames are still inside the streak")
        let weakened = tracker.process(pitchResult: emptyResult, at: 1.14, config: config, targets: targets)
        #expect(weakened?.freshness == .held,
                "The third consecutive YIN failure is the display's evidence, and it must weaken: freshness is \(weakened?.freshness.rawValue ?? "no reading")")
        #expect(weakened?.lastFreshAt == 1.08, "A weakened reading repeats the last measurement and must still date from it")
        #expect(weakened?.note == "E2")
        #expect(!tracker.shouldHoldThroughDropout, "test setup: three failures exhaust the streak")

        // 4. Coming back is the prompt direction: two consecutive successes, not
        //    three. The asymmetry is deliberate — giving up is the failure a player
        //    notices, so that is the sticky one.
        let firstSuccess = tracker.process(pitchResult: resultE2, at: 1.16, config: config, targets: targets)
        #expect(firstSuccess?.freshness == .held, "One confirmed frame is not yet enough to strengthen back to `fresh`")
        let refreshedReading = tracker.process(pitchResult: resultE2, at: 1.18, config: config, targets: targets)
        #expect(refreshedReading != nil)
        #expect(refreshedReading?.freshness == .fresh)
        #expect(refreshedReading?.lastFreshAt == 1.18)
        #expect(refreshedReading?.note == "E2")

        // 5. Extended silence past readingHoldDuration (at 2.20s, 1.02s after the
        //    1.18s measurement) expires cleanly. The hold is a duration, and the
        //    continuation streak is not allowed to reach it: a needle that sits
        //    live over silence for as long as the audio keeps delivering frames
        //    carrying no pitch is worse than a stale one.
        let expiredReading = tracker.process(pitchResult: emptyResult, at: 2.20, config: config, targets: targets)
        #expect(expiredReading == nil)
        #expect(tracker.continuityPrior == nil, "Continuity prior should be cleared after expiry")
        #expect(tracker.feedbackState == .ready)
    }

    @Test("Tracker decouples display hold (1.0s) and prior expiry (0.85s)")
    func testDisplayHoldAndPriorExpiryDecoupled() {
        let tracker = PitchTracker()
        let config = TunerConfig(instrument: .guitar, tuningId: "standard", mode: .manual, selectedString: 0)
        let targets = [
            StringTarget(note: "A4", midi: 69, frequency: 440.0, number: 1)
        ]

        let inTuneA4 = PitchResult(
            frequency: 440.0,
            closestNote: MusicalNote(midiNoteNumber: 69),
            centsDeviation: 0.0,
            confidence: 0.95,
            amplitudeRMS: 0.05,
            isSignalPresent: true,
            evidence: .measured
        )

        // Acquire in-tune manual A4 reading at t=10.0
        let freshReading = tracker.process(pitchResult: inTuneA4, at: 10.0, config: config, targets: targets)
        #expect(freshReading != nil)
        #expect(freshReading?.freshness == .fresh)
        #expect(freshReading?.lastFreshAt == 10.0)
        #expect(freshReading?.inTune == true)
        #expect(tracker.continuityPrior != nil)

        let lostResult = PitchResult(
            frequency: 0,
            closestNote: MusicalNote(midiNoteNumber: 69),
            centsDeviation: 0,
            confidence: 0,
            amplitudeRMS: 0.0001,
            isSignalPresent: false,
            evidence: .measured
        )

        // At t=10.10 (elapsed 0.10s <= 0.85s, <= 1.0s): retain display and prior.
        //
        // **What this used to assert.** `freshness == .held` — one silent frame is
        // enough to put a weakened state on the display.
        //
        // **Why that was wrong.** It is the flicker the continuation hysteresis
        // exists to remove: a display that follows the estimator's next verdict
        // blinks on every dropout. On the real four-strum recording that produced
        // 25 of 73 display runs lasting two frames or fewer.
        //
        // **What it asserts now.** A one-frame dropout is held *through* — the last
        // measured reading stays on screen with its own `lastFreshAt` — and the
        // prior is retained. The decoupling this test exists to prove is now
        // sharper, not weaker: at 10.90 s the prior has expired while the display
        // is still live and still asserting the last confirmed in-tune state.
        let reading10_10 = tracker.process(pitchResult: lostResult, at: 10.10, config: config, targets: targets)
        #expect(reading10_10 != nil)
        #expect(reading10_10?.freshness == .fresh,
                "One silent frame is a held-through dropout; freshness is \(reading10_10?.freshness.rawValue ?? "no reading")")
        #expect(reading10_10?.lastFreshAt == 10.0)
        #expect(reading10_10?.inTune == true, "Last confirmed in-tune visual state must be preserved during hold")
        #expect(tracker.continuityPrior != nil, "Continuity prior must be retained within 0.85s")

        // At t=10.90 (elapsed 0.90s > 0.85s, <= 1.0s): prior gone, display alive.
        let reading10_90 = tracker.process(pitchResult: lostResult, at: 10.90, config: config, targets: targets)
        #expect(reading10_90 != nil)
        #expect(reading10_90?.freshness == .fresh,
                "Two silent frames are still inside the continuation streak; freshness is \(reading10_90?.freshness.rawValue ?? "no reading")")
        #expect(reading10_90?.lastFreshAt == 10.0)
        #expect(reading10_90?.inTune == true)
        #expect(tracker.continuityPrior == nil, "Continuity prior must expire after 0.85s")

        // The third failure is where the display earns the right to weaken. Asserting
        // it here keeps the test covering the display hold at all: without it, the
        // `held` state would have no assertion anywhere in this file for this path.
        let reading10_92 = tracker.process(pitchResult: lostResult, at: 10.92, config: config, targets: targets)
        #expect(reading10_92?.freshness == .held,
                "A third consecutive YIN failure must weaken the display to a hold; freshness is \(reading10_92?.freshness.rawValue ?? "no reading")")
        #expect(reading10_92?.lastFreshAt == 10.0)
        #expect(reading10_92?.inTune == true)

        // At t=11.01 (elapsed 1.01s > 1.0s): return no active reading
        let reading11_01 = tracker.process(pitchResult: lostResult, at: 11.01, config: config, targets: targets)
        #expect(reading11_01 == nil, "Display hold must expire after 1.0s")
        #expect(tracker.continuityPrior == nil)
    }

    @Test("Guided tuning requires continuous fresh in-tune evidence and rejects held readings")
    func testGuidedProgressionRejectsHeldEvidence() {
        let tracker = PitchTracker()
        let config = TunerConfig(instrument: .guitar, tuningId: "standard", mode: .guided, guided: true)
        let targets = Presets.guitar[0].midi.enumerated().map { index, midi in
            StringTarget(note: PitchMath.midiNoteName(midi), midi: midi, frequency: PitchMath.midiFrequency(midi), number: 6 - index)
        }

        tracker.reset(targetCount: targets.count)
        #expect(tracker.guidedTargetIndex == 0)
        #expect(tracker.guidedProgress[0] == false)

        let inTuneResult = PitchResult(
            frequency: 82.41,
            closestNote: MusicalNote(midiNoteNumber: 40),
            centsDeviation: 0.0,
            confidence: 0.95,
            amplitudeRMS: 0.05,
            isSignalPresent: true,
            evidence: .measured
        )

        let lostResult = PitchResult(
            frequency: 0,
            closestNote: MusicalNote(midiNoteNumber: 40),
            centsDeviation: 0.0,
            confidence: 0.0,
            amplitudeRMS: 0.0001,
            isSignalPresent: false,
            evidence: .measured
        )

        // 1. Stream 0.8 seconds of fresh in-tune frames (10.0 to 10.84, confirming at 10.04)
        for t in stride(from: 10.0, through: 10.84, by: 0.02) {
            let r = tracker.process(pitchResult: inTuneResult, at: t, config: config, targets: targets)
            if t >= 10.04 {
                #expect(r?.freshness == .fresh)
            }
        }
        #expect(tracker.guidedProgress[0] == false, "0.8s of fresh hold is not enough to complete 1.0s requirement")

        // 1. Stream 0.3 seconds of lost signal (10.86 to 11.20). The first two
        //    frames are held *through* — the display is not yet entitled to move —
        //    and the third exhausts `continuationYinFailuresToWeaken` and weakens
        //    it. The time the display weakens is asserted, not a per-frame label:
        //    a per-frame label is exactly what the gate makes untrue, and a test
        //    that pins one is a test of the defect.
        var weakenedAt: TimeInterval?
        var claimedFresh: [TimeInterval] = []
        for t in stride(from: 10.86, through: 11.20, by: 0.02) {
            let r = tracker.process(pitchResult: lostResult, at: t, config: config, targets: targets)
            if r?.freshness == .held, weakenedAt == nil { weakenedAt = t }
            // The honest per-frame predicate is `lastFreshAt == at`, not
            // `freshness == .fresh`: a held-through frame is `.fresh` without
            // having been measured on it. No frame in this block may claim to be
            // a measurement, and that is the property guided progression rests on.
            if let r, r.lastFreshAt == r.at { claimedFresh.append(t) }
        }

        #expect(weakenedAt.map { abs($0 - 10.90) < 0.005 } == true,
                "The display weakened at \(weakenedAt.map { String(format: "%.2f", $0) } ?? "never")s; it must hold through a two-frame dropout and weaken on the third")
        #expect(claimedFresh.isEmpty,
                "Frames \(claimedFresh.map { String(format: "%.2f", $0) }) over a lost-signal block reported themselves as freshly measured; held-through frames must keep the old `lastFreshAt` so a consumer can tell a measurement from a repeat")

        // Even though 10.0 to 11.20 is 1.2s total, the lost frames must NOT advance guided tuning!
        #expect(tracker.guidedProgress[0] == false, "Held and held-through readings must NEVER count toward guided completion")
        #expect(tracker.guidedTargetIndex == 0)
    }

    @Test("New valid pluck during hold immediately replaces historical display")
    func testImmediateReplacementOnNewPluckDuringHold() {
        let tracker = PitchTracker()
        let config = TunerConfig(instrument: .guitar, tuningId: "standard", mode: .auto)
        let targets = Presets.guitar[0].midi.enumerated().map { index, midi in
            StringTarget(note: PitchMath.midiNoteName(midi), midi: midi, frequency: PitchMath.midiFrequency(midi), number: 6 - index)
        }

        // 1. Acquire String 6 (E2, 82.41 Hz)
        let resultE2 = PitchResult(
            frequency: 82.41,
            closestNote: MusicalNote(midiNoteNumber: 40),
            centsDeviation: 0.0,
            confidence: 0.9,
            amplitudeRMS: 0.04,
            isSignalPresent: true,
            evidence: .measured
        )
        _ = tracker.process(pitchResult: resultE2, at: 10.00, config: config, targets: targets)
        _ = tracker.process(pitchResult: resultE2, at: 10.02, config: config, targets: targets)
        let readingE2 = tracker.process(pitchResult: resultE2, at: 10.04, config: config, targets: targets)
        #expect(readingE2?.note == "E2")
        #expect(readingE2?.freshness == .fresh)

        // 2. Drop into a dropout at t=10.30.
        //
        //    **What this used to assert.** That the single silent frame at 10.30
        //    reads `.held`.
        //    **Why that was wrong.** Same reason as everywhere else in this file:
        //    a one-frame dropout is not evidence that the note stopped, and letting
        //    it change the display is the flicker. It is also the *weakest* version
        //    of this test's real claim, which is that a new pluck is acquired
        //    promptly out of a dropout — the frame's label is a side observation.
        //    **What it asserts now.** The dropout is held through (the display keeps
        //    E2 with its own `lastFreshAt`), and a sustained dropout does reach a
        //    genuine hold, so step 3 really is a replacement *out of a hold*.
        let emptyResult = PitchResult(frequency: 0, closestNote: MusicalNote(midiNoteNumber: 40), centsDeviation: 0, confidence: 0, amplitudeRMS: 0.0001, isSignalPresent: false, evidence: .measured)
        let through = tracker.process(pitchResult: emptyResult, at: 10.30, config: config, targets: targets)
        #expect(through?.freshness == .fresh,
                "One silent frame is a held-through dropout; freshness is \(through?.freshness.rawValue ?? "no reading")")
        #expect(through?.note == "E2")
        #expect(through?.lastFreshAt == 10.04, "A held-through frame must not claim to be a measurement")

        _ = tracker.process(pitchResult: emptyResult, at: 10.32, config: config, targets: targets)
        let held = tracker.process(pitchResult: emptyResult, at: 10.34, config: config, targets: targets)
        #expect(held?.freshness == .held,
                "Three consecutive failures must weaken the display to a hold; freshness is \(held?.freshness.rawValue ?? "no reading")")
        #expect(held?.note == "E2")

        // 3. New pluck on String 5 (A2, 110.0 Hz) at t=10.40 with onset RMS
        let resultA2 = PitchResult(
            frequency: 110.0,
            closestNote: MusicalNote(midiNoteNumber: 45),
            centsDeviation: 0.0,
            confidence: 0.95,
            amplitudeRMS: 0.08,
            isSignalPresent: true,
            evidence: .measured
        )
        // Onset requires 2 acquire readings
        _ = tracker.process(pitchResult: resultA2, at: 10.40, config: config, targets: targets)
        let replaced = tracker.process(pitchResult: resultA2, at: 10.42, config: config, targets: targets)

        #expect(replaced != nil)
        #expect(replaced?.freshness == .fresh)
        #expect(replaced?.note == "A2")
        #expect(replaced?.lastFreshAt == 10.42)
    }

    // MARK: - Task 6 Responsiveness & Step Response Tests

    @Test("Step response (+40 to -40 cents) converges to <= 5 cents error within 150ms at 20ms and 43ms cadences")
    func testStepResponsePositiveToNegative40Cents() {
        let config = TunerConfig(instrument: .guitar, tuningId: "standard", mode: .auto)
        let targets = Presets.guitar[0].midi.enumerated().map { index, midi in
            StringTarget(note: PitchMath.midiNoteName(midi), midi: midi, frequency: PitchMath.midiFrequency(midi), number: 6 - index)
        }

        let refFreq = 329.63 // High E (E4)
        let freqPlus40 = refFreq * pow(2.0, 40.0 / 1200.0)
        let freqMinus40 = refFreq * pow(2.0, -40.0 / 1200.0)

        // 1. Evaluate at 20ms cadence
        do {
            let tracker = PitchTracker()
            // Settle tracker on E4 at +40 cents
            for t in stride(from: 0.0, through: 0.50, by: 0.02) {
                let r = PitchResult(frequency: freqPlus40, closestNote: MusicalNote(midiNoteNumber: 64), centsDeviation: 40.0, confidence: 0.95, amplitudeRMS: 0.05, isSignalPresent: true, evidence: .measured)
                _ = tracker.process(pitchResult: r, at: t, config: config, targets: targets)
            }

            // Step to -40 cents at t = 0.52 (first changed estimate)
            var lastReading: TunerReading? = nil
            for t in stride(from: 0.52, through: 0.52 + 0.150, by: 0.02) {
                let r = PitchResult(frequency: freqMinus40, closestNote: MusicalNote(midiNoteNumber: 64), centsDeviation: -40.0, confidence: 0.95, amplitudeRMS: 0.05, isSignalPresent: true, evidence: .measured)
                lastReading = tracker.process(pitchResult: r, at: t, config: config, targets: targets)
            }

            let finalDisplay = lastReading?.displayCents ?? 0.0
            let error = abs(finalDisplay - (-40.0))
            #expect(error <= 5.0, "20ms cadence: display error within 150ms should be <= 5 cents, got \(error)")
        }

        // 2. Evaluate at 43ms cadence
        do {
            let tracker = PitchTracker()
            for t in stride(from: 0.0, through: 0.50, by: 0.043) {
                let r = PitchResult(frequency: freqPlus40, closestNote: MusicalNote(midiNoteNumber: 64), centsDeviation: 40.0, confidence: 0.95, amplitudeRMS: 0.05, isSignalPresent: true, evidence: .measured)
                _ = tracker.process(pitchResult: r, at: t, config: config, targets: targets)
            }

            var lastReading: TunerReading? = nil
            for t in stride(from: 0.543, through: 0.543 + 0.150, by: 0.043) {
                let r = PitchResult(frequency: freqMinus40, closestNote: MusicalNote(midiNoteNumber: 64), centsDeviation: -40.0, confidence: 0.95, amplitudeRMS: 0.05, isSignalPresent: true, evidence: .measured)
                lastReading = tracker.process(pitchResult: r, at: t, config: config, targets: targets)
            }

            let finalDisplay = lastReading?.displayCents ?? 0.0
            let error = abs(finalDisplay - (-40.0))
            #expect(error <= 5.0, "43ms cadence: display error within 150ms should be <= 5 cents, got \(error)")
        }
    }

    @Test("Stationary signal near in-tune maintains stable in-tune state without flutter or false target changes")
    func testStationarySignalJitterAndInTuneStability() {
        let tracker = PitchTracker()
        let config = TunerConfig(instrument: .guitar, tuningId: "standard", mode: .auto)
        let targets = Presets.guitar[0].midi.enumerated().map { index, midi in
            StringTarget(note: PitchMath.midiNoteName(midi), midi: midi, frequency: PitchMath.midiFrequency(midi), number: 6 - index)
        }

        let baseFreq = 110.0 // A2 (String 5)
        var readings: [TunerReading] = []

        // Stream 50 frames (1 second at 20ms) with small +/- 1.5 cent fluctuation
        for (i, t) in stride(from: 0.0, through: 1.0, by: 0.02).enumerated() {
            let jitterCents = 1.5 * sin(Double(i) * 0.5)
            let freq = baseFreq * pow(2.0, jitterCents / 1200.0)
            let result = PitchResult(
                frequency: freq,
                closestNote: MusicalNote(midiNoteNumber: 45),
                centsDeviation: jitterCents,
                confidence: 0.95,
                amplitudeRMS: 0.05,
                isSignalPresent: true,
                evidence: .measured
            )
            if let reading = tracker.process(pitchResult: result, at: t, config: config, targets: targets) {
                readings.append(reading)
            }
        }

        // All confirmed readings after initial acquisition (t >= 0.04) must remain A2 and inTune
        let confirmed = readings.filter { $0.at >= 0.04 }
        #expect(!confirmed.isEmpty)
        for r in confirmed {
            #expect(r.target.note == "A2", "Target must stay locked to A2")
            #expect(r.inTune == true, "In-tune hysteresis must prevent flutter on small jitter")
            #expect(r.freshness == .fresh)
        }

        // Display cents jitter between consecutive frames must remain smooth (<= 1.5 cents delta)
        for i in 1..<confirmed.count {
            let delta = abs(confirmed[i].displayCents - confirmed[i-1].displayCents)
            #expect(delta <= 1.5, "Frame-to-frame display jitter should remain smooth, got \(delta)")
        }
    }

    @Test("Chromatic mode identifies targets by MIDI note and immediately resets display cents on note change")
    func testChromaticTargetIdentityAndDisplayReset() {
        let tracker = PitchTracker()
        let config = TunerConfig(instrument: .ukulele, tuningId: "high-g", mode: .chromatic)
        let targets: [StringTarget] = []

        // 1. Play C4 (261.63 Hz, MIDI 60) with +30 cents deviation
        let c4Freq = 261.63 * pow(2.0, 30.0 / 1200.0)
        let c4Result = PitchResult(
            frequency: c4Freq,
            closestNote: MusicalNote(midiNoteNumber: 60),
            centsDeviation: 30.0,
            confidence: 0.95,
            amplitudeRMS: 0.05,
            isSignalPresent: true,
            evidence: .measured
        )

        // Elapsed confirmation: 0.00, 0.02, 0.04 (span = 0.040s)
        _ = tracker.process(pitchResult: c4Result, at: 0.00, config: config, targets: targets)
        _ = tracker.process(pitchResult: c4Result, at: 0.02, config: config, targets: targets)
        let c4Reading = tracker.process(pitchResult: c4Result, at: 0.04, config: config, targets: targets)

        #expect(c4Reading != nil)
        #expect(c4Reading?.note == "C4")
        #expect(c4Reading?.cents ?? 0 > 25.0)

        // 2. Play E4 (329.63 Hz, MIDI 64) with -25 cents deviation on an onset
        let e4Freq = 329.63 * pow(2.0, -25.0 / 1200.0)
        let e4Result = PitchResult(
            frequency: e4Freq,
            closestNote: MusicalNote(midiNoteNumber: 64),
            centsDeviation: -25.0,
            confidence: 0.95,
            amplitudeRMS: 0.20, // onset RMS (4x c4Result)
            isSignalPresent: true,
            evidence: .measured
        )

        // Onset requires 20ms span (0.10 to 0.12)
        _ = tracker.process(pitchResult: e4Result, at: 0.10, config: config, targets: targets)
        let e4Reading = tracker.process(pitchResult: e4Result, at: 0.12, config: config, targets: targets)

        #expect(e4Reading != nil)
        #expect(e4Reading?.note == "E4", "Chromatic tracker must switch note to E4")
        #expect(e4Reading?.freshness == .fresh)
        // Display cents must reset directly to E4's clamped cents (-25.0), NOT dragged from C4's +30 cents
        let displayError = abs((e4Reading?.displayCents ?? 0.0) - (-25.0))
        #expect(displayError < 1.0, "Display cents should reset immediately on target change, got error \(displayError)")
        #expect(e4Reading?.inTune == false, "Hysteresis must be reset on target change")
    }

    // MARK: - Recovery Trust Boundary

    @Test("A Sustained estimate may not assert in tune, but a Measured one still does")
    func testSustainedFramesCannotAssertInTune() {
        let tracker = PitchTracker()
        let config = TunerConfig(instrument: .guitar, tuningId: "standard", mode: .auto)
        let targets = Presets.guitar[0].midi.enumerated().map { index, midi in
            StringTarget(note: PitchMath.midiNoteName(midi), midi: midi, frequency: PitchMath.midiFrequency(midi), number: 6 - index)
        }

        // Dead-on E2 confirmed by YIN must report in tune.
        let confirmed = PitchResult(
            frequency: 82.41,
            closestNote: MusicalNote(midiNoteNumber: 40),
            centsDeviation: 0.0,
            confidence: 0.95,
            amplitudeRMS: 0.05,
            isSignalPresent: true,
            evidence: .measured
        )
        var confirmedReading: TunerReading?
        for t in stride(from: 10.0, through: 10.5, by: 0.02) {
            confirmedReading = tracker.process(pitchResult: confirmed, at: t, config: config, targets: targets)
        }
        #expect(confirmedReading?.inTune == true, "A YIN-confirmed in-tune frame must report inTune")

        let sustained = PitchResult(
            frequency: 82.41,
            closestNote: MusicalNote(midiNoteNumber: 40),
            centsDeviation: 0.0,
            confidence: 0.20,
            amplitudeRMS: 0.001,
            isSignalPresent: true,
            evidence: .sustained
        )

        // The identical frequency arriving as a Sustained estimate must not.
        //
        // **What this used to assert.** That ONE recovered frame at 10.52 is
        // published flagged as recovered, with `inTune == false` — that the trust
        // boundary is enforced by *labelling* the frame.
        //
        // **Why that was wrong.** Not because the boundary is wrong — it is
        // absolute, and `inTuneMayBeAsserted` reads the grade the frame carries
        // rather than the published flag, so the verdict was never assertable. But
        // a single recovered frame is not evidence that YIN has failed either, and
        // letting it change the display is the same flicker as a silent frame. The
        // assertion was also arithmetically impossible to keep: `AudioTestHelpers`
        // (and `TunerViewModel`) derive the display state from exactly those two
        // facts, so "stayed `fresh`" and "flagged as recovered" on the same reading
        // is a contradiction.
        //
        // **What it asserts now.** The boundary is enforced by *suppression*: a
        // lone Sustained frame never reaches the screen at all, and once the streak
        // justifies showing it, the frame that does reach the screen asserts
        // nothing. Both halves are asserted, because the first is what makes the
        // second a real statement about the display and not a grade check.
        let heldThrough = tracker.process(pitchResult: sustained, at: 10.52, config: config, targets: targets)
        #expect(heldThrough?.evidence == .measured,
                "One Sustained frame must not reach the display; the display is still showing the last YIN-confirmed reading")
        #expect(heldThrough?.freshness == .fresh)
        #expect(heldThrough?.inTune == true,
                "A held-through frame is still the last YIN-confirmed measurement, so its in-tune verdict is honest and must survive")
        #expect(tracker.consecutiveYinFailures == 1)

        _ = tracker.process(pitchResult: sustained, at: 10.54, config: config, targets: targets)
        let sustainedReading = tracker.process(pitchResult: sustained, at: 10.56, config: config, targets: targets)
        #expect(sustainedReading?.evidence == .sustained,
                "A third consecutive recovery-sourced frame must reach the display; its grade is \(String(describing: sustainedReading?.evidence))")
        #expect(sustainedReading?.inTune == false,
                "Sustained evidence must not assert in tune, even at zero cents error")

        // Suppressing the verdict must not corrupt the hysteresis state machine.
        // Two confirmed frames, not one: strengthening back to a YIN reading is the
        // prompt direction and takes two consecutive successes.
        let firstBack = tracker.process(pitchResult: confirmed, at: 10.58, config: config, targets: targets)
        #expect(firstBack?.inTune == false,
                "One confirmed frame is not enough to hand the display back; test setup for the next assertion")
        let stillConfirmed = tracker.process(pitchResult: confirmed, at: 10.60, config: config, targets: targets)
        #expect(stillConfirmed?.evidence == .measured)
        #expect(stillConfirmed?.inTune == true,
                "In-tune hysteresis must survive a Sustained frame without resetting")
    }

    @Test("Sustained frames never complete a guided string")
    func testSustainedFramesCannotCompleteGuidedString() {
        let tracker = PitchTracker()
        let config = TunerConfig(instrument: .guitar, tuningId: "standard", mode: .guided, guided: true)
        let targets = Presets.guitar[0].midi.enumerated().map { index, midi in
            StringTarget(note: PitchMath.midiNoteName(midi), midi: midi, frequency: PitchMath.midiFrequency(midi), number: 6 - index)
        }
        tracker.reset(targetCount: targets.count)

        let sustained = PitchResult(
            frequency: 82.41,
            closestNote: MusicalNote(midiNoteNumber: 40),
            centsDeviation: 0.0,
            confidence: 0.30,
            amplitudeRMS: 0.001,
            isSignalPresent: true,
            evidence: .sustained
        )
        for t in stride(from: 10.0, through: 12.5, by: 0.02) {
            _ = tracker.process(pitchResult: sustained, at: t, config: config, targets: targets)
        }
        #expect(tracker.guidedProgress[0] == false,
                "2.5s of Sustained in-tune frames must not complete a guided string")
    }

    // MARK: - Guided Progress Preservation

    @Test("Judgement-only config changes preserve guided progress; instrument changes do not")
    func testGuidedProgressPreservedOnlyForJudgementChanges() {
        let targets = Presets.guitar[0].midi.enumerated().map { index, midi in
            StringTarget(note: PitchMath.midiNoteName(midi), midi: midi, frequency: PitchMath.midiFrequency(midi), number: 6 - index)
        }
        let config = TunerConfig(instrument: .guitar, tuningId: "standard", mode: .guided, guided: true)

        // Build a real guided session by actually completing two strings, rather
        // than writing state the production code path never produces.
        let tracker = PitchTracker()
        tracker.reset(targetCount: targets.count)

        var clock: TimeInterval = 10.0
        for stringIndex in 0..<2 {
            let frequency = targets[stringIndex].frequency
            let inTune = PitchResult(
                frequency: frequency,
                closestNote: MusicalNote(midiNoteNumber: targets[stringIndex].midi),
                centsDeviation: 0.0,
                confidence: 0.95,
                amplitudeRMS: 0.05,
                isSignalPresent: true,
                evidence: .measured
            )
            // 1.3s of continuous in-tune evidence clears the 1.0s guided hold.
            for step in 0..<65 {
                _ = tracker.process(pitchResult: inTune, at: clock + Double(step) * 0.02, config: config, targets: targets)
            }
            clock += 1.3
        }

        #expect(tracker.guidedProgress.prefix(2) == [true, true],
                "test setup: two strings should be complete, got \(tracker.guidedProgress)")
        #expect(tracker.guidedTargetIndex == 2)

        let progressBefore = tracker.guidedProgress
        let indexBefore = tracker.guidedTargetIndex

        // A mode / precision / string-lock change must keep them.
        tracker.reset(targetCount: targets.count, preservingGuidedProgress: true)
        #expect(tracker.guidedProgress == progressBefore,
                "A judgement-only config change must not discard completed strings")
        #expect(tracker.guidedTargetIndex == indexBefore)

        // An instrument or preset change must discard them: different strings.
        tracker.reset(targetCount: targets.count, preservingGuidedProgress: false)
        #expect(tracker.guidedProgress == [false, false, false, false, false, false],
                "A string-set change must discard completed strings")
        #expect(tracker.guidedTargetIndex == 0)

        // A target-count mismatch is a string-set change even if preservation was
        // asked for: progress from a six-string session cannot apply to four strings.
        tracker.reset(targetCount: 4, preservingGuidedProgress: true)
        #expect(tracker.guidedProgress == [false, false, false, false],
                "Progress must not carry across a different number of strings")
    }

    @Test("Candidate confirmation resets after gap greater than candidate gap limit (> 250ms)")
    func testCandidateConfirmationResetsAfterLargeGap() {        let tracker = PitchTracker()
        let config = TunerConfig(instrument: .guitar, tuningId: "standard", mode: .auto)
        let targets = Presets.guitar[0].midi.enumerated().map { index, midi in
            StringTarget(note: PitchMath.midiNoteName(midi), midi: midi, frequency: PitchMath.midiFrequency(midi), number: 6 - index)
        }

        let resultE2 = PitchResult(frequency: 82.41, closestNote: MusicalNote(midiNoteNumber: 40), centsDeviation: 0.0, confidence: 0.9, amplitudeRMS: 0.03, isSignalPresent: true, evidence: .measured)
        let empty = PitchResult(frequency: 0, closestNote: MusicalNote(midiNoteNumber: 40), centsDeviation: 0, confidence: 0, amplitudeRMS: 0.0001, isSignalPresent: false, evidence: .measured)

        // Observation 1 at t = 0.00
        let r1 = tracker.process(pitchResult: resultE2, at: 0.00, config: config, targets: targets)
        #expect(r1 == nil)

        // Gap of 300ms (> 250ms limit)
        _ = tracker.process(pitchResult: empty, at: 0.30, config: config, targets: targets)

        // Observation at t = 0.31: candidate must have reset, so this is observation 1 again!
        let r2 = tracker.process(pitchResult: resultE2, at: 0.31, config: config, targets: targets)
        #expect(r2 == nil, "Reading must not be confirmed because previous candidate observation expired")

        // Observation 2 at t = 0.35 (span = 40ms from 0.31): confirms now!
        let r3 = tracker.process(pitchResult: resultE2, at: 0.35, config: config, targets: targets)
        #expect(r3 != nil)
        #expect(r3?.freshness == .fresh)
        #expect(r3?.note == "E2")
    }

    // MARK: - Continuation hysteresis

    /// A YIN-confirmed reading of E2, repeated. The starting point for every
    /// test below, so that each one varies exactly one thing.
    private static func yinE2(rms: Double = 0.05) -> PitchResult {
        PitchResult(
            frequency: 82.41,
            closestNote: MusicalNote(midiNoteNumber: 40),
            centsDeviation: 0.0,
            confidence: 0.9,
            amplitudeRMS: rms,
            isSignalPresent: true,
            evidence: .measured
        )
    }

    /// The identical reading arriving as Sustained evidence: a success for the
    /// pipeline, a failure for YIN.
    private static func sustainedE2() -> PitchResult {
        PitchResult(
            frequency: 82.41,
            closestNote: MusicalNote(midiNoteNumber: 40),
            centsDeviation: 0.0,
            confidence: 0.30,
            amplitudeRMS: 0.002,
            isSignalPresent: true,
            evidence: .sustained
        )
    }

    /// Nothing to hear, at a level that clears the level gate so the pipeline
    /// reports "here, but no pitch" rather than "nothing here".
    private static func silent() -> PitchResult {
        PitchResult(
            frequency: 0,
            closestNote: MusicalNote(midiNoteNumber: 40),
            centsDeviation: 0,
            confidence: 0,
            amplitudeRMS: 0.0003,
            isSignalPresent: false,
            evidence: .measured
        )
    }

    private static func guitarTargets() -> [StringTarget] {
        Presets.guitar[0].midi.enumerated().map { index, midi in
            StringTarget(note: PitchMath.midiNoteName(midi), midi: midi,
                          frequency: PitchMath.midiFrequency(midi), number: 6 - index)
        }
    }

    /// Number of times the state a player can see changed, over a trace of
    /// readings. A `nil` reading is the needle going dark, which is a change too.
    private static func visibleTransitions(_ readings: [TunerReading?]) -> Int {
        var transitions = 0
        var previous: String?
        for reading in readings {
            let state: String
            if let reading {
                state = reading.evidence == .sustained
                    ? "sustained"
                    : (reading.freshness == .fresh ? "fresh" : "held")
            } else {
                state = "none"
            }
            if state != previous { transitions += 1 }
            previous = state
        }
        return max(0, transitions - 1)  // the first frame is acquisition
    }

    @Test("An alternating YIN dropout does not move the display at all")
    func testAlternatingYinDropoutDoesNotFlicker() {
        let tracker = PitchTracker()
        let config = TunerConfig(instrument: .guitar, tuningId: "standard", mode: .auto)
        let targets = Self.guitarTargets()
        let cadence = 0.02

        // Acquire E2 and settle the display on a YIN-confirmed reading.
        var readings: [TunerReading?] = []
        for step in 0..<5 {
            readings.append(tracker.process(pitchResult: Self.yinE2(),
                                           at: 10.0 + Double(step) * cadence,
                                           config: config, targets: targets))
        }
        #expect(readings.last??.freshness == .fresh, "test setup: the display should be on a YIN reading")

        // 30 more frames with the estimator gone on every third one — the cadence
        // of a real decay tail, where YIN keeps losing lock and the recovery path
        // keeps handing back a reading.
        for step in 5..<35 {
            let frame = step % 3 == 0 ? Self.silent() : Self.yinE2()
            readings.append(tracker.process(pitchResult: frame,
                                           at: 10.0 + Double(step) * cadence,
                                           config: config, targets: targets))
        }

        let transitions = Self.visibleTransitions(readings)
        let trace = readings.map { reading -> String in
            guard let reading else { return "none" }
            if reading.freshness != .fresh { return "held" }
            return reading.evidence == .sustained ? "sustained" : "fresh"
        }.joined(separator: " ")
        #expect(transitions <= 1,
                "A dropout on every third frame produced \(transitions) visible transitions; the estimator never went three frames without a pitch, so the display never earned the right to change. Trace: \(trace)")
    }

    @Test("A new pluck on another string is still acquired promptly")
    func testNewPluckOnAnotherStringIsStillPrompt() {
        let tracker = PitchTracker()
        let config = TunerConfig(instrument: .guitar, tuningId: "standard", mode: .auto)
        let targets = Self.guitarTargets()
        let cadence = 0.02

        for step in 0..<5 {
            _ = tracker.process(pitchResult: Self.yinE2(), at: 10.0 + Double(step) * cadence,
                                 config: config, targets: targets)
        }

        // A2 on string 5: 500 cents from E2, so nothing about the string prior
        // can carry it. Acquisition, not continuation, has to do this work, and
        // the onset is what buys the shorter evidence span.
        let a2 = PitchResult(
            frequency: 110.0,
            closestNote: MusicalNote(midiNoteNumber: 45),
            centsDeviation: 0.0,
            confidence: 0.95,
            amplitudeRMS: 0.08,
            isSignalPresent: true,
            evidence: .measured
        )
        _ = tracker.process(pitchResult: a2, at: 10.10, config: config, targets: targets)
        let replaced = tracker.process(pitchResult: a2, at: 10.12, config: config, targets: targets)

        #expect(replaced?.note == "A2",
                "A 500-cent move to another string must be acquired, not held")
        #expect(replaced?.freshness == .fresh)
        #expect(replaced?.lastFreshAt == 10.12)

        // And the bound: the continuation hysteresis must not have cost it a
        // frame. Two frames is the onset requirement the tracker has always had,
        // and this change must not move it to three.
        let latencyMs = ((replaced?.at ?? 10.10) - 10.10) * 1000
        #expect(latencyMs <= 45,
                "The new string was acquired \(latencyMs) ms after the pluck; the onset requirement is 2 frames = 40 ms, and continuation hysteresis must not add to it")
    }

    @Test("A long dropout still ends a genuine loss: the display expires and the candidate goes with it")
    func testLongDropoutStillExpiresTheDisplay() {
        let tracker = PitchTracker()
        let config = TunerConfig(instrument: .guitar, tuningId: "standard", mode: .auto)
        let targets = Self.guitarTargets()
        let cadence = 0.02
        let lastFreshAt = 10.08   // the last of the five acquisition frames below

        for step in 0..<5 {
            _ = tracker.process(pitchResult: Self.yinE2(), at: 10.0 + Double(step) * cadence,
                                 config: config, targets: targets)
        }

        // A transient dropout: inside the hold, inside the continuation streak, and
        // inside the candidate gap. Nothing here may be thrown away.
        let insideHold = tracker.process(pitchResult: Self.silent(), at: 10.10,
                                         config: config, targets: targets)
        #expect(insideHold != nil, "test setup: 20 ms of silence is inside the 1.0 s hold")
        #expect(tracker.shouldHoldThroughDropout,
                "test setup: one silent frame is a transient dropout, not a loss")

        // Now keep going, past the hold and past the streak. The hysteresis delays
        // the display by at most `continuationYinFailuresToWeaken` frames; it must
        // not be able to reach the duration, or the needle would sit live over
        // silence for as long as the audio kept delivering frames carrying no
        // pitch.
        var expiredAt: TimeInterval?
        for step in 6..<80 {
            let at = 10.0 + Double(step) * cadence
            if tracker.process(pitchResult: Self.silent(), at: at,
                               config: config, targets: targets) == nil {
                expiredAt = at
                break
            }
        }

        #expect(expiredAt != nil, "The display never went dark over 1.5 s of silence")
        #expect((expiredAt ?? 99) <= lastFreshAt + PitchTracker.readingHoldDuration
                    + Double(PitchTracker.continuationYinFailuresToWeaken + 1) * cadence,
                "The display expired at \(expiredAt ?? 0)s, later than the 1.0s hold plus the continuation streak past it")
        #expect(!tracker.shouldHoldThroughDropout,
                "test setup: a sustained dropout must exhaust the continuation streak")

        // The same has to be true of the candidate, or the note would come back on
        // one frame of evidence after a silence long enough that it may not have
        // been the same note. `maxCandidateGap` is that bound: short gaps
        // individually do not trip it, and the accumulated silence does.
        let firstBack = tracker.process(pitchResult: Self.yinE2(), at: (expiredAt ?? 12) + 0.02,
                                        config: config, targets: targets)
        #expect(firstBack == nil,
                "One YIN frame after a \(String(format: "%.2f", (expiredAt ?? 12) - lastFreshAt))s dropout published a reading; the candidate must be gone, so this is a new acquisition needing 40 ms of evidence")
        #expect(tracker.process(pitchResult: Self.yinE2(), at: (expiredAt ?? 12) + 0.06,
                                config: config, targets: targets)?.freshness == .fresh,
                "The note should be re-acquired once 40 ms of evidence exists")
    }

    @Test("A Sustained reading is a failure for YIN, not a weaker success")
    func testSustainedFrameCountsAsYinFailure() {
        let tracker = PitchTracker()
        let config = TunerConfig(instrument: .guitar, tuningId: "standard", mode: .auto)
        let targets = Self.guitarTargets()
        let cadence = 0.02

        for step in 0..<5 {
            _ = tracker.process(pitchResult: Self.yinE2(), at: 10.0 + Double(step) * cadence,
                                 config: config, targets: targets)
        }
        #expect(tracker.consecutiveYinSuccesses == 5)
        #expect(tracker.consecutiveYinFailures == 0)

        // One Sustained frame: signal present, so the pipeline succeeded, but the
        // pitch came from the spectral scorer, so YIN did not produce it.
        let sustained = tracker.process(pitchResult: Self.sustainedE2(), at: 10.10,
                                        config: config, targets: targets)
        #expect(sustained != nil, "a Sustained reading is still a reading")
        #expect(sustained?.freshness == .fresh)
        #expect(tracker.consecutiveYinFailures == 1)
        #expect(tracker.consecutiveYinSuccesses == 0)
        #expect(tracker.shouldHoldThroughDropout)
    }
}

