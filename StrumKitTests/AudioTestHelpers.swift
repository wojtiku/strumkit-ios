import Foundation
@testable import StrumKit

public enum AudioTestHelpers {

    /// Generates pure synthetic sine wave samples matching chorder's tone() helper.
    public static func tone(frequency: Double, rate: Double, amplitude: Float = 0.1) -> [Float] {
        let length = Int(ceil(rate * 0.1))
        var samples = [Float](repeating: 0, count: length)
        for i in 0..<length {
            let t = Double(i) / rate
            samples[i] = amplitude * Float(sin(2.0 * Double.pi * frequency * t))
        }
        return samples
    }

    /// Known phase-derived fundamental, seeded noise, transient attack, and decay matching chorder's pluck() helper.
    public static func pluck(
        rate: Double,
        frequency: Double,
        seconds: Double = 1.4,
        snr: Double = .infinity,
        initialSeed: UInt64 = 42
    ) -> [Float] {
        let length = Int(round(rate * seconds))
        var signal = [Float](repeating: 0, count: length)

        for i in 0..<length {
            let t = Double(i) / rate
            let angle = 2.0 * Double.pi * frequency * t
            let attack = min(1.0, t / 0.006)
            let decay = exp(-t / 1.8)
            let envelope = Float(attack * decay)

            let h1 = 0.09 * sin(angle)
            let h2 = 0.15 * sin(2.0 * angle + 0.4)
            let h3 = 0.055 * sin(3.0 * angle + 0.8)
            signal[i] = envelope * Float(h1 + h2 + h3)
        }

        if !snr.isFinite { return signal }

        var sumSq: Double = 0.0
        for s in signal { sumSq += Double(s * s) }
        let rms = sqrt(sumSq / Double(signal.count))
        let amplitude = Float(rms * pow(10.0, -snr / 20.0) * sqrt(3.0))

        var seed = initialSeed
        for i in 0..<signal.count {
            seed = (seed &* 48271) % 2147483647
            let randNorm = (Float(seed) / 2147483647.0) * 2.0 - 1.0
            signal[i] += amplitude * randNorm
        }

        return signal
    }

    /// Parses a standard 16-bit PCM WAV file into Float samples normalized to [-1.0, 1.0].
    public static func loadWav(name: String) -> (samples: [Float], sampleRate: Double)? {
        let bundle = Bundle(for: BundleLocator.self)
        var wavUrl: URL? = bundle.url(forResource: name, withExtension: "wav")

        if wavUrl == nil {
            let directLocal = "/Users/wojtiku/src/strumkit-ios/StrumKitTests/Fixtures/\(name).wav"
            if FileManager.default.fileExists(atPath: directLocal) {
                wavUrl = URL(fileURLWithPath: directLocal)
            } else {
                // Fallback to relative path from source file
                let thisFile = URL(fileURLWithPath: #filePath)
                let fixturesDir = thisFile.deletingLastPathComponent().appendingPathComponent("Fixtures")
                let localUrl = fixturesDir.appendingPathComponent("\(name).wav")
                if FileManager.default.fileExists(atPath: localUrl.path) {
                    wavUrl = localUrl
                }
            }
        }

        guard let url = wavUrl, let data = try? Data(contentsOf: url) else {
            return nil
        }

        return parseWavData(data)
    }

    private static func readUInt32LE(data: Data, offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        return UInt32(data[offset]) |
            (UInt32(data[offset + 1]) << 8) |
            (UInt32(data[offset + 2]) << 16) |
            (UInt32(data[offset + 3]) << 24)
    }

    private static func readUInt16LE(data: Data, offset: Int) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        return UInt16(data[offset]) |
            (UInt16(data[offset + 1]) << 8)
    }

    private static func readInt16LE(data: Data, offset: Int) -> Int16 {
        let u = readUInt16LE(data: data, offset: offset)
        return Int16(bitPattern: u)
    }

    private static func parseWavData(_ data: Data) -> (samples: [Float], sampleRate: Double)? {
        guard data.count > 44 else { return nil }

        var sampleRate: Double = 44100.0
        var channels: Int = 1
        var bitsPerSample: Int = 16
        var dataOffset = 0
        var dataLength = 0

        var offset = 12
        while offset + 8 <= data.count {
            let chunkId = String(decoding: data[offset..<offset+4], as: UTF8.self)
            let chunkSize = Int(readUInt32LE(data: data, offset: offset + 4))
            let start = offset + 8

            if chunkId == "fmt " {
                let audioFormat = Int(readUInt16LE(data: data, offset: start))
                guard audioFormat == 1 || audioFormat == 65534 else { return nil } // PCM or WAVE_FORMAT_EXTENSIBLE
                channels = Int(readUInt16LE(data: data, offset: start + 2))
                sampleRate = Double(readUInt32LE(data: data, offset: start + 4))
                bitsPerSample = Int(readUInt16LE(data: data, offset: start + 14))
            }

            if chunkId == "data" {
                dataOffset = start
                dataLength = chunkSize
                break
            }

            offset = start + chunkSize + (chunkSize % 2)
        }

        guard dataOffset > 0 && bitsPerSample == 16 && channels > 0 else { return nil }

        let bytesPerSample = 2
        let frameSize = bytesPerSample * channels
        let availableBytes = min(dataLength, data.count - dataOffset)
        let sampleCount = availableBytes / frameSize
        var samples = [Float](repeating: 0, count: sampleCount)

        for i in 0..<sampleCount {
            let sampleVal = readInt16LE(data: data, offset: dataOffset + i * frameSize)
            samples[i] = Float(sampleVal) / 32768.0
        }

        return (samples, sampleRate)
    }

