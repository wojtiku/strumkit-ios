struct TunerDiagnostics: Sendable, Equatable {
    var sampleRate: Double = 44100.0
    var analysisMs: Double = 0.0
    var dspMs: Double = 0.0
    var queueDelayMs: Double = 0.0
    var resultAgeMs: Double = 0.0
    var replacedFrames: UInt64 = 0
    var callbackFrameCount: Int = 0
    var dropped: Int = 0
    var level: Double = 0.0

    init(
        sampleRate: Double = 44100.0,
        analysisMs: Double = 0.0,
        dspMs: Double = 0.0,
        queueDelayMs: Double = 0.0,
        resultAgeMs: Double = 0.0,
        replacedFrames: UInt64 = 0,
        callbackFrameCount: Int = 0,
        dropped: Int = 0,
        level: Double = 0.0
    ) {
        self.sampleRate = sampleRate
        self.analysisMs = analysisMs
        self.dspMs = dspMs
        self.queueDelayMs = queueDelayMs
        self.resultAgeMs = resultAgeMs
        self.replacedFrames = replacedFrames
        self.callbackFrameCount = callbackFrameCount
        self.dropped = dropped
        self.level = level
    }
}
