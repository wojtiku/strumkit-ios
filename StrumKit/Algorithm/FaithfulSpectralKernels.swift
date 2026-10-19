// StrumKit/Algorithm/FaithfulSpectralKernels.swift
import Foundation

/// Pure faithful spectral kernels ported directly from Tools/parity-contract/reference-source/spectrum.ts.
/// Implements radix-2 FFT, power spectrum, spectral peaks extraction, and unfolded pitch support.
public enum FaithfulSpectralKernels {

    // MARK: - Models

    public struct SpectralPeak: Sendable, Codable, Equatable {
        public var frequency: Double
        public var power: Double
        public var prominence: Double

        public init(frequency: Double, power: Double, prominence: Double) {
            self.frequency = frequency
            self.power = power
            self.prominence = prominence
        }
    }

    // MARK: - Math Helpers

    /// JS-compatible round: floor(x + 0.5), preserves negative half ties rounding towards +infinity.
    @inline(__always)
    public static func jsRound(_ value: Double) -> Double {
        return floor(value + 0.5)
    }

    /// Greatest common divisor.
    public static func gcd(_ a: Int, _ b: Int) -> Int {
        var x = a
        var y = b
        while y != 0 {
            let t = y
            y = x % y
            x = t
        }
        return abs(x)
    }

    // MARK: - Power Spectrum (Radix-2 FFT)

    /// Computes the unnormalized windowed half-spectrum power from an audio buffer.
    /// Uses symmetric Hann window (denominator N - 1), mean removal, and zero-padding
    /// to the next power of 2 of input.length * 2 (e.g. 4096 input -> 8192 FFT -> 4096 bins).
    public static func powerSpectrum(_ input: [Float]) -> [Double] {
        guard input.count >= 2 else { return [] }
        let size = 1 << Int(ceil(log2(Double(input.count * 2))))
        var real = [Double](repeating: 0.0, count: size)
        var imaginary = [Double](repeating: 0.0, count: size)

        var mean = 0.0
        for sample in input {
            mean += Double(sample)
        }
        mean /= Double(input.count)

        let nMinus1 = Double(input.count - 1)
        for i in 0..<input.count {
            let window = 0.5 - 0.5 * cos(2.0 * Double.pi * Double(i) / nMinus1)
            real[i] = (Double(input[i]) - mean) * window
        }

        // Radix-2 bit reversal permutation
        var j = 0
        for i in 1..<size {
            var bit = size >> 1
            while (j & bit) != 0 {
                j ^= bit
                bit >>= 1
            }
            j ^= bit
            if i < j {
                let value = real[i]
                real[i] = real[j]
                real[j] = value
            }
        }

        // Cooley-Tukey radix-2 butterfly stages
        var length = 2
        while length <= size {
            let angle = -2.0 * Double.pi / Double(length)
            let stepR = cos(angle)
            let stepI = sin(angle)
            var start = 0
            while start < size {
                var wr = 1.0
                var wi = 0.0
                let half = length / 2
                for j in 0..<half {
                    let a = start + j
                    let b = a + half
                    let r = wr * real[b] - wi * imaginary[b]
                    let im = wr * imaginary[b] + wi * real[b]
                    real[b] = real[a] - r
                    imaginary[b] = imaginary[a] - im
                    real[a] += r
                    imaginary[a] += im
                    let nextR = wr * stepR - wi * stepI
                    wi = wr * stepI + wi * stepR
                    wr = nextR
                }
                start += length
            }
            length <<= 1
        }

        var power = [Double](repeating: 0.0, count: size / 2)
        for i in 0..<power.count {
            power[i] = real[i] * real[i] + imaginary[i] * imaginary[i]
        }
        return power
    }

