// StrumKit/Algorithm/FaithfulNumericKernels.swift
import Foundation

/// Pure faithful numeric and filter kernels ported directly from Tools/parity-contract/reference-source/pitch.ts.
/// Implements biquad filtering, bandpass filter, Butterworth anti-aliasing with Float32 intermediate rounding,
/// box decimation, lag refinement, and filtered period residual.
public enum FaithfulNumericKernels {

    // MARK: - Models

    public struct LagRefinementResult: Sendable, Equatable {
        public var frequency: Double
        public var residual: Double

        public init(frequency: Double, residual: Double) {
            self.frequency = frequency
            self.residual = residual
        }
    }

    public struct BoxDecimationResult: Sendable, Equatable {
        public var samples: [Double]
        public var stride: Int
        public var rate: Double
        public var rms: Double

        public init(samples: [Double], stride: Int, rate: Double, rms: Double) {
            self.samples = samples
            self.stride = stride
            self.rate = rate
            self.rms = rms
        }
    }

    // MARK: - Direct Form Biquad Filter

    /// Direct form biquad filter.
    /// Resets state (x1, x2, y1, y2) to zero on every call — no persistent streaming filter memory across windows.
    public static func biquadFilterInPlace(
        _ samples: inout [Double],
        sampleRate rate: Double,
        cutoff: Double,
        q: Double,
        highpass: Bool
    ) {
        guard rate > 0 else { return }
        let omega = 2.0 * Double.pi * cutoff / rate
        let cosine = cos(omega)
        let alpha = sin(omega) / (2.0 * q)
        let a0 = 1.0 + alpha
        let b0 = (highpass ? 1.0 + cosine : 1.0 - cosine) / (2.0 * a0)
        let b1 = (highpass ? -(1.0 + cosine) : 1.0 - cosine) / a0
        let a1 = -2.0 * cosine / a0
        let a2 = (1.0 - alpha) / a0

        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        for i in 0..<samples.count {
            let x = samples[i]
            let y = b0 * x + b1 * x1 + b0 * x2 - a1 * y1 - a2 * y2
            samples[i] = y
            x2 = x1
            x1 = x
            y2 = y1
            y1 = y
        }
    }

    /// Functional wrapper for biquad filter.
    public static func biquadFilter(
        samples: [Double],
        sampleRate: Double,
        cutoff: Double,
        q: Double,
        highpass: Bool
    ) -> [Double] {
        var copy = samples
        biquadFilterInPlace(&copy, sampleRate: sampleRate, cutoff: cutoff, q: q, highpass: highpass)
        return copy
    }

    // MARK: - Three-Section Bandpass Filter

    /// Three-section biquad bandpass filter:
    /// Section 1: 100 Hz highpass, Q = 1 / sqrt(2)
    /// Section 2: 1200 Hz lowpass, Q = 0.541196
    /// Section 3: 1200 Hz lowpass, Q = 1.306563
    public static func bandpassFilterInPlace(_ samples: inout [Double], sampleRate: Double) {
        biquadFilterInPlace(&samples, sampleRate: sampleRate, cutoff: 100.0, q: 1.0 / sqrt(2.0), highpass: true)
        biquadFilterInPlace(&samples, sampleRate: sampleRate, cutoff: 1200.0, q: 0.541196, highpass: false)
        biquadFilterInPlace(&samples, sampleRate: sampleRate, cutoff: 1200.0, q: 1.306563, highpass: false)
    }

    /// Functional wrapper for three-section bandpass filter.
    public static func bandpassFilter(samples: [Double], sampleRate: Double) -> [Double] {
        var copy = samples
        bandpassFilterInPlace(&copy, sampleRate: sampleRate)
        return copy
    }

    // MARK: - Eighth-Order Butterworth Anti-Alias Filter

    /// Fixed Q values for eighth-order Butterworth filter (4 biquad sections).
    public static let butterworthQs: [Double] = [0.50979558, 0.60134489, 0.89997622, 2.56291545]

    /// Eighth-order Butterworth lowpass anti-alias filter at cutoff = decimatedRate / 4.
    public static func butterworthAntiAliasFilterInPlace(
        _ samples: inout [Double],
        sampleRate: Double,
        decimatedRate: Double
    ) {
        let cutoff = decimatedRate / 4.0
        for q in butterworthQs {
            biquadFilterInPlace(&samples, sampleRate: sampleRate, cutoff: cutoff, q: q, highpass: false)
        }
    }

