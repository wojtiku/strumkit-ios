import Testing
import Foundation
@testable import StrumKit

@Suite("Replay Metrics & Classification Tests")
struct ReplayMetricsTests {

    @Test("Metric tests prove 55 Hz is wrong for A4 and zero/nonfinite frequencies are invalid")
    func testPitchAccuracyMetrics() {
        #expect(AudioTestHelpers.isCorrectRecordedPitch(440, reference: 440))
        #expect(!AudioTestHelpers.isCorrectRecordedPitch(55, reference: 440))
        #expect(!AudioTestHelpers.isCorrectRecordedPitch(0, reference: 440))
        #expect(!AudioTestHelpers.isCorrectRecordedPitch(.nan, reference: 440))
        #expect(!AudioTestHelpers.isCorrectRecordedPitch(-440, reference: 440))
        #expect(!AudioTestHelpers.isCorrectRecordedPitch(.infinity, reference: 440))

        // Boundary tests (+- 50 cents)
        let semitoneUp = 440.0 * pow(2.0, 100.0 / 1200.0) // +100 cents -> false
        let withinThreshold = 440.0 * pow(2.0, 40.0 / 1200.0) // +40 cents -> true
        #expect(!AudioTestHelpers.isCorrectRecordedPitch(semitoneUp, reference: 440))
        #expect(AudioTestHelpers.isCorrectRecordedPitch(withinThreshold, reference: 440))
    }

    @Test("freshCoverageSeconds accurately clips and measures fresh duration")
    func testFreshCoverageCalculation() {
        let a4 = StringTarget(note: "A4", midi: 69, frequency: 440.0, number: 1)
        func reading(at: TimeInterval, frequency: Double, lastFreshAt: TimeInterval, freshness: TunerReading.Freshness, inTune: Bool) -> TunerReading {
            TunerReading(at: at, lastFreshAt: lastFreshAt, frequency: frequency, aim: .target(a4, inTune: inTune), cents: 0, displayCents: 0, freshness: freshness, evidence: .measured)
        }
        let frames: [AudioTestHelpers.ReplayFrame] = [
            .init(captureEndSeconds: 0.10, rawFrequency: 0, rawRMS: 0.001, confidence: 0, rejection: "gate", reading: nil),
            .init(captureEndSeconds: 0.20, rawFrequency: 440.0, rawRMS: 0.05, confidence: 0.9, rejection: nil,
                  reading: reading(at: 0.20, frequency: 440.0, lastFreshAt: 0.20, freshness: .fresh, inTune: true)),
            .init(captureEndSeconds: 0.30, rawFrequency: 440.0, rawRMS: 0.04, confidence: 0.9, rejection: nil,
                  reading: reading(at: 0.30, frequency: 440.0, lastFreshAt: 0.30, freshness: .fresh, inTune: true)),
            .init(captureEndSeconds: 0.40, rawFrequency: 440.0, rawRMS: 0.01, confidence: 0.5, rejection: nil,
                  reading: reading(at: 0.40, frequency: 440.0, lastFreshAt: 0.20, freshness: .held, inTune: false)),
            .init(captureEndSeconds: 0.50, rawFrequency: 55.0, rawRMS: 0.005, confidence: 0.8, rejection: nil,
                  reading: reading(at: 0.50, frequency: 55.0, lastFreshAt: 0.50, freshness: .fresh, inTune: false))
        ]

        let coverage = AudioTestHelpers.freshCoverageSeconds(frames: frames, reference: 440.0, intervalStart: 0.0, intervalEnd: 1.0)
        // Frame 0 at 0.10 (not fresh)
        // Frame 1 at 0.20 (fresh): delta = 0.20 - 0.10 = 0.10s
        // Frame 2 at 0.30 (fresh): delta = 0.30 - 0.20 = 0.10s
        // Frame 3 at 0.40 (held): contributes 0
        // Frame 4 at 0.50 (55 Hz wrong note): contributes 0
        // Total coverage = 0.20s
        #expect(abs(coverage - 0.20) < 1e-4)
    }
}
