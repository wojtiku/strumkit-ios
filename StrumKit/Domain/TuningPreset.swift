/// A tuning preset definition with ID, display label, and MIDI note array.
public struct TuningPreset: Identifiable, Hashable, Sendable {
    public let id: String
    public let label: String
    public let midi: [Int]

    public init(id: String, label: String, midi: [Int]) {
        self.id = id
        self.label = label
        self.midi = midi
    }
}
