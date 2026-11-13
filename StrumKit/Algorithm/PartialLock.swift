// StrumKit/Algorithm/PartialLock.swift
import Foundation

/// Measures the frequency of one partial of the sounding string, precisely.
///
/// The detector underneath answers *which note is sounding*. It does that from the whole
/// waveform over 85 ms, and the frequency it reports is whatever period best explains every
/// partial at once. On a real string that number is not stable: the partials are not exact
/// multiples of each other, they decay at different rates, and as the note fades the
/// estimate is pulled around by noise. Measured on the recorded fixtures it wanders by ten
/// cents and more through a decay during which the string itself does not move by one.
///
/// This stage answers a narrower question — *exactly how fast is the string vibrating* —
/// and answers it partial by partial, each in its own narrow band, where the string is tens
/// of decibels above the noise long after the waveform as a whole is not. It takes the
/// detector's note as the place to look, finds the peak of the windowed spectrum at each of
/// the first few partials over a longer window, and then follows those peaks from hop to
/// hop on its own.
///
/// No single partial is trusted. On the recordings a fundamental 35 dB above the noise
/// still swings by four cents — a real string vibrates in two planes at slightly different
/// rates, and the two beat — while the third and fourth partials of the same note hold
/// still. So every measurable partial votes, weighted by how steady it has actually been
/// and by how far it stands above the noise. A turn of the peg moves all of them together
/// and passes straight through; one partial's wobble is outvoted.
///
/// Partials of a real string are not exact multiples of the fundamental. Each one's
/// offset from the lowest is learned while the note sounds, so the reading is the pitch of
/// the lowest measurable partial, steadied by the others, and does not shift when one of
/// them fades.
///
/// What it will not do is name a note by itself. A lock starts only where the detector
/// pointed, moves only as far as a string can be turned between hops, and is dropped when
/// the detector keeps pointing somewhere else.
final class PartialLock {
    struct Tuning: Sendable, Equatable {
        /// Length of the analysis window. Precision improves with the 1.5th power of this,
        /// and the reading lags a moving pitch by half of it.
        var windowSeconds: Double = 0.170
        /// The window a lock starts with, and the one used while the pitch is moving, so
        /// that an onset is not diluted by what came before it and a peg turn is followed
        /// rather than averaged.
        var shortWindowSeconds: Double = 0.085
        /// How far from where it is expected a partial is searched for, in cents.
        var acquireCents: Double = 55
        var followCents: Double = 35
        /// A partial has to stand this far above the noise around it to start a lock, and
        /// this far to vote in one.
        var acquireSNR: Double = 24
        var holdSNR: Double = 20
        /// A partial this far above the noise is too rough to vote, but it is there: it
        /// can be the one the reading is referred to, with the steadier ones above it
        /// supplying the precision.
        var presentSNR: Double = 14
        /// The highest partial measured.
        var maxPartial: Int = 4
        /// How long a lock may carry on with no agreement from the detector.
        var unsupportedMs: Double = 2000
        /// The detector has to disagree this many hops in a row, consistently, before a
        /// lock is given up for a different note.
        var disagreementHops: Int = 2
        /// A steady drift faster than this, in cents per hop, counts as the pitch moving.
        var movingCentsPerHop: Double = 1.2
        /// A new lock says nothing until two hops running agree to within this many cents,
        /// or this long has passed. The first window after a pluck is mostly the pluck.
        var settleCents: Double = 3
        var settleMs: Double = 130
    }

    struct Measurement: Sendable, Equatable {
        /// The pitch of the string, in Hz.
        var frequency: Double
        /// How many partials voted.
        var partials: Int
        /// How far the clearest of them stands above the noise around it, in dB.
        var snr: Double
        /// Whether the detector agreed on this hop, or the lock carried the note alone.
        var supported: Bool
    }

    private struct Partial {
        /// Where this partial reads relative to the anchor, in cents.
        var offset = 0.0
        /// How far it has been straying from the consensus, in cents squared.
        var variance = 4.0
        var hops = 0
    }

    private struct Lock {
        var frequency: Double          // the string's pitch, Hz
        var startedAt: Double          // ms
        var lastSupported: Double      // ms
        var trend = 0.0                // signed, smoothed motion in cents per hop
        var anchor: Int
        /// The reading's level relative to the anchor's, in cents. Zero, except while the
        /// lock is easing over to a lower partial that came out of the noise late.
        var level = 0.0
        var settled = false
        var partials: [Int: Partial] = [:]
    }

