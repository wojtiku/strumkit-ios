import Foundation

/// Current microphone permission state.
public enum AudioPermissionStatus: Sendable, Equatable {
    case notDetermined
    case authorized
    case denied
}

/// What the tuner needs from a reference tone: to make a **String** audible, and to
/// stop.
///
/// Exists so a test can assert *which* tone was requested. The synthesiser itself is
/// integration-tested against real audio hardware; the observable thing worth pinning
/// is the tuner's choice, which is otherwise only audible.
public protocol ReferenceTonePlayer: AnyObject, Sendable {
    /// Plays the tone of the **String** at `frequency`, as identified by the player
    /// choosing `stringIndex` of `instrument`.
    func playString(frequency: Double, stringIndex: Int, instrument: InstrumentCategory)

    /// Stops any playing tone immediately.
    func stop()
}

/// Errors that can occur during audio engine lifecycle or recording.
public enum AudioCaptureError: LocalizedError, Sendable {
    case permissionDenied
    case engineFailed(String)
    case inputNodeUnavailable
    case sessionActivationFailed(String)
    case noInputChannelsAvailable

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "Microphone permission is required to analyze instrument pitch."
        case .engineFailed(let reason):
            "Audio engine failed: \(reason)"
        case .inputNodeUnavailable:
            "Audio input node is not available on this device."
        case .sessionActivationFailed(let reason):
            "Audio session activation failed: \(reason)"
        case .noInputChannelsAvailable:
            "Audio input format has 0 channels. No microphone is available."
        }
    }
}
