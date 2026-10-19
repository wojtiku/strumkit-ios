// StrumKit/Algorithm/FaithfulCaptureFraming.swift
import Foundation

// MARK: - Framing Discontinuity

/// Cause of a capture stream reset or discontinuity.
public enum FramingDiscontinuity: String, Sendable, Codable, Equatable {
    case overload
    case routeChange
    case rateChange
    case explicitReset
}

// MARK: - Faithful Capture Window

/// A strictly-framed 4096-sample audio window emitted on a 1024-sample hop.
///
/// Timestamps strictly follow the test-tuner parity contract:
/// - `sampleIndex`: accumulated sample count at the window's trailing edge.
/// - `timeMs`: window-end timestamp: `Double(sampleIndex) / sampleRate * 1000.0`.
/// - `workletTimeMs`: worklet render quantum timestamp: `Double(sampleIndex - 128) / sampleRate * 1000.0`.
/// - `hostTime`: monotonic host time of the trailing edge (if provided by capture).
/// - `rms`: raw frame RMS: `sqrt(sum(x^2) / 4096.0)`.
public struct FaithfulCaptureWindow: Sendable, Equatable {
    public let frameIndex: Int
    public let sampleIndex: Int
    public let timeMs: Double
    public let workletTimeMs: Double
    public let hostTime: TimeInterval?
    public let rms: Double
    public let samples: [Float]
    public let sampleRate: Double
    public let generation: Int

    public init(
        frameIndex: Int,
        sampleIndex: Int,
        timeMs: Double,
        workletTimeMs: Double,
        hostTime: TimeInterval?,
        rms: Double,
        samples: [Float],
        sampleRate: Double,
        generation: Int
    ) {
        self.frameIndex = frameIndex
        self.sampleIndex = sampleIndex
        self.timeMs = timeMs
        self.workletTimeMs = workletTimeMs
        self.hostTime = hostTime
        self.rms = rms
        self.samples = samples
        self.sampleRate = sampleRate
        self.generation = generation
    }
}

// MARK: - Faithful Capture Framing

/// Reblocks native audio capture callbacks of arbitrary buffer sizes into exact
/// 4096-sample analysis windows on 1024-sample hops, faithfully implementing
/// the sample-clock and worklet-quantum timing conventions of `audio-worklet.ts`.
///
/// Features:
/// - Sample-wise channel averaging across all available channels (`sum / channels.count`).
/// - Strict 4096-sample initial wait: no frames are emitted before sample 4096.
/// - Exact 1024-sample hop cadence regardless of input callback partitioning (128, 256, 512, 1024, or irregular).
/// - Sample-clock timestamps:
///   - `sampleIndex` at window end.
///   - `timeMs = Double(sampleIndex) / sampleRate * 1000.0`.
///   - `workletTimeMs = Double(sampleIndex - 128) / sampleRate * 1000.0`.
///   - Linearly interpolated host monotonic time at trailing edge.
///   - Raw frame RMS: `sqrt(sum(x^2) / 4096.0)`.
/// - Discontinuity, overload, route/rate change handling:
///   - Generation ID tracking.
///   - Bounded transport capacity (`bufferCapacity`).
///   - Overload triggers explicit discontinuity, increments generation, flushes buffer,
///     and invalidates in-flight state without silently dropping hops.
public final class FaithfulCaptureFraming: @unchecked Sendable {
    public static let windowSize: Int = 4096
    public static let hopSize: Int = 1024
    public static let workletQuantum: Int = 128

    public private(set) var sampleRate: Double
    public let bufferCapacity: Int
    public private(set) var generation: Int

    // Stream state
    public private(set) var sampleIndex: Int = 0         // Total accumulated samples in current generation
    public private(set) var frameIndex: Int = 0          // Number of frames emitted in current generation
    public private(set) var filled: Int = 0              // Accumulated samples towards initial window (tracks total samples)
    public private(set) var sinceLast: Int = 0           // Samples accumulated since last hop emission
    public private(set) var bufferedSampleCount: Int = 0 // Currently unconsumed samples in buffer

    // Discontinuity state
    public private(set) var discontinuityCount: Int = 0
    public private(set) var hasDiscontinuity: Bool = false
    public private(set) var lastDiscontinuityReason: FramingDiscontinuity? = nil

    // Circular ring buffer
    private var buffer: [Float]
    private var head: Int = 0 // write pointer
    private var tail: Int = 0 // read pointer

    // Internal lock for safe cross-thread capture and diagnostics access
    private let lock = NSLock()

