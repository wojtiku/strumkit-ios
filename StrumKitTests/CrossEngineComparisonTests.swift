// StrumKitTests/CrossEngineComparisonTests.swift
import Foundation
import Testing
@testable import StrumKit

/// Emits machine-readable traces for the coverage matrix so the same signals can
/// be pushed through the WebTuna oracle and compared cell by cell. See
/// `docs/tuner-reliability/webtuna/xeng.mjs` for the other side,
/// `docs/tuner-reliability/webtuna/xcompare.py` for the scorer, and
/// `docs/tuner-reliability/COMPARISON.md` for what the comparison is for.
///
/// This file is an **emitter only**. No scoring lives here: a Swift-side grader
/// would be able to grade its own homework, and the whole point of the
/// head-to-head is that the two numbers are produced by two different code
/// paths and compared by a third.
///
/// Two invariants the file is responsible for:
///
/// 1. `xcells.json` is written from *this* matrix, not hand-maintained, so the
///    two signal generators cannot disagree about which cells exist.
/// 2. Every cell's signal carries an FNV-1a checksum, printed on the SUMMARY
///    line, so the two generators cannot disagree about the *audio* either.
///    Emitting the cell list catches label drift; the checksum catches the
///    silent, far more dangerous case where both sides still know the same 40
///    labels but no longer generate the same waveform.
///
/// Polyphony is synthesised: `Case.extraFrequencies` reaches `xcells.json` as
/// `extraFrequencies` and `xeng.mjs`'s `buildSignal` mixes it in, so all four
/// `poly-` cells carry a real second voice on both sides. This was previously
/// broken — the frequency lived only on `Cell.extraStrings`, so every poly cell
/// rendered as a lone note and the head-to-head reported WebTuna hearing
/// everything, including the "E2+F♯2, the pair that defeats WebTuna".
/// `CoverageMatrixTests.polyCellsArePolyphonic` now guards it.
/// Emitter-side constants and helpers. A namespace rather than statics on the
/// suite, because Swift Testing's `@Test` bodies are instance methods and an
/// unqualified static member does not resolve from inside one.
private enum Xeng {

    /// Half-width, in cents, of "this engine read the right note".
    ///
    /// Mirrored by `CENTS_TOLERANCE` in `xeng.mjs`. `xcompare.py` scores the
    /// `first`/`last` fields these two produce rather than re-deriving them, so
    /// the two tolerances cannot drift apart silently either.
    static let centsTolerance = 50.0

    /// Repository root, derived from this file's own compile-time path.
    ///
    /// `#filePath` is absolute wherever the build ran, so this works from any
    /// checkout and in CI. A path relative to the process's working directory
    /// does **not**: the xctest host's cwd is not the repository root, and
    /// writing into a non-existent directory throws — which the plan's
    /// `try? data.write(to:)` would have swallowed. The failure that matters
    /// is not the throw, it is the consequence: no manifest, so
    /// `node xeng.mjs` runs over nothing, and the head-to-head comes out as a
    /// clean table of ties that looks like a real measurement.
    static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // StrumKitTests/
            .deletingLastPathComponent()   // repository root
    }

    /// FNV-1a, 32-bit, over the raw little-endian bytes of the samples.
    ///
    /// Byte-order-independent only by virtue of both sides running on the same
    /// little-endian machine; it is a change detector, not a wire format.
    /// `xeng.mjs` computes the identical function over the identical bytes.
    static func fnv1a32(_ samples: [Float]) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        samples.withUnsafeBufferPointer { buffer in
            let bytes = UnsafeRawBufferPointer(
                start: buffer.baseAddress,
                count: buffer.count * MemoryLayout<Float>.size)
            for byte in bytes {
                hash ^= UInt32(byte)
                hash = hash &* 16_777_619
            }
        }
        return hash
    }
}

@Suite("Cross-engine comparison trace emitter")
struct CrossEngineComparisonTests {