    /// Functional wrapper for eighth-order Butterworth anti-alias filter.
    public static func butterworthAntiAliasFilter(
        samples: [Double],
        sampleRate: Double,
        decimatedRate: Double
    ) -> [Double] {
        var copy = samples
        butterworthAntiAliasFilterInPlace(&copy, sampleRate: sampleRate, decimatedRate: decimatedRate)
        return copy
    }

    /// Mirrors intentional Float32 intermediate rounding on anti-alias output
    /// (Double -> Float32 -> Double) exactly as in reference pitch.ts lines 465-466:
    /// `input = Float32Array.from(antiAliased)`.
    @inline(__always)
    public static func mirrorFloat32Intermediate(_ samples: [Double]) -> [Double] {
        var result = [Double](repeating: 0.0, count: samples.count)
        for i in 0..<samples.count {
            result[i] = Double(Float(samples[i]))
        }
        return result
    }

    /// Transforms an input buffer through the complete anti-aliasing path:
    /// 1. Convert input to Double.
    /// 2. 4-section Butterworth lowpass at decimatedRate / 4.
    /// 3. Round to Float32 intermediate (`Float32Array.from(antiAliased)`).
    /// Returns the Float32 array and its Double representation.
    public static func antiAliasTransform(
        input: [Float],
        sampleRate: Double,
        decimatedRate: Double
    ) -> (asFloat: [Float], asDouble: [Double]) {
        var antiAliased = [Double](repeating: 0.0, count: input.count)
        for i in 0..<input.count {
            antiAliased[i] = Double(input[i])
        }
        butterworthAntiAliasFilterInPlace(&antiAliased, sampleRate: sampleRate, decimatedRate: decimatedRate)

        var asFloat = [Float](repeating: 0.0, count: input.count)
        var asDouble = [Double](repeating: 0.0, count: input.count)
        for i in 0..<input.count {
            let f = Float(antiAliased[i])
            asFloat[i] = f
            asDouble[i] = Double(f)
        }
        return (asFloat: asFloat, asDouble: asDouble)
    }

    // MARK: - Box Decimation

    /// Decimation stride: max(1, floor(sampleRate / 12000)).
    @inline(__always)
    public static func decimationStride(sampleRate: Double) -> Int {
        return max(1, Int(floor(sampleRate / 12000.0)))
    }

    /// Box decimation with optional mean removal and RMS computation.
    public static func boxDecimate(
        input: [Float],
        sampleRate: Double,
        removeMean: Bool = true
    ) -> BoxDecimationResult {
        let stride = decimationStride(sampleRate: sampleRate)
        let length = input.count / stride
        guard length > 0 else {
            return BoxDecimationResult(samples: [], stride: stride, rate: sampleRate / Double(stride), rms: 0.0)
        }

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
        if removeMean {
            for i in 0..<length {
                samples[i] -= mean
                energy += samples[i] * samples[i]
            }
        } else {
            for i in 0..<length {
                energy += samples[i] * samples[i]
            }
        }
        let rms = sqrt(energy / Double(length))
        return BoxDecimationResult(
            samples: samples,
            stride: stride,
            rate: sampleRate / Double(stride),
            rms: rms
        )
    }

    /// Box decimation for [Double] inputs.
    public static func boxDecimate(
        input: [Double],
        sampleRate: Double,
        removeMean: Bool = true
    ) -> BoxDecimationResult {
        let stride = decimationStride(sampleRate: sampleRate)
        let length = input.count / stride
        guard length > 0 else {
            return BoxDecimationResult(samples: [], stride: stride, rate: sampleRate / Double(stride), rms: 0.0)
        }

        var samples = [Double](repeating: 0.0, count: length)
        var mean = 0.0
        for i in 0..<length {
            var sum = 0.0
            let base = i * stride
            for j in 0..<stride {
                sum += input[base + j]
            }
            let avg = sum / Double(stride)
            samples[i] = avg
            mean += avg
        }
        mean /= Double(length)

        var energy = 0.0
        if removeMean {
            for i in 0..<length {
                samples[i] -= mean
                energy += samples[i] * samples[i]
            }
        } else {
            for i in 0..<length {
                energy += samples[i] * samples[i]
            }
        }
        let rms = sqrt(energy / Double(length))
        return BoxDecimationResult(
            samples: samples,
            stride: stride,
            rate: sampleRate / Double(stride),
            rms: rms
        )
    }

