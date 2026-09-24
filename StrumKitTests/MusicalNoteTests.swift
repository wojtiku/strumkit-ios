import Testing
import Foundation
@testable import StrumKit

@Suite("Musical Note & Pitch Math Tests")
struct MusicalNoteTests {

    @Test("Standard Concert Pitch A4 is 440 Hz")
    func testStandardA4() {
        let a4 = MusicalNote(noteName: .a, octave: 4, referenceA4: 440.0)
        #expect(abs(a4.frequency - 440.0) < 0.001)
        #expect(a4.midiNoteNumber == 69)
        #expect(a4.displayName == "A4")
    }

    @Test("Guitar standard tuning open strings match theoretical frequencies")
    func testGuitarOpenStrings() {
        let e2 = MusicalNote(noteName: .e, octave: 2)
        let a2 = MusicalNote(noteName: .a, octave: 2)
        let d3 = MusicalNote(noteName: .d, octave: 3)
        let g3 = MusicalNote(noteName: .g, octave: 3)
        let b3 = MusicalNote(noteName: .b, octave: 3)
        let e4 = MusicalNote(noteName: .e, octave: 4)

        #expect(abs(e2.frequency - 82.41) < 0.05)
        #expect(abs(a2.frequency - 110.00) < 0.05)
        #expect(abs(d3.frequency - 146.83) < 0.05)
        #expect(abs(g3.frequency - 196.00) < 0.05)
        #expect(abs(b3.frequency - 246.94) < 0.05)
        #expect(abs(e4.frequency - 329.63) < 0.05)
    }

    @Test("Ukulele standard tuning open strings match theoretical frequencies")
    func testUkuleleOpenStrings() {
        let g4 = MusicalNote(noteName: .g, octave: 4)
        let c4 = MusicalNote(noteName: .c, octave: 4)
        let e4 = MusicalNote(noteName: .e, octave: 4)
        let a4 = MusicalNote(noteName: .a, octave: 4)

        #expect(abs(g4.frequency - 392.00) < 0.05)
        #expect(abs(c4.frequency - 261.63) < 0.05)
        #expect(abs(e4.frequency - 329.63) < 0.05)
        #expect(abs(a4.frequency - 440.00) < 0.05)
    }

    @Test("Closest note detection and cents calculation")
    func testClosestNoteAndCents() {
        // Exactly A4 (440 Hz)
        let exactResult = MusicalNote.closest(to: 440.0, referenceA4: 440.0)
        #expect(exactResult != nil)
        #expect(exactResult?.note.displayName == "A4")
        #expect(abs(exactResult!.cents) < 0.01)

        // 10 cents sharp from A4: 440 * 2^(10/1200) ≈ 442.55 Hz
        let sharpFreq = 440.0 * pow(2.0, 10.0 / 1200.0)
        let sharpResult = MusicalNote.closest(to: sharpFreq, referenceA4: 440.0)
        #expect(sharpResult != nil)
        #expect(sharpResult?.note.displayName == "A4")
        #expect(abs(sharpResult!.cents - 10.0) < 0.05)

        // 15 cents flat from E2: 82.4069 * 2^(-15/1200) ≈ 81.696 Hz
        let flatFreq = 82.4069 * pow(2.0, -15.0 / 1200.0)
        let flatResult = MusicalNote.closest(to: flatFreq, referenceA4: 440.0)
        #expect(flatResult != nil)
        #expect(flatResult?.note.displayName == "E2")
        #expect(abs(flatResult!.cents - (-15.0)) < 0.05)
    }

    @Test("Alternate reference pitch A4 = 432 Hz calibration")
    func testA4Calibration() {
        let a4At432 = MusicalNote(noteName: .a, octave: 4, referenceA4: 432.0)
        #expect(abs(a4At432.frequency - 432.0) < 0.001)

        let result = MusicalNote.closest(to: 432.0, referenceA4: 432.0)
        #expect(result != nil)
        #expect(result?.note.displayName == "A4")
        #expect(abs(result!.cents) < 0.01)
    }
}
