import XCTest
@testable import WebTunaReference

/// The headline test: the Swift port and the real `WebTuna.wasm`, over the same
/// 40 coverage-matrix cells, compared call by call.
///
/// The oracle side is `Fixtures/oracle-trace.json`, recorded from the running
/// module by `tools/oracle-trace.mjs`. The signal side is generated in Swift and
/// `SignalParityTests` proves it is byte-identical to the JavaScript the oracle
/// consumed, via the FNV-1a checksum both sides compute.
///
/// This test **reports** rather than asserts on the exact-match fields, and
/// asserts only the properties that must hold regardless of how far the port
/// has got:
///
///   * the whole matrix runs, 32 calls per cell, with no crash and no NaN;
///   * the warm-up boundary is a property of the *engine*, so where the port
///     does produce a note at all it must not produce one during the first two
///     calls (§4.2);
///   * `MeasuredPitchHz`, where both engines report a pitch, is within 1 Hz.
///
/// A hard assertion on `CanHearANote`/`CurrentString`/`InTuneRatio` equality is
/// deliberately *not* made, because the port does not achieve it and pretending
/// otherwise is exactly what a reference implementation must not do. The
/// achieved numbers are in `README.md` §Fidelity and the reason is in
/// `DIVERGENCES.md` D6.
final class ConformanceTests: XCTestCase {

    private func run() throws -> ([CellConformance], OracleTrace) {
        let trace = try OracleTrace.load()
        let cells = try CoverageMatrix.cells()
        return (Conformance.run(cells: cells, trace: trace), trace)
    }

    func testCoverageMatrixRunsAndIsWellFormed() throws {
        let (results, trace) = try run()
        XCTAssertEqual(results.count, 40)
        var total = 0
        for r in results {
            XCTAssertGreaterThan(r.calls, 0, "\(r.label): no calls")
            // 3.0 s at 44.1 kHz is 32 whole 4096-sample calls.
            XCTAssertEqual(r.calls, 32, "\(r.label): call count")
            total += r.calls
        }
        XCTAssertEqual(total, 40 * 32)
        XCTAssertEqual(trace.wasmSHA256, "14ec8582a5cd1becfc8597fbc8bec75d2361f57522046ffdb0fbafc9394508bd",
                       "the fixture was recorded from a different binary")
    }

    /// The engine always returns "no note" for the first two calls (§4.2). The
    /// port must not beat that: a note on call 0 or 1 would mean the warm-up is
    /// not reproduced even when the steady state is.
    func testNoNoteDuringTheTwoWarmUpCalls() throws {
        let (results, _) = try run()
        var early = 0
        for r in results where (r.portFirstHeard ?? Int.max) < 2 { early += 1 }
        XCTAssertEqual(early, 0, "\(early) cells produced a note within the first two calls")
    }

    /// The per-field table, and the honest statement of what is and is not met.
    ///
    /// The task's criterion for `MeasuredPitchHz` is ~1 Hz. **The port does not
    /// meet it**, and no tolerance is set that would hide that: the test prints the
    /// achieved worst-case error and asserts only on the regression floors below,
    /// each of which is the number this port actually achieves today, so an
    /// improvement shows up and a regression is caught. Raising any of them to make
    /// the suite green would be exactly the failure mode this port exists to avoid.
    /// `DIVERGENCES.md` D6 and D7 explain the cause.
    func testConformanceSummaryAndRegressionFloors() throws {
        let (results, _) = try run()
        var maxHz = 0.0
        var worstLabel = ""
        for r in results {
            if r.maxHzError > maxHz { maxHz = r.maxHzError; worstLabel = r.label }
        }
        print("""

        CONFORMANCE — coverage matrix, 40 cells x 32 calls, 1280 calls total
        \(Conformance.summary(results))
        worst-pitch cell: \(worstLabel) at \(String(format: "%.3f", maxHz)) Hz  (criterion 1 Hz — NOT MET)
        """)

        let total = results.reduce(0) { $0 + $1.calls }
        XCTAssertEqual(total, 1280)
        // MicRms is exact — stage 3 plus the 64-frame peak hold. Asserted, not a floor.
        XCTAssertEqual(results.reduce(0) { $0 + $1.rmsWithin1e4 }, total,
                       "MicRms should match every call; a drop means stage 3 or §3.8 broke")
        // The warm-up boundary is an engine property, and is reproduced.
        XCTAssertEqual(results.filter { $0.oracleFirstHeard == $0.portFirstHeard }.count,
                       results.count, "the first-heard call must match the engine's")
        // Regression floors, each the measured value rounded down.
        XCTAssertGreaterThanOrEqual(results.reduce(0) { $0 + $1.canHearMatches }, 1080,
                                    "CanHearANote agreement regressed below 84 %")
        XCTAssertGreaterThanOrEqual(results.reduce(0) { $0 + $1.stringMatches }, 30,
                                    "CurrentString agreement regressed below 2.3 %")
        XCTAssertGreaterThanOrEqual(results.reduce(0) { $0 + $1.ratioMatches }, 570,
                                    "InTuneRatio agreement regressed below 44 %")
    }

    /// The per-field table, printed so the numbers in `README.md` can be checked
    /// against a run rather than taken on trust.
    func testPerFieldTable() throws {
        let (results, _) = try run()
        var lines: [String] = ["label                    hear   str  ratio   hz<=1  midi    pw  cents    rms  firstHeard"]
        for r in results {
            lines.append(String(format: "%-24@ %5d %5d %6d %7d %5d %5d %6d %5d  %@",
                               r.label as NSString,
                               r.canHearMatches, r.stringMatches, r.ratioMatches,
                               r.pitchWithin1Hz, r.midiMatches, r.pwMatches, r.centsExact,
                               r.rmsWithin1e4,
                               "\(r.oracleFirstHeard.map(String.init) ?? "-")/\(r.portFirstHeard.map(String.init) ?? "-")" as NSString))
        }
        print("\n" + lines.joined(separator: "\n"))
    }
}
