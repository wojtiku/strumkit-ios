import Testing
import Foundation
@testable import StrumKit

@Suite("YIN Pitch Detection DSP Tests")
struct PitchDetectionTests {

    /// Helper to generate pure synthetic sine wave PCM audio samples.
    private func generateSineWave(
        frequency: Double,
        sampleRate: Double = 44100.0,
        count: Int = 2048,
        amplitude: Float = 0.8
    ) -> [Float] {
        var buffer = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let t = Double(i) / sampleRate
            buffer[i] = amplitude * Float(sin(2.0 * Double.pi * frequency * t))
        }
        return buffer
    }

    @Test("Detects Guitar Low E (82.41 Hz) with sub-Hz accuracy")
    func testGuitarLowEPitch() {
        let detector = PitchDetector(sampleRate: 44100.0, bufferSize: 2048)
        let buffer = generateSineWave(frequency: 82.41, count: 2048)
        let result = detector.detectPitch(in: buffer, noiseGateRMS: 0.01)

        #expect(result.isSignalPresent)
        #expect(result.confidence > 0.85)
        #expect(abs(result.frequency - 82.41) < 0.5)
        #expect(result.closestNote.displayName == "E2")
        #expect(abs(result.centsDeviation) < 5.0)
    }

    @Test("Detects Guitar A string (110.0 Hz)")
    func testGuitarAPitch() {
        let detector = PitchDetector(sampleRate: 44100.0, bufferSize: 2048)
        let buffer = generateSineWave(frequency: 110.0, count: 2048)
        let result = detector.detectPitch(in: buffer, noiseGateRMS: 0.01)

        #expect(result.isSignalPresent)
        #expect(result.confidence > 0.85)
        #expect(abs(result.frequency - 110.0) < 0.4)
        #expect(result.closestNote.displayName == "A2")
    }

    @Test("Detects Middle C / Ukulele C4 (261.63 Hz)")
    func testUkuleleCPitch() {
        let detector = PitchDetector(sampleRate: 44100.0, bufferSize: 2048)
        let buffer = generateSineWave(frequency: 261.63, count: 2048)
        let result = detector.detectPitch(in: buffer, noiseGateRMS: 0.01)

        #expect(result.isSignalPresent)
        #expect(result.confidence > 0.85)
        #expect(abs(result.frequency - 261.63) < 0.3)
        #expect(result.closestNote.displayName == "C4")
    }

    @Test("Detects Concert A4 (440.0 Hz)")
    func testConcertAPitch() {
        let detector = PitchDetector(sampleRate: 44100.0, bufferSize: 2048)
        let buffer = generateSineWave(frequency: 440.0, count: 2048)
        let result = detector.detectPitch(in: buffer, noiseGateRMS: 0.01)

        #expect(result.isSignalPresent)
        #expect(result.confidence > 0.85)
        #expect(abs(result.frequency - 440.0) < 0.3)
        #expect(result.closestNote.displayName == "A4")
        #expect(abs(result.centsDeviation) < 2.0)
    }

    @Test("Noise gate silences ambient noise below threshold")
    func testNoiseGate() {
        let detector = PitchDetector(sampleRate: 44100.0, bufferSize: 2048)
        // Very low amplitude signal (0.002) below standard noise gate (0.012)
        let quietBuffer = generateSineWave(frequency: 440.0, count: 2048, amplitude: 0.002)
        let result = detector.detectPitch(in: quietBuffer, noiseGateRMS: 0.012)

        #expect(!result.isSignalPresent)
        #expect(result.frequency == 0)
    }

    @Test("Detects whisper-quiet guitar Low E (82.41 Hz) with amplitude 0.0005 (-66 dBFS)")
    func testQuietGuitarLowEPitch() {
        let detector = PitchDetector(sampleRate: 44100.0, bufferSize: 4410)
        let buffer = generateSineWave(frequency: 82.41, count: 4410, amplitude: 0.0005)
        let result = detector.detectPitch(in: buffer, noiseGateRMS: 0.0001)

        #expect(result.isSignalPresent)
        #expect(result.confidence > 0.80)
        #expect(abs(result.frequency - 82.41) < 0.6)
        #expect(result.closestNote.displayName == "E2")
    }

    @Test("Detects whisper-quiet Concert A4 (440.0 Hz) with amplitude 0.0005 (-66 dBFS)")
    func testQuietConcertAPitch() {
        let detector = PitchDetector(sampleRate: 44100.0, bufferSize: 4410)
        let buffer = generateSineWave(frequency: 440.0, count: 4410, amplitude: 0.0005)
        let result = detector.detectPitch(in: buffer, noiseGateRMS: 0.0001)

        #expect(result.isSignalPresent)
        #expect(result.confidence > 0.85)
        #expect(abs(result.frequency - 440.0) < 0.4)
        #expect(result.closestNote.displayName == "A4")
    }

    @Test("AudioRingBuffer accumulates chunks and preserves trailing sample sequence")
    func testAudioRingBufferAccumulation() {
        let required = AudioCaptureService.requiredInputSamples(for: 44100.0)
        #expect(required == 4328)

        let ring = AudioRingBuffer(capacity: 8192)
        #expect(ring.availableCount == 0)
        #expect(ring.readTrailing(count: required) == nil)

        // Write 5 chunks of 1000 samples (total 5000)
        for chunkIndex in 0..<5 {
            let chunk = [Float](repeating: Float(chunkIndex + 1), count: 1000)
            ring.write(chunk)
        }

        #expect(ring.availableCount == 5000)
        let trailing = ring.readTrailing(count: required)
        #expect(trailing != nil)
        #expect(trailing?.count == required)
        // Last sample should be from chunk 5 (value 5.0)
        #expect(trailing?.last == 5.0)
    }

    @Test("PitchTracker adapts ambient floor and adjusts sustain thresholds")
    func testPitchTrackerAdaptiveAmbientFloor() {
        let tracker = PitchTracker()
        #expect(tracker.ambientFloor == PitchTracker.initialAmbientFloor)

        // Acquisition thresholds
        let acqGate = tracker.recommendedNoiseGate(isSustaining: false)
        let acqYin = tracker.recommendedYinThreshold(isSustaining: false)
        #expect(acqYin == 0.15)
        #expect(acqGate >= 0.00015)

        // Sustain thresholds
        let susGate = tracker.recommendedNoiseGate(isSustaining: true)
        let susYin = tracker.recommendedYinThreshold(isSustaining: true)
        #expect(susYin == 0.25)
        #expect(susGate < acqGate) // Sustain threshold is more permissive to retain decays
    }
}
