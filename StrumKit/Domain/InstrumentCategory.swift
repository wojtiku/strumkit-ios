/// Supported instruments matching chorder specification.
public enum InstrumentCategory: String, CaseIterable, Identifiable, Sendable, Codable {
    case guitar = "guitar"
    case ukulele = "ukulele"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .guitar: "Guitar"
        case .ukulele: "Ukulele"
        }
    }
}
