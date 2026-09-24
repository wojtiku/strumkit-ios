import Testing
import Foundation
@testable import StrumKit

@Suite("Instrument & Tuning Preset Tests")
struct TuningTests {

    @Test("Guitar standard tuning identifies correct strings")
    func testGuitarStandardStrings() {
        let guitar = Instrument.guitarInstrument()
        let standard = guitar.defaultTuning

        #expect(standard.strings.count == 6)

        // String 6 (E2 ~82.41 Hz)
        let lowEResult = standard.closestString(to: 83.0)
        #expect(lowEResult != nil)
        #expect(lowEResult?.string.stringNumber == 6)
        #expect(lowEResult?.string.note.displayName == "E2")

        // String 1 (E4 ~329.63 Hz)
        let highEResult = standard.closestString(to: 328.0)
        #expect(highEResult != nil)
        #expect(highEResult?.string.stringNumber == 1)
        #expect(highEResult?.string.note.displayName == "E4")
    }

    @Test("Ukulele standard re-entrant tuning identifies correct strings")
    func testUkuleleStandardStrings() {
        let uke = Instrument.ukuleleInstrument()
        let standard = uke.defaultTuning

        #expect(standard.strings.count == 4)

        // String 3 (C4 ~261.63 Hz) - lowest pitch on re-entrant soprano uke
        let cResult = standard.closestString(to: 260.0)
        #expect(cResult != nil)
        #expect(cResult?.string.stringNumber == 3)
        #expect(cResult?.string.note.displayName == "C4")

        // String 1 (A4 ~440.00 Hz) - highest pitch
        let aResult = standard.closestString(to: 442.0)
        #expect(aResult != nil)
        #expect(aResult?.string.stringNumber == 1)
        #expect(aResult?.string.note.displayName == "A4")
    }

    @Test("Drop D tuning drops 6th string to D2")
    func testDropDTuning() {
        let guitar = Instrument.guitarInstrument()
        guard let dropD = guitar.tunings.first(where: { $0.id == "guitar-drop-d" }) else {
            Issue.record("Drop D tuning not found")
            return
        }

        let string6 = dropD.strings.first(where: { $0.stringNumber == 6 })
        #expect(string6?.note.displayName == "D2")
        #expect(abs((string6?.note.frequency ?? 0) - 73.42) < 0.05)
    }
}
