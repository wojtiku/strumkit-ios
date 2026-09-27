enum TunerMode: String, CaseIterable, Identifiable, Sendable, Codable {
    case auto = "auto"
    case guided = "guided"
    case chromatic = "chromatic"
    case manual = "manual"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: "Auto"
        case .guided: "Guided"
        case .chromatic: "Chromatic"
        case .manual: "Locked"
        }
    }
}
