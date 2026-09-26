import XCTest
@testable import WebTunaReference

/// Proves that the Swift signal generator in `CoverageMatrix.swift` produces the
/// same samples as the JavaScript `buildSignal` in `xeng.mjs`.
///
/// The contract is the FNV-1a checksum that both sides compute over the raw
/// float32 bytes. The expected values are the `sig=` fields the real WebTuna
/// oracle emitted for the same cells, recorded in `Fixtures/oracle-trace.json`.
///
/// This is the single most load-bearing test in the package. If it fails, the
/// conformance comparison is measuring two engines on two different signals and
/// every other number in the suite is meaningless. There is deliberately no
/// tolerance: the samples are float32 and the arithmetic is the same sequence of
/// operations, so either the bytes match or the two generators have drifted.
final class SignalParityTests: XCTestCase {
    func testEveryCellChecksumMatchesTheOracleTrace() throws {
        let trace = try OracleTrace.load()
        let cells = try CoverageMatrix.cells()
        XCTAssertEqual(cells.count, trace.cells.count,
                       "xcells.json and the oracle trace disagree on the cell list")

        var mismatches: [String] = []
        for cell in cells {
            let audio = CoverageMatrix.signal(for: cell)
            let got = FNV1a.hash32(audio)
            guard let expected = trace.sigByLabel[cell.label] else {
                mismatches.append("\(cell.label): absent from the oracle trace")
                continue
            }
            if got != expected {
                mismatches.append("\(cell.label): swift=\(FNV1a.hex32(got)) js=\(FNV1a.hex32(expected))")
            }
        }
        XCTAssertTrue(mismatches.isEmpty, """
            Signal parity FAILED — the Swift and JavaScript generators disagree, so \
            the conformance comparison would be meaningless.
            \(mismatches.joined(separator: "\n"))
            """)
    }

    /// The generator's own invariants, independent of the oracle. Cheap, and they
    /// catch a change that happens to keep a checksum stable only by accident.
    func testSignalShapeInvariants() throws {
        for cell in try CoverageMatrix.cells() {
            let audio = CoverageMatrix.signal(for: cell)
            XCTAssertEqual(audio.count, 132_300, "\(cell.label): expected 3.0 s at 44.1 kHz")
            var peak: Float = 0
            for v in audio { peak = max(peak, abs(v)) }
            XCTAssertLessThanOrEqual(peak, 1.0, "\(cell.label): clipped")
            if case .clean = cell.snrDB {
                XCTAssertGreaterThan(peak, 0, "\(cell.label): silent clean signal")
            }
        }
    }
}
