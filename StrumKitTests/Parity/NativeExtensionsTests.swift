// StrumKitTests/Parity/NativeExtensionsTests.swift
import Foundation
import Testing
@testable import StrumKit

@Suite("Native Extensions and Engine Profile Tests")
struct NativeExtensionsTests {

    let budgets = ParityBudgets.frozen

    // Helper: generates a pure sine wave at a given sample rate and frequency
    private func makeTone(frequency: Double, sampleRate: Double = 48000.0, amplitude: Float = 0.1, count: Int = 4096) -> [Float] {
        var buffer = [Float](repeating: 0, count: count)
        for i in 0..<count {
            buffer[i] = amplitude * Float(sin(2.0 * Double.pi * frequency * Double(i) / sampleRate))
        }
        return buffer
    }

    // MARK: - 1. Strict Ukulele Profile Isolation

    @Test("Strict ukulele profile rejects low guitar frequencies below 110 Hz")
    func strictUkuleleProfileRejectsOutOfBandLowFrequencies() {
        let profile = FaithfulEngineProfile.strictUkulele
        #expect(profile.validFrequency(82.4069) == false, "Guitar Low E must be invalid in strict ukulele profile")
        #expect(profile.validFrequency(73.4162) == false, "Drop D must be invalid in strict ukulele profile")
        #expect(profile.validFrequency(55.0) == false, "Drop A must be invalid in strict ukulele profile")
        #expect(profile.validFrequency(440.0) == true, "A4 must be valid in strict ukulele profile")
        #expect(profile.validFrequency(110.0) == true, "110 Hz lower boundary must be valid")
        #expect(profile.validFrequency(1100.0) == true, "1100 Hz upper boundary must be valid")
        #expect(profile.validFrequency(1101.0) == false, "1101 Hz must be invalid in strict ukulele profile")

        // Detecting an 82.41 Hz Low E using strict profile produces nil
        let lowE = makeTone(frequency: 82.4069, sampleRate: 48000.0)
        let candidate = FaithfulStatelessDetector.detectPitch(input: lowE, sampleRate: 48000.0, profile: .strictUkulele)
        #expect(candidate == nil, "Strict profile must not accept low E below 110 Hz")
    }

    // MARK: - 2. Extended-Range Profile Guitar Detection

    @Test("Extended-range profile accurately detects Guitar Low E (82.41 Hz) at 48k and 44.1k")
    func extendedRangeDetectsGuitarLowE() {
        let nominalE2 = 82.4068892282175 // MIDI 40

        for rate in [48000.0, 44100.0] {
            let buffer = makeTone(frequency: nominalE2, sampleRate: rate)
            let candidate = FaithfulStatelessDetector.detectPitch(
                input: buffer,
                sampleRate: rate,
                profile: .extendedRange
            )

            #expect(candidate != nil, "Extended range must detect Low E at \(rate) Hz")
            guard let candidate = candidate else { continue }

            #expect(abs(candidate.frequency - nominalE2) < 0.1, "Detected frequency within 0.1 Hz of nominal Low E")
            let centsError = abs(1200.0 * log2(candidate.frequency / nominalE2))
            #expect(centsError < 1.0, "Low E detection error must be under 1 cent (actual: \(centsError) cents)")
            #expect(candidate.confidence > 0.99)
            #expect(candidate.oddOnly == nil)
        }
    }

    @Test("Extended-range profile accurately detects Drop D (73.42 Hz)")
    func extendedRangeDetectsDropD() {
        let nominalD2 = 73.41619197935188 // MIDI 38
        let rate = 48000.0

        let buffer = makeTone(frequency: nominalD2, sampleRate: rate)
        let candidate = FaithfulStatelessDetector.detectPitch(
            input: buffer,
            sampleRate: rate,
            profile: .extendedRange
        )

        #expect(candidate != nil, "Extended range must detect Drop D")
        guard let candidate = candidate else { return }

        #expect(abs(candidate.frequency - nominalD2) < 0.1)
        let centsError = abs(1200.0 * log2(candidate.frequency / nominalD2))
        #expect(centsError < 1.0, "Drop D detection error under 1 cent (actual: \(centsError) cents)")
        #expect(candidate.confidence > 0.99)
    }