    let tuning: Tuning
    private var lock: Lock?
    private var dissent: (frequency: Double, count: Int)?
    private var window: [Double] = []
    private var windowLength = 0
    private var bandReal: [Double] = []
    private var bandImaginary: [Double] = []
    private var bandCount = 0
    private var bandStep = 0.0

    init(tuning: Tuning = Tuning()) {
        self.tuning = tuning
    }

    func reset() {
        lock = nil
        dissent = nil
    }

    /// - Parameters:
    ///   - history: the most recent audio, newest last. As much as is available, up to the
    ///     analysis window; less is fine.
    ///   - coarse: what the detector made of this hop, or `nil`.
    ///   - range: the frequencies a string may have.
    func measure(
        history: ArraySlice<Float>,
        sampleRate: Double,
        coarse: Double?,
        range: ClosedRange<Double>,
        timeMs: Double
    ) -> Measurement? {
        // Decide where to look.
        if let coarse {
            if let current = lock, abs(cents(coarse, current.frequency)) <= 60 {
                lock?.lastSupported = timeMs
                dissent = nil
            } else if lock != nil {
                if let d = dissent, abs(cents(coarse, d.frequency)) <= 60 {
                    dissent = (coarse, d.count + 1)
                } else {
                    dissent = (coarse, 1)
                }
                if dissent!.count >= tuning.disagreementHops {
                    lock = nil
                    dissent = nil
                }
            }
        }
        if let current = lock, timeMs - current.lastSupported > tuning.unsupportedMs {
            lock = nil
        }

        let acquiring = lock == nil
        guard let center = lock?.frequency ?? coarse, range.contains(center) else { return nil }

        // A new lock starts on the short window and grows into the long one, so nothing
        // from before the note began is measured as part of it.
        var seconds = tuning.windowSeconds
        if let current = lock {
            seconds = min(seconds, tuning.shortWindowSeconds + (timeMs - current.startedAt) / 1000)
            if abs(current.trend) > tuning.movingCentsPerHop { seconds = tuning.shortWindowSeconds }
        } else {
            seconds = tuning.shortWindowSeconds
        }
        let length = min(history.count, max(256, Int((seconds * sampleRate).rounded())))
        guard length >= 256 else { return nil }
        prepare(history: history, length: length)
        let duration = Double(length) / sampleRate

        let span = acquiring ? tuning.acquireCents : tuning.followCents
        let highest = min(tuning.maxPartial, Int(sampleRate * 0.45 / center))
        guard highest >= 1 else { return nil }
        let binHz = sampleRate / Double(length)

        struct Vote { var k: Int; var cents: Double; var snr: Double; var power: Double; var sigma2: Double; var votes: Bool }
        var votes: [Vote] = []
        for k in 1...highest {
            let offset = lock?.settled == true ? (lock?.partials[k]?.offset ?? 0) : 0
            let expected = center * Double(k) * pow(2, offset / 1200)
            let spanHz = expected * (pow(2, span / 1200) - 1)
            mixDown(to: expected, reach: spanHz + 6.5 * binHz, sampleRate: sampleRate)

            let p = peak(spanHz: spanHz, binHz: binHz)
            // A maximum at the edge of the search is the skirt of something else.
            guard abs(p.offsetHz) < spanHz * 0.97 else { continue }
            let found = expected + p.offsetHz
            let floor = noiseFloor(around: p.offsetHz, fundamental: center, binHz: binHz)
            let ratio = max(p.power, 1e-300) / max(floor, 1e-300)
            let snr = 10 * log10(ratio)
            guard snr >= tuning.presentSNR else { continue }
            // A steady tone through this window has one shape: a bin either side of the
            // peak it is down to a quarter. Anything else is not a steady tone.
            let shape = (power(offsetHz: p.offsetHz - binHz) + power(offsetHz: p.offsetHz + binHz)) / (2 * p.power)
            guard shape > 0.08, shape < (lock?.settled == true ? 0.6 : 0.9) else { continue }
            // What noise alone does to a peak this far above it, over a window this long.
            let sigmaHz = 0.8 / (duration * ratio.squareRoot())
            let sigmaNoise = 1731.0 * sigmaHz / (center * Double(k))
            let sigmaShape = 50.0 * abs(shape - 0.25)
            votes.append(Vote(
                k: k,
                cents: 1200 * log2(found / expected) + offset,
                snr: snr,
                power: p.power,
                sigma2: sigmaNoise * sigmaNoise + sigmaShape * sigmaShape,
                votes: snr >= tuning.holdSNR))
        }

        // Until a lock has settled it is started again on every hop: which partial is
        // the lowest clear one, and where the others sit relative to it, are both
        // questions the pluck itself answers badly.
        if acquiring || lock?.settled == false {
            let strongest = votes.map(\.power).max() ?? 0
            // The lowest partial that is clearly there, and not a footnote to the others.
            // Something has to be well clear of the noise for there to be a note at all;
            // given that, the reading is taken from the lowest partial that can vote.
            guard votes.contains(where: { $0.snr >= tuning.acquireSNR }),
                  let anchor = votes.first(where: { $0.power >= strongest * 0.01 }) else {
                if acquiring { return nil }
                lock = nil
                return nil
            }
            var fresh = Lock(
                frequency: center,
                startedAt: lock?.startedAt ?? timeMs,
                lastSupported: lock?.lastSupported ?? timeMs,
                anchor: anchor.k)
            for vote in votes { fresh.partials[vote.k] = Partial(offset: vote.cents - anchor.cents) }
            lock = fresh
        }
        guard var current = lock else { return nil }

        // Each vote, with its learned offset taken out, is an estimate of the same thing.
        var estimates: [(k: Int, value: Double, weight: Double)] = []
        for vote in votes where vote.votes {
            guard let partial = current.partials[vote.k] else { continue }
            estimates.append((vote.k, vote.cents - partial.offset, 1.0 / (partial.variance + vote.sigma2)))
        }
        if estimates.count >= 3 {
            let sorted = estimates.map(\.value).sorted()
            let median = sorted[sorted.count / 2]
            estimates.removeAll { abs($0.value - median) > 15 }
        }
        guard !estimates.isEmpty else {
            // Nothing measurable where the note was. Without the detector's say-so there
            // is no note.
            if coarse == nil || dissent != nil { lock = nil }
            return nil
        }
        let weightSum = estimates.reduce(0) { $0 + $1.weight }
        let fused = estimates.reduce(0) { $0 + $1.value * $1.weight } / weightSum

        // Learn how steady each partial is, and where it sits relative to the anchor. The
        // offset is measured against the anchor itself, never against the consensus: a
        // consensus that taught the offsets it is built from would be free to drift.
        let anchorCents = votes.first(where: { $0.k == current.anchor })?.cents
        for vote in votes {
            if var partial = current.partials[vote.k] {
                if vote.votes {
                    let residual = vote.cents - partial.offset - fused
                    partial.variance += 0.1 * (min(residual * residual, 400) - partial.variance)
                }
                partial.hops += 1
                if vote.k != current.anchor, let anchorCents {
                    let difference = vote.cents - anchorCents
                    if abs(difference - partial.offset) < 25 {
                        partial.offset += max(0.06, 1.0 / Double(partial.hops)) * (difference - partial.offset)
                    }
                }
                current.partials[vote.k] = partial
            } else {
                // A partial that has only now come out of the noise joins where the
                // consensus already is.
                current.partials[vote.k] = Partial(offset: vote.cents - fused)
            }
        }

        // The reading belongs to the lowest partial there is. If one lower than the
        // anchor has since become a steady voter, ease the level over to it — slowly,
        // because the two differ by a few cents and the needle should not step.
        var lowestOffset = 0.0
        if let lowest = votes.first(where: { ($0.k < current.anchor) && (current.partials[$0.k]?.hops ?? 0) >= 12 }),
           let partial = current.partials[lowest.k], partial.variance < 9 {
            lowestOffset = partial.offset
        }
        let step = 0.12 // cents per hop: about six cents a second
        current.level += max(-step, min(step, lowestOffset - current.level))

        let frequency = center * pow(2, fused / 1200)
        guard range.contains(frequency) else {
            lock = nil
            return nil
        }
        current.trend = acquiring ? 0 : current.trend + 0.3 * (fused - current.trend)
        current.frequency = frequency
        if !current.settled, !acquiring {
            current.settled = abs(fused) <= tuning.settleCents || timeMs - current.startedAt >= tuning.settleMs
        }
        lock = current
        guard current.settled else { return nil }

        return Measurement(
            frequency: frequency * pow(2, current.level / 1200),
            partials: estimates.count,
            snr: votes.map(\.snr).max() ?? 0,
            supported: current.lastSupported == timeMs
        )
    }

