// StrumKit/Algorithm/FaithfulStatelessDetector.swift
import Foundation

// MARK: - Models

/// Pure faithful pitch candidate ported directly from Tools/parity-contract/reference-source/pitch.ts.
/// Carries frequency, confidence, window RMS, and optional corroboration flags.
public struct FaithfulPitchCandidate: Sendable, Codable, Equatable {
    public var frequency: Double
    public var confidence: Double
    public var rms: Double
    /// True when the candidate is derived from an odd-only harmonic series (missing fundamental).
    /// Kept as an optional (nil when absent, true when present, distinct from false).
    public var oddOnly: Bool?
    /// True when the candidate is corroborated by the foreground spectral peak.
    /// Kept as an optional (nil when absent, true when present, distinct from false).
    public var foregroundAgrees: Bool?

    public init(
        frequency: Double,
        confidence: Double,
        rms: Double,
        oddOnly: Bool? = nil,
        foregroundAgrees: Bool? = nil
    ) {
        self.frequency = frequency
        self.confidence = confidence
        self.rms = rms
        self.oddOnly = oddOnly
        self.foregroundAgrees = foregroundAgrees
    }
}

/// Ranking policy for spectral candidate selection.
public enum SpectralRanking: String, Sendable, Codable, Equatable {
    case prominence
    case supportedPower = "supported-power"
}

/// Output of spectral pitch estimation before RMS is attached.
public struct SpectralPitchResult: Sendable, Codable, Equatable {
    public var frequency: Double
    public var confidence: Double
    public var oddOnly: Bool

    public init(frequency: Double, confidence: Double, oddOnly: Bool) {
        self.frequency = frequency
        self.confidence = confidence
        self.oddOnly = oddOnly
    }

    /// Converts spectral result into a FaithfulPitchCandidate by attaching window RMS.
    public func asCandidate(rms: Double) -> FaithfulPitchCandidate {
        FaithfulPitchCandidate(
            frequency: frequency,
            confidence: confidence,
            rms: rms,
            oddOnly: oddOnly
        )
    }
}

// MARK: - Frame Analysis Scratch Cache

/// Per-stream scratch explicitly invalidated for EVERY incoming public frame.
/// An input buffer's identity is not its contents: callers may reuse the buffer.
/// Transformed anti-alias input is a distinct frame and bypasses these caches.
public final class FaithfulFrameAnalysis: @unchecked Sendable {
    private var inputPtr: UnsafeRawPointer?
    private var inputCount: Int = 0
    private var rate: Double = 0.0
    private var power: [Double]?
    private var detectedPeaks: [FaithfulSpectralKernels.SpectralPeak]?
    private var filteredReady: Bool = false
    private var filteredSamples: [Double] = []
    private var cachedSpectral: [SpectralRanking: SpectralPitchResult?]?

    public init() {}

    /// Explicitly resets scratch state for a new public frame.
    public func begin(input: [Float], rate: Double) {
        self.inputPtr = input.withUnsafeBufferPointer { UnsafeRawPointer($0.baseAddress) }
        self.inputCount = input.count
        self.rate = rate
        self.power = nil
        self.detectedPeaks = nil
        self.filteredReady = false
        self.cachedSpectral = nil
        if self.filteredSamples.count != input.count {
            self.filteredSamples = [Double](repeating: 0.0, count: input.count)
        }
    }

    @inline(__always)
    private func isCurrentInput(_ input: [Float], rate: Double) -> Bool {
        guard rate == self.rate, input.count == self.inputCount else { return false }
        return input.withUnsafeBufferPointer { UnsafeRawPointer($0.baseAddress) } == self.inputPtr
    }

