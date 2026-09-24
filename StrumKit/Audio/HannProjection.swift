import Foundation

/// Projects a signal onto one frequency with a symmetric Hann window.
/// Exact native Swift implementation of chorder/src/audio/tuner/correlation.ts.
public enum HannProjection {
    public struct Result: Sendable {
        public let real: Double
        public let imaginary: Double
        public let weight: Double
    }

    /// Projects samples onto a target frequency using a Hann window.
    public static func project(
        samples: [Float],
        frequency: Double,
        sampleRate: Double,
        offset: Double = 0.0
    ) -> Result {
        let count = samples.count
        guard count > 1 else { return Result(real: 0, imaginary: 0, weight: 0) }

        var real: Double = 0.0
        var imaginary: Double = 0.0
        var weight: Double = 0.0

        let denom = Double(count - 1)
        let angleFactor = 2.0 * Double.pi * frequency / sampleRate

        for index in 0..<count {
            let window = 0.5 - 0.5 * cos(2.0 * Double.pi * Double(index) / denom)
            let angle = angleFactor * Double(index)
            let sample = Double(samples[index]) - offset

            real += sample * window * cos(angle)
            imaginary += sample * window * sin(angle)
            weight += window
        }

        return Result(real: real, imaginary: imaginary, weight: weight)
    }

    /// Detector energy is weight-normalized to compare projections across windows.
    public static func normalizedPower(
        samples: [Float],
        frequency: Double,
        sampleRate: Double,
        offset: Double = 0.0
    ) -> Double {
        let res = project(samples: samples, frequency: frequency, sampleRate: sampleRate, offset: offset)
        guard res.weight > 0 else { return 0.0 }
        return 2.0 * (res.real * res.real + res.imaginary * res.imaginary) / (res.weight * res.weight)
    }

    /// Raw power without weight normalization.
    public static func rawPower(
        samples: [Float],
        frequency: Double,
        sampleRate: Double,
        offset: Double = 0.0
    ) -> Double {
        let res = project(samples: samples, frequency: frequency, sampleRate: sampleRate, offset: offset)
        return res.real * res.real + res.imaginary * res.imaginary
    }
}