    // MARK: - Spectrum, evaluated only where it is needed

    private func cents(_ a: Double, _ b: Double) -> Double { 1200 * log2(a / b) }

    /// Copies the newest `length` samples, mean removed and Hann-windowed.
    private func prepare(history: ArraySlice<Float>, length: Int) {
        if window.count < length { window = [Double](repeating: 0, count: length) }
        windowLength = length
        let start = history.endIndex - length
        var mean = 0.0
        for i in 0..<length { mean += Double(history[start + i]) }
        mean /= Double(length)
        let scale = 2.0 * Double.pi / Double(length - 1)
        for i in 0..<length {
            window[i] = (Double(history[start + i]) - mean) * (0.5 - 0.5 * cos(scale * Double(i)))
        }
    }

    /// Shifts the windowed signal down so that `frequency` sits at zero, and sums it in
    /// blocks. Everything within `reach` Hz of that frequency survives intact, at a
    /// fraction of the length — so the many looks at the spectrum that one partial needs
    /// each cost a hundred-odd samples instead of several thousand.
    private func mixDown(to frequency: Double, reach: Double, sampleRate: Double) {
        let block = max(1, min(64, Int(0.25 * sampleRate / max(reach, 1))))
        let count = windowLength / block
        if bandReal.count < count {
            bandReal = [Double](repeating: 0, count: count)
            bandImaginary = [Double](repeating: 0, count: count)
        }
        bandCount = count
        bandStep = Double(block) / sampleRate
        let omega = 2.0 * Double.pi * frequency / sampleRate
        let stepCos = cos(omega), stepSin = sin(omega)
        window.withUnsafeBufferPointer { samples in
            for m in 0..<count {
                let start = m * block
                // Exact at the start of every block, so the rotation cannot drift.
                var c = cos(omega * Double(start)), s = -sin(omega * Double(start))
                var re = 0.0, im = 0.0
                for i in start..<(start + block) {
                    let x = samples[i]
                    re += x * c
                    im += x * s
                    let next = c * stepCos + s * stepSin
                    s = s * stepCos - c * stepSin
                    c = next
                }
                bandReal[m] = re
                bandImaginary[m] = im
            }
        }
    }