    @Test("Emit StrumKit traces for every coverage-matrix cell")
    func emitTraces() throws {
        let cells = CoverageMatrix.matrix(seed: CoverageMatrix.SEED_A)
        // `label` is the only unique key on a cell: `Case.name` is derived from
        // the frequency, so cells sharing a frequency share a name. The manifest
        // is keyed on `label`, and the parity check is too, so a duplicate label
        // would be a silent overwrite rather than an error.
        #expect(cells.count == 40,
                "spec §6 enumerates 40 cells; the manifest would be wrong for any other count")
        #expect(Set(cells.map(\.label)).count == cells.count,
                "matrix labels are not unique; the manifest would collapse cells")

        // --- 1. The manifest, written and verified before anything expensive ---
        //
        // Every field `xeng.mjs` needs is here and nowhere else, so the JS
        // generator is a pure function of this file's output.
        let manifestURL = Xeng.repositoryRoot
            .appendingPathComponent("docs/tuner-reliability/webtuna/xcells.json")

        let manifest: [[String: Any]] = cells.map { cell in
            var entry: [String: Any] = [
                "label": cell.label,
                // `noteHz` is the frequency a correct reading must land on;
                // `truthHz` is the fundamental the signal was built from. They
                // are equal in every cell today but they are different questions.
                "noteHz": cell.noteHz,
                "truthHz": cell.case.truthHz,
                "h1": cell.case.h1, "h2": cell.case.h2,
                "h3": cell.case.h3, "h4": cell.case.h4,
                "inharmonicity": cell.case.inharmonicity,
                "attackSeconds": cell.case.attackSeconds,
                "decayTau": cell.case.decayTau,
                "amplitude": cell.case.amplitude,
                // `CoverageMatrix.signal` folds a zero seed to 1 before use, so
                // the raw value is what has to travel for the fold to happen
                // identically on the other side. Small enough (< 2^53) to
                // survive JSONSerialization -> JSON.parse as a JS number.
                "seed": cell.case.seed,
                // WebTuna's compiled-in tuning is a six-string guitar, so a
                // ukulele cell has to be asked for in its chromatic mode
                // (-2). -1 is "auto" within the guitar tuning.
                "idx": cell.config.instrument == .guitar ? -1 : -2,
                // The cell's record of which strings it declared.
                "extraStrings": cell.extraStrings,
                // What `buildSignal` actually synthesises. Same list today; both
                // travel so neither side has to re-derive it, and a future change
                // to the signal that did not follow through to the cell (or the
                // reverse) shows up as a checksum mismatch rather than as a
                // quietly single-note matrix.
                "extraFrequencies": cell.case.extraFrequencies,
            ]
            // JSON has no infinity, so the clean case travels as a sentinel
            // string; this is exactly what `buildSignal` tests for. Written as
            // two statements because a `Double`/`String` ternary has no common
            // type to infer.
            if cell.case.snrDB.isFinite {
                entry["snrDB"] = cell.case.snrDB
            } else {
                entry["snrDB"] = "clean"
            }
            return entry
        }

        let data = try JSONSerialization.data(
            withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: manifestURL)

        // Read it back rather than trusting the write. A manifest that silently
        // failed to land is the exact silent-failure mode this task exists to
        // prevent, and it is cheap to rule out.
        let existedBefore = FileManager.default.fileExists(atPath: manifestURL.path)
        #expect(existedBefore, "xcells.json was not created at \(manifestURL.path)")

        let written = try Data(contentsOf: manifestURL)
        #expect(written.count == data.count,
                "xcells.json on disk is \(String(written.count)) bytes, wrote \(String(data.count))")

        let decoded = try JSONSerialization.jsonObject(with: written) as? [[String: Any]]
        let writtenCells: [[String: Any]] = decoded ?? []
        let writtenLabels = Set(writtenCells.compactMap { $0["label"] as? String })
        #expect(writtenLabels == Set(cells.map(\.label)),
                "the manifest's label set is not the matrix's label set")
        #expect(writtenCells.count == cells.count,
                "manifest has \(String(writtenCells.count)) entries, matrix has \(String(cells.count))")
        for key in ["truthHz", "h1", "h2", "h3", "h4", "inharmonicity",
                    "attackSeconds", "decayTau", "amplitude", "seed", "idx"] {
            #expect(writtenCells.first?[key] != nil,
                    "manifest is missing \(key), which buildSignal requires")
        }

        // --- 2. The trace ---
        for cell in cells {
            let audio = CoverageMatrix.signal(cell.case, rate: 44100, seconds: 3.0)
            let (frames, _) = AudioTestHelpers.replayTrace(
                samples: audio, sampleRate: 44100, config: cell.config)

            var firstCorrect: Double?
            var lastCorrect: Double?
            var firstReading: Double?
            var lastReading: Double?

            for f in frames {
                // The brief's measure of "heard": what YIN itself reported,
                // independent of the session's target arbitration. This is the
                // number G2's StrumKit column is defined on.
                let hz = f.rawFrequency
                let cents = hz > 0 ? 1200 * log2(hz / cell.noteHz) : Double.nan
                if hz > 0, abs(cents) <= Xeng.centsTolerance {
                    if firstCorrect == nil { firstCorrect = f.captureEndSeconds }
                    lastCorrect = f.captureEndSeconds
                }
                // A second, user-visible measure: the frequency the display
                // would have shown, which includes the spectral-recovery path
                // that `rawFrequency` cannot see. Reported alongside rather than
                // instead of, so G2's column keeps the meaning the plan gave it.
                if let reading = f.reading,
                   reading.frequency > 0,
                   abs(1200 * log2(reading.frequency / cell.noteHz)) <= Xeng.centsTolerance {
                    if firstReading == nil { firstReading = f.captureEndSeconds }
                    lastReading = f.captureEndSeconds
                }

                let centsText = cents.isNaN ? "nan" : String(format: "%.3f", cents)
                print("XENG|\(cell.label)|t=\(String(format: "%.5f", f.captureEndSeconds))"
                      + "|hz=\(String(format: "%.4f", hz))"
                      + "|cents=\(centsText)"
                      + "|state=\(f.displayState)"
                      + "|conf=\(String(format: "%.3f", f.confidence))")
            }

            let fmt = { (v: Double?) in String(format: "%.5f", v ?? -1) }
            print("XENG-SUMMARY|\(cell.label)|truth=\(cell.noteHz)"
                  + "|first=\(fmt(firstCorrect))|last=\(fmt(lastCorrect))"
                  + "|transitions=\(AudioTestHelpers.countDisplayTransitions(frames))"
                  + "|frames=\(frames.count)"
                  + "|firstReading=\(fmt(firstReading))|lastReading=\(fmt(lastReading))"
                  + "|extraStrings=\(cell.extraStrings.count)"
                  + "|sig=\(String(format: "%08x", Xeng.fnv1a32(audio)))")
        }
    }
}