    /// Lazily filtered bandpass samples for the current frame.
    public func filtered(input: [Float], rate: Double) -> [Double] {
        if !isCurrentInput(input, rate: rate) {
            var filtered = [Double](repeating: 0.0, count: input.count)
            for i in 0..<input.count { filtered[i] = Double(input[i]) }
            FaithfulNumericKernels.bandpassFilterInPlace(&filtered, sampleRate: rate)
            return filtered
        }
        if !filteredReady {
            for i in 0..<input.count {
                filteredSamples[i] = Double(input[i])
            }
            FaithfulNumericKernels.bandpassFilterInPlace(&filteredSamples, sampleRate: rate)
            filteredReady = true
        }
        return filteredSamples
    }

    /// Lazily computes power spectrum and spectral peaks for the current frame.
    public func peaks(input: [Float], rate: Double) -> [FaithfulSpectralKernels.SpectralPeak] {
        if !isCurrentInput(input, rate: rate) {
            return FaithfulSpectralKernels.spectralPeaks(input: input, sampleRate: rate)
        }
        if power == nil {
            power = FaithfulSpectralKernels.powerSpectrum(input)
        }
        if let peaks = detectedPeaks {
            return peaks
        }
        let peaks = FaithfulSpectralKernels.spectralPeaks(input: input, sampleRate: rate, power: power)
        detectedPeaks = peaks
        return peaks
    }

    /// Lazily computes and caches spectral pitch estimation for the current frame.
    public func spectral(
        input: [Float],
        rate: Double,
        ranking: SpectralRanking = .prominence
    ) -> SpectralPitchResult? {
        if !isCurrentInput(input, rate: rate) {
            return FaithfulStatelessDetector.detectSpectralPitch(input: input, sampleRate: rate, ranking: ranking)
        }
        if let cached = cachedSpectral?[ranking] {
            return cached
        }
        let peaks = self.peaks(input: input, rate: rate)
        let result = FaithfulStatelessDetector.detectSpectralPitch(
            input: input,
            sampleRate: rate,
            ranking: ranking,
            power: self.power!,
            peaks: peaks
        )
        if cachedSpectral == nil {
            cachedSpectral = [:]
        }
        cachedSpectral?[ranking] = result
        return result
    }
}

// MARK: - Stateless Pitch Detector

/// Pure faithful stateless pitch detector ported directly from Tools/parity-contract/reference-source/pitch.ts
/// and spectrum.ts.
public enum FaithfulStatelessDetector {

    // MARK: - Frequency Validity

    /// Validates frequency within the strict ukulele profile [110, 1100] Hz.
    @inline(__always)
    public static func validFrequency(_ frequency: Double) -> Bool {
        return frequency.isFinite && frequency >= 110.0 && frequency <= 1100.0
    }

    // MARK: - Spectral Pitch Detection

