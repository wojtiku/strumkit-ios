import Foundation

/// The nine fields `analyseBuffer` returns, plus the anti-piracy stub result.
///
/// §1.4 lists the JSON, and §5.1/§5.2 name the two quantisations as documented
/// weaknesses. One of them is not what WEBTUNA.md says — see DIVERGENCES.md D1:
/// `MeasuredPitchHz` is `rint`, not `floor`, and `TuningErrorCents` is
/// `floor(cents)`.
public struct WebTunaResult: Equatable, Sendable {
    public var canHearANote: Bool
    public var currentString: Int
    public var inTuneRatio: Double
    public var measuredPitchHz: Double
    public var measuredPitchMidi: Int
    public var micRms: Double
    public var possibleWrongStringId: Int
    public var tuningErrorCents: Double
    public var info: String = "This is a product of Yousician Ltd."

    /// The stub `analyseBuffer` returns when `checkDomain()` fails, i.e. when the
    /// page URL is not guitartuna/yousician/localhost (§2.3). The Swift port has
    /// no domain to check, so this is exposed for completeness only.
    public static let stub = WebTunaResult(canHearANote: false, currentString: -1,
                                            inTuneRatio: 0, measuredPitchHz: 0,
                                            measuredPitchMidi: -48, micRms: 0,
                                            possibleWrongStringId: -1, tuningErrorCents: 0)
}

/// The 1/15-semitone pitch decision chain and the per-call state machine.
///
/// WEBTUNA.md §3.6–§3.8, §4.6–§4.7. Every constant below is either quoted from
/// those sections or read out of the live engine.
public struct PitchDecision {
    /// §3.7: `g[47] = 15`, fixed.
    public static let ratioDenominator = 15
    /// §3.6: the stability counter saturates here.
    public static let stabilityCap = 17
    /// §3.6: the two derived booleans latch here ("`k[68]`, `k[69]`, both read out
    /// as 5 live").
    public static let latchThreshold = 5
    /// §3.6: a candidate must be within this many cents of the current pitch.
    public static let continuityCents: Float = 350
    /// §3.6: the second, tighter continuity test.
    public static let secondGateCents: Float = 70
    /// §3.6: chromatic mode's own gate.
    public static let chromaticCents: Float = 10
    /// §3.6: the pitch EMA.
    public static let emaOld: Float = 0.75
    public static let emaNew: Float = 0.25
    /// §3.6: the recent-pitch ring is 7 deep.
    public static let pitchRingSize = 7
    /// §3.8: `MicRms` is a hard 64-frame peak hold times this constant.
    public static let rmsRingSize = 64
    public static let micRmsScale: Float = 128
}

/// The mutable state. One instance per engine — WEBTUNA.md §5.10 notes the real
/// engine is a process-wide singleton with no reset, so a conformance harness has
/// to start a fresh one per case; `WebTunaReferenceEngine` is a value-holding
/// class so that is a one-liner.
public struct DetectorState {
    // --- framing ---
    public var ring = [Float](repeating: 0, count: FrameGeometry.realSize)
    public var writeCursor = 0

    // --- confidence ---
    /// The 7-entry recent-pitch ring and its cursor (`g[2]`, `g[3]`, `g[10]`).
    public var pitchRing = [Float](repeating: 0, count: PitchDecision.pitchRingSize)
    public var pitchRingCursor = 0
    /// `g[9]`: agreeing-result counter, clamped to 15. Advances **once per call**
    /// even though two FFT frames run per call (§3.7) — the mismatch §4.2 calls
    /// ~130 ms of avoidable latency.
    public var inTuneCount = 0
    /// `g[28]`: the stability counter, saturating at 17.
    public var stability = 0
    /// `g[14]`: consecutive agreeing frames; also the bonus applied to
    /// `inTuneCount` on the frame that first flags a note.
    public var agreeCount = 0
    /// `g[15]`: the smoothed pitch in Hz.
    public var smoothedPitch: Float = 0
    /// `g[28]`'s companion: `g[25]`, the string the engine has committed to.
    public var stableString = -1
    /// `g[27]`: the string currently being targeted.
    public var targetString = -1
    /// `g[16]`: the `stringIdx` argument the engine is currently running with.
    public var stringIndex: Int32 = -1
    /// `k[18]`: the state counter `h` that escalates 1 → 2 → 3 → …
    public var stateCounter = 0
    /// `k[76]`: "a `1` state is only re-entered while already flagged" (§3.6).
    public var stateFlag = false
    /// `k[20]`, `k[21]`: the previous frame's salience and refined value.
    public var previousSalience: Float = 0
    public var previousValue: Float = 0
    /// `g[104]`: "a note is present" latch. Drives `CanHearANote` and resets the
    /// `InTuneRatio` counter.
    public var noteLatched = false
    /// `g[116]`: what the engine reports as `CurrentString`.
    public var reportedString = 0

    // --- level meter ---
    /// `k[35]`: a 64-frame ring of per-frame spectrum RMS, peak-held (§3.8).
    public var rmsRing = [Float](repeating: 0, count: PitchDecision.rmsRingSize)
    public var rmsCursor = 0
    public var micRms: Float = 0

    // --- output smoothing ---
    /// `g[34]`: the pitch actually reported in Hz, cleared only when the mode
    /// changes (§4.6: "MeasuredPitchHz is never cleared").
    public var reportedPitch: Float = 0
    /// `g[37]`: the clamped measured frequency; `rint` of it is `MeasuredPitchHz`.
    public var clampedPitch: Float = 0
    /// `g[11]`: a 50/50 smoother on the reported pitch.
    public var reportedPitchSmoothed: Float = 0
    /// `g[33]`: the value fed into that smoother.
    public var pitchReport: Float = 0
    // --- diagnostics, not part of the algorithm ---
    /// How many frames found a grid peak, and how many of those passed §3.6's
    /// three-part harmonic-support gate. Instrumentation for the reference port:
    /// the decompile routes a *failure* into a continuity search rather than
    /// rejecting, so this ratio is a description, not a filter. See
    /// DIVERGENCES.md D7.
    public var harmonicGatePasses = 0
    public var harmonicGateOpportunities = 0

    public init() {}
}

/// Cents helper, matching the engine's own arithmetic. The engine computes
/// `logf(x) * 1200 * 1.442695`; `1.442695` is `log2(e)` truncated to six decimals,
/// so a plain `1200 * log2(x)` differs by about 1 part in 4·10⁶ — irrelevant, but
/// the truncation is reproduced so the arithmetic is auditable.
@inline(__always)
public func cents(fromRatio ratio: Float) -> Float {
    let x = max(1.0, ratio)      // `select_if(1.0f, x, x < 1.0f)`: clamp below at 1
    return logf(x) * 1200.0 * 1.442695
}
