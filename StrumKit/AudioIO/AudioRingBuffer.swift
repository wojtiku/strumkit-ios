import Foundation

/// Rolling audio ring buffer that maintains trailing audio samples for windowed analysis.
///
/// Generally useful, and real-time-safe: the capture tap runs on the audio engine's
/// real-time thread, so the hot path avoids heap allocation — samples are written
/// straight from the engine's channel pointer, and the trailing window is read into
/// a caller-supplied buffer under a single lock acquisition.
///
/// Behind the microphone seam. Nothing outside the audio edge needs to know how a
/// window of trailing audio is kept.
///
/// One deliberate exception, recorded rather than accommodated:
/// `PitchDetectionTests.testAudioRingBufferAccumulation` drives this type directly
/// through `@testable` instead of crossing the seam. It is testing accumulation
/// across writes — the ring buffer's own contract — which no seam test would
/// exercise, because the seam hands out `CapturedWindow`s and never shows its
/// bookkeeping. That is why the type is `internal` and not `private`.
final class AudioRingBuffer: @unchecked Sendable {
    private var buffer: [Float]
    private var head = 0
    private var count = 0
    private let capacity: Int
    private let lock = NSLock()

    init(capacity: Int = 16384) {
        self.capacity = capacity
        self.buffer = [Float](repeating: 0.0, count: capacity)
    }

    var availableCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    /// Appends samples read directly from the engine's channel buffer.
    ///
    /// Takes an unsafe pointer so the tap never materialises an intermediate
    /// `[Float]` for its own copy. That is a real-time constraint, not a
    /// convenience: this is called on the thread the engine delivers audio on, and
    /// an allocation there is a glitch the player hears.
    func write(unsafeBufferPointer source: UnsafePointer<Float>, count sourceCount: Int) {
        guard sourceCount > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        for i in 0..<sourceCount {
            buffer[head] = source[i]
            head = (head + 1) % capacity
            if count < capacity { count += 1 }
        }
    }

    /// Copies the trailing `requested` samples into `destination` and reports
    /// whether enough audio was available.
    ///
    /// - Returns: `false` when fewer than `requested` samples are buffered, leaving
    ///   `destination` untouched.
    @discardableResult
    func copyTrailing(count requested: Int, into destination: inout [Float]) -> Bool {
        precondition(requested <= destination.count)
        lock.lock()
        defer { lock.unlock() }
        guard count >= requested else { return false }
        destination.withUnsafeMutableBufferPointer { out in
            var readIdx = (head - requested + capacity) % capacity
            for i in 0..<requested {
                out[i] = buffer[readIdx]
                readIdx = (readIdx + 1) % capacity
            }
        }
        return true
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        head = 0
        count = 0
        for i in 0..<capacity { buffer[i] = 0.0 }
    }
}
