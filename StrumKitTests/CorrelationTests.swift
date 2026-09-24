import Testing
import Foundation
@testable import StrumKit

@Suite("Hann Correlation & Projection Tests (correlation.test.ts)")
struct CorrelationTests {

    @Test("keeps normalized and raw Hann power variants distinct")
    func testNormalizedAndRawHannPower() {
        // 33-sample sine wave matching chorder test
        let count = 33
        var samples = [Float](repeating: 0, count: count)
        for i in 0..<count {
            samples[i] = Float(sin(2.0 * Double.pi * Double(i) / 8.0))
        }

        let normalized = HannProjection.normalizedPower(samples: samples, frequency: 2000.0, sampleRate: 16000.0)
        let raw = HannProjection.rawPower(samples: samples, frequency: 2000.0, sampleRate: 16000.0)

        // A 33-sample symmetric Hann window has a hand-derived total weight of 16.
        // Expected: normalized == 2 * raw / 16^2
        let expected = 2.0 * raw / pow(16.0, 2.0)
        #expect(abs(normalized - expected) < 1e-10)
    }

    @Test("uses the negative imaginary convention for phase continuity")
    func testNegativeImaginaryPhaseConvention() {
        let count = 33
        var samples = [Float](repeating: 0, count: count)
        for i in 0..<count {
            samples[i] = Float(sin(2.0 * Double.pi * Double(i) / 8.0))
        }

        let projection = HannProjection.phaseAndPower(samples: samples, frequency: 2000.0, sampleRate: 16000.0)
        #expect(projection.power > 0)
        #expect(abs(projection.phase - (-Double.pi / 2.0)) < 1e-10)
    }
}
