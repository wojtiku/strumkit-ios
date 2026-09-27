public struct TunerConfig: Sendable, Equatable, Codable {
    public var instrument: InstrumentCategory
    public var tuningId: String
    public var customMidi: [Int]
    public var a4: Double
    public var mode: TunerMode
    public var selectedString: Int // Index 0 ..< targets.count
    public var precision: Bool
    public var guided: Bool

    public init(
        instrument: InstrumentCategory = .guitar,
        tuningId: String = "standard",
        customMidi: [Int] = [40, 45, 50, 55, 59, 64],
        a4: Double = TunerConstants.defaultA4Hz,
        mode: TunerMode = .auto,
        selectedString: Int = 0,
        precision: Bool = false,
        guided: Bool = false
    ) {
        self.instrument = instrument
        self.tuningId = tuningId
        self.customMidi = customMidi
        self.a4 = a4
        self.mode = mode
        self.selectedString = selectedString
        self.precision = precision
        self.guided = guided
    }
}
