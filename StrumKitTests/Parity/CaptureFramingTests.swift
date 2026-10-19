// StrumKitTests/Parity/CaptureFramingTests.swift
import Foundation
import Testing
@testable import StrumKit

@Suite("Native Audio Capture Framing & Sample-Clock Contract Tests")
struct CaptureFramingTests {

    // MARK: - 1. Channel Policy & Averaging

    @Test("Channel averaging: mono input preserves samples without scaling")
    func monoPreservesSamples() {
        let framer = FaithfulCaptureFraming(sampleRate: 44100.0, bufferCapacity: 16384)
        let monoInput = (0..<4096).map { Float(sin(Double($0) * 0.05)) }

        let windows = framer.process(channel: monoInput)
        #expect(windows.count == 1)
        let win = windows[0]
        #expect(win.samples.count == 4096)
        for i in 0..<4096 {
            #expect(win.samples[i] == monoInput[i])
        }
    }

    @Test("Channel averaging: stereo input performs sample-wise (ch0 + ch1) / 2")
    func stereoChannelAveraging() {
        let framer = FaithfulCaptureFraming(sampleRate: 44100.0, bufferCapacity: 16384)
        let ch0 = (0..<4096).map { Float($0) * 0.001 }
        let ch1 = (0..<4096).map { Float($0) * 0.003 }
        let expected = (0..<4096).map { (ch0[$0] + ch1[$0]) / 2.0 }

        let windows = framer.process(channels: [ch0, ch1])
        #expect(windows.count == 1)
        let win = windows[0]
        for i in 0..<4096 {
            #expect(win.samples[i] == expected[i])
        }
    }

    @Test("Channel averaging: 4-channel input computes sum / 4.0 with cancellation")
    func quadChannelAveragingWithCancellation() {
        let framer = FaithfulCaptureFraming(sampleRate: 44100.0, bufferCapacity: 16384)
        // Two channels cancel each other (+0.5 and -0.5), third is 0.8, fourth is 0.4 -> average = 0.3
        let ch0 = [Float](repeating: 0.5, count: 4096)
        let ch1 = [Float](repeating: -0.5, count: 4096)
        let ch2 = [Float](repeating: 0.8, count: 4096)
        let ch3 = [Float](repeating: 0.4, count: 4096)

        let windows = framer.process(channels: [ch0, ch1, ch2, ch3])
        #expect(windows.count == 1)
        let win = windows[0]
        for i in 0..<4096 {
            #expect(abs(win.samples[i] - 0.3) < 1e-6)
        }
    }

    // MARK: - 2. Initial Full-Window Wait & Stream Geometry

    @Test("Strict initial wait: 0 windows before sample 4096, 1st at 4096, 2nd at 5120, etc.")
    func strictInitialWaitAndHopCadence() {
        let framer = FaithfulCaptureFraming(sampleRate: 44100.0, bufferCapacity: 16384)

        // 1st chunk: 1024 samples -> 0 windows
        let chunk1 = [Float](repeating: 0.1, count: 1024)
        let win1 = framer.process(channel: chunk1)
        #expect(win1.isEmpty)
        #expect(framer.sampleIndex == 1024)
        #expect(framer.filled == 1024)
        #expect(framer.sinceLast == 1024)

        // 2nd chunk: 1024 samples -> 0 windows
        let win2 = framer.process(channel: chunk1)
        #expect(win2.isEmpty)
        #expect(framer.sampleIndex == 2048)

        // 3rd chunk: 1024 samples -> 0 windows
        let win3 = framer.process(channel: chunk1)
        #expect(win3.isEmpty)
        #expect(framer.sampleIndex == 3072)

        // 4th chunk: 1023 samples (total 4095) -> strictly 0 windows before 4096!
        let chunk4095 = [Float](repeating: 0.1, count: 1023)
        let win4095 = framer.process(channel: chunk4095)
        #expect(win4095.isEmpty)
        #expect(framer.sampleIndex == 4095)

        // 1 single sample (total 4096) -> exactly 1st window emitted!
        let chunk1sample = [Float](repeating: 0.1, count: 1)
        let win4096 = framer.process(channel: chunk1sample)
        #expect(win4096.count == 1)
        #expect(win4096[0].frameIndex == 0)
        #expect(win4096[0].sampleIndex == 4096)
        #expect(framer.frameIndex == 1)
        #expect(framer.sinceLast == 0)

        // 1023 samples (total 5119) -> 0 new windows
        let win5119 = framer.process(channel: [Float](repeating: 0.1, count: 1023))
        #expect(win5119.isEmpty)

        // 1 single sample (total 5120) -> exactly 2nd window emitted!
        let win5120 = framer.process(channel: [Float](repeating: 0.1, count: 1))
        #expect(win5120.count == 1)
        #expect(win5120[0].frameIndex == 1)
        #expect(win5120[0].sampleIndex == 5120)
        #expect(framer.frameIndex == 2)
        #expect(framer.sinceLast == 0)

        // 1024 samples (total 6144) -> exactly 3rd window emitted!
        let win6144 = framer.process(channel: [Float](repeating: 0.1, count: 1024))
        #expect(win6144.count == 1)
        #expect(win6144[0].frameIndex == 2)
        #expect(win6144[0].sampleIndex == 6144)
    }

