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

        // 4. Extended silence past readingHoldDuration (e.g. at 2.10s, > 0.85s later) expires cleanly
        let expiredReading = tracker.process(pitchResult: emptyResult, at: 2.10, config: config, targets: targets)
        #expect(expiredReading == nil)
        #expect(tracker.continuityPrior == nil, "Continuity prior should be cleared after expiry")
        #expect(tracker.feedbackState == .ready)
    }
}
