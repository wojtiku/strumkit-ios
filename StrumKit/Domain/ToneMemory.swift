struct ToneMemory: Sendable, Equatable {
    let note: String
    let frequency: Double
    let source: Source
    let reading: TunerReading?

    enum Source: String, Sendable {
        case detected
        case reference
        case target
    }

    init(note: String, frequency: Double, source: Source, reading: TunerReading? = nil) {
        self.note = note
        self.frequency = frequency
        self.source = source
        self.reading = reading
    }
}