    /// Detects spectral pitch by evaluating harmonic series consistency across spectral peaks.
    /// Matches `detectSpectralPitch` in reference spectrum.ts lines 85-157.
    public static func detectSpectralPitch(
        input: [Float],
        sampleRate: Double,
        ranking: SpectralRanking = .prominence,
        power: [Double]? = nil,
        peaks: [FaithfulSpectralKernels.SpectralPeak]? = nil
    ) -> SpectralPitchResult? {
        let spectrumPower = power ?? FaithfulSpectralKernels.powerSpectrum(input)
        let detectedPeaks = peaks ?? FaithfulSpectralKernels.spectralPeaks(input: input, sampleRate: sampleRate, power: spectrumPower)
        guard !detectedPeaks.isEmpty else { return nil }

        var totalPower = 0.0
        for value in spectrumPower {
            totalPower += value
        }

        struct Candidate {
            var frequency: Double
            var score: Double
            var count: Int
            var oddOnly: Bool
            var strongCount: Int
            var matchedPower: Double
        }

        var best: Candidate? = nil
        var bestOdd: Candidate? = nil

        let topPeakPower = detectedPeaks[0].power

        for peak in detectedPeaks {
            for harmonic in 1...8 {
                let candidate = peak.frequency / Double(harmonic)
                if candidate < 110.0 || candidate > 1100.0 {
                    continue
                }

                var score = 0.0
                var weightSum = 0.0
                var frequencySum = 0.0
                var count = 0
                var matchedPower = 0.0
                var hasLowPartial = false
                var oddPartials = Set<Int>()
                var strongCount = 0
                var strongWeight = 0.0
                var strongFrequency = 0.0

                for partial in detectedPeaks {
                    let h = Int(FaithfulSpectralKernels.jsRound(partial.frequency / candidate))
                    if h < 1 || h > 12 { continue }
                    let error = abs(partial.frequency / Double(h) - candidate)
                    if error > max(1.5, candidate * 0.008) { continue }
                    let weight = min(partial.prominence, 100.0) / sqrt(Double(h))
                    score += weight
                    weightSum += weight
                    frequencySum += weight * partial.frequency / Double(h)
                    count += 1
                    matchedPower += partial.power

                    if partial.power >= topPeakPower * 0.01 {
                        strongCount += 1
                        strongWeight += weight
                        strongFrequency += weight * partial.frequency / Double(h)
                    }

                    if h <= 2 {
                        hasLowPartial = true
                    }

                    if (h == 3 || h == 5 || h == 7)
                        && partial.prominence >= 15.0
                        && partial.power >= topPeakPower * 0.01
                        && error <= max(0.4, candidate * 0.002) {
                        oddPartials.insert(h)
                    }
                }

                if count < 3 || score < 50.0 { continue }

                if !hasLowPartial {
                    if oddPartials.count != 3 { continue }
                    guard strongWeight > 0.0 else { continue }
                    weightSum = strongWeight
                    frequencySum = strongFrequency
                    count = strongCount

                    let lag = sampleRate / (frequencySum / weightSum)
                    let whole = Int(floor(lag))
                    let fraction = lag - Double(whole)
                    var difference = 0.0
                    var energy = 0.0
                    let limit = input.count - whole - 1
                    if limit > 0 {
                        for i in 0..<limit {
                            let delayed = Double(input[i + whole]) * (1.0 - fraction) + Double(input[i + whole + 1]) * fraction
                            let diff = Double(input[i]) - delayed
                            difference += diff * diff
                            energy += Double(input[i]) * Double(input[i]) + delayed * delayed
                        }
                    }
                    if energy == 0.0 || (difference / energy > 0.35) {
                        continue
                    }
                }

                // Prefer a real fundamental over its subharmonics with the same matched peaks.
                score *= 1.0 + 0.03 * log2(candidate / 110.0)

                // Alternate family ranking
                if ranking == .supportedPower {
                    score *= sqrt(matchedPower / max(totalPower, 1e-24))
                }

                guard weightSum > 0.0 else { continue }
                let result = Candidate(
                    frequency: frequencySum / weightSum,
                    score: score,
                    count: count,
                    oddOnly: !hasLowPartial,
                    strongCount: strongCount,
                    matchedPower: matchedPower
                )

                if best == nil || score > best!.score {
                    best = result
                }
                if result.oddOnly && (bestOdd == nil || score > bestOdd!.score) {
                    bestOdd = result
                }
            }
        }

        // Only displace an artifact-supported winner, not another well-supported series.
        if let bestOddVal = bestOdd, let currentBest = best, currentBest.strongCount < 3 {
            best = bestOddVal
        }

        // Validate the winner without promoting a different, previously losing series.
        // Rough Hann main-lobe factor 3; reject only negligible (<1%) energy support.
        guard let currentBest = best else { return nil }
        if 3.0 * currentBest.matchedPower < 0.01 * totalPower {
            return nil
        }

        return SpectralPitchResult(
            frequency: currentBest.frequency,
            confidence: min(0.98, 0.8 + Double(currentBest.count) * 0.02),
            oddOnly: currentBest.oddOnly
        )
    }

    // MARK: - Decimated & Filtered Pitch Detection

