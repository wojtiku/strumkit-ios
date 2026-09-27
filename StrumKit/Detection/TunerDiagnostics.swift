public struct TunerDiagnostics: Sendable, Equatable {
    public var sampleRate: Double = 44100.0
    public var analysisMs: Double = 0.0
    public var dspMs: Double = 0.0
    public var queueDelayMs: Double = 0.0
    public var resultAgeMs: Double = 0.0
    public var replacedFrames: UInt64 = 0
    public var callbackFrameCount: Int = 0
    public var dropped: Int = 0
    public var level: Double = 0.0

    public init(
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
