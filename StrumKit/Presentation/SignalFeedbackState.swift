public enum SignalFeedbackState: String, Sendable {
    case ready
    case inactive
    case tracking
    case faint
    case checking
    case quiet
    case noisy
    case clipping
    case ambiguous

    public var advisoryMessage: String {
        switch self {
        case .ready, .inactive: "Play one string and let it ring"
        case .tracking: "Listening"
        case .faint: "Faint note — keep listening"
        case .checking: "Listening — checking signal"
        case .quiet: "Move closer to the mic or pluck a little louder"
        case .noisy: "Use a quieter spot and play one string at a time"
        case .clipping: "Input is clipping. Move back or lower the microphone gain"
        case .ambiguous: "Pitch is unclear. Mute the other strings and pluck again"
        }
    }
}
