import AVFoundation
import Foundation

/// The live microphone: `AVAudioEngine` behind the `MicrophoneSource` seam.
///
/// Three things happen here and nowhere else. How audio is taken from the engine is
/// *this* type's decision rather than something a caller has to know, AVFoundation's two
/// separate notification callbacks become one event type, and captured audio
/// becomes one typed window rather than a positional closure. Everything
/// device-specific underneath — the `AVAudioSession` configuration, the ring
/// buffer, the capture-edge clock — is a collaborator this file names and a
/// caller cannot, in `AudioSessionConfiguration` and `AudioRingBuffer`.
final class AVAudioEngineMicrophone: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var sink: AVAudioSinkNode?
    private var relay: CaptureRelay?
    private var isRunningInternal = false
    private let queue = DispatchQueue(label: "com.strumkit.audiocapture", qos: .userInteractive)

    /// The hardware's rate, which satisfies the seam's requirement and is not
    /// knowable until capture has started.
    private(set) var sampleRate: Double = 44100.0
    private let sessionConfiguration = AudioSessionConfiguration()

    private let eventLock = NSLock()
    private var _onEvent: (@Sendable (MicrophoneEvent) -> Void)?

    init() {}
}

extension AVAudioEngineMicrophone: MicrophoneSource {
    var onEvent: (@Sendable (MicrophoneEvent) -> Void)? {
        get {
            eventLock.lock()
            defer { eventLock.unlock() }
            return _onEvent
        }
        set {
            eventLock.lock()
            _onEvent = newValue
            eventLock.unlock()

            // The session configuration reports the raw notifications; the seam
            // reports what the tuner has to absorb. An interruption beginning and
            // one ending are the same fact with different answers to "may I
            // resume?".
            sessionConfiguration.onInterruption = { [weak self] began, shouldResume in
                self?.emit(.interrupted(resumable: !began && shouldResume))
            }
            sessionConfiguration.onRouteChange = { [weak self] _ in
                self?.emit(.routeChanged)
            }
        }
    }

    var permissionStatus: AudioPermissionStatus { checkPermissionStatus() }

    func requestPermission() async -> Bool {
        await requestMicrophonePermission()
    }

    /// Checks current microphone recording authorization status.
    private func checkPermissionStatus() -> AudioPermissionStatus {
        if #available(iOS 17.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted: return .authorized
            case .denied: return .denied
            case .undetermined: return .notDetermined
            @unknown default: return .denied
            }
        } else {
            switch AVAudioSession.sharedInstance().recordPermission {
            case .granted: return .authorized
            case .denied: return .denied
            case .undetermined: return .notDetermined
            @unknown default: return .denied
            }
        }
    }

    /// Requests recording permission asynchronously.
    private func requestMicrophonePermission() async -> Bool {
        if #available(iOS 17.0, *) {
            return await AVAudioApplication.requestRecordPermission()
        } else {
            return await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    /// Starts capturing audio, delivering each window as a `CapturedWindow`.
    ///
    /// Audio is taken from a sink node, not a tap. A tap hands over a tenth of a second
    /// at a time whatever size it is asked for, so everything downstream ran in bursts
    /// ten times a second and a tenth of a second late. A sink node is called once per
    /// hardware buffer — about a hundredth of a second — on the audio thread itself.
    ///
    /// That thread must not wait on anything, so all it does is copy the samples into a
    /// ring and wake the delivery thread, which does the allocating and the calling.
    func start(delivering: @escaping @Sendable (CapturedWindow) -> Void) throws {
        try queue.sync {
            guard !self.isRunningInternal else { return }

            try self.sessionConfiguration.activate()

            let inputNode = self.engine.inputNode
            let inputFormat = inputNode.outputFormat(forBus: 0)

            guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
                print("[StrumKit] Audio input format has 0 channels.")
                throw AudioCaptureError.noInputChannelsAvailable
            }

            let rate = inputFormat.sampleRate
            self.sampleRate = rate

            let relay = CaptureRelay(sampleRate: rate, deliver: delivering)
            let sink = AVAudioSinkNode { timestamp, frameCount, audioBufferList in
                relay.write(audioBufferList, frames: Int(frameCount), hostTime: timestamp.pointee.mHostTime)
                return noErr
            }

            self.detachSink()
            self.engine.attach(sink)
            self.engine.connect(inputNode, to: sink, format: inputFormat)
            self.sink = sink
            self.relay = relay

            do {
                self.engine.prepare()
                try self.engine.start()
                relay.start()
                self.isRunningInternal = true
            } catch {
                print("[StrumKit] Failed to start AVAudioEngine: \(error.localizedDescription)")
                self.detachSink()
                throw AudioCaptureError.engineFailed(error.localizedDescription)
            }
        }
    }

    private func detachSink() {
        relay?.stop()
        relay = nil
        if let sink {
            engine.disconnectNodeInput(sink)
            engine.detach(sink)
        }
        sink = nil
    }

    /// Stops audio capture and removes the sink.
    ///
    /// The session's observers deliberately outlive the tap — see
    /// `AudioSessionConfiguration`, which is where the reasoning lives. Unhooking
    /// them here would mean the notification that invites a resume had nowhere to
    /// go, because stopping the tap is what the interruption caused.
    func stop() {
        queue.sync {
            guard self.isRunningInternal else { return }
            self.engine.stop()
            self.detachSink()
            self.isRunningInternal = false

            self.sessionConfiguration.deactivate()
        }
    }

    private func emit(_ event: MicrophoneEvent) {
        eventLock.lock()
        let sink = _onEvent
        eventLock.unlock()
        sink?(event)
    }
}

