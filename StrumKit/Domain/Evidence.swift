/// Where a Reading came from, graded.
///
/// **Measured** evidence is periodicity found in the audio itself. **Sustained**
/// evidence extends a Note already being tracked, when fresh detection has gone
/// quiet but the Note has not.
///
/// A grade rather than a flag, so that a path added later has to choose a level
/// explicitly instead of silently inheriting one. Neither type that carries it
/// supplies a default, precisely so that "not stated" cannot mean "Measured":
/// this is the trust question, and inheriting an answer to it is the mistake the
/// type exists to prevent.
///
/// A third grade — naming a Note nothing else has confirmed — is deliberately
/// absent. The path that produced it was measured and found blocked: its gate
/// rejected exactly the weak fundamentals it existed to rescue. See
/// `docs/tuner-reliability/RESULTS.md` §13 and the glossary's Evidence entry.
enum Evidence: Sendable, Hashable {
    case measured
    case sustained

    /// Whether a Reading backed by this Evidence may declare a String in tune.
    ///
    /// `false` for Sustained. Sustained evidence extends a Note that is already
    /// being tracked; it may show a Reading and nothing more. Spectral recovery
    /// is less certain than YIN's autocorrelation, and a wrong cents value is
    /// directly actionable advice — "turn the peg" — so a Sustained Reading may
    /// move the needle and update the hold but must never become tuning advice.
    /// The cents readout is kept, de-emphasised, so the value stays inspectable.
    ///
    /// The rule is a property of the grade, so it is stated on the grade rather
    /// than on whatever module happens to schedule the frames: there is nothing
    /// left to decide at the call site.
    var mayAssertInTune: Bool { self == .measured }

    /// Whether a Reading backed by this Evidence may complete a Tuning sequence.
    ///
    /// `false` for Sustained. A completed String is a record that the player held
    /// it in tune, and a Note extended past the point where fresh detection could
    /// hear it is not evidence of that. The spectral path also reports its
    /// salience, capped below `PitchTracker.guidedCompletionPeriodicity`, so a
    /// Sustained frame fails the guided hold's periodicity requirement anyway;
    /// stating the rule here means the completion gate does not rest on that
    /// coincidence.
    var mayCompleteTuning: Bool { self == .measured }
}
