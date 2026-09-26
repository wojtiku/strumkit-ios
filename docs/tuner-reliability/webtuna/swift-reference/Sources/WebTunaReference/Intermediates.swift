import Foundation

/// The engine's own intermediate arrays, recorded from the running wasm by
/// `tools/probe-intermediates.mjs`.
///
/// This exists because the 56 band values and the compressed magnitudes are never
/// reported in the JSON: without them, "the filterbank is the same filterbank"
/// would be unfalsifiable, and a filterbank that is subtly different could still
/// produce plausible end-to-end numbers.
public struct Intermediates: Decodable, Sendable {
    public struct Case: Decodable, Sendable {
        public let label: String
        public let freq: Double
        public let idx: Int32
        public let calls: Int
        public let spectrum: [Float]
        public let spectrumRMS: Float
        public let bands: [Float]
        public let compressed: [Float]
        public let residual: [Float]
        /// The engine's own JSON for the last call, as a raw dictionary so the
        /// shape can change without breaking the fixture decode.
        public let output: [String: JSONValue]
    }

    public enum JSONValue: Decodable, Sendable {
        case number(Double), bool(Bool), string(String), null
        public init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let v = try? c.decode(Bool.self) { self = .bool(v); return }
            if let v = try? c.decode(Double.self) { self = .number(v); return }
            if let v = try? c.decode(String.self) { self = .string(v); return }
            self = .null
        }
    }

    public let sampleRate: Double
    public let cases: [Case]

    public static func load(from url: URL? = nil) throws -> Intermediates {
        let resolved = url ?? URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/intermediates.json")
        return try JSONDecoder().decode(Intermediates.self, from: try Data(contentsOf: resolved))
    }
}
