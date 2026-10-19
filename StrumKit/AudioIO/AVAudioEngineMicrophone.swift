import AVFoundation
import Foundation

/// The live microphone: `AVAudioEngine` behind the `MicrophoneSource` seam.
///
/// Three things happen here and nowhere else. The tap size is *this* type's
/// decision rather than a parameter a caller has to know, AVFoundation's two
/// separate notification callbacks become one event type, and captured audio
/// becomes one typed window rather than a positional closure. Everything
/// device-specific underneath — the `AVAudioSession` configuration, the ring
/// buffer, the capture-edge clock — is a collaborator this file names and a
/// caller cannot, in `AudioSessionConfiguration` and `AudioRingBuffer`.
final class AVAudioEngineMicrophone: @unchecked Sendable {
    /// Frames the engine is asked for per callback.
    ///
    /// A request, not a guarantee: the OS may deliver larger buffers, and nothing
    /// above the seam can act on the difference. So it is not an argument.
    private static let tapBufferSize: AVAudioFrameCount = 1024

    private let engine = AVAudioEngine()
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
    /// The tap's own frame length is a fact about the real-time thread, not
    /// something the caller is given: nothing above the seam can use it, and the
    /// window's trailing-edge timestamp already carries what the analysis needs.
    func start(delivering: @escaping @Sendable (CapturedWindow) -> Void) throws {
        try queue.sync {
            guard !self.isRunningInternal else { return }

            try self.sessionConfiguration.activate()

            let inputNode = self.engine.inputNode
            let inputFormat = inputNode.inputFormat(forBus: 0)

            guard inputFormat.channelCount > 0 else {
                print("[StrumKit] Audio input format has 0 channels.")
                throw AudioCaptureError.noInputChannelsAvailable
            }

            self.sampleRate = inputFormat.sampleRate > 0 ? inputFormat.sampleRate : 44100.0

            inputNode.removeTap(onBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: Self.tapBufferSize, format: inputFormat) { buffer, when in
                guard let channelData = buffer.floatChannelData else { return }
                let frameLength = Int(buffer.frameLength)
                guard frameLength > 0 else { return }

                // Determine capture-end timestamp using AVAudioTime.
                // Denotes buffer trailing edge (end) on the monotonic host timeline (CACurrentMediaTime / mach_absolute_time).
                let captureEndSeconds: TimeInterval
                if when.isHostTimeValid && when.hostTime > 0 {
                    let startSeconds = AVAudioTime.seconds(forHostTime: when.hostTime)
                    captureEndSeconds = startSeconds + (Double(frameLength) / inputFormat.sampleRate)
                } else {
                    captureEndSeconds = CACurrentMediaTime()
                }

                let samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))
                delivering(CapturedWindow(
                    samples: samples,
                    sampleRate: inputFormat.sampleRate,
                    captureEnd: captureEndSeconds
                ))
            }

            do {
                self.engine.prepare()
                try self.engine.start()
                self.isRunningInternal = true
            } catch {
                print("[StrumKit] Failed to start AVAudioEngine: \(error.localizedDescription)")
                inputNode.removeTap(onBus: 0)
                throw AudioCaptureError.engineFailed(error.localizedDescription)
            }
        }
    }

    /// Stops audio capture and removes the tap.
    ///
    /// The session's observers deliberately outlive the tap — see
    /// `AudioSessionConfiguration`, which is where the reasoning lives. Unhooking
    /// them here would mean the notification that invites a resume had nowhere to
    /// go, because stopping the tap is what the interruption caused.
    func stop() {
        queue.sync {
            guard self.isRunningInternal else { return }
            self.engine.inputNode.removeTap(onBus: 0)
            self.engine.stop()
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
