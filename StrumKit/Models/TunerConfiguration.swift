import Foundation

/// User preferences and runtime configuration for the tuning engine.
public struct TunerConfiguration: Sendable, Equatable {
    /// Reference frequency for note A4 (standard concert pitch is 440 Hz).
    public var referenceA4: Double = 440.0

    /// Threshold in cents within which a note is considered perfectly in-tune.
    public var inTuneToleranceCents: Double = 3.0

    /// Minimum RMS amplitude required to process pitch detection (noise gate).
    public var noiseGateRMS: Float = 0.012

    /// YIN algorithm threshold parameter (0.10 - 0.15 is standard).
    public var yinThreshold: Float = 0.15

    /// When true, automatically locks onto the closest string in the current tuning.
    /// When false, locks strictly to `selectedStringIndex`.
    public var autoDetectString: Bool = true

    /// Currently selected string number (1-based), or nil if auto-detecting.
    public var selectedStringNumber: Int? = nil

    /// Whether acoustic pitch pipe tone generation is enabled.
    public var isPitchPipeEnabled: Bool = false

    public init(
        referenceA4: Double = 440.0,
        inTuneToleranceCents: Double = 3.0,
        noiseGateRMS: Float = 0.012,
        yinThreshold: Float = 0.15,
        autoDetectString: Bool = true,
        selectedStringNumber: Int? = nil,
        isPitchPipeEnabled: Bool = false
    ) {
        self.referenceA4 = referenceA4
        self.inTuneToleranceCents = inTuneToleranceCents
        self.noiseGateRMS = noiseGateRMS
        self.yinThreshold = yinThreshold
        self.autoDetectString = autoDetectString
        self.selectedStringNumber = selectedStringNumber
        self.isPitchPipeEnabled = isPitchPipeEnabled
    }
}
