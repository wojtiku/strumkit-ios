import Testing
import Foundation
@testable import StrumKit

@Suite("Musical Note & Pitch Math Tests")
struct MusicalNoteTests {

    @Test("Standard Concert Pitch A4 is 440 Hz")
    func testStandardA4() {
        let freq = PitchMath.midiFrequency(69, a4: 440.0)
        #expect(abs(freq - 440.0) < 0.001)
        #expect(PitchMath.midiNoteName(69) == "A4")
    }

    @Test("Guitar standard open strings match theoretical MIDI numbers and frequencies")
    func testGuitarOpenStrings() {
        // E2: 40, A2: 45, D3: 50, G3: 55, B3: 59, E4: 64
        #expect(PitchMath.midiNoteName(40) == "E2")
        #expect(abs(PitchMath.midiFrequency(40) - 82.41) < 0.05)

        #expect(PitchMath.midiNoteName(45) == "A2")
        #expect(abs(PitchMath.midiFrequency(45) - 110.00) < 0.05)

        #expect(PitchMath.midiNoteName(50) == "D3")
        #expect(abs(PitchMath.midiFrequency(50) - 146.83) < 0.05)

        #expect(PitchMath.midiNoteName(55) == "G3")
        #expect(abs(PitchMath.midiFrequency(55) - 196.00) < 0.05)

        #expect(PitchMath.midiNoteName(59) == "B3")
        #expect(abs(PitchMath.midiFrequency(59) - 246.94) < 0.05)

        #expect(PitchMath.midiNoteName(64) == "E4")
        #expect(abs(PitchMath.midiFrequency(64) - 329.63) < 0.05)
    }

    @Test("Ukulele standard open strings match theoretical MIDI numbers and frequencies")
    func testUkuleleOpenStrings() {
        // High-G: 67 (G4), 60 (C4), 64 (E4), 69 (A4)
        #expect(PitchMath.midiNoteName(67) == "G4")
        #expect(abs(PitchMath.midiFrequency(67) - 392.00) < 0.05)

        #expect(PitchMath.midiNoteName(60) == "C4")
        #expect(abs(PitchMath.midiFrequency(60) - 261.63) < 0.05)

        #expect(PitchMath.midiNoteName(64) == "E4")
        #expect(abs(PitchMath.midiFrequency(64) - 329.63) < 0.05)

        #expect(PitchMath.midiNoteName(69) == "A4")
        #expect(abs(PitchMath.midiFrequency(69) - 440.00) < 0.05)
    }

    @Test("Cents between measured and reference")
    func testCentsBetween() {
        // Exactly 440 Hz
        #expect(abs(PitchMath.centsBetween(measured: 440.0, reference: 440.0)) < 0.001)

        // 10 cents sharp: 440 * 2^(10/1200) ≈ 442.55 Hz
        let sharp = 440.0 * pow(2.0, 10.0 / 1200.0)
        #expect(abs(PitchMath.centsBetween(measured: sharp, reference: 440.0) - 10.0) < 0.05)

        // 15 cents flat: 440 * 2^(-15/1200) ≈ 436.20 Hz
        let flat = 440.0 * pow(2.0, -15.0 / 1200.0)
        #expect(abs(PitchMath.centsBetween(measured: flat, reference: 440.0) - (-15.0)) < 0.05)
    }

    @Test("Note splitting splits base and octave properly")
    func testSplitNoteName() {
        let (e, oct2) = PitchMath.splitNoteName("E2")
        #expect(e == "E")
        #expect(oct2 == "2")

        let (fSharp, oct4) = PitchMath.splitNoteName("F♯4")
        #expect(fSharp == "F♯")
        #expect(oct4 == "4")
    }

    @Test("Alternate reference pitch A4 = 432 Hz calibration")
    func testA4Calibration() {
        let a4At432 = PitchMath.midiFrequency(69, a4: 432.0)
        #expect(abs(a4At432 - 432.0) < 0.001)

        let nearest = PitchMath.nearestMidi(for: 432.0, a4: 432.0)
        #expect(nearest?.note == "A4")
        #expect(abs(nearest!.cents) < 0.01)
    }
}
