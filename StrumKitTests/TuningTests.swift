import Testing
import Foundation
@testable import StrumKit

@Suite("Presets and Tunings Tests")
struct TuningTests {

    @Test("Guitar has 10 official presets matching chorder")
    func testGuitarPresets() {
        let presets = Presets.guitar
        #expect(presets.count == 10)

        let standard = presets.first(where: { $0.id == "standard" })
        #expect(standard?.midi == [40, 45, 50, 55, 59, 64])

        let dropD = presets.first(where: { $0.id == "drop-d" })
        #expect(dropD?.midi == [38, 45, 50, 55, 59, 64])

        let dadgad = presets.first(where: { $0.id == "dadgad" })
        #expect(dadgad?.midi == [38, 45, 50, 55, 57, 62])
    }

    @Test("Ukulele has 4 official presets matching chorder")
    func testUkulelePresets() {
        let presets = Presets.ukulele
        #expect(presets.count == 4)

        let highG = presets.first(where: { $0.id == "high-g" })
        #expect(highG?.midi == [67, 60, 64, 69])

        let lowG = presets.first(where: { $0.id == "low-g" })
        #expect(lowG?.midi == [55, 60, 64, 69])

        let baritone = presets.first(where: { $0.id == "baritone" })
        #expect(baritone?.midi == [50, 55, 59, 64])
    }

    @Test("Custom note range spans A1 (33) to B5 (83)")
    func testCustomNotesRange() {
        let notes = Presets.customNotes
        #expect(notes.first == 33)
        #expect(notes.last == 83)
        #expect(notes.count == 51)
    }
}
