/// What a **Reading** is measured against.
///
/// One question with two genuinely different answers, and the difference is the whole
/// distinction the tuner's two modes rest on:
///
/// - `target(StringTarget, inTune:)` — a **String** the player is aiming at. The cents
///   are how far short of it they are, which is advice: "turn the peg". The in-tune
///   verdict rides along in the case rather than beside it, because a **Reading** is
///   only ever in tune *with respect to a Target* — a Reading that has no Target cannot
///   hold one, so "no verdict" is the only honest answer available and it is the
///   answer the type gives for free.
/// - `note(MusicalNote)` — **Chromatic** mode. Nothing is being aimed at, so the cents
///   are a distance from the **Note**'s own frequency in equal temperament, and there
///   is no verdict to give. `MusicalNote` is a pitch and nothing more; it names no
///   String, and it is not a `StringTarget` with a missing string number.
public enum ReadingAim: Sendable, Hashable {
    case target(StringTarget, inTune: Bool)
    case note(MusicalNote)

    /// The **String** this **Reading** is measured against, or `nil` when it names a
    /// **Note** and nothing is being aimed at.
    public var target: StringTarget? {
        switch self {
        case .target(let target, _): target
        case .note: nil
        }
    }

    /// The in-tune verdict, or `nil` when this **Reading** names a **Note**.
    ///
    /// `nil` means *not applicable*, not *out of tune*. A consumer that needs a
    /// colour or a piece of advice has to say what it does without one; that is the
    /// point, because the alternative is a chromatic note being reported as wrong.
    public var inTune: Bool? {
        switch self {
        case .target(_, let inTune): inTune
        case .note: nil
        }
    }

    /// The **Note** named, whether it is the **String** being aimed at or the pitch
    /// heard in **Chromatic** mode. The Reading shows this and nothing else needs it.
    public var name: String {
        switch self {
        case .target(let target, _): target.note
        case .note(let note): note.displayName
        }
    }

    /// The frequency the cents are measured from. Deviation from it is advice in the
    /// **String** modes and a fact about equal temperament in **Chromatic** mode.
    public var frequency: Double {
        switch self {
        case .target(let target, _): target.frequency
        case .note(let note): note.frequency
        }
    }
}
