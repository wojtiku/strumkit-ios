import Testing
import Foundation
@testable import StrumKit

@Suite("Recorded Real Audio Fixture Replay Tests (recorded.test.ts)")
struct RecordedAudioTests {

    @Test("replays licensed real ukulele sustains with acceptance count >= 10")
    func testUkuleleSustainsReplay() {
        let ukeFiles = ["uke_a", "uke_c", "uke_e", "uke_g"]
        let config = TunerConfig(instrument: .ukulele, tuningId: "high-g", mode: .chromatic)

        for name in ukeFiles {
            guard let wav = AudioTestHelpers.loadWav(name: name) else {
                Issue.record("Failed to load WAV fixture: \(name).wav")
                continue
            }

            let (readings, _) = AudioTestHelpers.replay(samples: wav.samples, sampleRate: wav.sampleRate, config: config)
            let freshReadings = readings.filter { $0.freshness == .fresh }

            // Usable-audio regression gate: ensures the tuner detects at least 10 valid pitch windows on real instruments
            #expect(freshReadings.count >= 10, "Expected at least 10 fresh readings for \(name).wav, got \(freshReadings.count)")
        }
    }

    @Test("a licensed real strummed guitar chord never completes a guided string")
    func testStrummedGuitarChordRejectionInGuidedMode() {
        guard let wav = AudioTestHelpers.loadWav(name: "guitar-chord") else {
            Issue.record("Failed to load WAV fixture: guitar-chord.wav")
            return
        }

        let config = TunerConfig(instrument: .guitar, tuningId: "standard", mode: .guided, guided: true)
        let (_, tracker) = AudioTestHelpers.replay(samples: wav.samples, sampleRate: wav.sampleRate, config: config)

        // A polyphonic chord must NEVER accidentally validate and complete a single-string guided tune!
        #expect(!tracker.guidedProgress.contains(true), "A strummed chord must not complete any guided string")
    }
}
