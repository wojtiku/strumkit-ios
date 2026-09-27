struct AnalysisSnapshot: Sendable, Equatable {
    let reading: TunerReading?
    let pitchResult: PitchResult
    let feedbackState: SignalFeedbackState
    let guidedProgress: [Bool]
    let guidedTargetIndex: Int
    let diagnostics: TunerDiagnostics
    let generation: UInt64
    let sequence: UInt64

    init(
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