    /// Power of the signal at `offsetHz` from the frequency last mixed down to.
    private func power(offsetHz: Double) -> Double {
        let omega = 2.0 * Double.pi * offsetHz * bandStep
        let stepCos = cos(omega), stepSin = sin(omega)
        var c = 1.0, s = 0.0
        var re = 0.0, im = 0.0
        for m in 0..<bandCount {
            // (a + jb)(c - js)
            re += bandReal[m] * c + bandImaginary[m] * s
            im += bandImaginary[m] * c - bandReal[m] * s
            let next = c * stepCos - s * stepSin
            s = s * stepCos + c * stepSin
            c = next
        }
        return re * re + im * im
    }

    /// Where, within `spanHz` of the frequency mixed down to, the spectrum peaks.
    private func peak(spanHz: Double, binHz: Double) -> (offsetHz: Double, power: Double) {
        // A grid fine enough that the main lobe cannot fall between two points.
        let steps = max(5, min(25, Int((2 * spanHz / binHz).rounded(.up)))) | 1
        var best = 0
        var bestPower = -1.0
        for i in 0..<steps {
            let p = power(offsetHz: -spanHz + 2 * spanHz * Double(i) / Double(steps - 1))
            if p > bestPower { bestPower = p; best = i }
        }
        var low = -spanHz + 2 * spanHz * Double(max(0, best - 1)) / Double(steps - 1)
        var high = -spanHz + 2 * spanHz * Double(min(steps - 1, best + 1)) / Double(steps - 1)

        let golden = 0.6180339887498949
        var a = high - golden * (high - low), b = low + golden * (high - low)
        var pa = power(offsetHz: a), pb = power(offsetHz: b)
        let tolerance = binHz * 0.0005
        while high - low > tolerance {
            if pa > pb {
                high = b; b = a; pb = pa
                a = high - golden * (high - low); pa = power(offsetHz: a)
            } else {
                low = a; a = b; pa = pb
                b = low + golden * (high - low); pb = power(offsetHz: b)
            }
        }
        return ((low + high) / 2, max(pa, pb, bestPower))
    }

    /// The level just either side of a partial, clear of its own main lobe and of its
    /// neighbours. Measured locally because noise is not flat: a floor taken from across
    /// the spectrum flatters the low partials, which sit where the rumble is.
    private func noiseFloor(around offsetHz: Double, fundamental: Double, binHz: Double) -> Double {
        let near = min(3.5 * binHz, 0.33 * fundamental)
        let far = min(5.5 * binHz, 0.45 * fundamental)
        var probes = [
            power(offsetHz: offsetHz - far),
            power(offsetHz: offsetHz - near),
            power(offsetHz: offsetHz + near),
            power(offsetHz: offsetHz + far),
        ]
        probes.sort()
        return (probes[1] + probes[2]) / 2
    }
}
