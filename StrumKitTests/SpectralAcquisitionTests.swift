import Testing
import Foundation
@testable import StrumKit

/// Gates for the prior-free spectral **acquisition** path.
///
/// This path can name a pitch from nothing, which is the point and also the risk: unlike
/// recovery, it has no prior to lean on, so every mistake is a false note. The tests below
/// are therefore mostly about what it must *refuse*.
@Suite("Spectral Acquisition Gates")
struct SpectralAcquisitionTests {

    // MARK: - Helpers

    private static func targets(_ instrument: InstrumentCategory = .ukulele, _ tuning: String) -> [StringTarget] {
        let preset = Presets.presets(for: instrument).first { $0.id == tuning }!
        return preset.midi.enumerated().map { i, m in
            StringTarget(
                note: PitchMath.midiNoteName(m),
                midi: m,
                frequency: PitchMath.midiFrequency(m),
                number: preset.midi.count - i
            )
        }
    }

    /// Deterministic pluck with a controllable fundamental-to-partial balance.
    private static func pluck(
        rate: Double,
        fundamental: Double,
        seconds: Double,
        fundamentalAmplitude: Double,
        secondAmplitude: Double = 0.30,
        thirdAmplitude: Double = 0.22,
        noise: Double = 0,
        seed: UInt64 = 42
    ) -> [Float] {
        let n = Int(rate * seconds)
        var out = [Float](repeating: 0, count: n)
        var s = seed
        for i in 0..<n {
            s = (s &* 48271) % 2147483647
            let t = Double(i) / rate
            let env = exp(-t / 1.1) * min(1.0, t / 0.005)
            let a = 2.0 * .pi * fundamental * t
            let body = fundamentalAmplitude * sin(a)
                + secondAmplitude * sin(2 * a)
                + thirdAmplitude * sin(3 * a)
            out[i] = Float(env * body) + Float((Double(s) / 2147483647.0) * 2.0 - 1.0) * Float(noise)
        }
        return out
    }

    private static func session(
        _ instrument: InstrumentCategory = .ukulele,
        _ tuning: String,
        mode: TunerMode = .auto
    ) -> TunerAnalysisSession {
        TunerAnalysisSession(
            config: TunerConfig(instrument: instrument, tuningId: tuning, mode: mode),
            targets: targets(instrument, tuning)
        )
    }

    private static func replay(
        _ session: TunerAnalysisSession,
        samples: [Float],
        rate: Double,
        hop: Int = 1024
    ) -> [AudioTestHelpers.ReplayFrame] {
        let window = AudioCaptureService.requiredInputSamples(for: rate)
        var frames: [AudioTestHelpers.ReplayFrame] = []
        var sequence: UInt64 = 0
        for end in stride(from: hop, through: samples.count, by: hop) {
            sequence += 1
            let start = max(0, end - window)
            let frame = AnalysisFrame(
                samples: Array(samples[start..<end]),
                sampleRate: rate,
                captureEndSeconds: Double(end) / rate,
                sequence: sequence,
                generation: session.generation,
                callbackFrameCount: hop,
                newSampleCount: hop
            )
            guard let snapshot = session.processFrameSync(frame) else { continue }
            frames.append(
                AudioTestHelpers.ReplayFrame(
                    captureEndSeconds: frame.captureEndSeconds,
                    rawFrequency: snapshot.pitchResult.frequency,
                    rawRMS: snapshot.pitchResult.amplitudeRMS,
                    confidence: snapshot.pitchResult.confidence,
                    rejection: nil,
                    reading: snapshot.reading
                )
            )
        }
        return frames
    }

    // MARK: - It acquires what YIN cannot

    @Test("Acquires a note whose fundamental is far below YIN's evidence floor")
    func testAcquiresVeryWeakFundamental() {
        let rate = 48000.0
        // 0.012 amplitude against a 0.30 second partial: ~0.03% of the energy, roughly
        // an order of magnitude below the 0.4% floor YIN's arbitration requires.
        let signal = Self.pluck(
            rate: rate,
            fundamental: 440.0,
            seconds: 2.0,
            fundamentalAmplitude: 0.012
        )
        let session = Self.session(.ukulele, "high-g")
        let frames = Self.replay(session, samples: signal, rate: rate)
        let fresh = frames.compactMap { $0.reading }.filter { $0.freshness == .fresh }
        let correct = fresh.filter { AudioTestHelpers.isCorrectRecordedPitch($0.frequency, reference: 440.0) }
        let wrong = fresh.filter { !AudioTestHelpers.isCorrectRecordedPitch($0.frequency, reference: 440.0) }

        print(String(format: "ACQ weak-fundamental: fresh=%lld correct=%lld wrong=%lld",
                     fresh.count, correct.count, wrong.count))
        #expect(!correct.isEmpty, "Acquisition produced no correct reading on a pluck YIN cannot resolve")
        #expect(wrong.isEmpty, "Acquisition produced \(wrong.count) wrong readings")
    }

