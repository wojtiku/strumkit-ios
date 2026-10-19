// StrumKitTests/Parity/NumericKernelsTests.swift
import Foundation
import Testing
@testable import StrumKit

@Suite("Numeric Kernels Parity Tests")
struct NumericKernelsTests {

    // MARK: - 1. Radix-2 FFT and Power Spectrum Tests

    @Test("powerSpectrum geometry: 4096 input produces 4096 power bins from 8192-point FFT")
    func powerSpectrumGeometry() {
        let input = [Float](repeating: 0.1, count: 4096)
        let power = FaithfulSpectralKernels.powerSpectrum(input)
        #expect(power.count == 4096)
    }

    @Test("powerSpectrum removes DC offset (constant signal yields near-zero power)")
    func powerSpectrumDCRemoval() {
        let input = [Float](repeating: 0.85, count: 4096)
        let power = FaithfulSpectralKernels.powerSpectrum(input)
        for val in power {
            #expect(val < 1e-20)
        }
    }

    @Test("powerSpectrum matches reference vectors on 440 Hz sine at 48 kHz")
    func powerSpectrumReferenceSine() {
        let rate = 48000.0
        var input = [Float](repeating: 0, count: 4096)
        for i in 0..<4096 {
            input[i] = Float(0.1 * sin(2.0 * Double.pi * 440.0 * Double(i) / rate))
        }

        let power = FaithfulSpectralKernels.powerSpectrum(input)
        #expect(power.count == 4096)

        // First 5 power bins match reference JS output
        let expectedFirst5 = [
            2.912960143370448,
            2.096175268458284,
            0.7256533336353905,
            0.08401021713639965,
            0.0000018932896669231149
        ]
        for (i, expected) in expectedFirst5.enumerated() {
            #expect(abs(power[i] - expected) < 1e-6)
        }

        // Peak bin is at bin 75 (440 Hz * 8192 / 48000 = 75.09)
        var maxBin = 0
        var maxPower = 0.0
        for (i, p) in power.enumerated() {
            if p > maxPower {
                maxPower = p
                maxBin = i
            }
        }
        #expect(maxBin == 75)
        #expect(abs(maxPower - 10451.255109466738) < 1e-6)
    }

    @Test("powerSpectrum handles empty, single-sample, short, and nonfinite inputs without crashing")
    func powerSpectrumEdgeCases() {
        // Empty input
        let empty = FaithfulSpectralKernels.powerSpectrum([Float]())
        #expect(empty.isEmpty)

        // Single sample
        let single = FaithfulSpectralKernels.powerSpectrum([Float(1.0)])
        #expect(single.isEmpty)

        // Short input (64 samples) -> zero-padded to next power of 2 of 64 * 2 = 128 -> 64 power bins
        let short = [Float](repeating: 0.1, count: 64)
        let shortPower = FaithfulSpectralKernels.powerSpectrum(short)
        #expect(shortPower.count == 64)

        // Nonfinite input (NaN) produces nonfinite power without crashing
        let nans = [Float](repeating: Float.nan, count: 4096)
        let nanPower = FaithfulSpectralKernels.powerSpectrum(nans)
        #expect(nanPower.count == 4096)
        #expect(nanPower[0].isNaN)
    }

    // MARK: - 2. Spectral Peaks Extraction Tests

    @Test("spectralPeaks detects 440 Hz tone peak with sub-bin interpolation and prominence")
    func spectralPeaksReferenceTone() {
        let rate = 48000.0
        var input = [Float](repeating: 0, count: 4096)
        for i in 0..<4096 {
            input[i] = Float(0.1 * sin(2.0 * Double.pi * 440.0 * Double(i) / rate))
        }

        let peaks = FaithfulSpectralKernels.spectralPeaks(input: input, sampleRate: rate)
        #expect(!peaks.isEmpty)

        let top = peaks[0]
        #expect(abs(top.frequency - 440.00891891571547) < 1e-6)
        #expect(abs(top.power - 10451.255109466738) < 1e-6)
        #expect(abs(top.prominence - 146813.9375832628) < 1.0)
    }