    // MARK: - Lag Difference and Parabolic Refinement

    /// Refines candidate lag over [first, last] using parabolic interpolation and normalized error residual.
    public static func refineLag(
        signal: [Double],
        sampleRate: Double,
        first: Int,
        last: Int,
        windowEnd: Int,
        searchStart: Int,
        scoreStart: Int
    ) -> LagRefinementResult {
        func difference(_ lag: Int) -> Double {
            var sum = 0.0
            for i in searchStart..<windowEnd {
                let delta = signal[i] - signal[i + lag]
                sum += delta * delta
            }
            return sum
        }

        var best = first
        var value = Double.infinity
        for lag in first...last {
            let candidate = difference(lag)
            if candidate < value {
                value = candidate
                best = lag
            }
        }

        let left = difference(best - 1)
        let right = difference(best + 1)
        let curvature = left - 2.0 * value + right
        let offset: Double
        if curvature != 0.0 {
            let raw = (left - right) / (2.0 * curvature)
            offset = raw.isNaN ? 0.0 : max(-1.0, min(1.0, raw))
        } else {
            offset = 0.0
        }

        var error = 0.0
        var energy = 0.0
        for i in scoreStart..<windowEnd {
            let x = signal[i]
            let y = signal[i + best]
            energy += x * x + y * y
            let diff = x - y
            error += diff * diff
        }

        let residual = energy != 0.0 ? error / energy : Double.infinity
        let frequency = sampleRate / (Double(best) + offset)
        return LagRefinementResult(frequency: frequency, residual: residual)
    }

    /// Overload for [Float] inputs.
    public static func refineLag(
        signal: [Float],
        sampleRate: Double,
        first: Int,
        last: Int,
        windowEnd: Int,
        searchStart: Int,
        scoreStart: Int
    ) -> LagRefinementResult {
        func difference(_ lag: Int) -> Double {
            var sum = 0.0
            for i in searchStart..<windowEnd {
                let delta = Double(signal[i]) - Double(signal[i + lag])
                sum += delta * delta
            }
            return sum
        }

        var best = first
        var value = Double.infinity
        for lag in first...last {
            let candidate = difference(lag)
            if candidate < value {
                value = candidate
                best = lag
            }
        }

        let left = difference(best - 1)
        let right = difference(best + 1)
        let curvature = left - 2.0 * value + right
        let offset: Double
        if curvature != 0.0 {
            let raw = (left - right) / (2.0 * curvature)
            offset = raw.isNaN ? 0.0 : max(-1.0, min(1.0, raw))
        } else {
            offset = 0.0
        }

        var error = 0.0
        var energy = 0.0
        for i in scoreStart..<windowEnd {
            let x = Double(signal[i])
            let y = Double(signal[i + best])
            energy += x * x + y * y
            let diff = x - y
            error += diff * diff
        }

        let residual = energy != 0.0 ? error / energy : Double.infinity
        let frequency = sampleRate / (Double(best) + offset)
        return LagRefinementResult(frequency: frequency, residual: residual)
    }

    // MARK: - Filtered Period Residual

    /// Computes fractional-delay normalized period residual on a bandpassed signal.
    public static func filteredPeriodResidual(
        filteredSignal signal: [Double],
        sampleRate: Double,
        frequency: Double
    ) -> Double {
        let lag = sampleRate / frequency
        let whole = Int(floor(lag))
        let fraction = lag - Double(whole)
        var error = 0.0
        var energy = 0.0
        let start = Int(ceil(sampleRate * 0.012))
        let limit = signal.count - whole - 1
        if start < limit {
            for i in start..<limit {
                let delayed = signal[i + whole] * (1.0 - fraction) + signal[i + whole + 1] * fraction
                let diff = signal[i] - delayed
                error += diff * diff
                energy += signal[i] * signal[i] + delayed * delayed
            }
        }
        return energy > 0.0 ? error / energy : Double.infinity
    }

    /// Computes fractional-delay normalized period residual from raw input, applying bandpass filter.
    public static func filteredPeriodResidual(
        input: [Float],
        sampleRate: Double,
        frequency: Double
    ) -> Double {
        var signal = [Double](repeating: 0.0, count: input.count)
        for i in 0..<input.count {
            signal[i] = Double(input[i])
        }
        bandpassFilterInPlace(&signal, sampleRate: sampleRate)
        return filteredPeriodResidual(filteredSignal: signal, sampleRate: sampleRate, frequency: frequency)
    }
}
