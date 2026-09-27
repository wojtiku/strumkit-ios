/// Current microphone permission state.
public enum AudioPermissionStatus: Sendable, Equatable {
    case notDetermined
    case authorized
    case denied
}
