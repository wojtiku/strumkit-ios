import AVFoundation
import Foundation

/// The live microphone: `AVAudioEngine` behind the `MicrophoneSource` seam.
///
/// Two things happen here and nowhere else. The tap size becomes *this* type's
/// decision rather than a parameter a caller has to know, and AVFoundation's two
/// separate notification callbacks become one event type. Everything device-specific
/// underneath — the `AVAudioSession` configuration, the ring buffer, the
/// capture-edge clock — stays behind the seam, where a caller cannot depend on it.
public final class AVAudioEngineMicrophone: @unchecked Sendable {
    private let capture: AudioCaptureService
    private let tapBufferSize: AVAudioFrameCount

    private let eventLock = NSLock()
    private var _onEvent: (@Sendable (MicrophoneEvent) -> Void)?

    public init(
        capture: AudioCaptureService = AudioCaptureService(),
        tapBufferSize: AVAudioFrameCount = 1024
    ) {
        self.capture = capture
        self.tapBufferSize = tapBufferSize
    }
}

extension AVAudioEngineMicrophone: MicrophoneSource {
    public var onEvent: (@Sendable (MicrophoneEvent) -> Void)? {
        get {
            eventLock.lock()
            defer { eventLock.unlock() }
            return _onEvent
        }
        set {
            eventLock.lock()
            _onEvent = newValue
            eventLock.unlock()

            // The capture service reports the raw notifications; the seam reports
            // what the tuner has to absorb. An interruption beginning and one ending
            // are the same fact with different answers to "may I resume?".
            capture.onInterruption = { [weak self] began, shouldResume in
                self?.emit(.interrupted(resumable: !began && shouldResume))
            }
            capture.onRouteChange = { [weak self] _ in
                self?.emit(.routeChanged)
            }
        }
    }

    public var sampleRate: Double { capture.sampleRate }

    public var permissionStatus: AudioPermissionStatus { capture.checkPermissionStatus() }

    public func requestPermission() async -> Bool {
        await capture.requestPermission()
    }

    public func start(delivering: @escaping @Sendable (CapturedWindow) -> Void) throws {
        try capture.startCapture(bufferSize: tapBufferSize) { samples, sampleRate, captureEnd, _ in
            delivering(CapturedWindow(
                samples: samples,
                sampleRate: sampleRate,
                captureEnd: captureEnd
            ))
        }
    }

    public func stop() {
        capture.stopCapture()
    }

    private func emit(_ event: MicrophoneEvent) {
        eventLock.lock()
        let sink = _onEvent
        eventLock.unlock()
        sink?(event)
    }
}
