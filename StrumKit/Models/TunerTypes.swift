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

public enum SignalCondition: String, Sendable {
    case ready
    case quiet
    case noisy
    case clipping
    case ambiguous
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

public struct TunerReading: Sendable, Equatable {
    public let at: TimeInterval
    public let lastFreshAt: TimeInterval
    public let frequency: Double
    public let note: String
    public let target: StringTarget
    public let targetIndex: Int
    public let cents: Double
    public let displayCents: Double
    public let freshness: Freshness
    public let inTune: Bool
    public let recovered: Bool

    public enum Freshness: String, Sendable {
        case fresh
        case held
    }

    public init(
        at: TimeInterval,
        lastFreshAt: TimeInterval,
        frequency: Double,
        note: String,
        target: StringTarget,
        targetIndex: Int,
        cents: Double,
        displayCents: Double,
        freshness: Freshness,
        inTune: Bool,
        recovered: Bool = false
    ) {
        self.at = at
        // `lastFreshAt` is deliberately required. Defaulting it to `at` would let
        // a held reading look brand new to every consumer that drives fading and
        // expiry from it, silently reintroducing the bug this field exists to fix.
        self.lastFreshAt = lastFreshAt
        self.frequency = frequency
        self.note = note
        self.target = target
        self.targetIndex = targetIndex
        self.cents = cents
        self.displayCents = displayCents
        self.freshness = freshness
        self.inTune = inTune
        self.recovered = recovered
    }
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
