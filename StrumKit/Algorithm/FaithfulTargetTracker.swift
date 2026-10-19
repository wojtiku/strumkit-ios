// StrumKit/Algorithm/FaithfulTargetTracker.swift
import Foundation

// MARK: - Target

/// Instrument open-string target specification matching Tools/parity-contract/reference-source/tuning.ts.
public struct Target: Sendable, Codable, Equatable {
    public var note: String
    public var frequency: Double
    public var midi: Int
    public var stringNumber: Int?

    public init(note: String, midi: Int, stringNumber: Int? = nil, calibrationA4: Double = 440.0) {
        self.note = note
        self.midi = midi
        self.frequency = calibrationA4 * pow(2.0, Double(midi - 69) / 12.0)
        self.stringNumber = stringNumber
    }

    public init(note: String, frequency: Double, midi: Int, stringNumber: Int? = nil) {
        self.note = note
        self.frequency = frequency
        self.midi = midi
        self.stringNumber = stringNumber
    }

    /// Matches note name ignoring ASCII vs Unicode sharp symbol (e.g. "F#4" matches "F♯4").
    public func matchesNoteName(_ name: String) -> Bool {
        if self.note == name { return true }
        let normalizedSelf = self.note.replacingOccurrences(of: "♯", with: "#")
        let normalizedOther = name.replacingOccurrences(of: "♯", with: "#")
        return normalizedSelf == normalizedOther
    }
}

/// Helper function to construct a Target from note and MIDI number.
public func target(_ note: String, _ midi: Int) -> Target {
    Target(note: note, midi: midi)
}

// MARK: - Pre-calculated Tunings

/// Standard instrument tunings matching Tools/parity-contract/reference-source/tuning.ts.
public let TUNINGS: [String: [Target]] = [
    "standard": [target("G4", 67), target("C4", 60), target("E4", 64), target("A4", 69)],
    "low-g": [target("G3", 55), target("C4", 60), target("E4", 64), target("A4", 69)],
    "d": [target("A4", 69), target("D4", 62), target("F♯4", 66), target("B4", 71)],
    "slack": [target("G4", 67), target("C4", 60), target("E4", 64), target("G4", 67)],
]

/// Computes cents difference between a frequency and reference frequency: 1200 * log2(frequency / reference).
public func centsBetween(frequency: Double, reference: Double) -> Double {
    guard frequency > 0, reference > 0 else { return 0.0 }
    return 1200.0 * log2(frequency / reference)
}

// MARK: - Tracker Output Reading

/// Pure faithful reading output from the tracker matching reference-source/tuning.ts Reading interface.
public struct FaithfulReading: Sendable, Codable, Equatable {
    public var frequency: Double
    public var cents: Double
    public var index: Int
    public var note: String
    public var inTune: Bool
    public var rms: Double
    public var stringNumber: Int

    public init(
        frequency: Double,
        cents: Double,
        index: Int,
        note: String,
        inTune: Bool,
        rms: Double,
        stringNumber: Int? = nil
    ) {
        self.frequency = frequency
        self.cents = cents
        self.index = index
        self.note = note
        self.inTune = inTune
        self.rms = rms
        self.stringNumber = stringNumber ?? (4 - index)
    }
}

// MARK: - Configuration Policies

public enum GreenPolicy: String, Sendable, Codable, Equatable {
    case raw
    case medianGuard10 = "median-guard10"
    case medianGuard20 = "median-guard20"
    case medianGuard10Pause100 = "median-guard10-pause100"
    case medianGuard20Pause100 = "median-guard20-pause100"

    public var isPauseGreen: Bool {
        self == .medianGuard10Pause100 || self == .medianGuard20Pause100
    }
}

public enum MotionTrial: String, Sendable, Codable, Equatable {
    case product
    case historyFreshness = "history-freshness"
    case historyContradiction = "history-contradiction"
    case historyContradiction5 = "history-contradiction5"
    case fastPersistence64 = "fast-persistence64"
    case fastPersistence96 = "fast-persistence96"
    case fastPersistence64Ramp32 = "fast-persistence64-ramp32"
    case fastPersistence64Away = "fast-persistence64-away"
    case fastPersistence64AwayRearm = "fast-persistence64-away-rearm"
    case fastPersistence64AwayRearmBootstrap = "fast-persistence64-away-rearm-bootstrap"