    /// Detects pitch from audio buffer using decimation, bandpass filtering, CMNDF valley picking,
    /// parabolic interpolation, original-rate refinement, and harmonic octave verification.
    /// Matches `detectPitch` in reference pitch.ts lines 407-562.
    public static func detectPitch(
        input: [Float],
        sampleRate: Double,
        ranking: SpectralRanking = .prominence,
        analysis: FaithfulFrameAnalysis? = nil
    ) -> FaithfulPitchCandidate? {
        guard input.count >= 2, sampleRate > 0 else { return nil }

        // Independently measure the capture-rate band before interpreting a decimated period.
        var filteredInput: [Double]
        if let analysis = analysis {
            filteredInput = analysis.filtered(input: input, rate: sampleRate)
        } else {
            var raw = [Double](repeating: 0.0, count: input.count)
            for i in 0..<input.count { raw[i] = Double(input[i]) }
            FaithfulNumericKernels.bandpassFilterInPlace(&raw, sampleRate: sampleRate)
            filteredInput = raw
        }

        let stride = FaithfulNumericKernels.decimationStride(sampleRate: sampleRate)
        let length = input.count / stride
        guard length >= 2 else { return nil }

        var samples = [Double](repeating: 0.0, count: length)
        var mean = 0.0
        for i in 0..<length {
            var sum = 0.0
            let base = i * stride
            for j in 0..<stride {
                sum += Double(input[base + j])
            }
            let avg = sum / Double(stride)
            samples[i] = avg
            mean += avg
        }
        mean /= Double(length)

        var energy = 0.0
        for i in 0..<length {
            samples[i] -= mean
            energy += samples[i] * samples[i]
        }
        var rms = sqrt(energy / Double(length))
        if !rms.isFinite || rms < 0.000015 {
            return nil
        }

        let rate = sampleRate / Double(stride)
        FaithfulNumericKernels.bandpassFilterInPlace(&samples, sampleRate: rate)

        let start = Int(floor(rate * 0.012))
        let physicalStart = Int(ceil(sampleRate * 0.012))
        guard input.count > physicalStart, length > start else { return nil }

        var originalMean = 0.0
        let physicalCount = input.count - physicalStart
        for i in physicalStart..<input.count {
            originalMean += Double(input[i])
        }
        originalMean /= Double(physicalCount)

        var originalEnergy = 0.0
        var physicalEnergy = 0.0
        for i in physicalStart..<input.count {
            let diff = Double(input[i]) - originalMean
            originalEnergy += diff * diff
            physicalEnergy += filteredInput[i] * filteredInput[i]
        }

        var foldedEnergy = 0.0
        for i in start..<length {
            foldedEnergy += samples[i] * samples[i]
        }

        let physicalPower = physicalEnergy / Double(physicalCount)
        let outOfBandDominates = physicalPower < (originalEnergy / Double(physicalCount)) * 0.01
        var aliasFiltered = false

        if physicalPower < 0.000015 * 0.000015 {
            return nil
        }

        if outOfBandDominates {
            let minimumPeakPower = Double(input.count * input.count) * (0.000015 * 0.000015) / 16.0
            let peaks = analysis != nil
                ? analysis!.peaks(input: input, rate: sampleRate)
                : FaithfulSpectralKernels.spectralPeaks(input: input, sampleRate: sampleRate)
            if !FaithfulSpectralKernels.hasUnfoldedPitchSupport(peaks: peaks, minimumPower: minimumPeakPower) {
                return nil
            }
        }

        var currentInput = input
        var currentFilteredInput = filteredInput
        if outOfBandDominates || (foldedEnergy / Double(length - start) > physicalPower * 4.0) {
            aliasFiltered = true
            let transformed = FaithfulNumericKernels.antiAliasTransform(
                input: currentInput,
                sampleRate: sampleRate,
                decimatedRate: rate
            )
            currentInput = transformed.asFloat
            currentFilteredInput = transformed.asDouble
            FaithfulNumericKernels.bandpassFilterInPlace(&currentFilteredInput, sampleRate: sampleRate)

            for i in 0..<length {
                var sum = 0.0
                let base = i * stride
                for j in 0..<stride {
                    sum += Double(currentInput[base + j])
                }
                samples[i] = sum / Double(stride)
            }
            FaithfulNumericKernels.bandpassFilterInPlace(&samples, sampleRate: rate)
            rms = sqrt(physicalPower)
        }

        let maxLag = min(Int(floor(rate / 110.0)), length / 2 - 1)
        let minLag = max(2, Int(floor(rate / 1100.0)))
        let window = length - maxLag

        guard maxLag >= minLag, maxLag >= 1, window > start else {
            let spectral = analysis != nil
                ? analysis!.spectral(input: currentInput, rate: sampleRate, ranking: ranking)
                : detectSpectralPitch(input: currentInput, sampleRate: sampleRate, ranking: ranking)
            return spectral?.asCandidate(rms: rms)
        }

        var difference = [Double](repeating: 0.0, count: maxLag + 1)
        difference[0] = 1.0
        var cumulative = 0.0
        for lag in 1...maxLag {
            var sum = 0.0
            for i in start..<window {
                let delta = samples[i] - samples[i + lag]
                sum += delta * delta
            }
            cumulative += sum
            difference[lag] = cumulative != 0.0 ? (sum * Double(lag) / cumulative) : 1.0
        }

        var best = -1
        var lag = minLag
        while lag < maxLag {
            if difference[lag] < 0.16 {
                while lag + 1 < maxLag && difference[lag + 1] < difference[lag] {
                    lag += 1
                }
                best = lag
                break
            }
            lag += 1
        }

        if best < 0 {
            for l in (minLag + 1)..<maxLag {
                if best < 0 || difference[l] < difference[best] {
                    best = l
                }
            }
            if best < 0 || difference[best] > 0.25 {
                let spectral = analysis != nil
                    ? analysis!.spectral(input: currentInput, rate: sampleRate, ranking: ranking)
                    : detectSpectralPitch(input: currentInput, sampleRate: sampleRate, ranking: ranking)
                return spectral?.asCandidate(rms: rms)
            }
        }

        let left = difference[best - 1]
        let center = difference[best]
        let right = difference[best + 1]
        let denominator = left - 2.0 * center + right
        let offset: Double
        if denominator != 0.0 {
            let rawOffset = 0.5 * (left - right) / denominator
            offset = rawOffset.isNaN ? 0.0 : max(-1.0, min(1.0, rawOffset))
        } else {
            offset = 0.0
        }

        let approximateLag = (Double(best) + offset) * Double(stride)
        let first = max(2, Int(floor(approximateLag)) - stride)
        let last = min(Double(currentInput.count) / 2.0 - 2.0, ceil(approximateLag) + Double(stride))
        let originalWindow = currentInput.count - Int(ceil(last)) - 1
        let scoreStart = Int(ceil(sampleRate * 0.012))

        guard first <= Int(last), originalWindow > scoreStart, originalWindow > 0 else {
            let spectral = analysis != nil
                ? analysis!.spectral(input: currentInput, rate: sampleRate, ranking: ranking)
                : detectSpectralPitch(input: currentInput, sampleRate: sampleRate, ranking: ranking)
            return spectral?.asCandidate(rms: rms)
        }

        let raw = FaithfulNumericKernels.refineLag(
            signal: currentInput,
            sampleRate: sampleRate,
            first: first,
            last: Int(last),
            windowEnd: originalWindow,
            searchStart: 0,
            scoreStart: scoreStart
        )

        if !validFrequency(raw.frequency) {
            let spectral = analysis != nil
                ? analysis!.spectral(input: currentInput, rate: sampleRate, ranking: ranking)
                : detectSpectralPitch(input: currentInput, sampleRate: sampleRate, ranking: ranking)
            if let spectral = spectral, spectral.oddOnly {
                return spectral.asCandidate(rms: rms)
            }
            return nil
        }

        let filtered = FaithfulNumericKernels.refineLag(
            signal: currentFilteredInput,
            sampleRate: sampleRate,
            first: first,
            last: Int(last),
            windowEnd: originalWindow,
            searchStart: scoreStart,
            scoreStart: scoreStart
        )

        let frequency = validFrequency(filtered.frequency) && (aliasFiltered || filtered.residual < 0.25 * raw.residual)
            ? filtered.frequency : raw.frequency

        if aliasFiltered || (1.0 - center < 0.95) {
            let spectral = analysis != nil
                ? analysis!.spectral(input: currentInput, rate: sampleRate, ranking: ranking)
                : detectSpectralPitch(input: currentInput, sampleRate: sampleRate, ranking: ranking)
            if let spectral = spectral, spectral.oddOnly {
                return spectral.asCandidate(rms: rms)
            }
            if let spectral = spectral, abs(1200.0 * log2(spectral.frequency / (2.0 * frequency))) <= 50.0 {
                let peaks = analysis != nil
                    ? analysis!.peaks(input: currentInput, rate: sampleRate)
                    : FaithfulSpectralKernels.spectralPeaks(input: currentInput, sampleRate: sampleRate)
                func peakPower(_ hz: Double) -> Double {
                    var power = 0.0
                    for peak in peaks {
                        if abs(peak.frequency - hz) <= max(1.5, hz * 0.015) {
                            power = max(power, peak.power)
                        }
                    }
                    return power
                }
                let higherPower = peakPower(spectral.frequency)
                let lowerFrequency = spectral.frequency / 2.0
                var lowerEvidence = max(peakPower(frequency), peakPower(lowerFrequency))
                var harmonic = 3
                while harmonic <= 11 {
                    lowerEvidence = max(lowerEvidence, peakPower(lowerFrequency * Double(harmonic)))
                    harmonic += 2
                }
                if higherPower > 0.0 && lowerEvidence < 0.1 * higherPower {
                    return spectral.asCandidate(rms: rms)
                }
            }
        }

        return FaithfulPitchCandidate(frequency: frequency, confidence: 1.0 - center, rms: rms)
    }

