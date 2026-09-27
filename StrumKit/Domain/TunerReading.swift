import Foundation

struct TunerReading: Sendable, Equatable {
    let at: TimeInterval
    let lastFreshAt: TimeInterval
    let frequency: Double
    /// What this Reading is measured against: the **String** the player is aiming at,
    /// or — in **Chromatic** mode, where nothing is being aimed at — the **Note** it
    /// names instead. Never both, and never neither: a consumer that wants to know
    /// which it is holding switches on this, and cannot get it wrong by reading a flag.
    let aim: ReadingAim
    let cents: Double
    let displayCents: Double
    let freshness: Freshness
    let evidence: Evidence

    enum Freshness: String, Sendable {
        case fresh
        case held
    }

    init(
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
    var note: String { aim.name }

    /// The in-tune verdict, or `nil` in **Chromatic** mode, where nothing is being
    /// aimed at and the question does not apply. See `ReadingAim.inTune`.
    var inTune: Bool? { aim.inTune }
}
