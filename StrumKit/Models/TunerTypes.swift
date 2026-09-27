import Foundation

public enum TunerMode: String, CaseIterable, Identifiable, Sendable, Codable {
    case auto = "auto"
    case guided = "guided"
    case chromatic = "chromatic"
    case manual = "manual"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .auto: "Auto"
        case .guided: "Guided"
        case .chromatic: "Chromatic"
        case .manual: "Locked"
        }
    }
}

public enum EngineStatus: String, Sendable {
    case paused
    case requesting
    case listening
    case denied
    case missing
    case busy
    case interrupted
    case failed

    public var displayTitle: String {
        switch self {
        case .paused: "Microphone off"
        case .requesting: "Waiting for microphone permission"
        case .listening: "Listening"
        case .denied: "Microphone permission blocked"
        case .missing: "Microphone not found"
        case .busy: "Microphone is busy"
        case .interrupted: "Listening was interrupted"
        case .failed: "Audio processing stopped"
        }
    }

    public var guidanceError: String? {
        switch self {
        case .denied: "Allow microphone access in iOS Settings to enable tuning. You can still use reference tones."
        case .missing: "Connect a microphone or choose another input."
        case .busy: "Close other audio apps to allow tuning."
        case .interrupted: "Listening was interrupted. Bring the app to the foreground to reconnect."
        case .failed: "Audio processing stopped. Return to the app to retry."
        default: nil
        }
    }
}

public enum SignalFeedbackState: String, Sendable {
    case ready
    case inactive
    case tracking
    case faint
    case checking
    case quiet
    case noisy
    case clipping
    case ambiguous

    public var advisoryMessage: String {
        switch self {
        case .ready, .inactive: "Play one string and let it ring"
        case .tracking: "Listening"
        case .faint: "Faint note — keep listening"
        case .checking: "Listening — checking signal"
        case .quiet: "Move closer to the mic or pluck a little louder"
        case .noisy: "Use a quieter spot and play one string at a time"
        case .clipping: "Input is clipping. Move back or lower the microphone gain"
        case .ambiguous: "Pitch is unclear. Mute the other strings and pluck again"
        }
    }
}

/// A **String** the player is trying to reach, with the frequency it is currently
/// set to. It exists whether or not anything is sounding, and it is never a **Note**:
/// a String is a position on the instrument, not a pitch.
public struct StringTarget: Identifiable, Hashable, Sendable {
    public let note: String
    public let midi: Int
    public let frequency: Double
    public let number: Int // String number (e.g. 6 to 1 on guitar)

    public var id: Int { number }

    public init(note: String, midi: Int, frequency: Double, number: Int) {
        self.note = note
        self.midi = midi
        self.frequency = frequency
        self.number = number
    }
}

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
public enum Evidence: Sendable, Hashable {
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
    public var mayAssertInTune: Bool { self == .measured }

    /// Whether a Reading backed by this Evidence may complete a Tuning sequence.
    ///
    /// `false` for Sustained. A completed String is a record that the player held
    /// it in tune, and a Note extended past the point where fresh detection could
    /// hear it is not evidence of that. The spectral path also reports its
    /// salience, capped below `PitchTracker.guidedCompletionPeriodicity`, so a
    /// Sustained frame fails the guided hold's periodicity requirement anyway;
    /// stating the rule here means the completion gate does not rest on that
    /// coincidence.
    public var mayCompleteTuning: Bool { self == .measured }
}

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

public struct TunerConfig: Sendable, Equatable, Codable {
    public var instrument: InstrumentCategory
    public var tuningId: String
    public var customMidi: [Int]
    public var a4: Double
    public var mode: TunerMode
    public var selectedString: Int // Index 0 ..< targets.count
    public var precision: Bool
    public var guided: Bool

    public init(
        instrument: InstrumentCategory = .guitar,
        tuningId: String = "standard",
        customMidi: [Int] = [40, 45, 50, 55, 59, 64],
        a4: Double = TunerConstants.defaultA4Hz,
        mode: TunerMode = .auto,
        selectedString: Int = 0,
        precision: Bool = false,
        guided: Bool = false
    ) {
        self.instrument = instrument
        self.tuningId = tuningId
        self.customMidi = customMidi
        self.a4 = a4
        self.mode = mode
        self.selectedString = selectedString
        self.precision = precision
        self.guided = guided
    }
}

/// One window of audio offered to the analysis session, with the capture metadata
/// needed to place it in time and to judge whether it is still wanted: the rate it
/// was captured at, the timestamp of its *trailing* edge, the tap callback it
/// arrived in, and the generation it belongs to. `TunerAnalysisSession` drops a
/// frame whose `generation` is no longer current rather than analysing it, which
/// is what makes a configuration change safe while audio is in flight.
public struct AnalysisFrame: Sendable {
    public let samples: [Float]
    public let sampleRate: Double
    /// Denotes the timestamp at the trailing edge (end) of the analyzed audio window.
    public let captureEndSeconds: TimeInterval
    public let sequence: UInt64
    public let generation: UInt64
    public let callbackFrameCount: Int

    public init(
        samples: [Float],
        sampleRate: Double,
        captureEndSeconds: TimeInterval,
        sequence: UInt64,
        generation: UInt64,
        callbackFrameCount: Int = 0
    ) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.captureEndSeconds = captureEndSeconds
        self.sequence = sequence
        self.generation = generation
        self.callbackFrameCount = callbackFrameCount
    }
}

public struct AnalysisSnapshot: Sendable, Equatable {
    public let reading: TunerReading?
    public let pitchResult: PitchResult
    public let feedbackState: SignalFeedbackState
    public let guidedProgress: [Bool]
    public let guidedTargetIndex: Int
    public let diagnostics: TunerDiagnostics
    public let generation: UInt64
    public let sequence: UInt64

    public init(
        reading: TunerReading?,
        pitchResult: PitchResult,
        feedbackState: SignalFeedbackState,
        guidedProgress: [Bool],
        guidedTargetIndex: Int,
        diagnostics: TunerDiagnostics,
        generation: UInt64,
        sequence: UInt64
    ) {
        self.reading = reading
        self.pitchResult = pitchResult
        self.feedbackState = feedbackState
        self.guidedProgress = guidedProgress
        self.guidedTargetIndex = guidedTargetIndex
        self.diagnostics = diagnostics
        self.generation = generation
        self.sequence = sequence
    }
}

public struct TunerDiagnostics: Sendable, Equatable {
    public var sampleRate: Double = 44100.0
    public var analysisMs: Double = 0.0
    public var dspMs: Double = 0.0
    public var queueDelayMs: Double = 0.0
    public var resultAgeMs: Double = 0.0
    public var replacedFrames: UInt64 = 0
    public var callbackFrameCount: Int = 0
    public var dropped: Int = 0
    public var level: Double = 0.0

    public init(
        sampleRate: Double = 44100.0,
        analysisMs: Double = 0.0,
        dspMs: Double = 0.0,
        queueDelayMs: Double = 0.0,
        resultAgeMs: Double = 0.0,
        replacedFrames: UInt64 = 0,
        callbackFrameCount: Int = 0,
        dropped: Int = 0,
        level: Double = 0.0
    ) {
        self.sampleRate = sampleRate
        self.analysisMs = analysisMs
        self.dspMs = dspMs
        self.queueDelayMs = queueDelayMs
        self.resultAgeMs = resultAgeMs
        self.replacedFrames = replacedFrames
        self.callbackFrameCount = callbackFrameCount
        self.dropped = dropped
        self.level = level
    }
}