    @Test("spectralPeaks preserves stable tie ordering and truncates to top 40 peaks")
    func spectralPeaksStableTiesAndTruncation() {
        let rate = 48000.0
        let binHz = rate / 8192.0
        // Synthesize 50 distinct sinusoidal peaks
        var input = [Float](repeating: 0, count: 4096)
        for k in 1...50 {
            let freq = 120.0 + Double(k) * 40.0
            for i in 0..<4096 {
                input[i] += Float(0.01 * sin(2.0 * Double.pi * freq * Double(i) / rate))
            }
        }

        let peaks = FaithfulSpectralKernels.spectralPeaks(input: input, sampleRate: rate)
        // Truncated to at most 40
        #expect(peaks.count <= 40)

        // Sorted descending by power
        for i in 1..<peaks.count {
            #expect(peaks[i - 1].power >= peaks[i].power)
        }

        // Verify stable tie ordering directly on array with equal power
        var equalPowerPeaks: [FaithfulSpectralKernels.SpectralPeak] = [
            .init(frequency: 200, power: 10.0, prominence: 20.0),
            .init(frequency: 300, power: 20.0, prominence: 30.0),
            .init(frequency: 400, power: 10.0, prominence: 25.0),
            .init(frequency: 500, power: 10.0, prominence: 15.0)
        ]
        let sorted = FaithfulSpectralKernels.sortPeaksStableDescending(equalPowerPeaks)
        #expect(sorted[0].frequency == 300) // power 20.0
        #expect(sorted[1].frequency == 200) // power 10.0, first encountered
        #expect(sorted[2].frequency == 400) // power 10.0, second encountered
        #expect(sorted[3].frequency == 500) // power 10.0, third encountered
    }

    // MARK: - 3. Unfolded Pitch Support Tests

    @Test("hasUnfoldedPitchSupport: 5 kHz out-of-band tone alone is rejected")
    func unfoldedSupport5kHzTone() {
        let lone5kHz: [FaithfulSpectralKernels.SpectralPeak] = [
            .init(frequency: 5000.0, power: 100.0, prominence: 100.0)
        ]
        let hasSupport = FaithfulSpectralKernels.hasUnfoldedPitchSupport(peaks: lone5kHz, minimumPower: 0.0001)
        #expect(hasSupport == false)
    }

    @Test("hasUnfoldedPitchSupport: In-range audible tone [110, 1100] is accepted")
    func unfoldedSupportInRangeTone() {
        let tone440: [FaithfulSpectralKernels.SpectralPeak] = [
            .init(frequency: 440.0, power: 100.0, prominence: 100.0)
        ]
        let hasSupport = FaithfulSpectralKernels.hasUnfoldedPitchSupport(peaks: tone440, minimumPower: 0.0001)
        #expect(hasSupport == true)
    }

    @Test("hasUnfoldedPitchSupport: Missing fundamental with coprime odd harmonics is accepted")
    func unfoldedSupportCoprimeSeries() {
        // Missing fundamental 150 Hz with odd harmonics 3 (450), 5 (750), 7 (1050)
        let oddSeries: [FaithfulSpectralKernels.SpectralPeak] = [
            .init(frequency: 450.0, power: 100.0, prominence: 20.0),
            .init(frequency: 750.0, power: 80.0, prominence: 20.0),
            .init(frequency: 1050.0, power: 60.0, prominence: 20.0)
        ]
        let hasSupport = FaithfulSpectralKernels.hasUnfoldedPitchSupport(peaks: oddSeries, minimumPower: 0.0001)
        #expect(hasSupport == true)
    }

    @Test("hasUnfoldedPitchSupport: Non-coprime series without in-range fundamental is rejected")
    func unfoldedSupportNonCoprimeSeries() {
        // Partials at 2400, 3600, 4800 Hz. For candidate 600 Hz: harmonics are 4, 6, 8 (gcd=2 != 1)
        let nonCoprime: [FaithfulSpectralKernels.SpectralPeak] = [
            .init(frequency: 2400.0, power: 100.0, prominence: 20.0),
            .init(frequency: 3600.0, power: 80.0, prominence: 20.0),
            .init(frequency: 4800.0, power: 60.0, prominence: 20.0)
        ]
        let hasSupport = FaithfulSpectralKernels.hasUnfoldedPitchSupport(peaks: nonCoprime, minimumPower: 0.0001)
        #expect(hasSupport == false)

        // Adding 3000 Hz (harmonic 5) makes harmonics [4, 5, 6, 8] with gcd=1 -> accepted
        var coprime = nonCoprime
        coprime.append(.init(frequency: 3000.0, power: 90.0, prominence: 20.0))
        #expect(FaithfulSpectralKernels.hasUnfoldedPitchSupport(peaks: coprime, minimumPower: 0.0001) == true)
    }

    @Test("hasUnfoldedPitchSupport: Sub-threshold peaks (power < min or prominence < 15) are ignored")
    func unfoldedSupportSubThreshold() {
        // Low prominence (< 15)
        let lowProm: [FaithfulSpectralKernels.SpectralPeak] = [
            .init(frequency: 440.0, power: 100.0, prominence: 14.9)
        ]
        #expect(FaithfulSpectralKernels.hasUnfoldedPitchSupport(peaks: lowProm, minimumPower: 0.0001) == false)

        // Low power (< minPower)
        let lowPower: [FaithfulSpectralKernels.SpectralPeak] = [
            .init(frequency: 440.0, power: 0.00005, prominence: 50.0)
        ]
        #expect(FaithfulSpectralKernels.hasUnfoldedPitchSupport(peaks: lowPower, minimumPower: 0.0001) == false)
    }

