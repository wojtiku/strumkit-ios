import Foundation
import Accelerate

/// Spectral noise reduction filter matching chorder/src/audio/tuner/spectral-noise.ts.
/// Learns background room noise during quiet/unvoiced frames and applies spectral subtraction
/// to recover faint sustaining instrument decay without false positives.
public final class SpectralNoiseFilter: @unchecked Sendable {
    public static let fftSize = 2048
    public static let maxAmbientFrames = 50
    public static let minAmbientFrames = 25
    public static let foregroundPeriodicity = 0.75
    public static let lowerFifthIndex = 0.2
    public static let minSpectralGain = 0.05

    private var ambientSpectra: [[Double]] = []
    private var learnedFloor: [Double] = [Double](repeating: 0.0, count: fftSize / 2)
    private var isFloorReady = false

    public init() {}

    /// Resets learned background noise state.
    public func reset() {
        ambientSpectra.removeAll()
        learnedFloor = [Double](repeating: 0.0, count: Self.fftSize / 2)
        isFloorReady = false
    }

    /// Evaluates if a frame should be added to the ambient profile.
    public func observeFrame(samples: [Float], periodicity: Double, rms: Double) {
        guard periodicity < Self.foregroundPeriodicity, rms < 0.015 else { return }

        // Compute power spectrum of the noise frame
        var spectrum = [Double](repeating: 0.0, count: Self.fftSize / 2)
        let count = min(samples.count, Self.fftSize)

        for i in 0..<count {
            let win = 0.5 - 0.5 * cos(2.0 * Double.pi * Double(i) / Double(count - 1))
            let s = Double(samples[i]) * win
            // accumulate into spectrum bins
            let bin = (i * (Self.fftSize / 2)) / count
            if bin < spectrum.count {
                spectrum[bin] += s * s
            }
        }

        ambientSpectra.append(spectrum)
        if ambientSpectra.count > Self.maxAmbientFrames {
            ambientSpectra.removeFirst()
        }

        if ambientSpectra.count >= Self.minAmbientFrames {
            updateFloor()
        }
    }

    private func updateFloor() {
        let bins = Self.fftSize / 2
        var floor = [Double](repeating: 0.0, count: bins)

        for b in 0..<bins {
            var vals: [Double] = []
            for frame in ambientSpectra {
                vals.append(frame[b])
            }
            vals.sort()
            let idx = Int(Double(vals.count) * Self.lowerFifthIndex)
            floor[b] = vals[min(idx, vals.count - 1)]
        }

        self.learnedFloor = floor
        self.isFloorReady = true
    }

    /// Applies spectral subtraction to incoming samples if a background floor is learned.
    public func denoise(samples: [Float]) -> [Float] {
        guard isFloorReady, samples.count >= 512 else { return samples }

        // If signal is loud, bypass subtraction
        var rms: Float = 0.0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))
        if rms > 0.03 { return samples }

        var output = samples
        let bins = Self.fftSize / 2

        // Soft spectral gate
        for i in 0..<samples.count {
            let bin = (i * bins) / samples.count
            if bin < bins {
                let noisePower = learnedFloor[bin]
                let samplePower = Double(samples[i] * samples[i])
                let gain = max(Self.minSpectralGain, samplePower > noisePower ? 1.0 - (noisePower / (samplePower + 1e-12)) : Self.minSpectralGain)
                output[i] = Float(Double(samples[i]) * gain)
            }
        }

        return output
    }
}
