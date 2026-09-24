import Foundation

/// Current microphone permission state.
public enum AudioPermissionStatus: Sendable, Equatable {
    case notDetermined
    case authorized
    case denied
}

/// Errors that can occur during audio engine lifecycle or recording.
public enum AudioCaptureError: LocalizedError, Sendable {
    case permissionDenied
    case engineFailed(String)
    case inputNodeUnavailable

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "Microphone permission is required to analyze instrument pitch."
        case .engineFailed(let reason):
            "Audio engine failed: \(reason)"
        case .inputNodeUnavailable:
            "Audio input node is not available on this device."
        }
    }
}