    /// Overload for [Double] inputs.
    public static func powerSpectrum(_ input: [Double]) -> [Double] {
        guard input.count >= 2 else { return [] }
        let size = 1 << Int(ceil(log2(Double(input.count * 2))))
        var real = [Double](repeating: 0.0, count: size)
        var imaginary = [Double](repeating: 0.0, count: size)

        var mean = 0.0
        for sample in input {
            mean += sample
        }
        mean /= Double(input.count)

        let nMinus1 = Double(input.count - 1)
        for i in 0..<input.count {
            let window = 0.5 - 0.5 * cos(2.0 * Double.pi * Double(i) / nMinus1)
            real[i] = (input[i] - mean) * window
        }

        var j = 0
        for i in 1..<size {
            var bit = size >> 1
            while (j & bit) != 0 {
                j ^= bit
                bit >>= 1
            }
            j ^= bit
            if i < j {
                let value = real[i]
                real[i] = real[j]
                real[j] = value
            }
        }

        var length = 2
        while length <= size {
            let angle = -2.0 * Double.pi / Double(length)
            let stepR = cos(angle)
            let stepI = sin(angle)
            var start = 0
            while start < size {
                var wr = 1.0
                var wi = 0.0
                let half = length / 2
                for j in 0..<half {
                    let a = start + j
                    let b = a + half
                    let r = wr * real[b] - wi * imaginary[b]
                    let im = wr * imaginary[b] + wi * real[b]
                    real[b] = real[a] - r
                    imaginary[b] = imaginary[a] - im
                    real[a] += r
                    imaginary[a] += im
                    let nextR = wr * stepR - wi * stepI
                    wi = wr * stepI + wi * stepR
                    wr = nextR
                }
                start += length
            }
            length <<= 1
        }

        var power = [Double](repeating: 0.0, count: size / 2)
        for i in 0..<power.count {
            power[i] = real[i] * real[i] + imaginary[i] * imaginary[i]
        }
        return power
    }

    // MARK: - Spectral Peaks Extraction

    /// Stable descending sort by power (matches JS Array.prototype.sort stable semantics).
    public static func sortPeaksStableDescending(_ peaks: [SpectralPeak]) -> [SpectralPeak] {
        let indexed = peaks.enumerated().map { ($0.offset, $0.element) }
        let sorted = indexed.sorted { lhs, rhs in
            if lhs.1.power != rhs.1.power {
                return lhs.1.power > rhs.1.power
            }
            return lhs.0 < rhs.0
        }
        return sorted.map { $0.1 }
    }

    /// Extracts prominent spectral peaks from input or precomputed power spectrum.
    /// Excludes window main lobe (+-5 bins), computes prominence against local +-18 bins noise floor,
    /// applies log-parabolic offset clamped to [-0.5, 0.5], stably sorts descending by power,
    /// and slices top 40 peaks.
    public static func spectralPeaks(
        input: [Float],
        sampleRate: Double,
        power: [Double]? = nil
    ) -> [SpectralPeak] {
        let spectrum = power ?? powerSpectrum(input)
        guard spectrum.count >= 21 else { return [] }
        let binHz = sampleRate / Double(spectrum.count * 2)
        var peaks: [SpectralPeak] = []

        let startBin = Int(ceil(110.0 / binHz))
        var i = startBin
        while Double(i) < min(Double(spectrum.count - 20), 6000.0 / binHz) {
            if spectrum[i] <= spectrum[i - 1] || spectrum[i] <= spectrum[i + 1] {
                i += 1
                continue
            }
            var background = 0.0
            var count = 0
            let jStart = max(1, i - 18)
            let jEnd = i + 18
            for j in jStart...jEnd {
                if abs(j - i) <= 5 { continue }
                background += spectrum[j]
                count += 1
            }
            let avgBackground = count > 0 ? background / Double(count) : 0.0
            let prominence = spectrum[i] / max(avgBackground, 1e-24)
            if prominence < 4.0 {
                i += 1
                continue
            }
            let a = log(max(spectrum[i - 1], 1e-24))
            let b = log(max(spectrum[i], 1e-24))
            let c = log(max(spectrum[i + 1], 1e-24))
            let denom = 2.0 * (a - 2.0 * b + c)
            let rawOffset = denom != 0.0 ? (a - c) / denom : 0.0
            let offset = max(-0.5, min(0.5, rawOffset.isNaN ? 0.0 : rawOffset))
            peaks.append(SpectralPeak(
                frequency: (Double(i) + offset) * binHz,
                power: spectrum[i],
                prominence: prominence
            ))
            i += 1
        }

        let sorted = sortPeaksStableDescending(peaks)
        if sorted.count > 40 {
            return Array(sorted.prefix(40))
        }
        return sorted
    }

