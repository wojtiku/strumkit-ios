/// A tuning preset definition with ID, display label, and MIDI note array.
struct TuningPreset: Identifiable, Hashable, Sendable {
    let id: String
    let label: String
    let midi: [Int]

    init(id: String, label: String, midi: [Int]) {
        self.id = id
        self.label = label
        self.midi = midi
    }
}
