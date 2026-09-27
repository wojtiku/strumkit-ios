public struct ToneMemory: Sendable, Equatable {
    public let note: String
    public let frequency: Double
    public let source: Source
    public let reading: TunerReading?

    public enum Source: String, Sendable {
        case detected
        case reference
        case target
    }

    public init(note: String, frequency: Double, source: Source, reading: TunerReading? = nil) {
        self.note = note
        self.frequency = frequency
        self.source = source
        self.reading = reading
    }
}
