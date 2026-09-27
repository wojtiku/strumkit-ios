import Foundation

/// What the tuner needs from a microphone: windows of audio, timestamped on the host
/// monotonic clock, at whatever cadence the hardware provides.
///
/// An implementation owns the sample rate, the tap size, the ring buffer, and the
/// device-specific `AVAudioSession` configuration. A caller knows none of that.
protocol MicrophoneSource: AnyObject, Sendable {
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
    ///
    /// Events may still be reported after this — an interruption arrives whether or
    /// not the tap is running — so a caller that unhooks `onEvent` here cannot hear
    /// the one that invites a resume.
    func stop()
}
