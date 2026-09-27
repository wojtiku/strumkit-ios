/// Current microphone permission state.
enum AudioPermissionStatus: Sendable, Equatable {
    case notDetermined
    case authorized
    case denied
}