    // MARK: - 3. Arbitrary Callback Block Partitioning

    @Test("Arbitrary block partitioning: 128, 256, 512, 1024, and irregular chunks produce bit-identical windows")
    func arbitraryPartitioningBitIdentical() {
        // Generate 20,000 deterministic test samples (swept chirp + sine)
        let totalSamples = 20000
        var audio = [Float](repeating: 0.0, count: totalSamples)
        for i in 0..<totalSamples {
            let t = Double(i) / 44100.0
            let freq = 220.0 + 100.0 * sin(t * 10.0)
            audio[i] = Float(sin(2.0 * Double.pi * freq * t) * 0.25)
        }

        // Helper to feed audio in specified chunk partition
        func runPartition(chunkSizes: [Int]) -> [FaithfulCaptureWindow] {
            let framer = FaithfulCaptureFraming(sampleRate: 44100.0, bufferCapacity: 32768)
            var windows: [FaithfulCaptureWindow] = []
            var offset = 0
            var chunkIdx = 0

            while offset < totalSamples {
                let chunkSize = chunkSizes[chunkIdx % chunkSizes.count]
                let count = min(chunkSize, totalSamples - offset)
                let chunk = Array(audio[offset..<offset + count])
                let w = framer.process(channel: chunk)
                windows.append(contentsOf: w)
                offset += count
                chunkIdx += 1
            }
            return windows
        }

        // 1. Worklet native partition: 128 samples
        let baselineWindows = runPartition(chunkSizes: [128])
        #expect(baselineWindows.count == 1 + (totalSamples - 4096) / 1024)

        // 2. 256 samples
        let windows256 = runPartition(chunkSizes: [256])

        // 3. 512 samples
        let windows512 = runPartition(chunkSizes: [512])

        // 4. 1024 samples
        let windows1024 = runPartition(chunkSizes: [1024])

        // 5. Irregular partition: prime & odd sizes
        let irregularWindows = runPartition(chunkSizes: [441, 705, 128, 999, 333, 1024, 77, 2048, 513])

        // 6. Random irregular partition: pseudo-random sizes
        var randomSizes: [Int] = []
        var seed: UInt64 = 123456789
        for _ in 0..<100 {
            seed = (seed &* 6364136223846793005) &+ 1442695040888963407
            let size = 1 + Int((seed >> 32) % 1500)
            randomSizes.append(size)
        }
        let randomWindows = runPartition(chunkSizes: randomSizes)

        let allPartitions: [(String, [FaithfulCaptureWindow])] = [
            ("256", windows256),
            ("512", windows512),
            ("1024", windows1024),
            ("irregular", irregularWindows),
            ("random", randomWindows)
        ]

        for (name, partitionWindows) in allPartitions {
            #expect(partitionWindows.count == baselineWindows.count, "Partition \(name) frame count mismatch")
            for i in 0..<baselineWindows.count {
                let base = baselineWindows[i]
                let test = partitionWindows[i]

                #expect(test.frameIndex == base.frameIndex, "Partition \(name) frameIndex mismatch at [\(i)]")
                #expect(test.sampleIndex == base.sampleIndex, "Partition \(name) sampleIndex mismatch at [\(i)]")
                #expect(test.timeMs == base.timeMs, "Partition \(name) timeMs mismatch at [\(i)]")
                #expect(test.workletTimeMs == base.workletTimeMs, "Partition \(name) workletTimeMs mismatch at [\(i)]")
                #expect(test.rms == base.rms, "Partition \(name) rms mismatch at [\(i)]")

                // Bit-identical samples!
                for s in 0..<4096 {
                    #expect(test.samples[s] == base.samples[s], "Partition \(name) sample [\(s)] mismatch at frame [\(i)]")
                }
            }
        }
    }

    // MARK: - 4. Sample Clock vs Worklet Clock Conventions

