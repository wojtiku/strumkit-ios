struct AnalysisSnapshot: Sendable, Equatable {
    let reading: TunerReading?
    let feedbackState: SignalFeedbackState
    let guidedProgress: [Bool]
    let guidedTargetIndex: Int
    let diagnostics: TunerDiagnostics
    let generation: UInt64
    let sequence: UInt64
    let action: FaithfulPresentation.Action

    init(
        reading: TunerReading?,
        feedbackState: SignalFeedbackState,
        guidedProgress: [Bool],
        guidedTargetIndex: Int,
        diagnostics: TunerDiagnostics,
        generation: UInt64,
        sequence: UInt64,
        action: FaithfulPresentation.Action = .empty
    ) {
        self.reading = reading
        self.feedbackState = feedbackState
        self.guidedProgress = guidedProgress
        self.guidedTargetIndex = guidedTargetIndex
        self.diagnostics = diagnostics
        self.generation = generation
        self.sequence = sequence
        self.action = action
    }
}
