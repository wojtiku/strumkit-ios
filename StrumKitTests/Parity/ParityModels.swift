// StrumKitTests/Parity/ParityModels.swift
import Foundation

// MARK: - Numeric Budgets

public struct ParityBudgets: Sendable, Codable, Equatable {
    public var frequencyAbsoluteHz: Double
    public var rawCentsAbsolute: Double
    public var smoothedCentsAbsolute: Double
    public var confidenceAbsolute: Double
    public var rmsAbsolute: Double
    public var rmsRelative: Double
    public var sampleIndexExact: Bool
    public var timestampConversionErrorMaxMs: Double

    public init(
        frequencyAbsoluteHz: Double = 1e-6,
        rawCentsAbsolute: Double = 1e-6,
        smoothedCentsAbsolute: Double = 1e-6,
        confidenceAbsolute: Double = 1e-9,
        rmsAbsolute: Double = 1e-10,
        rmsRelative: Double = 1e-7,
        sampleIndexExact: Bool = true,
        timestampConversionErrorMaxMs: Double = 1e-6
    ) {
        self.frequencyAbsoluteHz = frequencyAbsoluteHz
        self.rawCentsAbsolute = rawCentsAbsolute
        self.smoothedCentsAbsolute = smoothedCentsAbsolute
        self.confidenceAbsolute = confidenceAbsolute
        self.rmsAbsolute = rmsAbsolute
        self.rmsRelative = rmsRelative
        self.sampleIndexExact = sampleIndexExact
        self.timestampConversionErrorMaxMs = timestampConversionErrorMaxMs
    }

    /// Frozen numeric budgets defined in Tools/parity-contract/schema/manifest.json.
    public static let frozen = ParityBudgets(
        frequencyAbsoluteHz: 1e-6,
        rawCentsAbsolute: 1e-6,
        smoothedCentsAbsolute: 1e-6,
        confidenceAbsolute: 1e-9,
        rmsAbsolute: 1e-10,
        rmsRelative: 1e-7,
        sampleIndexExact: true,
        timestampConversionErrorMaxMs: 1e-6
    )
}

// MARK: - Discrete Rules

public struct ParityDiscreteRules: Sendable, Codable, Equatable {
    public var nullMaskExact: Bool
    public var targetNotesExact: Bool
    public var targetIndicesExact: Bool
    public var publicationSlotsExact: Bool
    public var inTuneTransitionsExact: Bool
    public var confirmationEventsExact: Bool
    public var optionalFlagsExact: Bool

    public init(
        nullMaskExact: Bool = true,
        targetNotesExact: Bool = true,
        targetIndicesExact: Bool = true,
        publicationSlotsExact: Bool = true,
        inTuneTransitionsExact: Bool = true,
        confirmationEventsExact: Bool = true,
        optionalFlagsExact: Bool = true
    ) {
        self.nullMaskExact = nullMaskExact
        self.targetNotesExact = targetNotesExact
        self.targetIndicesExact = targetIndicesExact
        self.publicationSlotsExact = publicationSlotsExact
        self.inTuneTransitionsExact = inTuneTransitionsExact
        self.confirmationEventsExact = confirmationEventsExact
        self.optionalFlagsExact = optionalFlagsExact
    }

    /// Frozen discrete rules defined in Tools/parity-contract/schema/manifest.json.
    public static let frozen = ParityDiscreteRules(
        nullMaskExact: true,
        targetNotesExact: true,
        targetIndicesExact: true,
        publicationSlotsExact: true,
        inTuneTransitionsExact: true,
        confirmationEventsExact: true,
        optionalFlagsExact: true
    )
}

// MARK: - Detector Output

public struct ParityDetectorOutput: Sendable, Codable, Equatable {
    public var frequency: Double?
    public var confidence: Double?
    public var rms: Double
    public var foregroundAgrees: Bool?
    public var oddOnly: Bool?

    public init(
        frequency: Double? = nil,
        confidence: Double? = nil,
        rms: Double,
        foregroundAgrees: Bool? = nil,
        oddOnly: Bool? = nil
    ) {
        self.frequency = frequency
        self.confidence = confidence
        self.rms = rms
        self.foregroundAgrees = foregroundAgrees
        self.oddOnly = oddOnly
    }
}

// MARK: - Target

public struct ParityTarget: Sendable, Codable, Equatable {
    public var note: String
    public var frequency: Double
    public var index: Int

    public init(note: String, frequency: Double, index: Int) {
        self.note = note
        self.frequency = frequency
        self.index = index
    }
}

// MARK: - Tracker Output

public struct ParityTrackerOutput: Sendable, Codable, Equatable {
    public var target: ParityTarget?
    public var rawCents: Double?
    public var smoothedCents: Double?
    public var readingFrequency: Double?
    public var inTune: Bool

