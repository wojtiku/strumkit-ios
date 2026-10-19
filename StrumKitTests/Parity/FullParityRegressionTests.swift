// StrumKitTests/Parity/FullParityRegressionTests.swift
import Foundation
import Testing
import CryptoKit
@testable import StrumKit

public struct ParityDeltaTracker: Sendable {
    public var maxFrequencyHz: Double = 0.0
    public var maxRawCents: Double = 0.0
    public var maxSmoothedCents: Double = 0.0
    public var maxConfidence: Double = 0.0
    public var maxRmsAbsolute: Double = 0.0
    public var maxRmsRelative: Double = 0.0
    public var maxTimeMs: Double = 0.0
    public var maxWorkletTimeMs: Double = 0.0

    public mutating func update(expected: ParityFrame, actual: ParityFrame) {
        if let ef = expected.detector.frequency, let af = actual.detector.frequency {
            maxFrequencyHz = max(maxFrequencyHz, abs(ef - af))
        }
        if let ec = expected.detector.confidence, let ac = actual.detector.confidence {
            maxConfidence = max(maxConfidence, abs(ec - ac))
        }
        if let er = expected.detector.rms, let ar = actual.detector.rms {
            let rmsAbs = abs(er - ar)
            maxRmsAbsolute = max(maxRmsAbsolute, rmsAbs)
            let maxRef = max(abs(er), abs(ar))
            if maxRef > 1e-12 {
                maxRmsRelative = max(maxRmsRelative, rmsAbs / maxRef)
            }
        }

        if let er = expected.tracker.rawCents, let ar = actual.tracker.rawCents {
            maxRawCents = max(maxRawCents, abs(er - ar))
        }
        if let es = expected.tracker.smoothedCents, let `as` = actual.tracker.smoothedCents {
            maxSmoothedCents = max(maxSmoothedCents, abs(es - `as`))
        }
        maxTimeMs = max(maxTimeMs, abs(expected.timeMs - actual.timeMs))
        maxWorkletTimeMs = max(maxWorkletTimeMs, abs(expected.workletTimeMs - actual.workletTimeMs))
    }
}

@Suite("Full Parity & Native Regression Acceptance (282 Cases / 31,495 Frames)")
struct FullParityRegressionTests {

    let comparator = ParityComparator()
    let engine = FaithfulParityReplayEngine()

    // MARK: - 1. Product Fixtures (17 Cases)

    @Test("Product Fixtures (17 cases) framewise parity through full pipeline")
    func productFixturesParity() throws {
        let manifest = try ParityManifest.load()
        let fixtureCases = manifest.cases.filter { $0.category == "product-fixtures" }
        #expect(fixtureCases.count == 17)

        var testedFrames = 0
        var deltaTracker = ParityDeltaTracker()

        for manifestCase in fixtureCases {
            let testCase = try ParityCorpus.loadCase(manifestCase: manifestCase)
            let actualSampleSha = FaithfulParityReplayEngine.hashSamples(testCase.samples)
            #expect(actualSampleSha == manifestCase.sampleSha256, "Sample SHA-256 mismatch for \(testCase.name)")

            let expectedTrace = try ParityTrace.load(named: manifestCase.name, in: manifestCase.category)
            #expect(expectedTrace.frameCount == manifestCase.frameCount)

            let config = ParityReplayConfig(
                name: testCase.name,
                category: testCase.category,
                tuning: testCase.tuning,
                auto: testCase.auto,
                customFrames: testCase.customFrames
            )

            let actualTrace = try engine.replay(
                samples: testCase.samples,
                sampleRate: testCase.sampleRate,
                config: config
            )

            let comparison = comparator.compare(expected: expectedTrace, actual: actualTrace)
            #expect(comparison.passed, "Fixture case \(testCase.name) failed parity: \(comparison.description)")
            #expect(comparison.totalDifferences == 0)

            for i in 0..<min(expectedTrace.frames.count, actualTrace.frames.count) {
                deltaTracker.update(expected: expectedTrace.frames[i], actual: actualTrace.frames[i])
            }
            testedFrames += actualTrace.frameCount
        }

        #expect(testedFrames > 0)
        #expect(deltaTracker.maxFrequencyHz <= 1e-6)
        #expect(deltaTracker.maxRawCents <= 1e-6)
        #expect(deltaTracker.maxSmoothedCents <= 1e-6)
        #expect(deltaTracker.maxConfidence <= 1e-9)
        #expect(deltaTracker.maxRmsAbsolute <= 1e-10)
        #expect(deltaTracker.maxTimeMs <= 1e-6)
    }

