// StrumKitTests/Parity/ParityReplayEngine.swift
import Foundation

/// Frame specification for custom/sparse frame replays.
public struct ParityCustomFrame: Sendable, Codable, Equatable {
    public var frame: [Float]
    public var timeMs: Double

    public init(frame: [Float], timeMs: Double) {
        self.frame = frame
        self.timeMs = timeMs
    }
}

/// Configuration options for the pure replay engine.
public struct ParityReplayConfig: Sendable, Codable, Equatable {
    public var name: String
    public var category: String
    public var tuning: String
    public var auto: Bool
    public var customFrames: [ParityCustomFrame]?

    public init(
        name: String = "unnamed",
        category: String = "replay",
        tuning: String = "standard",
        auto: Bool = true,
        customFrames: [ParityCustomFrame]? = nil
    ) {
        self.name = name
        self.category = category
        self.tuning = tuning
        self.auto = auto
        self.customFrames = customFrames
    }
}

/// Pure replay engine protocol.
///
/// Accepts Float32 PCM, sample rate, timestamps, and configuration; produces a canonical ParityTrace.
/// Completely independent of AVAudioEngine, hardware microphones, Web Audio, Node, or network.
public protocol ParityReplayEngine: Sendable {
    func replay(
        samples: [Float],
        sampleRate: Double,
        config: ParityReplayConfig
    ) throws -> ParityTrace
}

extension ParityReplayEngine {
    public func replay(
        samples: [Float],
        sampleRate: Double,
        name: String = "replay",
        category: String = "synthetic"
    ) throws -> ParityTrace {
        try replay(
            samples: samples,
            sampleRate: sampleRate,
            config: ParityReplayConfig(name: name, category: category)
        )
    }
}

/// A stub replay engine that produces an empty trace, used as a negative control
/// to verify that an unported or broken engine fails decisively.
public struct StubReplayEngine: ParityReplayEngine {
    public init() {}

    public func replay(
        samples: [Float],
        sampleRate: Double,
        config: ParityReplayConfig
    ) throws -> ParityTrace {
        ParityTrace(
            name: config.name,
            category: config.category,
            sampleRate: sampleRate,
            sampleCount: samples.count,
            sampleSha256: "",
            frameCount: 0,
            clockConvention: "window-end",
            workletOffsetMs: (128.0 / sampleRate) * 1000.0,
            confirmedNotes: [],
            frames: []
        )
    }
}
