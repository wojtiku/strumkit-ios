import Foundation
import Accelerate

/// High-performance pitch detector implementing the YIN algorithm with Accelerate (vDSP).
/// Optimized for monophonic string instruments (Guitar, Ukulele, Bass) across 50 Hz - 2000 Hz.
public final class PitchDetector: Sendable {
    private let sampleRate: Double
    private let bufferSize: Int
    private let minFrequency: Double
    private let maxFrequency: Double

    public init(
        sampleRate: Double = 44100.0,
        bufferSize: Int = 2048,
        minFrequency: Double = 50.0,
        maxFrequency: Double = 2000.0
    ) {
        self.sampleRate = sampleRate
        self.bufferSize = bufferSize
        self.minFrequency = minFrequency
        self.maxFrequency = maxFrequency
    }

    /// Analyzes an incoming audio buffer of PCM Float samples.
    /// - Parameters:
    ///   - buffer: Array of Float audio samples (e.g. 1024 or 2048 samples).
    ///   - noiseGateRMS: Minimum RMS amplitude threshold to trigger detection.
    ///   - yinThreshold: Threshold for peak candidate selection (typically 0.10 - 0.15).
    ///   - referenceA4: Reference pitch for note calculation (default 440 Hz).
    /// - Returns: Analyzed `PitchResult` containing frequency, closest note, cents, and confidence.
    public func detectPitch(
        in buffer: [Float],
        noiseGateRMS: Float = 0.012,
        yinThreshold: Float = 0.15,
        referenceA4: Double = 440.0
    ) -> PitchResult {
        let count = buffer.count
        guard count >= 512 else { return .idle }

        // 1. Calculate RMS energy using vDSP
        var rms: Float = 0.0
        vDSP_rmsqv(buffer, 1, &rms, vDSP_Length(count))

        guard rms >= noiseGateRMS else {
            return PitchResult(
                frequency: 0,
                closestNote: MusicalNote(midiNoteNumber: 69, referenceA4: referenceA4),
                centsDeviation: 0,
                confidence: 0,
                amplitudeRMS: Double(rms),
                isSignalPresent: false
            )
        }

        // Half-window for YIN difference function
        let halfBufferSize = count / 2
        let minTau = max(2, Int(sampleRate / maxFrequency))
        let maxTau = min(halfBufferSize - 1, Int(sampleRate / minFrequency))

        guard maxTau > minTau else { return .idle }

        // 2. Compute Difference Function: d(tau) = sum_{j=0}^{halfBuffer}((x[j] - x[j+tau])^2)
        var diff = [Float](repeating: 0.0, count: maxTau + 1)
        var subBuffer = [Float](repeating: 0.0, count: halfBufferSize)
        var sqBuffer = [Float](repeating: 0.0, count: halfBufferSize)

        for tau in minTau...maxTau {
            buffer.withUnsafeBufferPointer { ptr in
                guard let base = ptr.baseAddress else { return }
                let x = base
                let xTau = base + tau

                // subBuffer = x - xTau
                vDSP_vsub(xTau, 1, x, 1, &subBuffer, 1, vDSP_Length(halfBufferSize))
                // sqBuffer = subBuffer^2
                vDSP_vsq(subBuffer, 1, &sqBuffer, 1, vDSP_Length(halfBufferSize))
                // diff[tau] = sum(sqBuffer)
                var sum: Float = 0.0
                vDSP_sve(sqBuffer, 1, &sum, vDSP_Length(halfBufferSize))
                diff[tau] = sum
            }
        }

        // 3. Cumulative Mean Normalized Difference Function (CMNDF)
        var cmndf = [Float](repeating: 1.0, count: maxTau + 1)
        cmndf[0] = 1.0

        var runningSum: Float = 0.0
        for tau in 1...maxTau {
            runningSum += diff[tau]
            if runningSum > 0 {
                cmndf[tau] = (diff[tau] * Float(tau)) / runningSum
            } else {
                cmndf[tau] = 1.0
            }
        }

        // 4. Absolute Thresholding: Find first dip below yinThreshold
        var tauEstimate = -1
        for tau in minTau..<maxTau {
            if cmndf[tau] < yinThreshold {
                // Find local minimum
                var localTau = tau
                while localTau + 1 < maxTau && cmndf[localTau + 1] < cmndf[localTau] {
                    localTau += 1
                }
                tauEstimate = localTau
                break
            }
        }

        // Fallback: If no dip below threshold, search for global minimum
        if tauEstimate == -1 {
            var minVal: Float = Float.greatestFiniteMagnitude
            for tau in minTau...maxTau {
                if cmndf[tau] < minVal {
                    minVal = cmndf[tau]
                    tauEstimate = tau
                }
            }
            // Discard if confidence is too low
            if minVal > 0.40 {
                return PitchResult(
                    frequency: 0,
                    closestNote: MusicalNote(midiNoteNumber: 69, referenceA4: referenceA4),
                    centsDeviation: 0,
                    confidence: 0,
                    amplitudeRMS: Double(rms),
                    isSignalPresent: true
                )
            }
        }

        guard tauEstimate > minTau && tauEstimate < maxTau else {
            return .idle
        }

        // 5. Parabolic Interpolation for sub-sample precision
        let s0 = cmndf[tauEstimate - 1]
        let s1 = cmndf[tauEstimate]
        let s2 = cmndf[tauEstimate + 1]

        let denominator = 2.0 * (2.0 * s1 - s0 - s2)
        let deltaTau: Double
        if abs(denominator) > 1e-6 {
            deltaTau = Double(s2 - s0) / Double(denominator)
        } else {
            deltaTau = 0.0
        }

        let refinedTau = Double(tauEstimate) + deltaTau
        guard refinedTau > 0 else { return .idle }

        let detectedFreq = sampleRate / refinedTau
        guard detectedFreq >= minFrequency && detectedFreq <= maxFrequency else {
            return .idle
        }

        let confidence = Double(max(0.0, min(1.0, 1.0 - s1)))

        // 6. Map to Closest Musical Note and Cents
        guard let (closestNote, cents) = MusicalNote.closest(to: detectedFreq, referenceA4: referenceA4) else {
            return .idle
        }

        return PitchResult(
            frequency: detectedFreq,
            closestNote: closestNote,
            centsDeviation: cents,
            confidence: confidence,
            amplitudeRMS: Double(rms),
            isSignalPresent: true
        )
    }
}