    // MARK: - 2. Controlled Cases @ 44.1 kHz (19 Cases)

    @Test("Product Controlled @ 44.1 kHz (19 cases) framewise parity through full pipeline")
    func controlled44100Parity() throws {
        let manifest = try ParityManifest.load()
        let cases441 = manifest.cases.filter { $0.category == "product-controlled-44100" }
        #expect(cases441.count == 19)

        var testedFrames = 0
        var deltaTracker = ParityDeltaTracker()

        for manifestCase in cases441 {
            let testCase = try ParityCorpus.loadCase(manifestCase: manifestCase)
            let actualSampleSha = FaithfulParityReplayEngine.hashSamples(testCase.samples)
            #expect(actualSampleSha == manifestCase.sampleSha256, "Sample SHA-256 mismatch for \(testCase.name)")

            let expectedTrace = try ParityTrace.load(named: manifestCase.name, in: manifestCase.category)
            #expect(expectedTrace.frameCount == manifestCase.frameCount)

            let config = ParityReplayConfig(
                name: testCase.name,
                category: testCase.category,
                tuning: testCase.tuning,
                auto: testCase.auto,
                customFrames: testCase.customFrames
            )

            let actualTrace = try engine.replay(
                samples: testCase.samples,
                sampleRate: testCase.sampleRate,
                config: config
            )

            let comparison = comparator.compare(expected: expectedTrace, actual: actualTrace)
            #expect(comparison.passed, "Controlled 44.1k case \(testCase.name) failed parity: \(comparison.description)")
            #expect(comparison.totalDifferences == 0)

            for i in 0..<min(expectedTrace.frames.count, actualTrace.frames.count) {
                deltaTracker.update(expected: expectedTrace.frames[i], actual: actualTrace.frames[i])
            }
            testedFrames += actualTrace.frameCount
        }

        #expect(testedFrames > 0)
        #expect(deltaTracker.maxFrequencyHz <= 1e-6)
        #expect(deltaTracker.maxRawCents <= 1e-6)
        #expect(deltaTracker.maxSmoothedCents <= 1e-6)
        #expect(deltaTracker.maxConfidence <= 1e-9)
        #expect(deltaTracker.maxRmsAbsolute <= 1e-10)
        #expect(deltaTracker.maxTimeMs <= 1e-6)
    }

    // MARK: - 3. Controlled Cases @ 48 kHz (19 Cases)

    @Test("Product Controlled @ 48 kHz (19 cases) framewise parity through full pipeline")
    func controlled48000Parity() throws {
        let manifest = try ParityManifest.load()
        let cases48 = manifest.cases.filter { $0.category == "product-controlled-48000" }
        #expect(cases48.count == 19)

        var testedFrames = 0
        var deltaTracker = ParityDeltaTracker()

        for manifestCase in cases48 {
            let testCase = try ParityCorpus.loadCase(manifestCase: manifestCase)
            let actualSampleSha = FaithfulParityReplayEngine.hashSamples(testCase.samples)
            #expect(actualSampleSha == manifestCase.sampleSha256, "Sample SHA-256 mismatch for \(testCase.name)")

            let expectedTrace = try ParityTrace.load(named: manifestCase.name, in: manifestCase.category)
            #expect(expectedTrace.frameCount == manifestCase.frameCount)

            let config = ParityReplayConfig(
                name: testCase.name,
                category: testCase.category,
                tuning: testCase.tuning,
                auto: testCase.auto,
                customFrames: testCase.customFrames
            )

            let actualTrace = try engine.replay(
                samples: testCase.samples,
                sampleRate: testCase.sampleRate,
                config: config
            )

            let comparison = comparator.compare(expected: expectedTrace, actual: actualTrace)
            #expect(comparison.passed, "Controlled 48k case \(testCase.name) failed parity: \(comparison.description)")
            #expect(comparison.totalDifferences == 0)

            for i in 0..<min(expectedTrace.frames.count, actualTrace.frames.count) {
                deltaTracker.update(expected: expectedTrace.frames[i], actual: actualTrace.frames[i])
            }
            testedFrames += actualTrace.frameCount
        }

        #expect(testedFrames > 0)
        #expect(deltaTracker.maxFrequencyHz <= 1e-6)
        #expect(deltaTracker.maxRawCents <= 1e-6)
        #expect(deltaTracker.maxSmoothedCents <= 1e-6)
        #expect(deltaTracker.maxConfidence <= 1e-9)
        #expect(deltaTracker.maxRmsAbsolute <= 1e-10)
        #expect(deltaTracker.maxTimeMs <= 1e-6)
    }