    // MARK: - 4. Biquad and Bandpass Filter Tests

    @Test("bandpassFilter matches exact 10-sample impulse response from reference implementation")
    func bandpassImpulseResponse() {
        var impulse = [Double](repeating: 0, count: 10)
        impulse[0] = 1.0

        FaithfulNumericKernels.bandpassFilterInPlace(&impulse, sampleRate: 48000.0)

        let expected: [Double] = [
            0.00003095116211047618,
            0.00023433813060034966,
            0.0008739064601422029,
            0.002208289811959668,
            0.004374755355492824,
            0.007382168264900827,
            0.011145710482577113,
            0.015516270467844179,
            0.02030496591766542,
            0.025303250666112262
        ]

        for (i, exp) in expected.enumerated() {
            #expect(abs(impulse[i] - exp) < 1e-12)
        }
    }

    @Test("bandpassFilter starts with zero state on every window (no persistent state)")
    func bandpassFilterZeroStatePerWindow() {
        let input = [Double](repeating: 1.0, count: 100)
        let run1 = FaithfulNumericKernels.bandpassFilter(samples: input, sampleRate: 48000.0)
        let run2 = FaithfulNumericKernels.bandpassFilter(samples: input, sampleRate: 48000.0)
        #expect(run1 == run2)
    }

    @Test("bandpassFilter passes 440 Hz in-band tone while strongly attenuating 50 Hz and 5 kHz out-of-band tones")
    func bandpassFrequencyResponse() {
        let rate = 48000.0
        let n = 2000

        func rmsAfterBandpass(freq: Double) -> Double {
            var sig = [Double](repeating: 0, count: n)
            for i in 0..<n {
                sig[i] = sin(2.0 * Double.pi * freq * Double(i) / rate)
            }
            FaithfulNumericKernels.bandpassFilterInPlace(&sig, sampleRate: rate)
            // discard startup
            let steady = sig.suffix(from: 500)
            let energy = steady.reduce(0.0) { $0 + $1 * $1 }
            return sqrt(energy / Double(steady.count))
        }

        let rms440 = rmsAfterBandpass(freq: 440.0)
        let rms50 = rmsAfterBandpass(freq: 50.0)
        let rms5000 = rmsAfterBandpass(freq: 5000.0)

        // 440 Hz is inside passband (100 Hz - 1200 Hz), attenuation should be small (~0.707 input RMS is ~0.707)
        #expect(rms440 > 0.6)
        // 50 Hz is below 100 Hz highpass
        #expect(rms50 < 0.25)
        // 5000 Hz is far above 1200 Hz lowpass
        #expect(rms5000 < 0.05)
    }

    // MARK: - 5. Butterworth Anti-Alias and Float32 Intermediate Rounding Tests

    @Test("butterworthAntiAlias matches exact 10-sample impulse response and mirrors Float32 intermediate")
    func butterworthAntiAliasImpulseAndFloat32Rounding() {
        var impulse = [Double](repeating: 0, count: 10)
        impulse[0] = 1.0

        let decimatedRate = 48000.0 / 4.0 // 12000
        FaithfulNumericKernels.butterworthAntiAliasFilterInPlace(&impulse, sampleRate: 48000.0, decimatedRate: decimatedRate)

        let expectedFloat64: [Double] = [
            8.881993231458804e-7,
            0.000012424509426046048,
            0.00008516077298413309,
            0.00038394680200199246,
            0.00129003531718417,
            0.0034692393818311733,
            0.007826042836087701,
            0.015307575200660773,
            0.026598047788717615,
            0.041802151023347306
        ]

        for (i, exp) in expectedFloat64.enumerated() {
            #expect(abs(impulse[i] - exp) < 1e-12)
        }

        // Apply Float32 intermediate rounding
        let rounded = FaithfulNumericKernels.mirrorFloat32Intermediate(impulse)
        let expectedFloat32: [Double] = [
            8.88199338078266e-7,
            0.000012424509804986883,
            0.0000851607765071094,
            0.0003839468117803335,
            0.0012900353176519275,
            0.003469239454716444,
            0.007826043292880058,
            0.015307575464248657,
            0.026598047465085983,
            0.04180214926600456
        ]

        for (i, exp) in expectedFloat32.enumerated() {
            #expect(abs(rounded[i] - exp) < 1e-14)
        }
    }