    @Test("Clock conventions: sample clock vs worklet quantum at 44.1, 48, and 96 kHz")
    func clockConventionsAcrossSampleRates() {
        let rates: [Double] = [44100.0, 48000.0, 96000.0]

        for rate in rates {
            let framer = FaithfulCaptureFraming(sampleRate: rate, bufferCapacity: 16384)
            let dummy = [Float](repeating: 0.05, count: 8192)
            let windows = framer.process(channel: dummy)

            let expectedWorkletOffsetMs = (128.0 / rate) * 1000.0

            for win in windows {
                let expectedTimeMs = (Double(win.sampleIndex) / rate) * 1000.0
                let expectedWorkletMs = (Double(win.sampleIndex - 128) / rate) * 1000.0

                #expect(abs(win.timeMs - expectedTimeMs) < 1e-10)
                #expect(abs(win.workletTimeMs - expectedWorkletMs) < 1e-10)
                #expect(abs((win.timeMs - win.workletTimeMs) - expectedWorkletOffsetMs) < 1e-10)
            }
        }
    }

    @Test("Host monotonic time: interpolated to window trailing edge and kept distinct from sample clock")
    func hostMonotonicTimeInterpolation() {
        let framer = FaithfulCaptureFraming(sampleRate: 44100.0, bufferCapacity: 16384)

        // Chunk of 4096 samples ending at hostTime = 100.0 seconds
        let chunk1 = [Float](repeating: 0.1, count: 4096)
        let win1 = framer.process(channel: chunk1, hostTime: 100.0)
        #expect(win1.count == 1)
        // Window ends at sample 4096 which is the end of the chunk -> hostTime must be exactly 100.0
        #expect(win1[0].hostTime == 100.0)

        // Chunk of 2048 samples ending at hostTime = 100.0 + (2048 / 44100)
        let chunk2 = [Float](repeating: 0.1, count: 2048)
        let hostTime2 = 100.0 + (2048.0 / 44100.0)
        let win2 = framer.process(channel: chunk2, hostTime: hostTime2)
        #expect(win2.count == 2)

        // win2[0] ends at sample 5120. Delta from chunk2 end (6144) is 1024 samples.
        let expectedHostTimeFrame1 = hostTime2 - (1024.0 / 44100.0)
        #expect(abs((win2[0].hostTime ?? 0) - expectedHostTimeFrame1) < 1e-9)

        // win2[1] ends at sample 6144 (end of chunk2)
        #expect(abs((win2[1].hostTime ?? 0) - hostTime2) < 1e-9)
    }

    // MARK: - 5. Route / Rate Changes, Resets & Generation Tracking

    @Test("Explicit reset, route change, and rate change increment generation and flush buffer")
    func resetsAndGenerations() {
        let framer = FaithfulCaptureFraming(sampleRate: 44100.0, bufferCapacity: 16384, initialGeneration: 1)
        #expect(framer.generation == 1)
        #expect(framer.discontinuityCount == 0)

        // Feed 2048 samples into generation 1
        let w1 = framer.process(channel: [Float](repeating: 0.1, count: 2048))
        #expect(w1.isEmpty)
        #expect(framer.bufferedSampleCount == 2048)

        // 1. Explicit reset
        framer.reset()
        #expect(framer.generation == 2)
        #expect(framer.discontinuityCount == 1)
        #expect(framer.hasDiscontinuity)
        #expect(framer.lastDiscontinuityReason == .explicitReset)
        #expect(framer.bufferedSampleCount == 0)
        #expect(framer.sampleIndex == 0)
        #expect(framer.frameIndex == 0)

        let consumed = framer.consumeDiscontinuity()
        #expect(consumed == .explicitReset)
        #expect(!framer.hasDiscontinuity)

        // Feeding 2048 samples into gen 2 must NOT emit a window (proves gen 1 samples did not leak!)
        let w2 = framer.process(channel: [Float](repeating: 0.1, count: 2048))
        #expect(w2.isEmpty)
        #expect(framer.bufferedSampleCount == 2048)

        // Feed another 2048 samples (total 4096 in gen 2) -> 1st window of gen 2
        let w3 = framer.process(channel: [Float](repeating: 0.1, count: 2048))
        #expect(w3.count == 1)
        #expect(w3[0].generation == 2)
        #expect(w3[0].frameIndex == 0)
        #expect(w3[0].sampleIndex == 4096)

        // 2. Route change
        framer.routeChanged()
        #expect(framer.generation == 3)
        #expect(framer.discontinuityCount == 2)
        #expect(framer.lastDiscontinuityReason == .routeChange)
        #expect(framer.bufferedSampleCount == 0)

        // 3. Rate change
        framer.setSampleRate(48000.0)
        #expect(framer.generation == 4)
        #expect(framer.sampleRate == 48000.0)
        #expect(framer.discontinuityCount == 3)
        #expect(framer.lastDiscontinuityReason == .rateChange)

        // Setting same rate must NOT reset or increment generation
        framer.setSampleRate(48000.0)
        #expect(framer.generation == 4)
        #expect(framer.discontinuityCount == 3)
    }

    // MARK: - 6. Bounded Transport & Overload Detection

