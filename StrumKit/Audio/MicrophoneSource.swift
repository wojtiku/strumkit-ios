import Foundation

/// What the tuner needs from a microphone: windows of audio, timestamped on the host
/// monotonic clock, at whatever cadence the hardware provides.
///
/// An implementation owns the sample rate, the tap size, the ring buffer, and the
/// device-specific `AVAudioSession` configuration. A caller knows none of that.
public protocol MicrophoneSource: AnyObject, Sendable {
    /// Delivered on an arbitrary thread.
    var onEvent: (@Sendable (MicrophoneEvent) -> Void)? { get set }

    /// Valid only while started; the hardware rate is not knowable before that.
    var sampleRate: Double { get }

    /// Whether the microphone is usable right now, without prompting the player.
    var permissionStatus: AudioPermissionStatus { get }

    /// Prompts the player, resolving to whether the microphone is usable afterwards.
    func requestPermission() async -> Bool

    /// Begins delivering windows, at the cadence the hardware provides.
    func start(delivering: @escaping @Sendable (CapturedWindow) -> Void) throws

    /// Stops delivering. Idempotent, and must leave nothing installed: a "stop" that
    /// leaves the tap in place delivers silence that looks like live audio.
    func stop()
}

/// Something happened to the microphone that the tuner has to absorb.
public enum MicrophoneEvent: Sendable, Equatable {
    /// An interruption began, or ended. `resumable` is the system's own answer to
    /// whether capture may be picked up again: it is `false` while the interruption
    /// is in progress, and true when it ended with the system inviting a resume.
    case interrupted(resumable: Bool)
    /// The input device or its route changed, so a running tap is on the wrong input.
    case routeChanged
}

/// One window of newly-captured audio.
public struct CapturedWindow: Sendable {
    public let samples: [Float]
    public let sampleRate: Double
    /// Host monotonic time of the window's *trailing edge*. The DSP's age maths
    /// (`resultAgeMs`) is measured from here, so it must not be a media timeline.
    public let captureEnd: TimeInterval

    public init(samples: [Float], sampleRate: Double, captureEnd: TimeInterval) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.captureEnd = captureEnd
    }
}