    public init(
        sampleRate: Double = 44100.0,
        bufferCapacity: Int = 16384,
        initialGeneration: Int = 1
    ) {
        precondition(bufferCapacity >= Self.windowSize, "bufferCapacity must be at least windowSize (4096)")
        self.sampleRate = sampleRate
        self.bufferCapacity = bufferCapacity
        self.generation = initialGeneration
        self.buffer = [Float](repeating: 0.0, count: bufferCapacity)
    }

    // MARK: - Ingestion / Processing

    /// Processes a single channel of Float32 audio samples.
    public func process(channel: [Float], hostTime: TimeInterval? = nil) -> [FaithfulCaptureWindow] {
        guard !channel.isEmpty else { return [] }
        return channel.withUnsafeBufferPointer { bp in
            let ptr = bp.baseAddress!
            return process(channelPointers: [ptr], channelCount: 1, frameCount: channel.count, hostTime: hostTime)
        }
    }

    /// Processes multiple channels of Float32 audio samples with sample-wise channel averaging.
    public func process(channels: [[Float]], hostTime: TimeInterval? = nil) -> [FaithfulCaptureWindow] {
        guard !channels.isEmpty, !channels[0].isEmpty else { return [] }
        let frameCount = channels[0].count
        for ch in channels {
            guard ch.count == frameCount else { return [] }
        }
        return withPointers(arrays: channels) { pointers in
            process(channelPointers: pointers, channelCount: channels.count, frameCount: frameCount, hostTime: hostTime)
        }
    }

    /// Real-time safe processing entry point for `AVAudioEngine` tap buffers.
    public func process(
        channelData: UnsafePointer<UnsafeMutablePointer<Float>>,
        channelCount: Int,
        frameCount: Int,
        hostTime: TimeInterval? = nil
    ) -> [FaithfulCaptureWindow] {
        guard channelCount > 0, frameCount > 0 else { return [] }
        var pointers: [UnsafePointer<Float>] = []
        pointers.reserveCapacity(channelCount)
        for i in 0..<channelCount {
            pointers.append(UnsafePointer(channelData[i]))
        }
        return process(channelPointers: pointers, channelCount: channelCount, frameCount: frameCount, hostTime: hostTime)
    }

    /// Core processing method accepting raw channel pointers.
    public func process(
        channelPointers: [UnsafePointer<Float>],
        channelCount: Int,
        frameCount: Int,
        hostTime: TimeInterval? = nil
    ) -> [FaithfulCaptureWindow] {
        guard channelCount > 0, frameCount > 0 else { return [] }

        lock.lock()
        defer { lock.unlock() }

        // Bounded capacity check: if appending would exceed transport bufferCapacity,
        // mark discontinuity, increment generation, and flush buffer rather than silently dropping hops.
        if bufferedSampleCount + frameCount > bufferCapacity {
            performReset(reason: .overload)
            return []
        }

        // 1. Ingest & average channels sample-wise
        if channelCount == 1 {
            let src = channelPointers[0]
            let firstPart = min(frameCount, bufferCapacity - head)
            buffer.withUnsafeMutableBufferPointer { dst in
                let base = dst.baseAddress!
                (base + head).assign(from: src, count: firstPart)
                let secondPart = frameCount - firstPart
                if secondPart > 0 {
                    base.assign(from: src + firstPart, count: secondPart)
                }
            }
            head = (head + frameCount) % bufferCapacity
            bufferedSampleCount += frameCount
        } else {
            let invChannels = 1.0 / Float(channelCount)
            for i in 0..<frameCount {
                var sum: Float = 0.0
                for c in 0..<channelCount {
                    sum += channelPointers[c][i]
                }
                buffer[head] = sum * invChannels
                head = (head + 1) % bufferCapacity
            }
            bufferedSampleCount += frameCount
        }

        let chunkEndSample = self.sampleIndex + frameCount
        self.sampleIndex = chunkEndSample
        self.filled = self.sampleIndex

        // 2. Emit complete 4096-sample windows every 1024 samples
        var emittedWindows: [FaithfulCaptureWindow] = []

        while bufferedSampleCount >= Self.windowSize {
            // Copy 4096 samples from ring buffer starting at tail
            var windowSamples = [Float](repeating: 0.0, count: Self.windowSize)
            windowSamples.withUnsafeMutableBufferPointer { outBp in
                let outPtr = outBp.baseAddress!
                let firstPart = min(Self.windowSize, bufferCapacity - tail)
                buffer.withUnsafeBufferPointer { bufBp in
                    let bufPtr = bufBp.baseAddress!
                    outPtr.assign(from: bufPtr + tail, count: firstPart)
                    let secondPart = Self.windowSize - firstPart
                    if secondPart > 0 {
                        (outPtr + firstPart).assign(from: bufPtr, count: secondPart)
                    }
                }
            }

            // Window trailing-edge sample index and timestamps
            let winSampleIndex = Self.windowSize + frameIndex * Self.hopSize
            let timeMs = (Double(winSampleIndex) / sampleRate) * 1000.0
            let workletTimeMs = (Double(winSampleIndex - Self.workletQuantum) / sampleRate) * 1000.0

            // Interpolate host monotonic time if provided
            let frameHostTime: TimeInterval?
            if let hostTime = hostTime {
                let deltaSamples = chunkEndSample - winSampleIndex
                let deltaSec = Double(deltaSamples) / sampleRate
                frameHostTime = hostTime - deltaSec
            } else {
                frameHostTime = nil
            }

            // Raw frame RMS
            var energy: Double = 0.0
            for s in windowSamples {
                let d = Double(s)
                energy += d * d
            }
            let rms = sqrt(energy / Double(Self.windowSize))

            let window = FaithfulCaptureWindow(
                frameIndex: frameIndex,
                sampleIndex: winSampleIndex,
                timeMs: timeMs,
                workletTimeMs: workletTimeMs,
                hostTime: frameHostTime,
                rms: rms,
                samples: windowSamples,
                sampleRate: sampleRate,
                generation: generation
            )
            emittedWindows.append(window)

            // Advance by hop size (1024 samples)
            tail = (tail + Self.hopSize) % bufferCapacity
            bufferedSampleCount -= Self.hopSize
            frameIndex += 1
        }

        // Update sinceLast
        if sampleIndex < Self.windowSize {
            sinceLast = sampleIndex
        } else {
            sinceLast = (sampleIndex - Self.windowSize) % Self.hopSize
        }

        return emittedWindows
    }

