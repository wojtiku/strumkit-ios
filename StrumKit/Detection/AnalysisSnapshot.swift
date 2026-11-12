/// What one hop of audio changed about the display, as the analysis session publishes it.
struct AnalysisSnapshot: Sendable, Equatable {
    /// The **Reading** to show, or `nil` to show nothing.
    let reading: TunerReading?
    let feedbackState: SignalFeedbackState
    let guidedProgress: [Bool]
    let guidedTargetIndex: Int
    let diagnostics: TunerDiagnostics
    /// The configuration generation this was computed under. A consumer drops a
    /// snapshot whose generation is no longer the session's.
    let generation: UInt64
    let sequence: UInt64

    init(
        reading: TunerReading?,
        feedbackState: SignalFeedbackState,
        guidedProgress: [Bool],
        guidedTargetIndex: Int,
        diagnostics: TunerDiagnostics,
        generation: UInt64,
        sequence: UInt64
    ) {
        self.reading = reading
        self.feedbackState = feedbackState
        self.guidedProgress = guidedProgress
        self.guidedTargetIndex = guidedTargetIndex
        self.diagnostics = diagnostics
        self.generation = generation
        self.sequence = sequence
    }
}