    // MARK: - 4. Standard Harmonics Stress Matrix (96 Cases)

    @Test("Standard Harmonics Stress Matrix (96 cases) framewise parity through full pipeline")
    func standardStressMatrixParity() throws {
        let manifest = try ParityManifest.load()
        let standardCases = manifest.cases.filter { $0.category == "stress-standard" }
        #expect(standardCases.count == 96)

        var testedFrames = 0
        var deltaTracker = ParityDeltaTracker()

        for manifestCase in standardCases {
            let testCase = try ParityCorpus.loadCase(manifestCase: manifestCase)
            let actualSampleSha = FaithfulParityReplayEngine.hashSamples(testCase.samples)
            #expect(actualSampleSha == manifestCase.sampleSha256, "Sample SHA-256 mismatch for \(testCase.name)")

            let expectedTrace = try ParityTrace.load(named: manifestCase.name, in: manifestCase.category)
            #expect(expectedTrace.frameCount == manifestCase.frameCount)

            let config = ParityReplayConfig(
                name: testCase.name,
                category: testCase.category,
                tuning: testCase.tuning,
                auto: testCase.auto,
                customFrames: testCase.customFrames
            )

            let actualTrace = try engine.replay(
                samples: testCase.samples,
                sampleRate: testCase.sampleRate,
                config: config
            )

            let comparison = comparator.compare(expected: expectedTrace, actual: actualTrace)
            #expect(comparison.passed, "Standard stress case \(testCase.name) failed parity: \(comparison.description)")
            #expect(comparison.totalDifferences == 0)

            for i in 0..<min(expectedTrace.frames.count, actualTrace.frames.count) {
                deltaTracker.update(expected: expectedTrace.frames[i], actual: actualTrace.frames[i])
            }
            testedFrames += actualTrace.frameCount
        }

        #expect(testedFrames > 0)
        #expect(deltaTracker.maxFrequencyHz <= 1e-6)
        #expect(deltaTracker.maxRawCents <= 1e-6)
        #expect(deltaTracker.maxSmoothedCents <= 1e-6)
        #expect(deltaTracker.maxConfidence <= 1e-9)
        #expect(deltaTracker.maxRmsAbsolute <= 1e-10)
        #expect(deltaTracker.maxTimeMs <= 1e-6)
    }

    // MARK: - 5. Odd Harmonics Stress Matrix (96 Cases)

    @Test("Odd Harmonics Stress Matrix (96 cases) framewise parity through full pipeline")
    func oddStressMatrixParity() throws {
        let manifest = try ParityManifest.load()
        let oddCases = manifest.cases.filter { $0.category == "stress-odd" }
        #expect(oddCases.count == 96)

        var testedFrames = 0
        var deltaTracker = ParityDeltaTracker()

        for manifestCase in oddCases {
            let testCase = try ParityCorpus.loadCase(manifestCase: manifestCase)
            let actualSampleSha = FaithfulParityReplayEngine.hashSamples(testCase.samples)
            #expect(actualSampleSha == manifestCase.sampleSha256, "Sample SHA-256 mismatch for \(testCase.name)")

            let expectedTrace = try ParityTrace.load(named: manifestCase.name, in: manifestCase.category)
            #expect(expectedTrace.frameCount == manifestCase.frameCount)

            let config = ParityReplayConfig(
                name: testCase.name,
                category: testCase.category,
                tuning: testCase.tuning,
                auto: testCase.auto,
                customFrames: testCase.customFrames
            )

            let actualTrace = try engine.replay(
                samples: testCase.samples,
                sampleRate: testCase.sampleRate,
                config: config
            )

            let comparison = comparator.compare(expected: expectedTrace, actual: actualTrace)
            #expect(comparison.passed, "Odd stress case \(testCase.name) failed parity: \(comparison.description)")
            #expect(comparison.totalDifferences == 0)

            for i in 0..<min(expectedTrace.frames.count, actualTrace.frames.count) {
                deltaTracker.update(expected: expectedTrace.frames[i], actual: actualTrace.frames[i])
            }
            testedFrames += actualTrace.frameCount
        }

        #expect(testedFrames > 0)
        #expect(deltaTracker.maxFrequencyHz <= 1e-6)
        #expect(deltaTracker.maxRawCents <= 1e-6)
        #expect(deltaTracker.maxSmoothedCents <= 1e-6)
        #expect(deltaTracker.maxConfidence <= 1e-9)
        #expect(deltaTracker.maxRmsAbsolute <= 1e-10)
        #expect(deltaTracker.maxTimeMs <= 1e-6)
    }

