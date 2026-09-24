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
        case .denied: "Allow microphone access in iOS Settings, then start again. You can still use the reference tones."
        case .missing: "Connect a microphone or choose another input, then start again."
        case .busy: "Close other audio apps, then start again."
        case .interrupted: "Return to this app and press Start tuning to reconnect your microphone."
        case .failed: "Press Start tuning to retry."
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

public struct TunerDiagnostics: Sendable, Equatable {
    public var sampleRate: Double = 44100.0
    public var analysisMs: Double = 0.0
    public var dropped: Int = 0
    public var level: Double = 0.0

    public init(sampleRate: Double = 44100.0, analysisMs: Double = 0.0, dropped: Int = 0, level: Double = 0.0) {
        self.sampleRate = sampleRate
        self.analysisMs = analysisMs
        self.dropped = dropped
        self.level = level
    }
}