    @Test("Acquisition covers a longer sustain than acquisition alone would")
    func testAcquisitionExtendsSustain() {
        let rate = 48000.0
        let signal = Self.pluck(rate: rate, fundamental: 440.0, seconds: 3.0, fundamentalAmplitude: 0.012)

        // Control: recovery only, which cannot acquire at all.
        let control = Self.session(.ukulele, "high-g")
        let controlFrames = Self.replay(control, samples: signal, rate: rate)
        let controlFresh = controlFrames.compactMap { $0.reading }.filter { $0.freshness == .fresh }

        let withAcquisition = Self.session(.ukulele, "high-g")
        let frames = Self.replay(withAcquisition, samples: signal, rate: rate)
        let fresh = frames.compactMap { $0.reading }.filter { $0.freshness == .fresh }

        print(String(format: "ACQ sustain: without=%lld with=%lld", controlFresh.count, fresh.count))
        #expect(fresh.count > controlFresh.count,
                "Acquisition added nothing: \(fresh.count) vs \(controlFresh.count)")
    }

    // MARK: - What it must refuse

    @Test("Never acquires from silence or from broadband noise")
    func testRefusesSilenceAndNoise() {
        let rate = 48000.0
        let length = Int(rate * 1.5)

        for amplitude in [Float(0.0), 0.004, 0.02] as [Float] {
            var noise = [Float](repeating: 0, count: length)
            var seed: UInt64 = 987654321
            for i in 0..<length {
                seed = (seed &* 48271) % 2147483647
                noise[i] = amplitude * Float((Double(seed) / 2147483647.0) * 2.0 - 1.0)
            }
            let session = Self.session(.ukulele, "high-g")
            let frames = Self.replay(session, samples: noise, rate: rate)
            let fresh = frames.compactMap { $0.reading }.filter { $0.freshness == .fresh }
            print(String(format: "ACQ noise amp=%.4f: fresh=%lld", amplitude, fresh.count))
            #expect(fresh.isEmpty,
                    "Acquisition invented \(fresh.count) readings from noise at amplitude \(amplitude)")
        }
    }

    @Test("Never acquires a note that then drifts to a different string")
    func testDoesNotStitchAcrossStrings() {
        let rate = 48000.0
        // Two weak-fundamental plucks a semitone apart, with a gap.
        let a = Self.pluck(rate: rate, fundamental: 392.0, seconds: 1.2, fundamentalAmplitude: 0.012, seed: 11)
        let gap = [Float](repeating: 0, count: Int(rate * 0.4))
        let b = Self.pluck(rate: rate, fundamental: 440.0, seconds: 1.2, fundamentalAmplitude: 0.012, seed: 22)

        let session = Self.session(.ukulele, "high-g")
        let frames = Self.replay(session, samples: a + gap + b, rate: rate)
        let fresh = frames.compactMap { $0.reading }.filter { $0.freshness == .fresh }

        let secondHalf = fresh.filter { $0.at > 2.0 }
        let wrongInSecondHalf = secondHalf.filter { !AudioTestHelpers.isCorrectRecordedPitch($0.frequency, reference: 440.0) }
        print(String(format: "ACQ stitch: fresh=%lld wrongInSecondHalf=%lld", fresh.count, wrongInSecondHalf.count))
        #expect(!wrongInSecondHalf.isEmpty || fresh.isEmpty,
                "Acquisition never moved off the first string: \(fresh.count) fresh readings, none correct for the second")
    }

    @Test("Acquired evidence is tagged recovered and cannot complete a guided string")
    func testAcquiredEvidenceIsRecovered() {
        let rate = 48000.0
        let signal = Self.pluck(rate: rate, fundamental: 82.41, seconds: 2.5, fundamentalAmplitude: 0.012)

        let session = Self.session(.guitar, "standard", mode: .guided)
        let frames = Self.replay(session, samples: signal, rate: rate)
        let fresh = frames.compactMap { $0.reading }.filter { $0.freshness == .fresh }

        #expect(!fresh.isEmpty, "Expected acquisition to produce something on a weak guitar E2")
        #expect(fresh.allSatisfy { $0.recovered },
                "Acquired evidence must be tagged recovered so it cannot assert in tune")
        #expect(!fresh.contains { $0.inTune },
                "Acquired evidence must never assert that a string is in tune")
        #expect(Self.session(.guitar, "standard", mode: .guided).guidedProgress.allSatisfy { !$0 },
                "Acquired evidence must never complete a guided string")
    }

    @Test("Acquisition does not fire when YIN already has the note")
    func testDoesNotInterfereWithWorkingDetector() {
        let rate = 48000.0
        // A strong, ordinary note: YIN handles this, so acquisition must stay out of the way.
        let signal = Self.pluck(
            rate: rate,
            fundamental: 440.0,
            seconds: 2.0,
            fundamentalAmplitude: 0.25,
            secondAmplitude: 0.12,
            thirdAmplitude: 0.08
        )
        let session = Self.session(.ukulele, "high-g")
        let frames = Self.replay(session, samples: signal, rate: rate)
        let fresh = frames.compactMap { $0.reading }.filter { $0.freshness == .fresh }

        #expect(!fresh.isEmpty, "Regression: a strong ordinary pluck now produces no readings")
        #expect(fresh.contains { !$0.recovered },
                "Regression: a strong ordinary pluck is no longer being detected by YIN directly")
    }
}
