import Foundation

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
