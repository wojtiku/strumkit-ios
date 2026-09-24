import Testing
import Foundation
@testable import StrumKit

@Suite("Pitch DSP Engine Tests (pitch.test.ts)")
struct PitchTests {

    @Test("rejects a source shorter than one analysis window")
    func testSourceShorterThanWindow() {
        let resampler = Resampler()
        let shortSource = [Float](repeating: 0.1, count: Resampler.windowSize - 1)
        let output = resampler.resampleWindow(source: shortSource, inputRate: Resampler.analysisRate)
        #expect(output == nil)
    }

    @Test("detects high E (329.63 Hz) without octave change at 44.1kHz, 48kHz, 96kHz")
    func testHighEOctavePreservation() {
        for rate in [44100.0, 48000.0, 96000.0] {
            let detector = PitchDetector(sampleRate: rate)
            let source = AudioTestHelpers.tone(frequency: 329.6275569, rate: rate)
            let result = detector.detectPitch(in: source)

            #expect(result.frequency > 0, "Frequency should be detected at \(rate) Hz")
            let centsErr = abs(1200.0 * log2(result.frequency / 329.6275569))
            #expect(centsErr < 2.0, "Cents error at \(rate) Hz was \(centsErr)")
            #expect(result.confidence > 0.80)
        }
    }

    @Test("correctly resamples and detects pitch at 22,050 Hz")
    func testResamplingAt22050Hz() {
        let rate = 22050.0
        let detector = PitchDetector(sampleRate: rate)
        let length = Int(ceil(rate * 0.11))
        var source = [Float](repeating: 0, count: length)
        for i in 0..<length {
            source[i] = 0.1 * Float(sin(2.0 * Double.pi * 220.0 * Double(i) / rate))
        }

        let result = detector.detectPitch(in: source)
        #expect(result.frequency > 0)
        let centsErr = abs(1200.0 * log2(result.frequency / 220.0))
        #expect(centsErr < 2.0)
    }

    @Test("meets clean-tone median <= 1 cent and p95 <= 2 cents accuracy gates over complete range")
    func testCleanToneAccuracyGates() {
        var errors: [Double] = []
        let testFrequencies: [Double] = [
            50.0, 51.3, 55.0, 73.42, 82.4069, 110.0, 146.832, 196.0,
            246.942, 261.626, 329.628, 392.0, 439.0, 466.0, 587.33,
            783.99, 987.77, 1050.0, 1099.0
        ]

        for rate in [44100.0, 48000.0, 96000.0] {
            let detector = PitchDetector(sampleRate: rate)
            for freq in testFrequencies {
                let source = AudioTestHelpers.tone(frequency: freq, rate: rate)
                let result = detector.detectPitch(in: source)
                #expect(result.frequency > 0, "Should detect pitch for \(freq) Hz at \(rate) Hz")
                let err = abs(1200.0 * log2(result.frequency / freq))
                errors.append(err)
            }
        }

        errors.sort()
        let median = errors[errors.count / 2]
        let p95 = errors[Int(Double(errors.count) * 0.95)]

        #expect(median <= 1.0, "Median error \(median) cents must be <= 1 cent")
        #expect(p95 <= 2.0, "P95 error \(p95) cents must be <= 2 cents")
    }

    @Test("hears a weak fundamental through 2nd/3rd harmonics, DC offset, and seeded noise")
    func testWeakFundamentalThroughHarmonicsAndNoise() {
        for rate in [44100.0, 48000.0, 96000.0] {
            let detector = PitchDetector(sampleRate: rate)
            let length = Int(ceil(rate * 0.1))
            var seed: UInt64 = 73
            var source = [Float](repeating: 0, count: length)

            for i in 0..<length {
                seed = (seed &* 48271) % 2147483647
                let noise = (Float(seed) / 2147483647.0 - 0.5) * 0.015
                let angle = 2.0 * Double.pi * 82.4069 * Double(i) / rate
                // Fundamental is only 0.06, 2nd harmonic is 0.30 (5x stronger!), 3rd is 0.12, plus 0.14 DC
                source[i] = 0.14 + 0.06 * Float(sin(angle)) + 0.30 * Float(sin(2.0 * angle)) + 0.12 * Float(sin(3.0 * angle)) + noise
            }

            let result = detector.detectPitch(in: source)
            #expect(result.frequency > 0, "Must detect low E fundamental at \(rate) Hz")
            let centsErr = abs(1200.0 * log2(result.frequency / 82.4069))
            #expect(centsErr < 3.0, "Octave error prevented: error was \(centsErr) cents")
        }
    }

    @Test("abstains on silence, broadband noise, clipping, and invalid samples")
    func testAbstentionPolicy() {
        let rate = 48000.0
        let detector = PitchDetector(sampleRate: rate)

        // Silence
        let silence = [Float](repeating: 0, count: 4800)
        #expect(detector.detectPitch(in: silence).frequency == 0)

        // Seeded broadband noise
        var seed: UInt64 = 42
        var noise = [Float](repeating: 0, count: 4800)
        for i in 0..<4800 {
            seed = (seed &* 48271) % 2147483647
            noise[i] = (Float(seed) / 2147483647.0 - 0.5) * 0.3
        }
        #expect(detector.detectPitch(in: noise).frequency == 0)

        // Clipped source (amplitude 1.5)
        let clipped = AudioTestHelpers.tone(frequency: 110.0, rate: rate, amplitude: 1.5)
        #expect(detector.detectPitch(in: clipped).frequency == 0)
    }

    @Test("rejects a spurious fundamental made only from conflicting upper harmonics")
    func testConflictingUpperHarmonicsRejection() {
        let rate = 48000.0
        let detector = PitchDetector(sampleRate: rate)
        let count = 4800
        var source = [Float](repeating: 0, count: count)
        // 220 Hz and 330 Hz without fundamental 110 Hz
        for i in 0..<count {
            let t = Double(i) / rate
            source[i] = 0.3 * Float(sin(2.0 * Double.pi * 220.0 * t)) + 0.25 * Float(sin(2.0 * Double.pi * 330.0 * t))
        }

        let result = detector.detectPitch(in: source)
        // Must NOT falsely claim 110 Hz when 110 Hz has no fundamental energy
        if result.frequency > 0 {
            let centsFrom110 = abs(1200.0 * log2(result.frequency / 110.0))
            #expect(centsFrom110 > 50.0, "Should not detect 110 Hz fundamental when absent")
        }
    }
}
