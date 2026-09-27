/// The standard tuning calibration frequency constants.
public enum TunerConstants {
    public static let defaultA4Hz: Double = 440.0
    public static let minCalibrationHz: Double = 415.0
    public static let maxCalibrationHz: Double = 466.0

    public static let customMidiMin: Int = 33 // A1
    public static let customMidiMax: Int = 83 // B5

    public static let detectorMinHz: Double = 50.0
    public static let detectorMaxHz: Double = 1100.0

    public static let maxDetuningCents: Double = 200.0
}