    @Test("Bounded transport: buffer exhaustion marks overload, increments generation, and resets safely")
    func boundedTransportOverloadDetection() {
        let framer = FaithfulCaptureFraming(sampleRate: 44100.0, bufferCapacity: 8192, initialGeneration: 1)

        // Feed 3072 samples (no frame emitted yet, 3072 samples buffered)
        let w1 = framer.process(channel: [Float](repeating: 0.1, count: 3072))
        #expect(w1.isEmpty)
        #expect(framer.bufferedSampleCount == 3072)
        #expect(framer.generation == 1)

        // Feed 6000 samples: 3072 + 6000 = 9072 > bufferCapacity (8192) -> OVERLOAD!
        let w2 = framer.process(channel: [Float](repeating: 0.1, count: 6000))
        #expect(w2.isEmpty) // Corrupted overload chunk is dropped
        #expect(framer.generation == 2)
        #expect(framer.hasDiscontinuity)
        #expect(framer.lastDiscontinuityReason == .overload)
        #expect(framer.discontinuityCount == 1)
        #expect(framer.bufferedSampleCount == 0) // Buffer flushed

        // Subsequent valid audio starts clean in generation 2
        let w3 = framer.process(channel: [Float](repeating: 0.2, count: 4096))
        #expect(w3.count == 1)
        #expect(w3[0].generation == 2)
        #expect(w3[0].frameIndex == 0)
        #expect(w3[0].sampleIndex == 4096)
    }

    // MARK: - 7. Worklet Golden Trace Agreement

    @Test("Golden worklet trace agreement: compare framed sampleIndex, timestamps, and RMS to frozen trace")
    func goldenTraceFramingAgreement() throws {
        // 1. Test vector-silence-zeros-44100 where golden.detector.rms is exactly raw frame RMS (0.0)
        let zerosTrace = try ParityTrace.load(at: "traces/targeted/vector-silence-zeros-44100.json")
        let zerosAudio = [Float](repeating: 0.0, count: zerosTrace.sampleCount)
        let zerosFrames = FaithfulCaptureFraming.frameOffline(samples: zerosAudio, sampleRate: zerosTrace.sampleRate)

        #expect(zerosFrames.count == zerosTrace.frameCount)
        for i in 0..<zerosTrace.frameCount {
            let golden = zerosTrace.frames[i]
            let actual = zerosFrames[i]
            #expect(actual.frameIndex == golden.frameIndex)
            #expect(actual.sampleIndex == golden.sampleIndex)
            #expect(abs(actual.timeMs - golden.timeMs) < 1e-6)
            #expect(abs(actual.workletTimeMs - golden.workletTimeMs) < 1e-6)
            #expect(actual.rms == 0.0)
            #expect(golden.detector.rms == 0.0)
        }

        // 2. Test vector-rate-44100-A4 golden trace across different chunk partitions
        let trace = try ParityTrace.load(at: "traces/targeted/vector-rate-44100-A4.json")
        let sampleRate = trace.sampleRate
        let sampleCount = trace.sampleCount

        // Synthesize the 440 Hz test tone matching the golden trace definition in corpus.ts
        var audio = [Float](repeating: 0.0, count: sampleCount)
        for i in 0..<sampleCount {
            audio[i] = Float(0.1 * sin(2.0 * Double.pi * 440.0 * Double(i) / sampleRate))
        }

        let partitions = [128, 512, 1024, 441]

        for chunkSize in partitions {
            let framer = FaithfulCaptureFraming(sampleRate: sampleRate, bufferCapacity: 32768)
            var frames: [FaithfulCaptureWindow] = []
            var offset = 0
            while offset < sampleCount {
                let count = min(chunkSize, sampleCount - offset)
                let chunk = Array(audio[offset..<offset + count])
                let w = framer.process(channel: chunk)
                frames.append(contentsOf: w)
                offset += count
            }

            #expect(frames.count == trace.frameCount, "Chunk size \(chunkSize) frame count mismatch")

            for i in 0..<trace.frameCount {
                let golden = trace.frames[i]
                let actual = frames[i]

                #expect(actual.frameIndex == golden.frameIndex)
                #expect(actual.sampleIndex == golden.sampleIndex)
                #expect(abs(actual.timeMs - golden.timeMs) < 1e-6)
                #expect(abs(actual.workletTimeMs - golden.workletTimeMs) < 1e-6)

                // Verify raw frame RMS formula: sqrt(sum(x^2) / 4096)
                var expectedEnergy = 0.0
                for s in actual.samples {
                    let d = Double(s)
                    expectedEnergy += d * d
                }
                let expectedRms = sqrt(expectedEnergy / 4096.0)
                #expect(abs(actual.rms - expectedRms) < 1e-12)
            }
        }
    }
}
