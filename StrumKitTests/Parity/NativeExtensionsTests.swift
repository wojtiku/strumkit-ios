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

    @Test("All shipped guitar presets resolve to 6 targets with descending string indices 6..1")
    func shippedGuitarPresetsValidation() {
        for preset in Presets.guitar {
            let targets = FaithfulTargetResolver.resolve(instrument: .guitar, presetId: preset.id)
            #expect(targets.count == 6, "Preset \(preset.id) must have 6 targets")

            for (index, target) in targets.enumerated() {
                let expectedStringNum = 6 - index
                #expect(target.stringNumber == expectedStringNum, "String number must be \(expectedStringNum)")

                let expectedMidi = preset.midi[index]
                #expect(target.midi == expectedMidi)

                let expectedFreq = PitchMath.midiFrequency(expectedMidi, a4: 440.0)
                #expect(abs(target.frequency - expectedFreq) < 1e-9)
            }
        }
    }

    @Test("All shipped ukulele presets and Baritone resolve to 4 targets with string indices 4..1")
    func shippedUkulelePresetsValidation() {
        for preset in Presets.ukulele {
            let targets = FaithfulTargetResolver.resolve(instrument: .ukulele, presetId: preset.id)
            #expect(targets.count == 4, "Ukulele preset \(preset.id) must have 4 targets")

            for (index, target) in targets.enumerated() {
                let expectedStringNum = 4 - index
                #expect(target.stringNumber == expectedStringNum, "String number must be \(expectedStringNum)")

                let expectedMidi = preset.midi[index]
                #expect(target.midi == expectedMidi)

                let expectedFreq = PitchMath.midiFrequency(expectedMidi, a4: 440.0)
                #expect(abs(target.frequency - expectedFreq) < 1e-9)
            }
        }

        // Verify Baritone specifically
        let baritoneTargets = FaithfulTargetResolver.resolve(instrument: .ukulele, presetId: "baritone")
        #expect(baritoneTargets.map(\.note) == ["D3", "G3", "B3", "E4"])
        #expect(baritoneTargets.map(\.midi) == [50, 55, 59, 64])
        #expect(baritoneTargets.compactMap(\.stringNumber) == [4, 3, 2, 1])

        // Verify profile resolution for Baritone uses extended range
        let baritoneProfile = FaithfulEngineProfile.profile(for: .ukulele, tuningId: "baritone")
        #expect(baritoneProfile == .extendedRange)
    }

    @Test("Custom tuning range (MIDI 33..83) resolves accurately")
    func customTuningRangeValidation() {
        let allCustomNotes = Presets.customNotes
        #expect(allCustomNotes.first == 33) // A1 (55.0 Hz)
        #expect(allCustomNotes.last == 83)  // B5 (987.77 Hz)

        let customPresetMidi = [33, 40, 50, 60, 70, 83]
        let targets = FaithfulTargetResolver.resolve(instrument: .guitar, presetId: "custom", customMidi: customPresetMidi)
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
        let nominalA4Standard = 440.0
        let nominalA4Calibrated = 432.0

        let targets440 = FaithfulTargetResolver.resolve(midi: [69], calibrationA4: nominalA4Standard)
        let targets432 = FaithfulTargetResolver.resolve(midi: [69], calibrationA4: nominalA4Calibrated)

        #expect(targets440[0].frequency == 440.0)
        #expect(targets432[0].frequency == 432.0)

        // Target frequency ratio is exactly 432/440 (-31.76665 cents)
        let expectedCentsShift = 1200.0 * log2(432.0 / 440.0)
        let actualCentsShift = centsBetween(frequency: targets432[0].frequency, reference: targets440[0].frequency)
        #expect(abs(actualCentsShift - expectedCentsShift) < 1e-9)

        // Engine DSP detection on 432 Hz audio still measures 432 Hz regardless of calibration
        let buffer432 = makeTone(frequency: 432.0, sampleRate: 48000.0)
        let candidate = FaithfulStatelessDetector.detectPitch(input: buffer432, sampleRate: 48000.0)
        #expect(candidate != nil)
        #expect(abs(candidate!.frequency - 432.0) < 0.05)

        // When measuring a 432 Hz reading against 432 Hz target, deviation is 0.0 cents
        let reading432 = FaithfulReading(
            frequency: 432.0,
            cents: 0.0,
            index: 0,
            note: "A4",
            inTune: true,
            rms: 0.07,
            stringNumber: 1
        )
        let nativeReading = FaithfulReadingAdapter.adapt(
            reading: reading432,
            rawFrequency: 432.0,
            timeMs: 1000.0,
            lastFreshTimeMs: 1000.0,
            freshness: .fresh,
            targets: targets432,
            mode: .auto,
            calibrationA4: 432.0
        )
        #expect(abs(nativeReading.cents) < 1e-6)
    }

    // MARK: - 5. Chromatic Mode Semantics

    @Test("Chromatic mode produces Note without Target and nil inTune")
    func chromaticModeSemantics() {
        let adapter = FaithfulReadingAdapter(mode: .chromatic)
        let targetList = [target("A4", 69)]

        let reading = FaithfulReading(
            frequency: 440.0,
            cents: 0.0,
            index: 0,
            note: "A4",
            inTune: true,
            rms: 0.07,
            stringNumber: 1
        )

        let nativeReading = FaithfulReadingAdapter.adapt(
            reading: reading,
            rawFrequency: 440.0,
            timeMs: 1000.0,
            lastFreshTimeMs: 1000.0,
            freshness: .fresh,
            targets: targetList,
            mode: .chromatic
        )

        // ReadingAim must be .note, never .target
        #expect(nativeReading.aim.target == nil, "Chromatic mode must have nil target")
        #expect(nativeReading.aim.inTune == nil, "Chromatic mode must have nil inTune verdict")
        #expect(nativeReading.inTune == nil, "TunerReading.inTune must be nil in chromatic mode")
        #expect(nativeReading.note == "A4")
        #expect(abs(nativeReading.cents) < 0.01)
    }

    // MARK: - 6. Guided Sequence Advancement Requirements

    @Test("Guided sequence strictly requires fresh measured confirmation to complete string")
    func guidedSequenceCompletionGate() {
        let sequence = FaithfulGuidedSequence(targetCount: 4)
        #expect(sequence.currentTargetIndex == 0)
        #expect(sequence.progress == [false, false, false, false])
        #expect(!sequence.isComplete)

        // 1. Proximity alone (cents = 0.0, but inTune = false): NO advancement
        let readingInProximityOnly = TunerReading(
            at: 1.0,
            lastFreshAt: 1.0,
            frequency: 440.0,
            aim: .target(StringTarget(note: "G4", midi: 67, frequency: 391.99, number: 4), inTune: false),
            cents: 0.0,
            displayCents: 0.0,
            freshness: .fresh,
            evidence: .measured
        )
        let advanced1 = sequence.observe(reading: readingInProximityOnly, targetIndex: 0)
        #expect(!advanced1, "Proximity alone without inTune confirmation must never advance guided sequence")
        #expect(sequence.currentTargetIndex == 0)
        #expect(sequence.progress[0] == false)

        // 2. Held freshness (inTune = true, but freshness = .held): NO advancement
        let readingHeld = TunerReading(
            at: 1.5,
            lastFreshAt: 1.0,
            frequency: 440.0,
            aim: .target(StringTarget(note: "G4", midi: 67, frequency: 391.99, number: 4), inTune: true),
            cents: 0.0,
            displayCents: 0.0,
            freshness: .held,
            evidence: .measured
        )
        let advanced2 = sequence.observe(reading: readingHeld, targetIndex: 0)
        #expect(!advanced2, "Held reading must never advance guided sequence")
        #expect(sequence.currentTargetIndex == 0)

        // 3. Sustained evidence (inTune = true, but evidence = .sustained): NO advancement
        let readingSustained = TunerReading(
            at: 2.0,
            lastFreshAt: 2.0,
            frequency: 440.0,
            aim: .target(StringTarget(note: "G4", midi: 67, frequency: 391.99, number: 4), inTune: true),
            cents: 0.0,
            displayCents: 0.0,
            freshness: .fresh,
            evidence: .sustained
        )
        let advanced3 = sequence.observe(reading: readingSustained, targetIndex: 0)
        #expect(!advanced3, "Sustained evidence must never advance guided sequence")
        #expect(sequence.currentTargetIndex == 0)

        // 4. Out-of-order string confirmation (tuning string 1 while waiting for string 0): NO advancement
        let readingWrongString = TunerReading(
            at: 2.5,
            lastFreshAt: 2.5,
            frequency: 440.0,
            aim: .target(StringTarget(note: "C4", midi: 60, frequency: 261.63, number: 3), inTune: true),
            cents: 0.0,
            displayCents: 0.0,
            freshness: .fresh,
            evidence: .measured
        )
        let advanced4 = sequence.observe(reading: readingWrongString, targetIndex: 1)
        #expect(!advanced4, "Out-of-order string must not complete active string")
        #expect(sequence.currentTargetIndex == 0)

        // 5. Fresh measured confirmation on string 0: ADVANCE to string 1!
        let readingConfirmed0 = TunerReading(
            at: 3.0,
            lastFreshAt: 3.0,
            frequency: 392.0,
            aim: .target(StringTarget(note: "G4", midi: 67, frequency: 391.99, number: 4), inTune: true),
            cents: 0.0,
            displayCents: 0.0,
            freshness: .fresh,
            evidence: .measured
        )
        let advanced5 = sequence.observe(reading: readingConfirmed0, targetIndex: 0)
        #expect(advanced5, "Fresh measured confirmation must complete string 0")
        #expect(sequence.progress[0] == true)
        #expect(sequence.currentTargetIndex == 1)

        // 6. Complete remaining strings sequentially
        for i in 1...3 {
            let readingConfirmed = TunerReading(
                at: Double(i + 3),
                lastFreshAt: Double(i + 3),
                frequency: 440.0,
                aim: .target(StringTarget(note: "A4", midi: 69, frequency: 440.0, number: 4 - i), inTune: true),
                cents: 0.0,
                displayCents: 0.0,
                freshness: .fresh,
                evidence: .measured
            )
            let adv = sequence.observe(reading: readingConfirmed, targetIndex: i)
            #expect(adv)
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

    // MARK: - 7. Precision Preferences Presentation Overlay

    @Test("Precision preference overlay formats and checks presentation without mutating confirmation")
    func precisionPreferencesPresentationOverlay() {
        var pref = FaithfulPrecisionPreference(isHighPrecision: false)
        #expect(pref.isPreciseInTune(cents: 4.5) == true, "Standard ±5c allows 4.5c")
        #expect(pref.isPreciseInTune(cents: 5.5) == false, "Standard ±5c rejects 5.5c")
        #expect(pref.formatCents(4.2) == "4", "Standard formats integer")
        #expect(pref.formatCents(4.6) == "5", "Standard formats integer")

        pref.isHighPrecision = true
        #expect(pref.isPreciseInTune(cents: 1.8) == true, "High-precision ±2c allows 1.8c")
        #expect(pref.isPreciseInTune(cents: 2.5) == false, "High-precision ±2c rejects 2.5c")
        #expect(pref.formatCents(1.8) == "1.8", "High precision formats tenth decimal")
    }
}
