// StrumKit/Algorithm/FaithfulEngineProfile.swift
import Foundation

// MARK: - Engine Profile

/// Explicit configuration profile distinguishing the strict reference ukulele engine
/// from the native extended-range engine for guitar, baritone, and custom tunings.
public struct FaithfulEngineProfile: Sendable, Codable, Equatable {
    public var id: String
    public var minFrequency: Double
    public var maxFrequency: Double
    public var highpassCutoff: Double
    public var lowpassCutoff: Double

    public init(
        id: String,
        minFrequency: Double,
        maxFrequency: Double,
        highpassCutoff: Double,
        lowpassCutoff: Double
    ) {
        self.id = id
        self.minFrequency = minFrequency
        self.maxFrequency = maxFrequency
        self.highpassCutoff = highpassCutoff
        self.lowpassCutoff = lowpassCutoff
    }

    /// Strict ukulele profile matching reference test-tuner source bit-identically:
    /// - Range: [110.0, 1100.0] Hz
    /// - Filter: 100 Hz HP biquad, 1200 Hz LP biquads
    public static let strictUkulele = FaithfulEngineProfile(
        id: "strict-ukulele",
        minFrequency: 110.0,
        maxFrequency: 1100.0,
        highpassCutoff: 100.0,
        lowpassCutoff: 1200.0
    )

    /// Extended-range profile for Guitar, Baritone, and Custom tunings:
    /// - Range: [50.0, 1200.0] Hz (Drop A MIDI 33 = 55.0 Hz, Low E MIDI 40 = 82.41 Hz, up to D5/E5)
    /// - Filter: 40 Hz HP biquad, 1200 Hz LP biquads
    /// - Lag bounds: min lag max(2, floor(rate / 1200.0)), max lag min(floor(rate / 50.0), floor(length / 2) - 1)
    public static let extendedRange = FaithfulEngineProfile(
        id: "extended-range",
        minFrequency: 50.0,
        maxFrequency: 1200.0,
        highpassCutoff: 40.0,
        lowpassCutoff: 1200.0
    )

    /// Checks whether a frequency is valid under this profile.
    @inline(__always)
    public func validFrequency(_ frequency: Double) -> Bool {
        frequency.isFinite && frequency >= minFrequency && frequency <= maxFrequency
    }

    /// Minimum lag for CMNDF valley picking.
    @inline(__always)
    public func minLag(rate: Double) -> Int {
        max(2, Int(floor(rate / maxFrequency)))
    }

    /// Maximum lag for CMNDF valley picking given sample rate and decimated buffer length.
    @inline(__always)
    public func maxLag(rate: Double, length: Int) -> Int {
        min(Int(floor(rate / minFrequency)), length / 2 - 1)
    }

    /// Resolves the engine profile for an instrument category and tuning ID.
    static func profile(for instrument: InstrumentCategory, tuningId: String = "") -> FaithfulEngineProfile {
        switch instrument {
        case .guitar:
            return .extendedRange
        case .ukulele:
            if tuningId == "baritone" || tuningId == "custom" {
                return .extendedRange
            }
            return .strictUkulele
        }
    }
}

// MARK: - Dynamic Target Resolution & Shipped Presets

enum FaithfulTargetResolver {
    /// Resolves an array of MIDI notes into Targets for a specific calibration A4.
    ///
    /// At A4 = 440 Hz, target frequencies are bit-identical to standard reference tunings:
    /// `target.frequency = calibrationA4 * pow(2.0, Double(midi - 69) / 12.0)`
    static func resolve(
        midi: [Int],
        calibrationA4: Double = 440.0
    ) -> [Target] {
        let total = midi.count
        return midi.enumerated().map { index, noteNumber in
            let noteName = PitchMath.midiNoteName(noteNumber)
            let stringNum = total - index
            let freq = calibrationA4 * pow(2.0, Double(noteNumber - 69) / 12.0)
            return Target(
                note: noteName,
                frequency: freq,
                midi: noteNumber,
                stringNumber: stringNum
            )
        }
    }

