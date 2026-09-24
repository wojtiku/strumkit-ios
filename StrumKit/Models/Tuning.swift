import Foundation

/// Represents a single string on an instrument with its expected target pitch.
public struct TunedString: Identifiable, Hashable, Sendable {
    public let stringNumber: Int // 1-indexed (e.g. string 1 is highest pitch in standard guitar notation)
    public let note: MusicalNote

    public var id: Int { stringNumber }

    public var displayName: String {
        "\(stringNumber): \(note.displayName)"
    }

    public init(stringNumber: Int, note: MusicalNote) {
        self.stringNumber = stringNumber
        self.note = note
    }
}

/// Represents a specific musical tuning preset for an instrument.
public struct Tuning: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let strings: [TunedString]

    public init(id: String, name: String, strings: [TunedString]) {
        self.id = id
        self.name = name
        self.strings = strings
    }

    /// Finds the closest string in this tuning to a given detected frequency.
    public func closestString(to frequency: Double) -> (string: TunedString, cents: Double)? {
        guard !strings.isEmpty, frequency > 20.0 else { return nil }

        var closest: TunedString?
        var minAbsCents = Double.greatestFiniteMagnitude
        var resultCents = 0.0

        for str in strings {
            let cents = 1200.0 * log2(frequency / str.note.frequency)
            let absCents = abs(cents)
            if absCents < minAbsCents {
                minAbsCents = absCents
                closest = str
                resultCents = cents
            }
        }

        guard let closest else { return nil }
        return (closest, resultCents)
    }
}
