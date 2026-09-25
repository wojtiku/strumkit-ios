import AVFoundation
import Foundation

/// Service responsible for configuring AVAudioSession and capturing microphone buffers via AVAudioEngine.
public final class AudioCaptureService: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var isRunningInternal = false
    private let queue = DispatchQueue(label: "com.strumkit.audiocapture", qos: .userInteractive)

    public private(set) var sampleRate: Double = 44100.0
    private var ringBuffer: AudioRingBuffer? = nil

    public init() {}

    /// Calculates required trailing sample count for the polyphase sinc resampler.
    public static func requiredInputSamples(for sampleRate: Double) -> Int {
        if sampleRate <= Resampler.analysisRate {
            return Resampler.windowSize
        }
        let ratio = sampleRate / Resampler.analysisRate
        return Int(ceil(Double(2 * Resampler.resamplerRadius + 1) + Double(Resampler.windowSize - 1) * ratio))
    }

    /// Checks current microphone recording authorization status.
    public func checkPermissionStatus() -> AudioPermissionStatus {
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
    public func requestPermission() async -> Bool {
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

    /// Starts capturing audio, streaming PCM float samples via the buffer handler.
    /// - Parameters:
    ///   - bufferSize: Requested tap buffer size (e.g., 2048 samples).
    ///   - onBufferReceived: Closure invoked on background queue with array of Float PCM samples.
    public func startCapture(
        bufferSize: AVAudioFrameCount = 2048,
        onBufferReceived: @escaping @Sendable ([Float], Double) -> Void
    ) throws {
        queue.sync {
            guard !self.isRunningInternal else { return }

            #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            do {
                // Measurement mode disables Apple's auto-gain-control (AGC) and high-pass voice filters,
                // preserving low-frequency guitar harmonics (e.g., E2 82Hz).
                try session.setCategory(
                    .playAndRecord,
                    mode: .measurement,
                    options: [.defaultToSpeaker, .allowBluetoothHFP, .mixWithOthers]
                )
                try session.setPreferredIOBufferDuration(Double(bufferSize) / 44100.0)

                // 1. Hardware Microphone Directionality: Cardioid pattern rejects off-axis room noise
                if let inputs = session.availableInputs,
                   let builtInMic = inputs.first(where: { $0.portType == .builtInMic }) {
                    if let dataSources = builtInMic.dataSources {
                        for source in dataSources {
                            if let supportedPatterns = source.supportedPolarPatterns,
                               supportedPatterns.contains(.cardioid) {
                                try? source.setPreferredPolarPattern(.cardioid)
                            }
                        }
                    }
                }

                // 2. Hardware Input Gain (if supported on active interface/headset)
                if session.isInputGainSettable {
                    try? session.setInputGain(1.0)
                }

                try session.setActive(true, options: .notifyOthersOnDeactivation)
            } catch {
                print("[StrumKit] AVAudioSession setup warning: \(error.localizedDescription)")
            }
            #endif

            let inputNode = self.engine.inputNode
            let inputFormat = inputNode.inputFormat(forBus: 0)

            guard inputFormat.channelCount > 0 else {
                print("[StrumKit] Audio input format has 0 channels. (Simulator with no mic input)")
                return
            }

            self.sampleRate = inputFormat.sampleRate > 0 ? inputFormat.sampleRate : 44100.0
            let neededSamples = Self.requiredInputSamples(for: self.sampleRate)
            let ring = AudioRingBuffer(capacity: max(16384, neededSamples * 2))
            self.ringBuffer = ring

            inputNode.removeTap(onBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { buffer, _ in
                guard let channelData = buffer.floatChannelData else { return }
                let frameLength = Int(buffer.frameLength)
                guard frameLength > 0 else { return }

                // Read channel 0 samples
                let channelPointer = channelData[0]
                let samples = Array(UnsafeBufferPointer(start: channelPointer, count: frameLength))

                ring.write(samples)
                if let window = ring.readTrailing(count: neededSamples) {
                    onBufferReceived(window, inputFormat.sampleRate)
                } else if ring.availableCount >= 512 {
                    let partial = ring.readTrailing(count: ring.availableCount) ?? samples
                    onBufferReceived(partial, inputFormat.sampleRate)
                }
            }

            do {
                self.engine.prepare()
                try self.engine.start()
                self.isRunningInternal = true
            } catch {
                print("[StrumKit] Failed to start AVAudioEngine: \(error.localizedDescription)")
            }
        }
    }

    /// Stops audio capture and removes the tap.
    public func stopCapture() {
        queue.sync {
            guard self.isRunningInternal else { return }
            self.engine.inputNode.removeTap(onBus: 0)
            self.engine.stop()
            self.ringBuffer?.reset()
            self.ringBuffer = nil
            self.isRunningInternal = false

            #if os(iOS)
            do {
                try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            } catch {
                print("[StrumKit] Could not deactivate AVAudioSession: \(error.localizedDescription)")
            }
            #endif
        }
    }

    public var isCapturing: Bool {
        queue.sync { isRunningInternal }
    }
}

/// Rolling audio ring buffer that maintains trailing audio samples for windowed analysis.
public final class AudioRingBuffer: @unchecked Sendable {
    private var buffer: [Float]
    private var head = 0
    private var count = 0
    private let capacity: Int
    private let lock = NSLock()

    public init(capacity: Int = 16384) {
        self.capacity = capacity
        self.buffer = [Float](repeating: 0.0, count: capacity)
    }

    public var availableCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    public func write(_ samples: [Float]) {
        lock.lock()
        defer { lock.unlock() }
        for s in samples {
            buffer[head] = s
            head = (head + 1) % capacity
            if count < capacity { count += 1 }
        }
    }

    public func readTrailing(count requested: Int) -> [Float]? {
        lock.lock()
        defer { lock.unlock() }
        guard count >= requested else { return nil }
        var result = [Float](repeating: 0.0, count: requested)
        var readIdx = (head - requested + capacity) % capacity
        for i in 0..<requested {
            result[i] = buffer[readIdx]
            readIdx = (readIdx + 1) % capacity
        }
        return result
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        head = 0
        count = 0
        for i in 0..<capacity { buffer[i] = 0.0 }
    }
}
