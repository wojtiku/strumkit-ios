struct TunerConfig: Sendable, Equatable, Codable {
    var instrument: InstrumentCategory
    var tuningId: String
    var customMidi: [Int]
    var a4: Double
    var mode: TunerMode
    var selectedString: Int // Index 0 ..< targets.count

    init(
        instrument: InstrumentCategory = .guitar,
        tuningId: String = "standard",
        customMidi: [Int] = [40, 45, 50, 55, 59, 64],
        a4: Double = TunerConstants.defaultA4Hz,
        mode: TunerMode = .auto,
        selectedString: Int = 0
    ) {
        self.instrument = instrument
        self.tuningId = tuningId
        self.customMidi = customMidi
        self.a4 = a4
        self.mode = mode
        self.selectedString = selectedString
    }
}
