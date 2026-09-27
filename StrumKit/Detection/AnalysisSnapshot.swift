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