    // MARK: - Onset Refinement

    /// Independent onset refinement: improves frequency accuracy on weak onsets [0.75, 0.98)
    /// if an agreeing spectral harmonic series is available.
    /// Matches `refineOnsetPitch` in reference pitch.ts lines 118-123.
    public static func refineOnsetPitch(
        input: [Float],
        sampleRate: Double,
        pitch: FaithfulPitchCandidate?,
        analysis: FaithfulFrameAnalysis? = nil
    ) -> FaithfulPitchCandidate? {
        guard let pitch = pitch else { return nil }
        if pitch.confidence < 0.75 || pitch.confidence >= 0.98 { return pitch }
        let spectral = analysis != nil
            ? analysis!.spectral(input: input, rate: sampleRate, ranking: .prominence)
            : detectSpectralPitch(input: input, sampleRate: sampleRate, ranking: .prominence)
        guard let spectral = spectral else { return pitch }
        if abs(1200.0 * log2(spectral.frequency / pitch.frequency)) > 50.0 { return pitch }
        var refined = pitch
        refined.frequency = spectral.frequency
        return refined
    }

    // MARK: - Filtered Period Residual

    /// Computes fractional-delay normalized period residual on a filtered signal,
    /// leveraging FaithfulFrameAnalysis if available.
    public static func filteredPeriodResidual(
        input: [Float],
        sampleRate: Double,
        frequency: Double,
        analysis: FaithfulFrameAnalysis? = nil
    ) -> Double {
        let signal: [Double]
        if let analysis = analysis {
            signal = analysis.filtered(input: input, rate: sampleRate)
        } else {
            var copy = [Double](repeating: 0.0, count: input.count)
            for i in 0..<input.count { copy[i] = Double(input[i]) }
            FaithfulNumericKernels.bandpassFilterInPlace(&copy, sampleRate: sampleRate)
            signal = copy
        }
        return FaithfulNumericKernels.filteredPeriodResidual(
            filteredSignal: signal,
            sampleRate: sampleRate,
            frequency: frequency
        )
    }
}