/// Carries captured audio from the audio thread to a thread that may allocate.
///
/// The audio thread writes into a fixed ring under a lock held for one `memcpy` and
/// signals; the delivery thread wakes, takes whatever has arrived, and hands it on as
/// a `CapturedWindow` stamped with the host time of its last sample.
private final class CaptureRelay: @unchecked Sendable {
    private let sampleRate: Double
    private let deliver: @Sendable (CapturedWindow) -> Void

    private var guardLock = os_unfair_lock()
    private var ring: [Float]
    private var readIndex = 0
    private var available = 0
    /// Host time, in seconds, of the last sample written.
    private var lastEnd: TimeInterval = 0
    private var overruns = 0
    private var running = false

    private let wake = DispatchSemaphore(value: 0)
    private let thread = DispatchQueue(label: "com.strumkit.audiocapture.delivery", qos: .userInteractive)
    private var reportedCadence = false

    init(sampleRate: Double, deliver: @escaping @Sendable (CapturedWindow) -> Void) {
        self.sampleRate = sampleRate
        self.deliver = deliver
        // Two seconds: far more than the delivery thread can fall behind without the
        // session declaring the stream lost anyway.
        self.ring = [Float](repeating: 0, count: Int(sampleRate * 2))
    }

    func start() {
        os_unfair_lock_lock(&guardLock)
        running = true
        os_unfair_lock_unlock(&guardLock)
        thread.async { [self] in
            while isRunning {
                _ = wake.wait(timeout: .now() + .milliseconds(100))
                drain()
            }
        }
    }

    func stop() {
        os_unfair_lock_lock(&guardLock)
        running = false
        os_unfair_lock_unlock(&guardLock)
        wake.signal()
    }

    private var isRunning: Bool {
        os_unfair_lock_lock(&guardLock)
        defer { os_unfair_lock_unlock(&guardLock) }
        return running
    }

    /// Audio thread. No allocation, no waiting beyond one uncontended lock.
    func write(_ list: UnsafePointer<AudioBufferList>, frames: Int, hostTime: UInt64) {
        guard frames > 0 else { return }
        let buffers = UnsafeBufferPointer<AudioBuffer>(
            start: UnsafeRawPointer(list).advanced(by: MemoryLayout<AudioBufferList>.offset(of: \AudioBufferList.mBuffers)!)
                .assumingMemoryBound(to: AudioBuffer.self),
            count: Int(list.pointee.mNumberBuffers))
        guard let first = buffers.first, first.mData != nil else { return }
        let channelsInFirst = max(1, Int(first.mNumberChannels))
        guard Int(first.mDataByteSize) >= frames * channelsInFirst * MemoryLayout<Float>.size else { return }

        let start = hostTime > 0 ? AVAudioTime.seconds(forHostTime: hostTime) : CACurrentMediaTime()
        let end = start + Double(frames) / sampleRate
        let capacity = ring.count

        os_unfair_lock_lock(&guardLock)
        if available + frames > capacity {
            // The delivery thread has stalled for two seconds. Start again from now.
            available = 0
            readIndex = 0
            overruns += 1
        }
        var writeIndex = (readIndex + available) % capacity
        ring.withUnsafeMutableBufferPointer { out in
            // Average every channel, as the parity contract's channel policy does.
            let scale = 1.0 / Float(buffers.count * channelsInFirst)
            for frame in 0..<frames {
                var sum: Float = 0
                for buffer in buffers {
                    guard let data = buffer.mData else { continue }
                    let samples = data.assumingMemoryBound(to: Float.self)
                    let channels = max(1, Int(buffer.mNumberChannels))
                    for channel in 0..<channels { sum += samples[frame * channels + channel] }
                }
                out[writeIndex] = sum * scale
                writeIndex += 1
                if writeIndex == capacity { writeIndex = 0 }
            }
        }
        available += frames
        lastEnd = end
        os_unfair_lock_unlock(&guardLock)

        wake.signal()
    }

    /// Delivery thread.
    private func drain() {
        os_unfair_lock_lock(&guardLock)
        let count = available
        guard count > 0 else {
            os_unfair_lock_unlock(&guardLock)
            return
        }
        var samples = [Float](repeating: 0, count: count)
        let capacity = ring.count
        let from = readIndex
        ring.withUnsafeBufferPointer { source in
            samples.withUnsafeMutableBufferPointer { out in
                let firstPart = min(count, capacity - from)
                out.baseAddress!.update(from: source.baseAddress! + from, count: firstPart)
                if firstPart < count {
                    (out.baseAddress! + firstPart).update(from: source.baseAddress!, count: count - firstPart)
                }
            }
        }
        readIndex = (from + count) % capacity
        available = 0
        let end = lastEnd
        os_unfair_lock_unlock(&guardLock)

        if !reportedCadence {
            reportedCadence = true
            print("[StrumKit] capture: \(count) frames per delivery at \(Int(sampleRate)) Hz")
        }
        deliver(CapturedWindow(samples: samples, sampleRate: sampleRate, captureEnd: end))
    }
}