    public var isFastPersistence: Bool {
        switch self {
        case .fastPersistence64, .fastPersistence96, .fastPersistence64Ramp32,
             .fastPersistence64Away, .fastPersistence64AwayRearm, .fastPersistence64AwayRearmBootstrap:
            return true
        default:
            return false
        }
    }

    public var isFastPersistence64AwayRearm: Bool {
        self == .fastPersistence64AwayRearm || self == .fastPersistence64AwayRearmBootstrap
    }

    public var isFastPersistence64Away: Bool {
        self == .fastPersistence64Away || isFastPersistence64AwayRearm
    }

    public var isHistoryContradiction: Bool {
        self == .historyContradiction || self == .historyContradiction5
    }
}

public enum BootstrapSeed: String, Sendable, Codable, Equatable {
    case mean
    case latest
}

// MARK: - Tracker Implementation

/// Pure faithful target tracker and state machine ported directly from Tools/parity-contract/reference-source/tuning.ts.
public final class FaithfulTracker: @unchecked Sendable {

    public static let tunings = TUNINGS

    // Configuration
    public let maxSlewCentsPerMs: Double
    public let greenPolicy: GreenPolicy
    public let motionTrial: MotionTrial
    public let bootstrapConfidence: Double
    public let bootstrapSeed: BootstrapSeed
    public let decayDamping: Bool

    // User settings
    public var tuning: String = "standard"
    public var auto: Bool = true
    public var selected: Int = 0
    public var targets: [Target]? = nil

    // History & Target Identity
    public internal(set) var history: [Double] = []
    public internal(set) var current: Int? = nil
    public internal(set) var pending: Int? = nil
    public internal(set) var pendingCount: Int = 0
    public internal(set) var pendingSince: Double = -.infinity
    public internal(set) var pendingTime: Double = -.infinity
    public internal(set) var smoothed: Double? = nil
    public internal(set) var lastTime: Double = -.infinity
    public internal(set) var lastPitchTime: Double = -.infinity

    // Motion & Decay State
    public internal(set) var responsiveUntil: Double = -.infinity
    public internal(set) var settledSince: Double? = nil
    public internal(set) var rawDepartureCount: Int = 0
    public internal(set) var greenEvidenceMs: Double = 0.0
    public internal(set) var greenLastQualified: Double = -.infinity
    public internal(set) var greenPreviousQualified: Bool = false
    public internal(set) var greenPreviousTime: Double = -.infinity
    public internal(set) var innovationAnchor: Double? = nil
    public internal(set) var innovationDirection: Double = 0.0
    public internal(set) var innovationLastTime: Double = -.infinity
    public internal(set) var innovationEvidenceMs: Double = 0.0
    public internal(set) var innovationPlateauMs: Double = 0.0
    public internal(set) var recoveringHistory: Bool = false
    public internal(set) var bootstrapStrong: Bool = false
    public internal(set) var bootstrapAvailable: Bool = true

    public struct DecayPoint: Sendable, Codable, Equatable {
        public var time: Double
        public var rms: Double
        public var cents: Double

        public init(time: Double, rms: Double, cents: Double) {
            self.time = time
            self.rms = rms
            self.cents = cents
        }
    }

    public struct SmallPlateau: Sendable, Codable, Equatable {
        public var cents: Double
        public var since: Double
        public var ready: Bool

        public init(cents: Double, since: Double, ready: Bool) {
            self.cents = cents
            self.since = since
            self.ready = ready
        }
    }

    public struct SmallStep: Sendable, Codable, Equatable {
        public var direction: Double
        public var since: Double

        public init(direction: Double, since: Double) {
            self.direction = direction
            self.since = since
        }
    }

    public internal(set) var decayEnvelope: [DecayPoint] = []
    public internal(set) var dampedDecay: Bool = false
    public internal(set) var decayMotionUntil: Double = -.infinity
    public internal(set) var smallPlateau: SmallPlateau? = nil
    public internal(set) var smallStep: SmallStep? = nil
    public internal(set) var smallMotionUntil: Double = -.infinity
    public internal(set) var decayAcquired: Double = -.infinity
    public internal(set) var observedDecay: Bool = false
    public internal(set) var decayLevel: Double? = nil

    // MARK: - Initializer