    @Test("Extended-range profile accurately detects Drop A (55.0 Hz)")
    func extendedRangeDetectsDropA() {
        let nominalA1 = 55.0 // MIDI 33
        let rate = 48000.0

        let buffer = makeTone(frequency: nominalA1, sampleRate: rate)
        let candidate = FaithfulStatelessDetector.detectPitch(
            input: buffer,
            sampleRate: rate,
            profile: .extendedRange
        )

        #expect(candidate != nil, "Extended range must detect Drop A (55 Hz)")
        guard let candidate = candidate else { return }

        #expect(abs(candidate.frequency - nominalA1) < 0.1)
        let centsError = abs(1200.0 * log2(candidate.frequency / nominalA1))
        #expect(centsError < 1.0, "Drop A detection error under 1 cent (actual: \(centsError) cents)")
        #expect(candidate.confidence > 0.98)
    }

    @Test("Extended-range profile accurately detects High E (329.63 Hz)")
    func extendedRangeDetectsHighE() {
        let nominalE4 = 329.6275569128699 // MIDI 64
        let rate = 48000.0

        let buffer = makeTone(frequency: nominalE4, sampleRate: rate)
        let candidate = FaithfulStatelessDetector.detectPitch(
            input: buffer,
            sampleRate: rate,
            profile: .extendedRange
        )

        #expect(candidate != nil)
        guard let candidate = candidate else { return }
        #expect(abs(candidate.frequency - nominalE4) < 0.05)
        #expect(candidate.confidence > 0.99)
    }

    // MARK: - 3. Shipped Presets, Baritone, and Custom Notes

    private func resolvedTargets(
        _ instrument: InstrumentCategory, _ tuningId: String, customMidi: [Int] = [], a4: Double = 440.0
    ) -> [StringTarget] {
        Tuning.resolve(
            instrument: instrument, tuningId: tuningId, customMidi: customMidi,
            mode: .auto, a4: a4).targets
    }

    @Test("All shipped guitar presets resolve to 6 targets with descending string indices 6..1")
    func shippedGuitarPresetsValidation() {
        for preset in Presets.guitar {
            let targets = resolvedTargets(.guitar, preset.id)
            #expect(targets.count == 6, "Preset \(preset.id) must have 6 targets")

            for (index, target) in targets.enumerated() {
                #expect(target.number == 6 - index)
                #expect(target.midi == preset.midi[index])
                #expect(abs(target.frequency - PitchMath.midiFrequency(preset.midi[index], a4: 440.0)) < 1e-9)
            }
        }
    }

    @Test("All shipped ukulele presets and Baritone resolve to 4 targets with string indices 4..1")
    func shippedUkulelePresetsValidation() {
        for preset in Presets.ukulele {
            let targets = resolvedTargets(.ukulele, preset.id)
            #expect(targets.count == 4, "Ukulele preset \(preset.id) must have 4 targets")

            for (index, target) in targets.enumerated() {
                #expect(target.number == 4 - index)
                #expect(target.midi == preset.midi[index])
                #expect(abs(target.frequency - PitchMath.midiFrequency(preset.midi[index], a4: 440.0)) < 1e-9)
            }
        }

        // Verify Baritone specifically
        let baritoneTargets = resolvedTargets(.ukulele, "baritone")
        #expect(baritoneTargets.map(\.note) == ["D3", "G3", "B3", "E4"])
        #expect(baritoneTargets.map(\.midi) == [50, 55, 59, 64])
        #expect(baritoneTargets.map(\.number) == [4, 3, 2, 1])

        // Verify profile resolution for Baritone uses extended range
        let baritoneProfile = FaithfulEngineProfile.profile(for: .ukulele, tuningId: "baritone")
        #expect(baritoneProfile == .extendedRange)
    }

    @Test("Custom tuning range (MIDI 33..83) resolves accurately")
    func customTuningRangeValidation() {
        let allCustomNotes = Presets.customNotes
        #expect(allCustomNotes.first == 33) // A1 (55.0 Hz)
        #expect(allCustomNotes.last == 83)  // B5 (987.77 Hz)

        let targets = resolvedTargets(.guitar, Tuning.customTuningId, customMidi: [33, 40, 50, 60, 70, 83])
        #expect(targets.count == 6)
        #expect(targets[0].note == "A1")
        #expect(targets[0].midi == 33)
        #expect(abs(targets[0].frequency - 55.0) < 1e-9)
        #expect(targets[5].note == "B5")
        #expect(targets[5].midi == 83)
    }

    // MARK: - 4. Dynamic Calibration (432 Hz vs 440 Hz)

