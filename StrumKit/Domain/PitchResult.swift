/// Analyzed pitch state from the DSP pipeline.
struct PitchResult: Sendable, Equatable {
    let frequency: Double
    let closestNote: MusicalNote
    let centsDeviation: Double
    let confidence: Double
    let amplitudeRMS: Double
    let isSignalPresent: Bool
    let evidence: Evidence
    /// `true` when the input exceeded the clipping threshold, which forces
    /// abstention independently of level.
    let isClipped: Bool

    init(
        frequency: Double,
        closestNote: MusicalNote,
        centsDeviation: Double,
        confidence: Double,
        amplitudeRMS: Double,
        isSignalPresent: Bool,
        evidence: Evidence,
        isClipped: Bool = false
    ) {
        self.frequency = frequency
        self.closestNote = closestNote
        self.centsDeviation = centsDeviation
        self.confidence = confidence
        self.amplitudeRMS = amplitudeRMS
        self.isSignalPresent = isSignalPresent
        self.evidence = evidence
        self.isClipped = isClipped
    }

    /// The placeholder for a frame that was never analysed — no signal, or nothing
    /// the estimator was willing to name. Nothing was heard, so nothing is being
    /// claimed: `isSignalPresent` is false, and every consumer of a `PitchResult`
    /// acts on that before it acts on anything else here.
    static let idle = PitchResult(
        frequency: 0,
        closestNote: MusicalNote(midiNoteNumber: 69),
        centsDeviation: 0,
        confidence: 0,
        amplitudeRMS: 0,
        isSignalPresent: false,
        evidence: .measured
    )
}