    public init(
        maxSlewCentsPerMs: Double = 0.75,
        greenPolicy: GreenPolicy = .raw,
        motionTrial: MotionTrial = .fastPersistence64AwayRearmBootstrap,
        bootstrapConfidence: Double = 0.98,
        bootstrapSeed: BootstrapSeed = .mean,
        decayDamping: Bool? = nil
    ) {
        precondition(maxSlewCentsPerMs > 0, "Smoothing slew rate must be positive")
        self.maxSlewCentsPerMs = maxSlewCentsPerMs
        self.greenPolicy = greenPolicy
        self.motionTrial = motionTrial
        self.bootstrapConfidence = bootstrapConfidence
        self.bootstrapSeed = bootstrapSeed
        self.decayDamping = decayDamping ?? (motionTrial == .fastPersistence64AwayRearmBootstrap)
    }

    // MARK: - Target & String Helpers

    /// Returns the target list for current tuning.
    public var currentTargets: [Target] {
        if let targets = self.targets {
            return targets
        }
        return TUNINGS[tuning] ?? TUNINGS["standard"]!
    }

    /// Maps positional target index (0..<totalStrings) to instrument string number (totalStrings...1).
    /// Ukulele target index 0..3 maps to string numbers 4, 3, 2, 1.
    public static func stringNumber(forIndex index: Int, totalStrings: Int = 4) -> Int {
        totalStrings - index
    }

    /// Currently active string number, or nil if no target is active.
    public var currentStringNumber: Int? {
        guard let current else { return nil }
        return Self.stringNumber(forIndex: current, totalStrings: currentTargets.count)
    }

    // MARK: - State Management

    private func clearInnovation() {
        self.innovationAnchor = nil
        self.innovationDirection = 0.0
        self.innovationLastTime = -.infinity
        self.innovationEvidenceMs = 0.0
        self.innovationPlateauMs = 0.0
        self.recoveringHistory = false
    }

    /// Resets all motion and decay tracking, history, current target, and pending candidate,
    /// while explicitly PRESERVING user configuration (`tuning`, `auto`, and `selected`).
    public func reset() {
        self.history = []
        self.current = nil
        self.pending = nil
        self.pendingCount = 0
        self.pendingSince = -.infinity
        self.pendingTime = -.infinity
        self.smoothed = nil
        self.bootstrapStrong = false
        self.bootstrapAvailable = true
        self.lastTime = -.infinity
        self.lastPitchTime = -.infinity
        self.responsiveUntil = -.infinity
        self.settledSince = nil
        self.rawDepartureCount = 0
        self.greenEvidenceMs = 0.0
        self.greenLastQualified = -.infinity
        self.greenPreviousQualified = false
        self.greenPreviousTime = -.infinity
        self.clearInnovation()
        self.decayEnvelope = []
        self.dampedDecay = false
        self.decayMotionUntil = -.infinity
        self.smallPlateau = nil
        self.smallStep = nil
        self.smallMotionUntil = -.infinity
        self.decayAcquired = -.infinity
        self.observedDecay = false
        self.decayLevel = nil
    }

    // MARK: - Push Input

    /// Feed pure scripted pitch values for testing.
    public func push(
        frequency: Double?,
        confidence: Double?,
        rms: Double = 0.05,
        oddOnly: Bool? = nil,
        foregroundAgrees: Bool? = nil,
        time: Double
    ) -> FaithfulReading? {
        guard let frequency, let confidence else {
            return push(pitch: nil, time: time)
        }
        let candidate = FaithfulPitchCandidate(
            frequency: frequency,
            confidence: confidence,
            rms: rms,
            oddOnly: oddOnly,
            foregroundAgrees: foregroundAgrees
        )
        return push(pitch: candidate, time: time)
    }