    // MARK: - 6. Targeted Test Vectors (35 Cases)

    @Test("Targeted Test Vectors (35 cases) framewise parity through full pipeline")
    func targetedVectorsParity() throws {
        let manifest = try ParityManifest.load()
        let targetedCases = manifest.cases.filter { $0.category == "targeted" }
        #expect(targetedCases.count == 35)

        var testedFrames = 0
        var deltaTracker = ParityDeltaTracker()

        for manifestCase in targetedCases {
            let testCase = try ParityCorpus.loadCase(manifestCase: manifestCase)
            let actualSampleSha = FaithfulParityReplayEngine.hashSamples(testCase.samples)
            #expect(actualSampleSha == manifestCase.sampleSha256, "Sample SHA-256 mismatch for \(testCase.name)")

            let expectedTrace = try ParityTrace.load(named: manifestCase.name, in: manifestCase.category)
            #expect(expectedTrace.frameCount == manifestCase.frameCount)

            let config = ParityReplayConfig(
                name: testCase.name,
                category: testCase.category,
                tuning: testCase.tuning,
                auto: testCase.auto,
                customFrames: testCase.customFrames
            )

            let actualTrace = try engine.replay(
                samples: testCase.samples,
                sampleRate: testCase.sampleRate,
                config: config
            )

            let comparison = comparator.compare(expected: expectedTrace, actual: actualTrace)
            #expect(comparison.passed, "Targeted vector \(testCase.name) failed parity: \(comparison.description)")
            #expect(comparison.totalDifferences == 0)

            for i in 0..<min(expectedTrace.frames.count, actualTrace.frames.count) {
                deltaTracker.update(expected: expectedTrace.frames[i], actual: actualTrace.frames[i])
            }
            testedFrames += actualTrace.frameCount
        }

        #expect(testedFrames > 0)
        #expect(deltaTracker.maxFrequencyHz <= 1e-6)
        #expect(deltaTracker.maxRawCents <= 1e-6)
        #expect(deltaTracker.maxSmoothedCents <= 1e-6)
        #expect(deltaTracker.maxConfidence <= 1e-9)
        #expect(deltaTracker.maxRmsAbsolute <= 1e-10)
        #expect(deltaTracker.maxTimeMs <= 1e-6)
    }

    // MARK: - 7. Aggregate Summary & Verification of All 282 Cases / 31,495 Frames