    /// Overload for [Double] inputs.
    public static func spectralPeaks(
        input: [Double],
        sampleRate: Double,
        power: [Double]? = nil
    ) -> [SpectralPeak] {
        let spectrum = power ?? powerSpectrum(input)
        guard spectrum.count >= 21 else { return [] }
        let binHz = sampleRate / Double(spectrum.count * 2)
        var peaks: [SpectralPeak] = []

        let startBin = Int(ceil(110.0 / binHz))
        var i = startBin
        while Double(i) < min(Double(spectrum.count - 20), 6000.0 / binHz) {
            if spectrum[i] <= spectrum[i - 1] || spectrum[i] <= spectrum[i + 1] {
                i += 1
                continue
            }
            var background = 0.0
            var count = 0
            let jStart = max(1, i - 18)
            let jEnd = i + 18
            for j in jStart...jEnd {
                if abs(j - i) <= 5 { continue }
                background += spectrum[j]
                count += 1
            }
            let avgBackground = count > 0 ? background / Double(count) : 0.0
            let prominence = spectrum[i] / max(avgBackground, 1e-24)
            if prominence < 4.0 {
                i += 1
                continue
            }
            let a = log(max(spectrum[i - 1], 1e-24))
            let b = log(max(spectrum[i], 1e-24))
            let c = log(max(spectrum[i + 1], 1e-24))
            let denom = 2.0 * (a - 2.0 * b + c)
            let rawOffset = denom != 0.0 ? (a - c) / denom : 0.0
            let offset = max(-0.5, min(0.5, rawOffset.isNaN ? 0.0 : rawOffset))
            peaks.append(SpectralPeak(
                frequency: (Double(i) + offset) * binHz,
                power: spectrum[i],
                prominence: prominence
            ))
            i += 1
        }

        let sorted = sortPeaksStableDescending(peaks)
        if sorted.count > 40 {
            return Array(sorted.prefix(40))
        }
        return sorted
    }

    // MARK: - Unfolded Pitch Support

    /// Checks for in-range fundamental energy or a coprime harmonic series (GCD == 1).
    /// Used when out-of-band input dominates to prevent loud interferers from setting a false floor.
    public static func hasUnfoldedPitchSupport(peaks: [SpectralPeak], minimumPower: Double) -> Bool {
        let audible = peaks.filter { $0.prominence >= 15.0 && $0.power >= minimumPower }
        if audible.contains(where: { $0.frequency >= 110.0 && $0.frequency <= 1100.0 }) {
            return true
        }

        for peak in audible {
            for divisor in 2...8 {
                let candidate = peak.frequency / Double(divisor)
                if candidate < 110.0 || candidate > 1100.0 {
                    continue
                }
                var harmonics = Set<Int>()
                for partial in audible {
                    let harmonic = Int(floor(partial.frequency / candidate + 0.5))
                    if harmonic >= 1 && harmonic <= 12 {
                        let err = abs(partial.frequency / Double(harmonic) - candidate)
                        let tol = max(1.5, candidate * 0.008)
                        if err <= tol {
                            harmonics.insert(harmonic)
                        }
                    }
                }
                if harmonics.count >= 3 {
                    let overallGcd = harmonics.reduce(0) { gcd($0, $1) }
                    if overallGcd == 1 {
                        return true
                    }
                }
            }
        }
        return false
    }
}