    /// Resolves targets for a named preset under an instrument category with dynamic calibration.
    static func resolve(
        instrument: InstrumentCategory,
        presetId: String,
        calibrationA4: Double = 440.0,
        customMidi: [Int]? = nil
    ) -> [Target] {
        if presetId == "custom", let customMidi = customMidi, !customMidi.isEmpty {
            return resolve(midi: customMidi, calibrationA4: calibrationA4)
        }

        let presets = Presets.presets(for: instrument)
        if let preset = presets.first(where: { $0.id == presetId }) {
            return resolve(midi: preset.midi, calibrationA4: calibrationA4)
        }

        // Check reference source ukulele tunings by fallback
        if let refTargets = TUNINGS[presetId] {
            if calibrationA4 == 440.0 {
                return refTargets
            }
            return refTargets.enumerated().map { index, t in
                Target(
                    note: t.note,
                    midi: t.midi,
                    stringNumber: t.stringNumber ?? (refTargets.count - index),
                    calibrationA4: calibrationA4
                )
            }
        }

        let fallbackMidi = instrument == .guitar
            ? Presets.guitar[0].midi
            : Presets.ukulele[0].midi
        return resolve(midi: fallbackMidi, calibrationA4: calibrationA4)
    }
}

// MARK: - Precision Preference (Presentation Overlay)

/// Precision preference presentation overlay.
///
/// Controls UI presentation (e.g. ±2 cents indicator, decimal precision)
/// WITHOUT mutating or weakening the canonical 400 ms ±5c confirmation contract.
public struct FaithfulPrecisionPreference: Sendable, Codable, Equatable {
    public var isHighPrecision: Bool
    public var highPrecisionToleranceCents: Double

    public init(isHighPrecision: Bool = false, highPrecisionToleranceCents: Double = 2.0) {
        self.isHighPrecision = isHighPrecision
        self.highPrecisionToleranceCents = highPrecisionToleranceCents
    }

    /// Evaluates whether the smoothed cents deviation satisfies the presentation precision threshold.
    public func isPreciseInTune(cents: Double) -> Bool {
        guard cents.isFinite else { return false }
        let tolerance = isHighPrecision ? highPrecisionToleranceCents : 5.0
        return abs(cents) <= tolerance
    }

    /// Formats cents for readout presentation: tenths with high precision, integer otherwise.
    public func formatCents(_ cents: Double) -> String {
        guard cents.isFinite else { return "—" }
        return String(format: isHighPrecision ? "%.1f" : "%.0f", abs(cents))
    }
}

// MARK: - Guided Sequence Progression

/// Sequenced string advancement for Guided mode.
///
/// Progresses sequentially (from string index 0 to targetCount - 1).
/// String completion strictly requires fresh measured confirmation:
/// `inTune == true && evidence == .measured && freshness == .fresh`.
/// Proximity alone (`inTune == false`) or sustained/held evidence NEVER advances a string.
public final class FaithfulGuidedSequence: @unchecked Sendable {
    public private(set) var progress: [Bool]
    public private(set) var currentTargetIndex: Int
    public let targetCount: Int

    public var isComplete: Bool {
        progress.allSatisfy { $0 }
    }

    public init(targetCount: Int) {
        self.targetCount = targetCount
        self.progress = Array(repeating: false, count: targetCount)
        self.currentTargetIndex = 0
    }

    /// Restarts the guided tuning sequence.
    public func reset() {
        self.progress = Array(repeating: false, count: targetCount)
        self.currentTargetIndex = 0
    }

    /// Evaluates whether an incoming native TunerReading satisfies the completion gate
    /// for the currently active guided target index.
    @discardableResult
    func observe(
        reading: TunerReading?,
        targetIndex: Int?
    ) -> Bool {
        guard let reading = reading,
              let targetIndex = targetIndex,
              targetIndex == currentTargetIndex,
              targetIndex >= 0,
              targetIndex < targetCount else {
            return false
        }

        // Proximity alone never advances: inTune must be true (earned 400 ms confirmation)
        guard reading.inTune == true else {
            return false
        }

        // Must be fresh measured confirmation; held or sustained evidence never advances
        guard reading.evidence == .measured && reading.freshness == .fresh else {
            return false
        }

        // Award completion and advance
        progress[targetIndex] = true
        if currentTargetIndex + 1 < targetCount {
            currentTargetIndex += 1
        }
        return true
    }

    /// Evaluates an algorithm FaithfulReading directly.
    @discardableResult
    func observe(
        reading: FaithfulReading?,
        freshness: TunerReading.Freshness = .fresh,
        evidence: Evidence = .measured
    ) -> Bool {
        guard let reading = reading,
              reading.index == currentTargetIndex,
              reading.index >= 0,
              reading.index < targetCount else {
            return false
        }

        // Must have completed 400 ms confirmation
        guard reading.inTune else {
            return false
        }

        // Must be fresh measured evidence
        guard evidence == .measured && freshness == .fresh else {
            return false
        }

        progress[reading.index] = true
        if currentTargetIndex + 1 < targetCount {
            currentTargetIndex += 1
        }
        return true
    }
}