    @Test("Dynamic calibration shifts target frequencies atomically without mutating DSP detection")
    func dynamicCalibrationTargetShift() {
        // High-G ukulele: the fourth String is A4.
        let targets440 = resolvedTargets(.ukulele, "high-g", a4: 440.0)
        let targets432 = resolvedTargets(.ukulele, "high-g", a4: 432.0)

        #expect(targets440[3].frequency == 440.0)
        #expect(targets432[3].frequency == 432.0)

        // Target frequency ratio is exactly 432/440 (-31.76665 cents)
        let expectedCentsShift = 1200.0 * log2(432.0 / 440.0)
        let actualCentsShift = centsBetween(frequency: targets432[3].frequency, reference: targets440[3].frequency)
        #expect(abs(actualCentsShift - expectedCentsShift) < 1e-9)

        // Engine DSP detection on 432 Hz audio still measures 432 Hz regardless of calibration
        let buffer432 = makeTone(frequency: 432.0, sampleRate: 48000.0)
        let candidate = FaithfulStatelessDetector.detectPitch(input: buffer432, sampleRate: 48000.0)
        #expect(candidate != nil)
        #expect(abs(candidate!.frequency - 432.0) < 0.05)

        // Through the engine, a 432 Hz tone is on the A4 String under 432 Hz Calibration,
        // and about 32 cents flat of it under 440 Hz.
        func lastReading(a4: Double) -> TunerReading? {
            let resolved = Tuning.resolve(
                instrument: .ukulele, tuningId: "high-g", customMidi: [],
                mode: .auto, a4: a4)
            let engine = ReadingEngine(configuration: ReadingEngine.Configuration(resolved), sampleRate: 48000.0)
            let tone = (0..<48000).map { i -> Float in
                let t = Double(i) / 48000.0
                return Float(sin(2.0 * .pi * 432.0 * t) + 0.5 * sin(2.0 * .pi * 864.0 * t)) * 0.15
            }
            return engine.push(tone, sampleRate: 48000.0).compactMap(\.display.reading).last
        }
        let calibrated = lastReading(a4: 432.0)
        #expect(calibrated?.aim.target?.note == "A4")
        #expect(abs(calibrated?.cents ?? 99) < 1.0)
        let standard = lastReading(a4: 440.0)
        #expect(standard?.aim.target?.note == "A4")
        #expect(abs((standard?.cents ?? 0) - expectedCentsShift) < 1.0)
    }

    // MARK: - 5. Guided Sequence Advancement Requirements

    @Test("Guided sequence strictly requires fresh measured confirmation to complete string")
    func guidedSequenceCompletionGate() {
        let sequence = FaithfulGuidedSequence(targetCount: 4)
        #expect(sequence.currentTargetIndex == 0)
        #expect(sequence.progress == [false, false, false, false])
        #expect(!sequence.isComplete)

        func tracked(index: Int, inTune: Bool) -> FaithfulReading {
            FaithfulReading(frequency: 392.0, cents: 0.0, index: index, note: "G4", inTune: inTune, rms: 0.1)
        }

        // 1. Proximity alone (cents = 0.0, but inTune = false): NO advancement
        #expect(!sequence.observe(reading: tracked(index: 0, inTune: false)),
                "Proximity alone without inTune confirmation must never advance guided sequence")
        #expect(sequence.currentTargetIndex == 0)
        #expect(sequence.progress[0] == false)

        // 2. Held freshness: NO advancement
        #expect(!sequence.observe(reading: tracked(index: 0, inTune: true), freshness: .held),
                "Held reading must never advance guided sequence")

        // 3. Sustained evidence: NO advancement
        #expect(!sequence.observe(reading: tracked(index: 0, inTune: true), evidence: .sustained),
                "Sustained evidence must never advance guided sequence")
        #expect(sequence.currentTargetIndex == 0)

        // 4. Out-of-order string confirmation: NO advancement
        #expect(!sequence.observe(reading: tracked(index: 1, inTune: true)),
                "Out-of-order string must not complete active string")
        #expect(sequence.currentTargetIndex == 0)

        // 5. Fresh measured confirmation on string 0: ADVANCE to string 1
        #expect(sequence.observe(reading: tracked(index: 0, inTune: true)),
                "Fresh measured confirmation must complete string 0")
        #expect(sequence.progress[0] == true)
        #expect(sequence.currentTargetIndex == 1)

        // 6. Complete remaining strings sequentially
        for i in 1...3 {
            #expect(sequence.observe(reading: tracked(index: i, inTune: true)))
            #expect(sequence.progress[i] == true)
        }

        #expect(sequence.isComplete, "All strings must be marked complete")
        #expect(sequence.progress == [true, true, true, true])

        // Reset restarts sequence
        sequence.reset()
        #expect(sequence.currentTargetIndex == 0)
        #expect(sequence.progress == [false, false, false, false])
        #expect(!sequence.isComplete)
    }
}