    public init(
        target: ParityTarget? = nil,
        rawCents: Double? = nil,
        smoothedCents: Double? = nil,
        readingFrequency: Double? = nil,
        inTune: Bool
    ) {
        self.target = target
        self.rawCents = rawCents
        self.smoothedCents = smoothedCents
        self.readingFrequency = readingFrequency
        self.inTune = inTune
    }
}

// MARK: - Publication Action & Output

public enum ParityPublicationAction: String, Sendable, Codable, Equatable {
    case published
    case held
    case empty
    case skipped
}

public struct ParityPublicationOutput: Sendable, Codable, Equatable {
    public var action: ParityPublicationAction
    public var note: String?
    public var cents: Double?
    public var frequency: Double?
    public var inTune: Bool?

    public init(
        action: ParityPublicationAction,
        note: String? = nil,
        cents: Double? = nil,
        frequency: Double? = nil,
        inTune: Bool? = nil
    ) {
        self.action = action
        self.note = note
        self.cents = cents
        self.frequency = frequency
        self.inTune = inTune
    }
}

// MARK: - Confirmation Output

public struct ParityConfirmationOutput: Sendable, Codable, Equatable {
    public var event: Bool
    public var stringIndex: Int?
    public var note: String?

    public init(
        event: Bool,
        stringIndex: Int? = nil,
        note: String? = nil
    ) {
        self.event = event
        self.stringIndex = stringIndex
        self.note = note
    }
}

// MARK: - Frame

public struct ParityFrame: Sendable, Codable, Equatable {
    public var frameIndex: Int
    public var sampleIndex: Int
    public var timeMs: Double
    public var workletTimeMs: Double
    public var detector: ParityDetectorOutput
    public var tracker: ParityTrackerOutput
    public var publication: ParityPublicationOutput
    public var confirmation: ParityConfirmationOutput

    public init(
        frameIndex: Int,
        sampleIndex: Int,
        timeMs: Double,
        workletTimeMs: Double,
        detector: ParityDetectorOutput,
        tracker: ParityTrackerOutput,
        publication: ParityPublicationOutput,
        confirmation: ParityConfirmationOutput
    ) {
        self.frameIndex = frameIndex
        self.sampleIndex = sampleIndex
        self.timeMs = timeMs
        self.workletTimeMs = workletTimeMs
        self.detector = detector
        self.tracker = tracker
        self.publication = publication
        self.confirmation = confirmation
    }
}

// MARK: - Trace

public struct ParityTrace: Sendable, Codable, Equatable {
    public var name: String
    public var category: String
    public var sampleRate: Double
    public var sampleCount: Int
    public var sampleSha256: String
    public var frameCount: Int
    public var clockConvention: String
    public var workletOffsetMs: Double
    public var confirmedNotes: [String]
    public var frames: [ParityFrame]

    public init(
        name: String,
        category: String,
        sampleRate: Double,
        sampleCount: Int,
        sampleSha256: String,
        frameCount: Int,
        clockConvention: String = "window-end",
        workletOffsetMs: Double,
        confirmedNotes: [String],
        frames: [ParityFrame]
    ) {
        self.name = name
        self.category = category
        self.sampleRate = sampleRate
        self.sampleCount = sampleCount
        self.sampleSha256 = sampleSha256
        self.frameCount = frameCount
        self.clockConvention = clockConvention
        self.workletOffsetMs = workletOffsetMs
        self.confirmedNotes = confirmedNotes
        self.frames = frames
    }
}

// MARK: - Manifest Models

public struct ParityManifestCase: Sendable, Codable, Equatable {
    public var name: String
    public var category: String
    public var description: String
    public var sampleRate: Double
    public var sampleCount: Int
    public var sampleSha256: String
    public var frameCount: Int
    public var traceFile: String
    public var traceSha256: String
    public var confirmedNotes: [String]
}

public struct ParityManifestAuthority: Sendable, Codable, Equatable {
    public var gitCommit: String
    public var nativeBaseCommit: String
    public var author: String
    public var sourceHashes: [String: String]
}

public struct ParityClockConventions: Sendable, Codable, Equatable {
    public var windowSizeSamples: Int
    public var hopSizeSamples: Int
    public var workletOffsetQuantumSamples: Int
    public var workletOffsetFormula: String
    public var windowEndFormula: String
    public var workletTimeMsFormula: String
    public var windowEndTimeMsFormula: String
}

public struct ParityManifestSummary: Sendable, Codable, Equatable {
    public var totalCases: Int
    public var categoryCounts: [String: Int]
    public var productCases: Int
    public var stressCases: Int
    public var targetedCases: Int
    public var totalFrames: Int
}

public struct ParityManifest: Sendable, Codable, Equatable {
    public var schemaVersion: Int
    public var authority: ParityManifestAuthority
    public var numericBudgets: ParityBudgets
    public var discreteRules: ParityDiscreteRules
    public var clockConventions: ParityClockConventions
    public var summary: ParityManifestSummary
    public var cases: [ParityManifestCase]
}
