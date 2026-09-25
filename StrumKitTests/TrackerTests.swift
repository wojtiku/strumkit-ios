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
            isSignalPresent: true
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
            isSignalPresent: true
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
            isSignalPresent: true
        )

        // 1. Initial 3 frames to acquire String 6 (E2)
        _ = tracker.process(pitchResult: resultE2, at: 1.00, config: config, targets: targets)
        _ = tracker.process(pitchResult: resultE2, at: 1.02, config: config, targets: targets)
        let freshReading = tracker.process(pitchResult: resultE2, at: 1.04, config: config, targets: targets)

        #expect(freshReading != nil)
        #expect(freshReading?.freshness == .fresh)
        #expect(freshReading?.note == "E2")
        #expect(tracker.continuityPrior != nil)

        // 2. Momentary silent/unvoiced frame (phase dip or quiet decay) at 1.10s (60ms later)
        let emptyResult = PitchResult(
            frequency: 0,
            closestNote: MusicalNote(midiNoteNumber: 69),
            centsDeviation: 0,
            confidence: 0,
            amplitudeRMS: 0.0003,
            isSignalPresent: false
        )
        let heldReading = tracker.process(pitchResult: emptyResult, at: 1.10, config: config, targets: targets)

        #expect(heldReading != nil)
        #expect(heldReading?.freshness == .held)
        #expect(heldReading?.note == "E2")
        #expect(tracker.continuityPrior != nil, "Continuity prior should be retained during sustain hold")

        // 3. A single continuing frame at 1.14s immediately refreshes without needing 3 new confirmations
        let refreshedReading = tracker.process(pitchResult: resultE2, at: 1.14, config: config, targets: targets)
        #expect(refreshedReading != nil)
        #expect(refreshedReading?.freshness == .fresh)
        #expect(refreshedReading?.note == "E2")

        // 4. Extended silence past readingHoldDuration (e.g. at 2.20s, > 1.0s after 1.14s) expires cleanly
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
            isSignalPresent: true
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
            isSignalPresent: false
        )

        // At t=10.10 (elapsed 0.10s <= 0.85s, <= 1.0s): retain display and prior
        let reading10_10 = tracker.process(pitchResult: lostResult, at: 10.10, config: config, targets: targets)
        #expect(reading10_10 != nil)
        #expect(reading10_10?.freshness == .held)
        #expect(reading10_10?.lastFreshAt == 10.0)
        #expect(reading10_10?.inTune == true, "Last confirmed in-tune visual state must be preserved during hold")
        #expect(tracker.continuityPrior != nil, "Continuity prior must be retained within 0.85s")

        // At t=10.90 (elapsed 0.90s > 0.85s, <= 1.0s): retain display but expire prior
        let reading10_90 = tracker.process(pitchResult: lostResult, at: 10.90, config: config, targets: targets)
        #expect(reading10_90 != nil)
        #expect(reading10_90?.freshness == .held)
        #expect(reading10_90?.lastFreshAt == 10.0)
        #expect(reading10_90?.inTune == true)
        #expect(tracker.continuityPrior == nil, "Continuity prior must expire after 0.85s")

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
            isSignalPresent: true
        )

        let lostResult = PitchResult(
            frequency: 0,
            closestNote: MusicalNote(midiNoteNumber: 40),
            centsDeviation: 0.0,
            confidence: 0.0,
            amplitudeRMS: 0.0001,
            isSignalPresent: false
        )

        // 1. Stream 0.8 seconds of fresh in-tune frames (10.0 to 10.84, confirming at 10.04)
        for t in stride(from: 10.0, through: 10.84, by: 0.02) {
            let r = tracker.process(pitchResult: inTuneResult, at: t, config: config, targets: targets)
            if t >= 10.04 {
                #expect(r?.freshness == .fresh)
            }
        }
        #expect(tracker.guidedProgress[0] == false, "0.8s of fresh hold is not enough to complete 1.0s requirement")

        // 2. Stream 0.3 seconds of lost signal (10.86 to 11.20), producing held readings
        for t in stride(from: 10.86, through: 11.20, by: 0.02) {
            let r = tracker.process(pitchResult: lostResult, at: t, config: config, targets: targets)
            #expect(r?.freshness == .held)
        }

        // Even though 10.0 to 11.20 is 1.2s total, the 0.3s held frames must NOT advance guided tuning!
        #expect(tracker.guidedProgress[0] == false, "Held readings must NEVER count toward guided completion")
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
            isSignalPresent: true
        )
        _ = tracker.process(pitchResult: resultE2, at: 10.00, config: config, targets: targets)
        _ = tracker.process(pitchResult: resultE2, at: 10.02, config: config, targets: targets)
        let readingE2 = tracker.process(pitchResult: resultE2, at: 10.04, config: config, targets: targets)
        #expect(readingE2?.note == "E2")
        #expect(readingE2?.freshness == .fresh)

        // 2. Drop into hold at t=10.30
        let emptyResult = PitchResult(frequency: 0, closestNote: MusicalNote(midiNoteNumber: 40), centsDeviation: 0, confidence: 0, amplitudeRMS: 0.0001, isSignalPresent: false)
        let held = tracker.process(pitchResult: emptyResult, at: 10.30, config: config, targets: targets)
        #expect(held?.freshness == .held)
        #expect(held?.note == "E2")

        // 3. New pluck on String 5 (A2, 110.0 Hz) at t=10.40 with onset RMS
        let resultA2 = PitchResult(
            frequency: 110.0,
            closestNote: MusicalNote(midiNoteNumber: 45),
            centsDeviation: 0.0,
            confidence: 0.95,
            amplitudeRMS: 0.08,
            isSignalPresent: true
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
                let r = PitchResult(frequency: freqPlus40, closestNote: MusicalNote(midiNoteNumber: 64), centsDeviation: 40.0, confidence: 0.95, amplitudeRMS: 0.05, isSignalPresent: true)
                _ = tracker.process(pitchResult: r, at: t, config: config, targets: targets)
            }

            // Step to -40 cents at t = 0.52 (first changed estimate)
            var lastReading: TunerReading? = nil
            for t in stride(from: 0.52, through: 0.52 + 0.150, by: 0.02) {
                let r = PitchResult(frequency: freqMinus40, closestNote: MusicalNote(midiNoteNumber: 64), centsDeviation: -40.0, confidence: 0.95, amplitudeRMS: 0.05, isSignalPresent: true)
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
                let r = PitchResult(frequency: freqPlus40, closestNote: MusicalNote(midiNoteNumber: 64), centsDeviation: 40.0, confidence: 0.95, amplitudeRMS: 0.05, isSignalPresent: true)
                _ = tracker.process(pitchResult: r, at: t, config: config, targets: targets)
            }

            var lastReading: TunerReading? = nil
            for t in stride(from: 0.543, through: 0.543 + 0.150, by: 0.043) {
                let r = PitchResult(frequency: freqMinus40, closestNote: MusicalNote(midiNoteNumber: 64), centsDeviation: -40.0, confidence: 0.95, amplitudeRMS: 0.05, isSignalPresent: true)
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
                isSignalPresent: true
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
            isSignalPresent: true
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
            isSignalPresent: true
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

    @Test("Candidate confirmation resets after gap greater than candidate gap limit (> 250ms)")
    func testCandidateConfirmationResetsAfterLargeGap() {
        let tracker = PitchTracker()
        let config = TunerConfig(instrument: .guitar, tuningId: "standard", mode: .auto)
        let targets = Presets.guitar[0].midi.enumerated().map { index, midi in
            StringTarget(note: PitchMath.midiNoteName(midi), midi: midi, frequency: PitchMath.midiFrequency(midi), number: 6 - index)
        }

        let resultE2 = PitchResult(frequency: 82.41, closestNote: MusicalNote(midiNoteNumber: 40), centsDeviation: 0.0, confidence: 0.9, amplitudeRMS: 0.03, isSignalPresent: true)
        let empty = PitchResult(frequency: 0, closestNote: MusicalNote(midiNoteNumber: 40), centsDeviation: 0, confidence: 0, amplitudeRMS: 0.0001, isSignalPresent: false)

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
}

