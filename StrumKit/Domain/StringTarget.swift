/// A **String** the player is trying to reach, with the frequency it is currently
/// set to. It exists whether or not anything is sounding, and it is never a **Note**:
/// a String is a position on the instrument, not a pitch.
struct StringTarget: Identifiable, Hashable, Sendable {
    let note: String
    let midi: Int
    let frequency: Double
    let number: Int // String number (e.g. 6 to 1 on guitar)

    var id: Int { number }

    init(note: String, midi: Int, frequency: Double, number: Int) {
        self.note = note
        self.midi = midi
        self.frequency = frequency
        self.number = number
    }
}