    /// Primary push method accepting a FaithfulPitchCandidate and millisecond timestamp.
    public func push(pitch: FaithfulPitchCandidate?, time: Double) -> FaithfulReading? {
        let pauseGreen = self.greenPolicy.isPauseGreen
        if pauseGreen && (time - self.greenLastQualified > 100) {
            self.greenEvidenceMs = 0.0
        }

        // Identity follows the display hold, independently of the shorter pitch-history lifetime.
        if self.lastTime != -.infinity && (time - self.lastTime > 1000) {
            self.reset()
        }

        if time - self.lastPitchTime > 300 {
            self.history = []
            if self.motionTrial != .historyFreshness {
                self.smoothed = nil
            }
            self.responsiveUntil = -.infinity
            self.settledSince = nil
            self.rawDepartureCount = 0
            self.clearInnovation()
        }

        if pitch == nil || pitch!.confidence < 0.75 {
            if self.decayDamping {
                self.dampedDecay = false
                self.decayEnvelope = []
                self.smallStep = nil
            }
            if self.history.count < 5 {
                self.bootstrapStrong = false
            }
            if self.motionTrial.isFastPersistence {
                self.clearInnovation()
                self.responsiveUntil = -.infinity
            }
            self.greenPreviousQualified = false
            self.rawDepartureCount = 0
            // A brief dropout may hold already-confirmed green, but must not complete
            // an unfinished confirmation while no new pitch evidence is arriving.
            if let settledSince = self.settledSince, (self.lastTime - settledSince < 400) {
                self.settledSince = nil
            }
            self.pending = nil
            self.pendingCount = 0
            return nil
        }

        guard let pitch = pitch else { return nil }

        // Missing estimates are not continuous evidence: limit one catch-up gain,
        // independently of the 300 ms history lifetime and one-second display hold.
        let elapsed = max(1.0, min(64.0, time - self.lastPitchTime))
        self.lastPitchTime = time

        let targets = currentTargets
        var index = self.selected

        if self.auto {
            let distances = targets.map { abs(centsBetween(frequency: pitch.frequency, reference: $0.frequency)) }
            guard let minDistance = distances.min(),
                  let minIndex = distances.firstIndex(of: minDistance) else {
                return nil
            }
            index = minIndex

            if distances[index] > 250 {
                if self.decayDamping {
                    self.dampedDecay = false
                    self.decayEnvelope = []
                    self.smallStep = nil
                }
                if self.history.count < 5 {
                    self.bootstrapStrong = false
                }
                if self.motionTrial.isFastPersistence {
                    self.clearInnovation()
                    self.responsiveUntil = -.infinity
                }
                self.greenPreviousQualified = false
                self.rawDepartureCount = 0
                if let settledSince = self.settledSince, (self.lastTime - settledSince < 400) {
                    self.settledSince = nil
                }
                self.pending = nil
                self.pendingCount = 0
                return nil
            }

            if let current = self.current, index != current, distances[current] < distances[index] + 25 {
                index = current
            }
        }

        if index != self.current || (self.smoothed == nil && (time - self.lastTime > 300)) {
            self.clearInnovation()
            self.greenPreviousQualified = false
            self.greenEvidenceMs = 0.0
            self.rawDepartureCount = 0
            if let settledSince = self.settledSince, (self.lastTime - settledSince < 400) {
                self.settledSince = nil
            }
            if self.pending != index || (time - self.pendingTime > 150) {
                self.pending = index
                self.pendingCount = 0
                self.pendingSince = time
            }
            self.pendingTime = time
            self.pendingCount += 1
            if self.pendingCount < 2 {
                return nil
            }
            if self.auto && self.current != nil && index != self.current && (time - self.pendingSince < 160) {
                return nil
            }
            self.current = index
            self.decayAcquired = self.bootstrapAvailable ? time : -.infinity
            self.observedDecay = false
            self.decayEnvelope = []
            self.decayLevel = nil
            self.dampedDecay = false
            self.smallPlateau = nil
            self.smallStep = nil
            self.decayMotionUntil = -.infinity
            self.smallMotionUntil = -.infinity
            self.bootstrapStrong = self.bootstrapAvailable && (pitch.confidence >= self.bootstrapConfidence) && (pitch.oddOnly == nil)
            self.bootstrapAvailable = false
            self.history = []
            self.smoothed = nil
            self.responsiveUntil = -.infinity
            self.settledSince = nil
        }

        self.pending = nil
        self.pendingCount = 0

        if self.motionTrial == .historyFreshness && (time - self.lastTime > 300) {
            // Detector eligibility is not current-target numerical freshness. Replace
            // old votes but preserve the needle, so recovery is smoothed, not snapped.
            self.history = []
            self.responsiveUntil = -.infinity
            self.settledSince = nil
        }

        let historyAge = time - self.lastTime
        self.lastTime = time

        let cents = centsBetween(frequency: pitch.frequency, reference: targets[index].frequency)

        if self.decayDamping {
            let last = self.decayEnvelope.last
            if self.observedDecay, let decayLevel = self.decayLevel, pitch.rms >= decayLevel {
                self.observedDecay = false
                self.dampedDecay = false
                self.decayMotionUntil = time + 300
            }

            if self.smallPlateau == nil || (last != nil && (time - last!.time > 300)) {
                self.smallPlateau = SmallPlateau(cents: cents, since: time, ready: false)
            }

            if var plateau = self.smallPlateau {
                let deviation = cents - plateau.cents
                let corroborated = pitch.confidence >= 0.98 || (pitch.confidence >= 0.95 && pitch.foregroundAgrees == true)

                if plateau.ready && corroborated && pitch.oddOnly == nil && abs(deviation) > 12 {
                    // The measured plateau release overlaps the >8-cent innovation path
                    // through 12 cents. Beyond it, retire decay rather than trapping a turn
                    // that crossed the release band between hops.
                    self.dampedDecay = false
                    self.observedDecay = false
                    self.smallStep = nil
                    self.decayMotionUntil = time + 300
                }

                if plateau.ready && corroborated && pitch.oddOnly == nil && abs(deviation) >= 2 && abs(deviation) <= 12 {
                    let direction = deviation > 0 ? 1.0 : (deviation < 0 ? -1.0 : 0.0)
                    if self.smallStep == nil || self.smallStep!.direction != direction || (last != nil && (time - last!.time > 64)) {
                        self.smallStep = SmallStep(direction: direction, since: time)
                    } else if (time - self.smallStep!.since) >= 64 {
                        self.smallMotionUntil = time + 250
                        self.decayMotionUntil = time + 300
                        self.dampedDecay = false
                        self.observedDecay = false
                        self.smallStep = nil
                        plateau = SmallPlateau(cents: cents, since: time, ready: false)
                        self.smallPlateau = plateau
                    }
                } else {
                    self.smallStep = nil
                    if abs(deviation) > 12 || (!plateau.ready && abs(deviation) > 1) {
                        plateau = SmallPlateau(cents: cents, since: time, ready: false)
                        self.smallPlateau = plateau
                    } else if pitch.confidence >= 0.95 && pitch.oddOnly == nil
                        && ((time - plateau.since >= 250) || (!self.observedDecay && self.bootstrapStrong
                            && self.history.count < 5 && corroborated
                            && (time - plateau.since >= 20) && abs(deviation) <= 0.25
                            && self.history.allSatisfy { abs($0 - plateau.cents) <= 0.25 })) {
                        plateau.ready = true
                        self.smallPlateau = plateau
                    }
                }
            }

            if let last = last, (time - last.time > 300 || (abs(cents - last.cents) > 8
                && ((pitch.confidence >= 0.95 && pitch.oddOnly == nil) || abs(cents - last.cents) > 20))) {
                self.dampedDecay = false
                self.observedDecay = false
                self.decayEnvelope = []
                self.decayMotionUntil = time + 300
            }

            self.decayEnvelope.append(DecayPoint(time: time, rms: pitch.rms, cents: cents))

            // Keep at least 64 ms of physical evidence even at high capture rates.
            while self.decayEnvelope.count > 4 && (time - self.decayEnvelope[1].time >= 64 - 1e-9) {
                self.decayEnvelope.removeFirst()
            }

            let envelope = self.decayEnvelope
            if (time - self.decayAcquired <= 500) && pitch.confidence >= 0.98 && pitch.oddOnly == nil
                && time >= self.decayMotionUntil && envelope.count >= 4
                && (time - envelope[0].time >= 64 - 1e-9) && (time - envelope[0].time <= 100)
                && envelope.indices.allSatisfy({ i in
                    i == 0 || envelope[i].rms < envelope[i - 1].rms * pow(0.9, (envelope[i].time - envelope[i - 1].time) / 64.0)
                }) {
                self.dampedDecay = true
                self.observedDecay = true
                if self.decayLevel == nil {
                    self.decayLevel = envelope[0].rms
                }
            }

            if self.dampedDecay, let smoothed = self.smoothed, abs(cents - smoothed) < 1 {
                self.dampedDecay = false
            }
        }

        self.history.append(cents)
        if self.history.count > 5 {
            self.history.removeFirst()
        }

        let sorted = self.history.sorted()
        var median = sorted[sorted.count / 2]

        let bootstrap = self.motionTrial == .fastPersistence64AwayRearmBootstrap
        if pitch.confidence < self.bootstrapConfidence || pitch.oddOnly != nil {
            self.bootstrapStrong = false
        }
        if bootstrap && self.bootstrapStrong && self.history.count < 5 {
            // Seed from the currently available observations, not a latched first
            // waveform value. Once all five votes exist, normal tracking resumes.
            median = self.bootstrapSeed == .latest ? cents : (self.history.reduce(0.0, +) / Double(self.history.count))
            self.smoothed = median
        }

        if self.motionTrial.isHistoryContradiction && historyAge > 300, let smoothed = self.smoothed,
           (median - smoothed) * (cents - smoothed) < 0 {
            self.history = [cents]
            median = cents
            self.responsiveUntil = -.infinity
            self.settledSince = nil
            self.recoveringHistory = true
        }

        if self.recoveringHistory && self.history.count >= (self.motionTrial == .historyContradiction5 ? 5 : 3) {
            self.recoveringHistory = false
        }

        if self.smoothed == nil {
            self.smoothed = median
        } else {
            // Calm small fluctuations, but follow a confirmed peg adjustment quickly.
            // Time-based gains behave consistently at different device sample rates.
            var allowFast = !self.recoveringHistory
            let currentSmoothed = self.smoothed!

            if self.motionTrial.isFastPersistence {
                if self.motionTrial.isFastPersistence64AwayRearm {
                    // Retire old recovery evidence only after a continuously observed,
                    // near-target plateau. Keep the fixed anchor during genuine ramps.
                    let continuous = (time - self.innovationLastTime <= 64)
                    let settled = abs(cents - currentSmoothed) <= 2 && abs(median - currentSmoothed) <= 2
                        && abs(cents) <= 5 && abs(median) <= 5 && abs(currentSmoothed) <= 5
                    self.innovationPlateauMs = continuous && settled ? self.innovationPlateauMs + (time - self.innovationLastTime) : 0.0
                    if self.innovationPlateauMs >= 64 {
                        self.clearInnovation()
                        self.responsiveUntil = -.infinity
                    }
                }

                let anchor = self.innovationAnchor ?? currentSmoothed
                let difference = cents - anchor
                let direction = abs(difference) > 8 ? (difference > 0 ? 1.0 : -1.0) : 0.0

                if direction == 0.0 {
                    self.clearInnovation()
                    self.responsiveUntil = -.infinity
                } else if direction != self.innovationDirection || (time - self.innovationLastTime > 64) {
                    self.clearInnovation()
                    self.responsiveUntil = -.infinity
                    let currentDifference = cents - currentSmoothed
                    if abs(currentDifference) > 8 {
                        self.innovationAnchor = currentSmoothed
                        self.innovationDirection = currentDifference > 0 ? 1.0 : -1.0
                        self.innovationLastTime = time
                    }
                } else {
                    self.innovationEvidenceMs += (time - self.innovationLastTime)
                    self.innovationLastTime = time
                }

                let duration = self.motionTrial == .fastPersistence96 ? 96.0 : 64.0
                let signMedian = (median - currentSmoothed) > 0 ? 1.0 : ((median - currentSmoothed) < 0 ? -1.0 : 0.0)
                let signCents = (cents - currentSmoothed) > 0 ? 1.0 : ((cents - currentSmoothed) < 0 ? -1.0 : 0.0)

                allowFast = (self.innovationEvidenceMs >= duration - 1e-9)
                    && signMedian == self.innovationDirection
                    && signCents == self.innovationDirection

                if self.motionTrial.isFastPersistence64Away
                    && abs(median) < abs(currentSmoothed)
                    && abs(cents) < abs(currentSmoothed)
                    && (median - currentSmoothed) * (cents - currentSmoothed) > 0 {
                    allowFast = true
                }

                if !allowFast {
                    self.responsiveUntil = -.infinity
                }
            }

            if allowFast && abs(median - currentSmoothed) > 8 {
                self.responsiveUntil = time + 180
            }

            let nearTarget = abs(cents) <= 5 && abs(median) <= 5 && abs(currentSmoothed) <= 5
            var timeConstant: Double = 220.0
            if time < self.responsiveUntil || (self.decayDamping && time < self.smallMotionUntil) {
                timeConstant = 50.0
            } else if self.decayDamping && self.observedDecay && !nearTarget {
                timeConstant = 500.0
            } else {
                timeConstant = 220.0
            }

            if self.decayDamping && self.dampedDecay && !nearTarget {
                timeConstant = 1000.0
            }

            if self.motionTrial == .fastPersistence64Ramp32 && timeConstant == 50.0 {
                let fraction = min(1.0, max(0.0, (self.innovationEvidenceMs - 64.0) / 32.0))
                timeConstant = 220.0 - 170.0 * fraction
            }

            let gain = 1.0 - exp(-elapsed / timeConstant)
            let change = gain * (median - currentSmoothed)
            let limit = self.maxSlewCentsPerMs * elapsed
            self.smoothed = currentSmoothed + max(-limit, min(limit, change))
        }

        guard let smoothedVal = self.smoothed else { return nil }

        // Default: sustained raw evidence, independently of the fast needle.
        // Offline alternatives use the measured median, not the smoothed needle
        // alone. Their immediate and consecutive raw-departure guards remain live.
        self.rawDepartureCount = abs(cents) > 5 ? self.rawDepartureCount + 1 : 0

        let measuredInRange: Bool
        switch self.greenPolicy {
        case .raw:
            measuredInRange = abs(cents) <= 5
        case .medianGuard10, .medianGuard10Pause100:
            measuredInRange = abs(median) <= 5 && abs(cents) <= 10 && self.rawDepartureCount < 2
        case .medianGuard20, .medianGuard20Pause100:
            measuredInRange = abs(median) <= 5 && abs(cents) <= 20 && self.rawDepartureCount < 2
        }

        if measuredInRange && abs(smoothedVal) <= 5 {
            if self.settledSince == nil {
                self.settledSince = time
            }
        } else {
            self.settledSince = nil
        }

        let qualified = measuredInRange && abs(smoothedVal) <= 5
        if pauseGreen {
            if !qualified {
                self.greenEvidenceMs = 0.0
            } else {
                if self.greenPreviousQualified && (time - self.greenPreviousTime <= 64) {
                    self.greenEvidenceMs += max(0.0, time - self.greenPreviousTime)
                }
                self.greenLastQualified = time
            }
            self.greenPreviousQualified = qualified
            self.greenPreviousTime = time
        }

        let inTune: Bool
        if pauseGreen {
            inTune = qualified && (self.greenEvidenceMs >= 400.0 - 1e-9)
        } else {
            inTune = (self.settledSince != nil) && (time - self.settledSince! >= 400.0)
        }

        let readingFrequency = targets[index].frequency * pow(2.0, smoothedVal / 1200.0)
        return FaithfulReading(
            frequency: readingFrequency,
            cents: smoothedVal,
            index: index,
            note: targets[index].note,
            inTune: inTune,
            rms: pitch.rms,
            stringNumber: Self.stringNumber(forIndex: index, totalStrings: targets.count)
        )
    }
}

