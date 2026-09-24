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

    @Test("History prunes points older than 7 seconds")
    func testHistoryPruning() {
        let tracker = PitchTracker()
        let config = TunerConfig(instrument: .guitar, tuningId: "standard", mode: .chromatic)
        let targets = Presets.guitar[0].midi.enumerated().map { index, midi in
            StringTarget(note: PitchMath.midiNoteName(midi), midi: midi, frequency: PitchMath.midiFrequency(midi), number: 6 - index)
        }

        let sampleResult = PitchResult(
            frequency: 440.0,
            closestNote: MusicalNote(midiNoteNumber: 69),
            centsDeviation: 0.0,
            confidence: 0.9,
            amplitudeRMS: 0.05,
            isSignalPresent: true
        )

        _ = tracker.process(pitchResult: sampleResult, at: 1.0, config: config, targets: targets)
        _ = tracker.process(pitchResult: sampleResult, at: 5.0, config: config, targets: targets)
        _ = tracker.process(pitchResult: sampleResult, at: 10.0, config: config, targets: targets)

        // At t = 10.0s, point at t = 1.0s is 9 seconds old (> 7s), so it should be pruned
        #expect(!tracker.history.contains(where: { $0.at == 1.0 }))
        #expect(tracker.history.contains(where: { $0.at == 5.0 }))
        #expect(tracker.history.contains(where: { $0.at == 10.0 }))
    }
}
