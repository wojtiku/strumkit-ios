import Foundation

public struct TunerReading: Sendable, Equatable {
    public let at: TimeInterval
    public let lastFreshAt: TimeInterval
    public let frequency: Double
    /// What this Reading is measured against: the **String** the player is aiming at,
    /// or — in **Chromatic** mode, where nothing is being aimed at — the **Note** it
    /// names instead. Never both, and never neither: a consumer that wants to know
    /// which it is holding switches on this, and cannot get it wrong by reading a flag.
    public let aim: ReadingAim
    public let cents: Double
    public let displayCents: Double
    public let freshness: Freshness
    public let evidence: Evidence

    public enum Freshness: String, Sendable {
        case fresh
        case held
    }

    public init(
        at: TimeInterval,
        lastFreshAt: TimeInterval,
        frequency: Double,
        aim: ReadingAim,
        cents: Double,
        displayCents: Double,
        freshness: Freshness,
        evidence: Evidence
    ) {
        self.at = at
        // `lastFreshAt` is deliberately required. Defaulting it to `at` would let
        // a held reading look brand new to every consumer that drives fading and
        // expiry from it, silently reintroducing the bug this field exists to fix.
        self.lastFreshAt = lastFreshAt
        self.frequency = frequency
        self.aim = aim
        self.cents = cents
        self.displayCents = displayCents
        self.freshness = freshness
        self.evidence = evidence
    }

    /// The **Note** heard, named by whatever this Reading is measured against.
    ///
    /// Derived rather than stored: it used to be a second copy of
    /// `aim.target.note`, which is two fields that can disagree about the same pitch.
    /// There is now one place a Reading's name comes from.
    public var note: String { aim.name }

    /// The in-tune verdict, or `nil` in **Chromatic** mode, where nothing is being
    /// aimed at and the question does not apply. See `ReadingAim.inTune`.
    public var inTune: Bool? { aim.inTune }
}
