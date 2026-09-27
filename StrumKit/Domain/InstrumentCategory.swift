/// Supported instruments matching chorder specification.
enum InstrumentCategory: String, CaseIterable, Identifiable, Sendable, Codable {
    case guitar = "guitar"
    case ukulele = "ukulele"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .guitar: "Guitar"
        case .ukulele: "Ukulele"
        }
    }
}
