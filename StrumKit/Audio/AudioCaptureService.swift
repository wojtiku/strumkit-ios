import AVFoundation
import Foundation

/// Service responsible for configuring AVAudioSession and capturing microphone buffers via AVAudioEngine.
public final class AudioCaptureService: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var isRunningInternal = false
    private let queue = DispatchQueue(label: "com.strumkit.audiocapture", qos: .userInteractive)

    public private(set) var sampleRate: Double = 44100.0

    public init() {}

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

            inputNode.removeTap(onBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { buffer, _ in
                guard let channelData = buffer.floatChannelData else { return }
                let frameLength = Int(buffer.frameLength)
                guard frameLength > 0 else { return }

                // Read channel 0 samples
                let channelPointer = channelData[0]
                let samples = Array(UnsafeBufferPointer(start: channelPointer, count: frameLength))

                onBufferReceived(samples, inputFormat.sampleRate)
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