// MARK: - Aliases

public typealias FaithfulTargetTracker = FaithfulTracker
public typealias TunerTracker = FaithfulTracker

// MARK: - Tuning Feedback

/// Faithful implementation of reference-source/feedback.ts TuningFeedback.
/// Tracks visual proximity and awards exactly one confirmation event per string index.
public final class TuningFeedback: @unchecked Sendable {
    public private(set) var nearby: (note: String, index: Int)? = nil
    public private(set) var completed: Set<Int> = []

    public init() {}

    public func reset() {
        completed.removeAll()
        clearReading()
    }

    public func clearReading() {
        nearby = nil
    }

    @discardableResult
    public func observe(_ reading: FaithfulReading?) -> Bool {
        guard let reading else { return false }
        if reading.cents.isFinite && abs(reading.cents) <= 5.0 {
            nearby = (note: reading.note, index: reading.index)
        } else {
            nearby = nil
        }
        guard reading.inTune && !completed.contains(reading.index) else {
            return false
        }
        completed.insert(reading.index)
        return true
    }

    public func green(note: String, cents: Double, index: Int? = nil, inTune: Bool? = nil) -> Bool {
        if let inTune = inTune, inTune, let index = index, completed.contains(index) {
            return true
        }
        guard let nearby = nearby else { return false }
        guard nearby.note == note else { return false }
        if let index = index, index != nearby.index { return false }
        return cents.isFinite && abs(cents) <= 5.0
    }
}

public typealias FaithfulFeedback = TuningFeedback