    // MARK: - Resets & Discontinuity

    /// Explicitly resets framing state, flushes buffered samples, and increments generation.
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        performReset(reason: .explicitReset)
    }

    /// Triggers an explicit reset due to an audio route change.
    public func routeChanged() {
        lock.lock()
        defer { lock.unlock() }
        performReset(reason: .routeChange)
    }

    /// Updates the sample rate. If different from current rate, triggers an explicit rate-change reset.
    public func setSampleRate(_ newRate: Double) {
        lock.lock()
        defer { lock.unlock() }
        guard newRate > 0 else { return }
        if newRate != sampleRate {
            sampleRate = newRate
            performReset(reason: .rateChange)
        }
    }

    /// Consumes and clears the current discontinuity flag and reason.
    public func consumeDiscontinuity() -> FramingDiscontinuity? {
        lock.lock()
        defer { lock.unlock() }
        guard hasDiscontinuity else { return nil }
        hasDiscontinuity = false
        let reason = lastDiscontinuityReason
        lastDiscontinuityReason = nil
        return reason
    }

    private func performReset(reason: FramingDiscontinuity) {
        generation += 1
        discontinuityCount += 1
        hasDiscontinuity = true
        lastDiscontinuityReason = reason
        head = 0
        tail = 0
        bufferedSampleCount = 0
        sampleIndex = 0
        frameIndex = 0
        filled = 0
        sinceLast = 0
        buffer.withUnsafeMutableBufferPointer { bp in
            guard let base = bp.baseAddress else { return }
            base.initialize(repeating: 0.0, count: bp.count)
        }
    }

    // MARK: - Offline Utility

    /// Frames an entire audio sequence with unbounded capacity for offline replay and test fixtures.
    public static func frameOffline(
        samples: [Float],
        sampleRate: Double
    ) -> [FaithfulCaptureWindow] {
        let capacity = max(16384, samples.count + 4096)
        let framer = FaithfulCaptureFraming(
            sampleRate: sampleRate,
            bufferCapacity: capacity,
            initialGeneration: 1
        )
        return framer.process(channel: samples)
    }
}

// MARK: - Helper Functions

private func withPointers<R>(arrays: [[Float]], _ body: ([UnsafePointer<Float>]) -> R) -> R {
    func helper(index: Int, accumulated: inout [UnsafePointer<Float>]) -> R {
        if index == arrays.count {
            return body(accumulated)
        }
        return arrays[index].withUnsafeBufferPointer { bp in
            accumulated.append(bp.baseAddress!)
            defer { accumulated.removeLast() }
            return helper(index: index + 1, accumulated: &accumulated)
        }
    }
    var acc: [UnsafePointer<Float>] = []
    acc.reserveCapacity(arrays.count)
    return helper(index: 0, accumulated: &acc)
}
