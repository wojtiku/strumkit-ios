enum SignalFeedbackState: String, Sendable {
    case ready
    case inactive
    case tracking
    case checking

    var advisoryMessage: String {
        switch self {
        case .ready, .inactive: "Play one string and let it ring"
        case .tracking: "Listening"
        case .checking: "Listening — checking signal"
        }
    }
}
