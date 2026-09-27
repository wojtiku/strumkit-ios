/// Official presets matching chorder/src/audio/tuner/presets.ts
enum Presets {
    static let guitar: [TuningPreset] = [
        TuningPreset(id: "standard", label: "Standard · E A D G B E", midi: [40, 45, 50, 55, 59, 64]),
        TuningPreset(id: "drop-d", label: "Drop D", midi: [38, 45, 50, 55, 59, 64]),
        TuningPreset(id: "drop-c", label: "Drop C", midi: [36, 43, 48, 53, 57, 62]),
        TuningPreset(id: "drop-b", label: "Drop B", midi: [35, 42, 47, 52, 56, 61]),
        TuningPreset(id: "drop-a", label: "Drop A", midi: [33, 40, 45, 50, 54, 59]),
        TuningPreset(id: "half-down", label: "Half step down", midi: [39, 44, 49, 54, 58, 63]),
        TuningPreset(id: "full-down", label: "Full step down", midi: [38, 43, 48, 53, 57, 62]),
        TuningPreset(id: "dadgad", label: "DADGAD", midi: [38, 45, 50, 55, 57, 62]),
        TuningPreset(id: "open-d", label: "Open D", midi: [38, 45, 50, 54, 57, 62]),
        TuningPreset(id: "open-g", label: "Open G", midi: [38, 43, 50, 55, 59, 62])
    ]

    static let ukulele: [TuningPreset] = [
        TuningPreset(id: "high-g", label: "High G · G C E A", midi: [67, 60, 64, 69]),
        TuningPreset(id: "low-g", label: "Low G · G C E A", midi: [55, 60, 64, 69]),
        TuningPreset(id: "baritone", label: "Baritone · D G B E", midi: [50, 55, 59, 64]),
        TuningPreset(id: "d-tuning", label: "D tuning · A D F♯ B", midi: [69, 62, 66, 71])
    ]

    static func presets(for instrument: InstrumentCategory) -> [TuningPreset] {
        switch instrument {
        case .guitar: guitar
        case .ukulele: ukulele
        }
    }

    /// Available MIDI notes for custom tuning selection (A1 to B5 inclusively).
    static let customNotes: [Int] = Array(TunerConstants.customMidiMin...TunerConstants.customMidiMax)
}