    // MARK: - 6. Box Decimation Tests

    @Test("boxDecimate produces correct stride and sample averaging across sample rates")
    func boxDecimateStrides() {
        // At 48000 Hz, stride = floor(48000 / 12000) = 4
        #expect(FaithfulNumericKernels.decimationStride(sampleRate: 48000.0) == 4)
        // At 44100 Hz, stride = floor(44100 / 12000) = 3
        #expect(FaithfulNumericKernels.decimationStride(sampleRate: 44100.0) == 3)
        // At 96000 Hz, stride = floor(96000 / 12000) = 8
        #expect(FaithfulNumericKernels.decimationStride(sampleRate: 96000.0) == 8)
        // At 11025 Hz, stride = max(1, floor(11025 / 12000)) = 1
        #expect(FaithfulNumericKernels.decimationStride(sampleRate: 11025.0) == 1)

        // Test box average on [1, 2, 3, 4, 5, 6, 7, 8] with stride 4
        let input: [Float] = [1, 2, 3, 4, 5, 6, 7, 8]
        // Stride 4 -> length = 2.
        // Box 0: (1+2+3+4)/4 = 2.5
        // Box 1: (5+6+7+8)/4 = 6.5
        // Mean = 4.5
        // Box 0 after mean removal = -2.0, Box 1 after mean removal = 2.0
        let resultWithMeanRemoval = FaithfulNumericKernels.boxDecimate(input: input, sampleRate: 48000.0, removeMean: true)
        #expect(resultWithMeanRemoval.stride == 4)
        #expect(resultWithMeanRemoval.samples.count == 2)
        #expect(abs(resultWithMeanRemoval.samples[0] - (-2.0)) < 1e-9)
        #expect(abs(resultWithMeanRemoval.samples[1] - 2.0) < 1e-9)

        let resultWithoutMeanRemoval = FaithfulNumericKernels.boxDecimate(input: input, sampleRate: 48000.0, removeMean: false)
        #expect(abs(resultWithoutMeanRemoval.samples[0] - 2.5) < 1e-9)
        #expect(abs(resultWithoutMeanRemoval.samples[1] - 6.5) < 1e-9)
    }

    // MARK: - 7. Lag Difference and Parabolic Refinement Tests

    @Test("refineLag recovers integer and fractional periods with reference values")
    func refineLagIntegerAndFractional() {
        let rate = 48000.0

        // Integer period: 100 samples (480 Hz)
        var sigInt = [Double](repeating: 0, count: 2000)
        for i in 0..<2000 {
            sigInt[i] = sin(2.0 * Double.pi * Double(i) / 100.0)
        }
        let rInt = FaithfulNumericKernels.refineLag(
            signal: sigInt,
            sampleRate: rate,
            first: 80,
            last: 120,
            windowEnd: 1800,
            searchStart: 0,
            scoreStart: 500
        )
        #expect(abs(rInt.frequency - 480.0) < 1e-6)
        #expect(rInt.residual < 1e-12)

        // Fractional period: 100.25 samples (478.80299... Hz)
        var sigFrac = [Double](repeating: 0, count: 2000)
        for i in 0..<2000 {
            sigFrac[i] = sin(2.0 * Double.pi * Double(i) / 100.25)
        }
        let rFrac = FaithfulNumericKernels.refineLag(
            signal: sigFrac,
            sampleRate: rate,
            first: 80,
            last: 120,
            windowEnd: 1800,
            searchStart: 0,
            scoreStart: 500
        )
        #expect(abs(rFrac.frequency - 478.80317999938757) < 1e-5)
        #expect(abs(rFrac.residual - 0.00012220210701851392) < 1e-8)
    }

    // MARK: - 8. Filtered Period Residual Tests

    @Test("filteredPeriodResidual matches reference on 440 Hz tone and rejects off-pitch")
    func filteredPeriodResidualReference() {
        let rate = 48000.0
        var input = [Float](repeating: 0, count: 4096)
        for i in 0..<4096 {
            input[i] = Float(0.1 * sin(2.0 * Double.pi * 440.0 * Double(i) / rate))
        }

        let res440 = FaithfulNumericKernels.filteredPeriodResidual(input: input, sampleRate: rate, frequency: 440.0)
        let res300 = FaithfulNumericKernels.filteredPeriodResidual(input: input, sampleRate: rate, frequency: 300.0)

        // Reference JS: res440: 2.2441618155072814e-8, res300: 1.9783180501766158
        #expect(abs(res440 - 2.2441618155072814e-8) < 1e-10)
        #expect(abs(res300 - 1.9783180501766158) < 1e-6)
    }
}
