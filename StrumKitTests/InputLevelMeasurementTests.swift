import Testing
import Foundation
@testable import StrumKit

@Suite("Input Level Measurement")
struct InputLevelMeasurementTests {
    @Test("A silent input is reported as silent rather than inferred")
    func testSilentInputMeasuresZero() {
        let config = TunerConfig(instrument: .ukulele, tuningId: "high-g", mode: .auto)
        let session = TunerAnalysisSession(config: config, targets: [])
        let window = [Float](repeating: 0, count: 1024)
        for i in 0..<40 {
            _ = session.processFrameSync(AnalysisFrame(
                samples: window, sampleRate: 48000, captureEndSeconds: Double(i) * 0.021,
                sequence: UInt64(i), generation: session.generation, callbackFrameCount: 1024
            ))
        }
        let level = session.inputLevel
        #expect(level.peak < 1e-6, "pure silence must measure as silence, not as a live level")
        #expect(level.frames == 40)
    }

    @Test("A real signal measures as a real level")
    func testSignalInputMeasuresNonZero() {
        let config = TunerConfig(instrument: .ukulele, tuningId: "high-g", mode: .auto)
        let session = TunerAnalysisSession(config: config, targets: [])
        var window = [Float](repeating: 0, count: 1024)
        for i in 0..<window.count {
            window[i] = 0.2 * Float(sin(2 * .pi * 440.0 * Double(i) / 48000))
        }
        for i in 0..<40 {
            _ = session.processFrameSync(AnalysisFrame(
                samples: window, sampleRate: 48000, captureEndSeconds: Double(i) * 0.021,
                sequence: UInt64(i), generation: session.generation, callbackFrameCount: 1024
            ))
        }
        let level = session.inputLevel
        #expect(level.peak > 0.1, "a 0.2-amplitude tone must measure as a live level, got peak \(level.peak)")
    }
}