    /// Frame-by-frame diagnostic record for production replay simulations.
    public struct ReplayFrame: Sendable {
        public let captureEndSeconds: Double
        public let rawFrequency: Double
        public let rawRMS: Double
        public let confidence: Double
        public let rejection: String? // "gate", "clipping", "noPeriodicity", "ambiguity", "targetMismatch", "acquiring"
        public let reading: TunerReading?

        public init(
            captureEndSeconds: Double,
            rawFrequency: Double,
            rawRMS: Double,
            confidence: Double,
            rejection: String?,
            reading: TunerReading?
        ) {
            self.captureEndSeconds = captureEndSeconds
            self.rawFrequency = rawFrequency
            self.rawRMS = rawRMS
            self.confidence = confidence
            self.rejection = rejection
            self.reading = reading
        }
    }

    /// Evaluates if an estimated frequency falls within 50 cents of the target reference.
    public static func isCorrectRecordedPitch(_ frequency: Double, reference: Double) -> Bool {
        guard frequency.isFinite, frequency > 0, reference > 0 else { return false }
        return abs(1200 * log2(frequency / reference)) <= 50
    }

    /// Computes fresh coverage duration in seconds over an evaluation interval.
    public static func freshCoverageSeconds(
        frames: [ReplayFrame],
        reference: Double,
        intervalStart: Double,
        intervalEnd: Double
    ) -> Double {
        var coverage: Double = 0.0
        var previousTime: Double = intervalStart

        for frame in frames {
            let t = frame.captureEndSeconds
            guard t >= intervalStart && t <= intervalEnd else { continue }
            if let reading = frame.reading, reading.freshness == .fresh, isCorrectRecordedPitch(reading.frequency, reference: reference) {
                let delta = max(0.0, t - max(intervalStart, previousTime))
                coverage += delta
            }
            previousTime = t
        }
        return coverage
    }

    /// Production-equivalent replay trace with 2,048-sample hops, trailing capture window, and dynamic tracker thresholds.
    public static func replayTrace(
        samples: [Float],
        sampleRate: Double,
        config: TunerConfig,
        hopSamples: Int = 2048,
        enableSpectralRecovery: Bool = true
    ) -> (frames: [ReplayFrame], tracker: PitchTracker) {
        let available = Presets.presets(for: config.instrument)
        let preset = available.first(where: { $0.id == config.tuningId }) ?? available[0]
        let midiList = config.tuningId == "custom" ? config.customMidi : preset.midi
        let targets = midiList.enumerated().map { index, midi in
            StringTarget(note: PitchMath.midiNoteName(midi), midi: midi, frequency: PitchMath.midiFrequency(midi, a4: config.a4), number: midiList.count - index)
        }

        let tracker = PitchTracker()
        tracker.reset(targetCount: targets.count)
        let session = TunerAnalysisSession(config: config, targets: targets, tracker: tracker)
        session.isSpectralRecoveryEnabled = enableSpectralRecovery

        var frames: [ReplayFrame] = []
        let windowLength = AudioCaptureService.requiredInputSamples(for: sampleRate)
        var sequence: UInt64 = 0

        for endSample in stride(from: hopSamples, through: samples.count, by: hopSamples) {
            sequence &+= 1
            let atSeconds = Double(endSample) / sampleRate
            let startSample = max(0, endSample - windowLength)
            let window = Array(samples[startSample..<endSample])

            let frame = AnalysisFrame(
                samples: window,
                sampleRate: sampleRate,
                captureEndSeconds: atSeconds,
                sequence: sequence,
                generation: session.generation,
                callbackFrameCount: hopSamples
            )

            guard let snapshot = session.processFrameSync(frame) else { continue }

            var rejection: String? = nil
            if !snapshot.pitchResult.isSignalPresent {
                if snapshot.pitchResult.amplitudeRMS < Double(tracker.recommendedNoiseGate(isSustaining: false)) {
                    rejection = "gate"
                } else {
                    rejection = "noPeriodicity"
                }
            } else if snapshot.reading == nil {
                if snapshot.feedbackState == .checking {
                    rejection = "acquiring"
                } else if snapshot.feedbackState == .ambiguous {
                    rejection = "ambiguity"
                } else {
                    rejection = "targetMismatch"
                }
            }

            frames.append(ReplayFrame(
                captureEndSeconds: atSeconds,
                rawFrequency: snapshot.pitchResult.frequency,
                rawRMS: snapshot.pitchResult.amplitudeRMS,
                confidence: snapshot.pitchResult.confidence,
                rejection: rejection,
                reading: snapshot.reading
            ))
        }

        return (frames, tracker)
    }

    /// Replays audio through PitchDetector and PitchTracker (adapter for existing tests).
    public static func replay(
        samples: [Float],
        sampleRate: Double,
        config: TunerConfig
    ) -> (readings: [TunerReading], tracker: PitchTracker) {
        let (frames, tracker) = replayTrace(samples: samples, sampleRate: sampleRate, config: config, hopSamples: 2048)
        let readings = frames.compactMap { $0.reading }
        return (readings, tracker)
    }
}

private final class BundleLocator {}
