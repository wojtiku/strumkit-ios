enum EngineStatus: String, Sendable {
    case paused
    case requesting
    case listening
    case denied
    case missing
    case busy
    case interrupted
    case failed

    var displayTitle: String {
        switch self {
        case .paused: "Microphone off"
        case .requesting: "Waiting for microphone permission"
        case .listening: "Listening"
        case .denied: "Microphone permission blocked"
        case .missing: "Microphone not found"
        case .busy: "Microphone is busy"
        case .interrupted: "Listening was interrupted"
        case .failed: "Audio processing stopped"
        }
    }

    var guidanceError: String? {
        switch self {
        case .denied: "Allow microphone access in iOS Settings to enable tuning. You can still use reference tones."
        case .missing: "Connect a microphone or choose another input."
        case .busy: "Close other audio apps to allow tuning."
        case .interrupted: "Listening was interrupted. Bring the app to the foreground to reconnect."
        case .failed: "Audio processing stopped. Return to the app to retry."
        default: nil
        }
    }
}
