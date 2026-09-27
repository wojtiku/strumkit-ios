/// The standard tuning calibration frequency constants.
enum TunerConstants {
    static let defaultA4Hz: Double = 440.0
    static let minCalibrationHz: Double = 415.0
    static let maxCalibrationHz: Double = 466.0

    static let customMidiMin: Int = 33 // A1
    static let customMidiMax: Int = 83 // B5

    static let detectorMinHz: Double = 50.0
    static let detectorMaxHz: Double = 1100.0

    static let maxDetuningCents: Double = 200.0
}