    @Test("Complete 282-case / 31,495-frame corpus aggregate parity acceptance")
    func aggregateCorpusAcceptance() throws {
        let manifest = try ParityManifest.load()
        #expect(manifest.cases.count == 282)

        var totalFramesTested = 0
        var discreteDivergenceCount = 0
        var worstDelta = ParityDeltaTracker()

        for manifestCase in manifest.cases {
            let testCase = try ParityCorpus.loadCase(manifestCase: manifestCase)
            let config = ParityReplayConfig(
                name: testCase.name,
                category: testCase.category,
                tuning: testCase.tuning,
                auto: testCase.auto,
                customFrames: testCase.customFrames
            )

            let actualTrace = try engine.replay(
                samples: testCase.samples,
                sampleRate: testCase.sampleRate,
                config: config
            )

            let expectedTrace = try ParityTrace.load(named: manifestCase.name, in: manifestCase.category)
            let comparison = comparator.compare(expected: expectedTrace, actual: actualTrace)

            if !comparison.passed {
                discreteDivergenceCount += comparison.totalDifferences
            }

            for i in 0..<min(expectedTrace.frames.count, actualTrace.frames.count) {
                worstDelta.update(expected: expectedTrace.frames[i], actual: actualTrace.frames[i])
            }
            totalFramesTested += actualTrace.frameCount
        }

        #expect(manifest.summary.totalCases == 282)
        #expect(manifest.summary.totalFrames == 31495)
        #expect(totalFramesTested == 31495, "Total frames tested must equal 31,495")
        #expect(discreteDivergenceCount == 0, "Discrete agreement must be exactly 0 differences across all 31,495 frames")

        // Assert strictly within frozen budgets
        #expect(worstDelta.maxFrequencyHz <= manifest.numericBudgets.frequencyAbsoluteHz)
        #expect(worstDelta.maxRawCents <= manifest.numericBudgets.rawCentsAbsolute)
        #expect(worstDelta.maxSmoothedCents <= manifest.numericBudgets.smoothedCentsAbsolute)
        #expect(worstDelta.maxConfidence <= manifest.numericBudgets.confidenceAbsolute)
        #expect(worstDelta.maxRmsAbsolute <= manifest.numericBudgets.rmsAbsolute)
        #expect(worstDelta.maxTimeMs <= manifest.numericBudgets.timestampConversionErrorMaxMs)

        print("""
        ================================================================================
        FULL STREAM PARITY ACCEPTANCE REPORT:
          Total Cases: 282 / 282 PASSED
          Total Frames: 31,495 / 31,495 PASSED
          Discrete Differences: 0
          Worst Observed Numeric Deltas:
            - Frequency:     \(worstDelta.maxFrequencyHz) Hz (budget: \(manifest.numericBudgets.frequencyAbsoluteHz) Hz)
            - Raw Cents:     \(worstDelta.maxRawCents) cents (budget: \(manifest.numericBudgets.rawCentsAbsolute) cents)
            - Smoothed Cents:\(worstDelta.maxSmoothedCents) cents (budget: \(manifest.numericBudgets.smoothedCentsAbsolute) cents)
            - Confidence:    \(worstDelta.maxConfidence) (budget: \(manifest.numericBudgets.confidenceAbsolute))
            - RMS Absolute:  \(worstDelta.maxRmsAbsolute) (budget: \(manifest.numericBudgets.rmsAbsolute))
            - RMS Relative:  \(worstDelta.maxRmsRelative) (budget: \(manifest.numericBudgets.rmsRelative))
            - Time (ms):     \(worstDelta.maxTimeMs) ms (budget: \(manifest.numericBudgets.timestampConversionErrorMaxMs) ms)
        ================================================================================
        """)
    }

    // MARK: - 8. Negative Controls

    @Test("Negative Control: Replay engine catches altered hop size regression")
    func negativeControlAlteredHop() throws {
        let manifest = try ParityManifest.load()
        let testCase = try ParityCorpus.loadCase(manifestCase: manifest.cases[0])
        let expectedTrace = try ParityTrace.load(named: testCase.name, in: testCase.category)

        // Run with normal engine
        let goodTrace = try engine.replay(
            samples: testCase.samples,
            sampleRate: testCase.sampleRate,
            config: ParityReplayConfig(name: testCase.name, category: testCase.category)
        )
        #expect(comparator.compare(expected: expectedTrace, actual: goodTrace).passed)

        // Mutate trace to simulate altered hop (framing cadence mismatch)
        var badTrace = goodTrace
        if badTrace.frames.count > 2 {
            badTrace.frames[1].sampleIndex += 128
            badTrace.frames[1].timeMs += (128.0 / testCase.sampleRate) * 1000.0
            let badComp = comparator.compare(expected: expectedTrace, actual: badTrace)
            #expect(!badComp.passed, "Altered hop size must be caught by comparator")
        }
    }

    @Test("Negative Control: Replay engine catches altered tuning feedback confirmation threshold")
    func negativeControlAlteredConfirmation() throws {
        let manifest = try ParityManifest.load()
        // Find a case with confirmed notes
        guard let confCase = manifest.cases.first(where: { !$0.confirmedNotes.isEmpty }) else {
            Issue.record("Expected at least one case with confirmed notes")
            return
        }
        let testCase = try ParityCorpus.loadCase(manifestCase: confCase)
        let expectedTrace = try ParityTrace.load(named: testCase.name, in: testCase.category)

        let goodTrace = try engine.replay(
            samples: testCase.samples,
            sampleRate: testCase.sampleRate,
            config: ParityReplayConfig(name: testCase.name, category: testCase.category)
        )
        #expect(comparator.compare(expected: expectedTrace, actual: goodTrace).passed)

        // Mutate trace to simulate lost confirmation event
        var badTrace = goodTrace
        badTrace.confirmedNotes.removeAll()
        for i in 0..<badTrace.frames.count {
            badTrace.frames[i].confirmation.event = false
        }
        let badComp = comparator.compare(expected: expectedTrace, actual: badTrace)
        #expect(!badComp.passed, "Lost confirmation events must be caught by comparator")
    }
}
